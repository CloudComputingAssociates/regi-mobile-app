import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:provider/provider.dart';

import '../models/tether.dart';
import '../services/auth_service.dart';
import '../services/avatar_service.dart';
import '../services/tether_identity.dart';
import '../services/tether_service.dart';
import '../services/user_food_service.dart';
import '../widgets/close_disk_button.dart';

/// The phone's capture surface — the "Camera" screen reached from the left-nav
/// drawer. It fulfills a device command the web app queued for this phone.
///
/// TRANSPORT: commands ride the tether poll heartbeat (POST /api/tether/poll),
/// at-least-once — the server redelivers a command every poll until we ack it
/// (POST /api/tether/ack) or it TTL-expires. The app-root presence loop ignores
/// commands; THIS screen is what polls, shows what's queued, captures, uploads
/// to the API by id, then acks. Redelivery-until-ack is why nothing pops the
/// camera unbidden: the request just waits here until the user fulfills it.
///
/// Command types handled:
///   • captureMeal   → mealId → POST /image/upload/product (source=meal)
///   • captureAvatar → POST /image/upload/avatar
///
/// No pending command → empty state; there's simply nothing to capture.
class CameraScreen extends StatefulWidget {
  const CameraScreen({super.key});

  @override
  State<CameraScreen> createState() => _CameraScreenState();
}

class _CameraScreenState extends State<CameraScreen> {
  static const Color _bg = Color(0xFF1B1B1B);
  static const Color _scanRed = Color(0xFFFF3B30);

  // Capture kinds (from the command's `capture.kind`). All but avatar upload to
  // the product image endpoint; only source/target id differ. See _usePhoto.
  static const String _kindMeal = 'meal';
  static const String _kindFood = 'food';
  static const String _kindMealset = 'mealset';
  static const String _kindAvatar = 'avatar';

  final TetherService _tether = TetherService();
  final TetherIdentity _identity = TetherIdentity();
  final UserFoodService _foods = UserFoodService();
  final AvatarService _avatars = AvatarService();

  // Messages already fulfilled (acked) this session, so a redelivered command
  // is ignored instead of re-shot. De-dupe key is the messageId.
  final Set<String> _handled = {};

