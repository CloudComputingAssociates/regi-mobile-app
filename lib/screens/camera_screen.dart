import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:provider/provider.dart';

import '../services/auth_service.dart';
import '../services/avatar_service.dart';
import '../services/mobile_command_service.dart';
import '../services/user_food_service.dart';
import '../widgets/close_disk_button.dart';

/// The phone's capture surface — the "Phone panel" reached from the left-nav
/// drawer. It is the one screen that fulfills a mobile-bus command.
///
/// Delivery is pull-based and durable: the web app (only when it can see this
/// phone is tethered/live) drops a command on `regi.mobile.requests`; the api
/// holds it in a per-user pending store; this panel pulls the next one over
/// HTTP (the browser can't read Kafka), shows Title/Description of what it's
/// capturing, takes the photo, uploads to the API by id for that command's
/// type, then reports completion so the api clears the entry and emits a
/// response event. If anything drops in between, the request persists in the
/// queue and re-surfaces here — nothing pops the camera unbidden.
///
/// Command types handled:
///   • camera.captureMeal   → payload.mealId → POST /image/upload/product
///   • camera.captureAvatar → POST /image/upload/avatar
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

  static const String _typeCaptureMeal = 'camera.captureMeal';
  static const String _typeCaptureAvatar = 'camera.captureAvatar';

  final MobileCommandService _commands = MobileCommandService();
  final UserFoodService _foods = UserFoodService();
  final AvatarService _avatars = AvatarService();

  // True while the initial (or post-upload) pull is in flight.
  bool _loading = true;
  // The command we're currently fulfilling, or null when the queue is empty.
  MobileCommand? _command;
  // A freshly-taken photo held for preview until the user commits it with
  // "Use photo". Cleared on retake and after a successful upload.
  Uint8List? _pendingPhoto;
  // Upload in flight.
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    _loadNext();
  }

  @override
  void dispose() {
    _commands.dispose();
    _foods.dispose();
    _avatars.dispose();
    super.dispose();
  }

  /// Pull the next queued command for this user. Runs on open and again after
  /// each successful upload so a second queued request surfaces without
  /// leaving the screen.
  Future<void> _loadNext() async {
    final auth = context.read<AuthService>();
    setState(() {
      _loading = true;
      _pendingPhoto = null;
    });
    final jwt = await auth.getAccessToken();
    if (jwt == null) {
      if (!mounted) return;
      setState(() => _loading = false);
      _toast('Not authenticated.');
      return;
    }
    try {
      final cmd = await _commands.getNext(jwt);
      if (!mounted) return;
      setState(() {
        _command = cmd;
        _loading = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _command = null;
        _loading = false;
      });
      _toast('Couldn’t check for a request — try again.');
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
  /// report completion, then pull the next queued command.
  Future<void> _usePhoto() async {
    final cmd = _command;
    final photo = _pendingPhoto;
    if (cmd == null || photo == null) return;
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
      switch (cmd.type) {
        case _typeCaptureMeal:
          final mealId = cmd.mealId;
          if (mealId == null) {
            throw const FormatException('captureMeal without a mealId');
          }
          await _foods.uploadProductImage(mealId, jwt, photo, source: 'meal');
          break;
        case _typeCaptureAvatar:
          await _avatars.uploadAvatar(photo, 'avatar.jpg', jwt);
          break;
        default:
          throw FormatException('unsupported command type ${cmd.type}');
      }
      // Tell the api the capture landed so it clears the pending entry and
      // emits the response event. Best-effort — a hiccup here just means the
      // command may resurface on the next pull.
      try {
        await _commands.complete(cmd.commandId, jwt);
      } catch (_) {/* non-fatal */}
      if (!mounted) return;
      setState(() => _saving = false);
      _toast('Photo uploaded.');
      await _loadNext();
    } catch (e) {
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
        title: const Text('Phone'),
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

  /// No command queued — the user opened the panel with nothing to shoot.
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
    // Title/Description come resolved from the server so the phone can say what
    // it's capturing without knowing the domain: "Meal Photo: Turkey & Lettuce…".
    final heading = cmd.description.isEmpty
        ? cmd.title
        : '${cmd.title}: ${cmd.description}';
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(20, 20, 20, 32),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            heading,
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
