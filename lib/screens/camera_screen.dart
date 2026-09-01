import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:provider/provider.dart';

import '../services/auth_service.dart';
import '../services/camera_request_service.dart';
import '../services/user_food_service.dart';
import '../widgets/close_disk_button.dart';

/// Standalone Camera screen, pushed onto the root Navigator from the drawer.
///
/// This is the phone half of the "take a phone pic of this meal" flow. The web
/// app — only when it can see this device is tethered/live — queues a
/// meal-photo request (a Kafka `camera-requests` message the api holds in a
/// per-user pending store). The user then opens this screen, which pulls the
/// pending request over HTTP (the browser can't read Kafka directly), shows
/// which meal it's for, captures a photo in-app, and uploads it straight to
/// that meal's product image (GCS + URI update happen server-side).
///
/// No pending request → nothing to shoot; we show an empty state. That IS the
/// "if something disconnects, protection" rule: with no queued request there's
/// no meal to attach a photo to, so capture is inert.
class CameraScreen extends StatefulWidget {
  const CameraScreen({super.key});

  @override
  State<CameraScreen> createState() => _CameraScreenState();
}

class _CameraScreenState extends State<CameraScreen> {
  static const Color _bg = Color(0xFF1B1B1B);
  static const Color _scanRed = Color(0xFFFF3B30);

  final CameraRequestService _requests = CameraRequestService();
  final UserFoodService _foods = UserFoodService();

  // True while the initial (or post-upload) pending-request fetch is in flight.
  bool _loading = true;
  // The meal we've been asked to photograph, or null when the queue is empty.
  PendingMealPhoto? _request;
  // A freshly-taken photo held for preview until the user commits it with
  // "Use photo". Cleared on retake and after a successful upload.
  Uint8List? _pendingPhoto;
  // Upload in flight.
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    _loadPending();
  }

  @override
  void dispose() {
    _requests.dispose();
    _foods.dispose();
    super.dispose();
  }

  /// Fetch the head of the meal-photo queue for this user. Runs on open and
  /// again after each successful upload so a second queued request surfaces
  /// without leaving the screen.
  Future<void> _loadPending() async {
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
      final req = await _requests.getPending(jwt);
      if (!mounted) return;
      setState(() {
        _request = req;
        _loading = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _request = null;
        _loading = false;
      });
      _toast('Couldn’t check for a photo request — try again.');
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

  /// Upload the committed photo to the requested meal's product image
  /// (source=meal), then re-check the queue for the next request.
  Future<void> _usePhoto() async {
    final req = _request;
    final photo = _pendingPhoto;
    if (req == null || photo == null) return;
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
      await _foods.uploadProductImage(req.mealId, jwt, photo, source: 'meal');
      if (!mounted) return;
      setState(() => _saving = false);
      _toast('Meal photo updated.');
      // Server clears the pending request on a successful meal upload; refresh
      // to pick up any next queued meal (or land on the empty state).
      await _loadPending();
    } on UserFoodException catch (e) {
      if (!mounted) return;
      setState(() => _saving = false);
      _toast('Upload failed (HTTP ${e.statusCode}).');
    } catch (_) {
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
            : _request == null
                ? _emptyState()
                : _requestBody(_request!),
      ),
    );
  }

  /// No meal-photo request queued. The user reached the screen with nothing to
  /// shoot — explain, and offer a manual re-check in case one arrived.
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
              'No meal photo requested',
              style: TextStyle(color: Colors.white, fontSize: 17),
            ),
            const SizedBox(height: 8),
            const Text(
              'Pick a meal in the web app and tap “take phone pic”. '
              'The request shows up here.',
              textAlign: TextAlign.center,
              style: TextStyle(color: Colors.white54, fontSize: 13),
            ),
            const SizedBox(height: 20),
            OutlinedButton.icon(
              onPressed: _loadPending,
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

  Widget _requestBody(PendingMealPhoto req) {
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(20, 20, 20, 32),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Heading: which meal this photo is for.
          Text(
            'Meal Photo: ${req.mealName}',
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
            'Tap “Take pic” to photograph this meal',
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