  // True while a poll (initial or post-ack) is in flight.
  bool _loading = true;
  // This device's server id (from tether register), needed to poll + ack.
  int? _deviceId;
  // The command we're currently fulfilling, or null when nothing's queued.
  MobileCommand? _command;
  // A freshly-taken photo held for preview until the user commits it with
  // "Use photo". Cleared on retake and after a successful upload.
  Uint8List? _pendingPhoto;
  // Upload + ack in flight.
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    _loadNext();
  }

  @override
  void dispose() {
    _tether.dispose();
    _foods.dispose();
    _avatars.dispose();
    super.dispose();
  }

  /// Poll the heartbeat for queued commands and surface the first un-handled
  /// one. Runs on open, on "Check again", and after each successful ack.
  Future<void> _loadNext() async {
    final auth = context.read<AuthService>();
    setState(() {
      _loading = true;
      _pendingPhoto = null;
    });
    final deviceId = _deviceId ?? await _identity.savedDeviceId();
    final jwt = await auth.getAccessToken();
    if (deviceId == null || jwt == null) {
      if (!mounted) return;
      setState(() {
        _deviceId = deviceId;
        _command = null;
        _loading = false;
      });
      _toast(deviceId == null
          ? 'This phone isn’t registered yet — reopen the app.'
          : 'Not authenticated.');
      return;
    }
    _deviceId = deviceId;
    try {
      final res = await _tether.poll(deviceId, jwt);
      // First un-handled command that has a resolvable capture target.
      MobileCommand? next;
      for (final c in res.commands) {
        if (!_handled.contains(c.messageId) && c.target != null) {
          next = c;
          break;
        }
      }
      if (!mounted) return;
      setState(() {
        _command = next;
        _loading = false;
      });
    } on TetherException catch (e) {
      if (!mounted) return;
      setState(() {
        _command = null;
        _loading = false;
      });
      _toast('Request check failed: HTTP ${e.statusCode}');
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _command = null;
        _loading = false;
      });
      _toast('Request check error: $e');
    }
  }

  /// Open the device camera. On web this is a file input with
  /// `capture=environment`, so it works on iOS Safari too. Downscaled at
  /// capture (the server resizes to 720×720 + an 80×80 thumb anyway).
  Future<void> _takePic() async {
    try {
      final shot = await ImagePicker().pickImage(
        source: ImageSource.camera,
        maxWidth: 1280,
        maxHeight: 1280,
        imageQuality: 85,
      );
      if (shot == null) return; // user cancelled
      final bytes = await shot.readAsBytes();
      if (!mounted) return;
      setState(() => _pendingPhoto = bytes);
      // Auto-upload: the camera already gave an accept/retake moment before the
      // shot came back, so a second in-app confirm is redundant. Go straight to
      // upload; on failure the photo stays with a Retake button.
      await _usePhoto();
    } catch (e) {
      _toast('Camera unavailable: $e');
    }
  }

  /// Upload the committed photo to the endpoint this command's KIND maps to,
  /// then ack (done) with kind+id so the server advances its cursor and the web
  /// can route its refresh, then pull the next queued command.
  Future<void> _usePhoto() async {
    final cmd = _command;
    final target = cmd?.target;
    final photo = _pendingPhoto;
    final deviceId = _deviceId;
    if (cmd == null || target == null || photo == null || deviceId == null) {
      return;
    }
    final auth = context.read<AuthService>();
    setState(() => _saving = true);
    final jwt = await auth.getAccessToken();
    if (jwt == null) {
      if (!mounted) return;
      setState(() => _saving = false);
      _toast('Not authenticated.');
      return;
    }
    // STEP 1 — upload by kind. meal/food/mealset all POST to the product image
    // endpoint (only source + target id differ); avatar goes to its own
    // endpoint, keyed off the JWT user (id is null).
    final isProductUpload = target.kind != _kindAvatar;
    String? cdnUrl;
    try {
      switch (target.kind) {
        case _kindMeal:
          cdnUrl = await _foods.uploadProductImage(
              _requireId(target), jwt, photo,
              source: 'meal');
          break;
        case _kindFood:
        case _kindMealset:
          // mealset attaches to the same product row as food (source=user);
          // confirm the entity id with the API team if this ever diverges.
          cdnUrl = await _foods.uploadProductImage(
              _requireId(target), jwt, photo,
              source: 'user');
          break;
        case _kindAvatar:
          await _avatars.uploadAvatar(photo, 'avatar.jpg', jwt);
          break;
        default:
          throw FormatException('unsupported capture kind ${target.kind}');
      }
      debugPrint('CAMERA upload OK kind=${target.kind} id=${target.id} '
          'cdnUrl=$cdnUrl');
    } on UserFoodException catch (e) {
      _uploadFailed('Upload rejected: HTTP ${e.statusCode} ${_trim(e.body)}');
      return;
    } on AvatarException catch (e) {
      _uploadFailed('Upload rejected: HTTP ${e.statusCode} ${_trim(e.body)}');
      return;
    } catch (e) {
      _uploadFailed('Upload error: $e');
      return;
    }

    // A product upload that returns 200 but NO cdn_url means the API didn't
    // store to GCS — surface that instead of a false "done".
    if (isProductUpload && cdnUrl == null) {
      _uploadFailed('API accepted the upload but returned no image URL — '
          'nothing was stored to GCS.');
      return;
    }

    // Result echoed to the web so it can route its refresh: kind + id (+ url).
    final result = <String, dynamic>{
      'kind': target.kind,
      if (target.id != null) 'id': target.id,
      if (cdnUrl != null) 'cdnUrl': cdnUrl,
    };

    // STEP 2 — ack so the server advances its cursor and echoes the result to
    // the web. Mark handled first so a redelivery mid-ack doesn't re-shoot.
    _handled.add(cmd.messageId);
    try {
      await _tether.ack(deviceId, cmd.messageId, 'done', jwt, result: result);
      debugPrint('CAMERA ack OK messageId=${cmd.messageId}');
    } on TetherException catch (e) {
      // Photo IS uploaded; only the ack failed. Don't unmark — re-acking is a
      // safe no-op and we don't want to re-shoot. Tell the user plainly.
      if (!mounted) return;
      setState(() => _saving = false);
      _toast('Uploaded ✓ but ack failed: HTTP ${e.statusCode} — '
          'web may not refresh. ${_trim(e.body)}');
      return;
    } catch (e) {
      if (!mounted) return;
      setState(() => _saving = false);
      _toast('Uploaded ✓ but ack error: $e');
      return;
    }

    if (!mounted) return;
    setState(() => _saving = false);
    _toast(cdnUrl != null ? 'Uploaded ✓ → $cdnUrl' : 'Uploaded ✓');
    await _loadNext();
  }

  /// Common failure path for a failed upload: don't mark handled (so the
  /// command redelivers for a retry), stop the spinner, surface the reason.
  void _uploadFailed(String message) {
    _handled.remove(_command?.messageId ?? '');
    if (!mounted) return;
    setState(() => _saving = false);
    _toast(message);
  }

  /// Trim an API error body so a long HTML/JSON payload doesn't blow out the
  /// toast.
  static String _trim(String body) {
    final s = body.replaceAll('\n', ' ').trim();
    return s.length > 140 ? '${s.substring(0, 140)}…' : s;
  }

  void _toast(String msg) {
    if (!mounted) return;
    final m = ScaffoldMessenger.of(context);
    m.hideCurrentSnackBar();
    m.showSnackBar(SnackBar(
      content: Text(msg),
      behavior: SnackBarBehavior.floating,
      duration: const Duration(seconds: 3),
    ));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: _bg,
      appBar: AppBar(
        backgroundColor: _bg,
        foregroundColor: Colors.white,
        automaticallyImplyLeading: false,
        title: const Text('Camera'),
        actions: [
          CloseDiskButton(onClose: () => Navigator.of(context).maybePop()),
        ],
      ),
      body: SafeArea(
        child: _loading
            ? const Center(child: CircularProgressIndicator(color: _scanRed))
            : _command == null
                ? _emptyState()
                : _commandBody(_command!),
      ),
    );
  }

  /// No command queued — the user opened the screen with nothing to shoot.
  Widget _emptyState() {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(28),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.photo_camera_outlined,
                color: Colors.white24, size: 64),
            const SizedBox(height: 16),
            const Text(
              'Nothing to capture',
              style: TextStyle(color: Colors.white, fontSize: 17),
            ),
            const SizedBox(height: 8),
            const Text(
              'Ask from the web app (it has to see this phone connected). '
              'The request shows up here.',
              textAlign: TextAlign.center,
              style: TextStyle(color: Colors.white54, fontSize: 13),
            ),
            const SizedBox(height: 20),
            OutlinedButton.icon(
              onPressed: _loadNext,
              icon: const Icon(Icons.refresh, size: 18),
              label: const Text('Check again'),
              style: OutlinedButton.styleFrom(
                foregroundColor: Colors.white,
                side: const BorderSide(color: Colors.white24),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _commandBody(MobileCommand cmd) {
    final target = cmd.target!; // selection guarantees a non-null target
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(20, 20, 20, 32),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            _headingFor(target),
            style: const TextStyle(
              color: Colors.white,
              fontSize: 18,
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: 16),
          _pictureBox(),
          const SizedBox(height: 16),
          _actionButton(),
        ],
      ),
    );
  }

  /// What we're capturing. Prefer the target's name ("Take a photo — {name}")
  /// so the user knows the subject; fall back to a kind label (+ id) for a
  /// legacy/nameless target. Avatar always reads "Profile photo".
  String _headingFor(CaptureTarget t) {
    if (t.kind == _kindAvatar) return 'Profile photo';
    if (t.name.isNotEmpty) return 'Take a photo — ${t.name}';
    final label = switch (t.kind) {
      _kindMeal => 'Meal Photo',
      _kindFood => 'Food Photo',
      _kindMealset => 'MealSet Photo',
      _ => 'Capture (${t.kind})',
    };
    return t.id != null ? '$label (#${t.id})' : label;
  }

  /// The entity id required for a product upload (meal/food/mealset). Throws a
  /// FormatException — caught by [_usePhoto] — if the command arrived without
  /// one, rather than uploading to a null id.
  int _requireId(CaptureTarget t) {
    final id = t.id;
    if (id == null) {
      throw FormatException('${t.kind} capture without an id');
    }
    return id;
  }

  /// Just the image (or placeholder) with an "Uploading…" overlay while the
  /// upload is in flight. No buttons on the image — the action lives in the
  /// full-width button below, so it can't be mistaken for part of the photo.
  Widget _pictureBox() {
    final pending = _pendingPhoto;
    return AspectRatio(
      aspectRatio: 1,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(12),
        child: Stack(
          fit: StackFit.expand,
          children: [
            if (pending != null)
              Image.memory(pending, fit: BoxFit.cover)
            else
              _placeholder(),
            if (_saving)
              Container(
                color: Colors.black54,
                alignment: Alignment.center,
                child: const Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    CircularProgressIndicator(color: _scanRed),
                    SizedBox(height: 12),
                    Text('Uploading…',
                        style: TextStyle(color: Colors.white, fontSize: 14)),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _placeholder() {
    return Container(
      color: Colors.black,
      alignment: Alignment.center,
      child: const Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.photo_camera, color: Colors.white24, size: 56),
          SizedBox(height: 8),
          Text(
            'Tap the button below to take the photo',
            style: TextStyle(color: Colors.white38, fontSize: 13),
          ),
        ],
      ),
    );
  }

  /// The one big, unmissable action under the image. Its label reflects state:
  /// uploading, first capture, or retake-after-a-failed-upload (a leftover
  /// _pendingPhoto with the spinner gone means the last upload failed).
  Widget _actionButton() {
    final retake = _pendingPhoto != null && !_saving;
    return SizedBox(
      width: double.infinity,
      child: ElevatedButton.icon(
        onPressed: _saving ? null : _takePic,
        icon: Icon(_saving
            ? Icons.hourglass_top
            : retake
                ? Icons.refresh
                : Icons.photo_camera),
        label: Text(_saving
            ? 'Uploading…'
            : retake
                ? 'Retake & upload'
                : 'Take photo'),
        style: ElevatedButton.styleFrom(
          backgroundColor: _scanRed,
          foregroundColor: Colors.white,
          disabledBackgroundColor: const Color(0xFF3A2A2A),
          disabledForegroundColor: Colors.white38,
          padding: const EdgeInsets.symmetric(vertical: 16),
          textStyle:
              const TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
          ),
        ),
      ),
    );
  }
}
