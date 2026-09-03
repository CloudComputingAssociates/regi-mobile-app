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

  static const String _typeCaptureMeal = 'captureMeal';
  static const String _typeCaptureAvatar = 'captureAvatar';

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
      // First command we haven't already fulfilled this session.
      MobileCommand? next;
      for (final c in res.commands) {
        if (!_handled.contains(c.messageId)) {
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
    } catch (e) {
      _toast('Camera unavailable: $e');
    }
  }

  /// Upload the committed photo to the endpoint this command's type maps to,
  /// then ack the command (done) so the server stops redelivering it, then
  /// pull the next queued command.
  Future<void> _usePhoto() async {
    final cmd = _command;
    final photo = _pendingPhoto;
    final deviceId = _deviceId;
    if (cmd == null || photo == null || deviceId == null) return;
    final auth = context.read<AuthService>();
    setState(() => _saving = true);
    final jwt = await auth.getAccessToken();
    if (jwt == null) {
      if (!mounted) return;
      setState(() => _saving = false);
      _toast('Not authenticated.');
      return;
    }
    try {
      Object? result;
      switch (cmd.type) {
        case _typeCaptureMeal:
          final mealId = cmd.mealId;
          if (mealId == null) {
            throw const FormatException('captureMeal without a mealId');
          }
          final url =
              await _foods.uploadProductImage(mealId, jwt, photo, source: 'meal');
          if (url != null) result = {'cdnUrl': url};
          break;
        case _typeCaptureAvatar:
          await _avatars.uploadAvatar(photo, 'avatar.jpg', jwt);
          break;
        default:
          throw FormatException('unsupported command type ${cmd.type}');
      }
      // Upload landed → ack done. Mark handled so a redelivery before the
      // server cursor advances doesn't re-shoot it.
      _handled.add(cmd.messageId);
      await _tether.ack(deviceId, cmd.messageId, 'done', jwt, result: result);
      if (!mounted) return;
      setState(() => _saving = false);
      _toast('Photo uploaded.');
      await _loadNext();
    } catch (e) {
      // Upload or ack failed — do NOT mark handled; the command redelivers on
      // the next poll so the user can retry.
      _handled.remove(cmd.messageId);
      if (!mounted) return;
      setState(() => _saving = false);
      _toast('Upload failed — check your connection and try again.');
    }
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
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(20, 20, 20, 32),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            _headingFor(cmd),
            style: const TextStyle(
              color: Colors.white,
              fontSize: 18,
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: 16),
          _pictureBox(),
        ],
      ),
    );
  }

  /// What we're capturing. The poll command carries only type + mealId (no
  /// name), so the heading is type-based; a meal shows its id for reference.
  String _headingFor(MobileCommand cmd) {
    switch (cmd.type) {
      case _typeCaptureMeal:
        return cmd.mealId != null ? 'Meal Photo (#${cmd.mealId})' : 'Meal Photo';
      case _typeCaptureAvatar:
        return 'Profile Photo';
      default:
        return 'Capture: ${cmd.type}';
    }
  }

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

            // Button layer.
            if (pending != null)
              Positioned(
                left: 10,
                right: 10,
                bottom: 10,
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    _pillButton(
                      onPressed: _saving ? null : _takePic,
                      icon: Icons.refresh,
                      label: 'Retake',
                      filled: false,
                    ),
                    _pillButton(
                      onPressed: _saving ? null : _usePhoto,
                      icon: Icons.check,
                      label: 'Use photo',
                    ),
                  ],
                ),
              )
            else
              Positioned(
                right: 10,
                bottom: 10,
                child: _pillButton(
                  onPressed: _saving ? null : _takePic,
                  icon: Icons.photo_camera,
                  label: 'Take pic',
                ),
              ),

            if (_saving)
              Container(
                color: Colors.black45,
                alignment: Alignment.center,
                child: const CircularProgressIndicator(color: _scanRed),
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
            'Tap “Take pic” to capture',
            style: TextStyle(color: Colors.white38, fontSize: 13),
          ),
        ],
      ),
    );
  }

  Widget _pillButton({
    required VoidCallback? onPressed,
    required IconData icon,
    required String label,
    bool filled = true,
  }) {
    return ElevatedButton.icon(
      onPressed: onPressed,
      icon: Icon(icon, size: 18),
      label: Text(label),
      style: ElevatedButton.styleFrom(
        backgroundColor: filled ? _scanRed : Colors.black54,
        foregroundColor: Colors.white,
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(10),
        ),
      ),
    );
  }
}
