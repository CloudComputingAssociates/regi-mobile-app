import 'dart:async';

import 'package:flutter/material.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:provider/provider.dart';

import '../services/auth_service.dart';
import '../services/user_food_service.dart';

/// Standalone Food UPC scan screen, pushed onto the root Navigator from
/// the drawer. Owns its own camera (a [MobileScannerController]) — no
/// global state is touched, mirroring the Journal screen's
/// self-contained-mic convention.
///
/// FLOW
///   • Camera auto-starts on open (scanning, Scan button disabled).
///   • Point at a UPC → first detection stops the camera and POSTs the
///     code to /userfoods/barcode (categoryId 9 = processed food for now).
///   • On success the returned product name (food.description) is dropped
///     into the read-only Name box; the Scan button comes alive.
///   • On failure a "Lookup food failure" toast shows; Scan still comes
///     alive so the user can retry.
///   • Pressing Scan re-opens the Name box for editing (optional short
///     name) and restarts the camera.
///
/// The Name box is the user's OPTIONAL short name (userDescription) BEFORE
/// a scan; AFTER a successful scan it is overwritten with the resolved
/// product name and locked until the next Scan press.
class FoodUpcScanScreen extends StatefulWidget {
  const FoodUpcScanScreen({super.key});

  @override
  State<FoodUpcScanScreen> createState() => _FoodUpcScanScreenState();
}

class _FoodUpcScanScreenState extends State<FoodUpcScanScreen> {
  static const Color _bg = Color(0xFF1B1B1B);
  static const Color _inputFill = Color(0xFF555555);
  static const Color _scanRed = Color(0xFFFF3B30);

  final UserFoodService _service = UserFoodService();
  final TextEditingController _name = TextEditingController();

  // Restrict to the retail-product symbologies so the detector isn't
  // distracted by QR / Code-128 clutter in frame.
  final MobileScannerController _controller = MobileScannerController(
    detectionSpeed: DetectionSpeed.noDuplicates,
    formats: const [
      BarcodeFormat.upcA,
      BarcodeFormat.upcE,
      BarcodeFormat.ean13,
      BarcodeFormat.ean8,
    ],
  );

  // Camera live and hunting for a code. Auto-true on mount (the
  // MobileScanner widget auto-starts the controller). While true the
  // Scan button is stippled — there's nothing to (re)start.
  bool _scanning = true;
  // POST in flight. Also disables the Scan button and shows a spinner.
  bool _busy = false;
  // Last successful lookup. Non-null == Name box is locked to the
  // resolved product name until the user taps Scan again.
  ScannedFood? _result;

  @override
  void dispose() {
    _controller.dispose();
    _service.dispose();
    _name.dispose();
    super.dispose();
  }

  /// First barcode of a scan session. Guarded so the rapid-fire detection
  /// stream only triggers one lookup: bail unless we're actively scanning
  /// and not already posting.
  void _onDetect(BarcodeCapture capture) {
    if (!_scanning || _busy) return;
    final code = capture.barcodes
        .map((b) => b.rawValue)
        .firstWhere((v) => v != null && v.isNotEmpty, orElse: () => null);
    if (code == null) return;
    setState(() => _scanning = false);
    unawaited(_controller.stop());
    unawaited(_lookup(code));
  }

  Future<void> _lookup(String upcCode) async {
    // Capture AuthService before the awaits so we never reach through a
    // stale BuildContext.
    final auth = context.read<AuthService>();
    setState(() => _busy = true);

    final jwt = await auth.getAccessToken();
    if (jwt == null) {
      if (!mounted) return;
      setState(() => _busy = false);
      _toast('Not authenticated.');
      return;
    }

    try {
      final food = await _service.lookupByBarcode(
        upcCode,
        jwt,
        userDescription: _name.text,
      );
      if (!mounted) return;
      setState(() {
        _result = food;
        _busy = false;
        // Overlay the Name box with the resolved product name and lock it.
        _name.text = food.name;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() => _busy = false);
      _toast('Lookup food failure');
    }
  }

  /// Re-arm: unlock the Name box, forget the last result, restart the
  /// camera. Clears the box so the user can type a fresh optional short
  /// name before the next scan.
  Future<void> _rescan() async {
    setState(() {
      _result = null;
      _name.clear();
      _scanning = true;
    });
    try {
      await _controller.start();
    } catch (_) {
      if (mounted) _toast('Could not start camera.');
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
    final locked = _result != null;
    return Scaffold(
      backgroundColor: _bg,
      appBar: AppBar(
        backgroundColor: _bg,
        foregroundColor: Colors.white,
        title: const Text('Food UPC scan'),
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(20, 20, 20, 32),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _scannerBox(),
            const SizedBox(height: 20),
            _nameField(locked),
            const SizedBox(height: 8),
            _resultLine(),
            const SizedBox(height: 20),
            _scanButton(),
          ],
        ),
      ),
    );
  }

  /// Square camera preview with a red UPC-style reticle. The
  /// [MobileScanner] stays mounted for the screen's whole life — we drive
  /// the camera with the controller's [stop]/[start] rather than adding/
  /// removing the widget, because a remount would auto-start the camera
  /// and race an explicit [start] (→ controllerInitializing). Between
  /// scans an opaque panel is stacked over the (stopped) preview.
  Widget _scannerBox() {
    return AspectRatio(
      aspectRatio: 1,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(12),
        child: Stack(
          fit: StackFit.expand,
          children: [
            MobileScanner(
              controller: _controller,
              onDetect: _onDetect,
              fit: BoxFit.cover,
              errorBuilder: (context, error) => _cameraError(error),
            ),
            // Red reticle — only while the camera is live, so the user
            // knows where to aim.
            if (_scanning) _redReticle(),
            // Opaque "camera off" panel between scans (after a result,
            // before the next Scan press).
            if (!_scanning && !_busy)
              Container(
                color: Colors.black,
                alignment: Alignment.center,
                child: const Icon(
                  Icons.qr_code_scanner,
                  color: Colors.white24,
                  size: 64,
                ),
              ),
            if (_busy)
              Container(
                color: Colors.black,
                alignment: Alignment.center,
                child: const CircularProgressIndicator(color: _scanRed),
              ),
          ],
        ),
      ),
    );
  }

  Widget _redReticle() {
    return IgnorePointer(
      child: Center(
        child: FractionallySizedBox(
          widthFactor: 0.8,
          heightFactor: 0.45,
          child: Container(
            decoration: BoxDecoration(
              border: Border.all(color: _scanRed, width: 3),
              borderRadius: BorderRadius.circular(10),
            ),
            child: const Center(
              child: SizedBox(
                width: double.infinity,
                child: Divider(color: _scanRed, thickness: 2, height: 2),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _cameraError(MobileScannerException error) {
    return Container(
      color: Colors.black,
      alignment: Alignment.center,
      padding: const EdgeInsets.all(16),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.no_photography, color: _scanRed, size: 48),
          const SizedBox(height: 12),
          Text(
            'Camera unavailable\n${error.errorCode.name}',
            textAlign: TextAlign.center,
            style: const TextStyle(color: Colors.white70, fontSize: 13),
          ),
        ],
      ),
    );
  }

  Widget _nameField(bool locked) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          locked ? 'Name' : 'Name (optional)',
          style: const TextStyle(
            color: Colors.white,
            fontSize: 14,
            fontWeight: FontWeight.w600,
          ),
        ),
        const SizedBox(height: 6),
        TextField(
          controller: _name,
          readOnly: locked,
          style: const TextStyle(color: Colors.white),
          decoration: InputDecoration(
            filled: true,
            fillColor: _inputFill,
            hintText: locked ? null : 'e.g. Triscuits',
            hintStyle: const TextStyle(color: Colors.white54, fontSize: 13),
            contentPadding:
                const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
            border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(8),
              borderSide: BorderSide.none,
            ),
          ),
        ),
      ],
    );
  }

  /// Status line under the Name box. Shows the resolved product name
  /// prominently after a scan; otherwise a hint about what to do.
  Widget _resultLine() {
    if (_result != null) {
      return Text(
        _result!.name,
        style: const TextStyle(
          color: Color(0xFFF2B33D),
          fontSize: 16,
          fontWeight: FontWeight.bold,
        ),
      );
    }
    return Text(
      _busy ? 'Looking up…' : 'Point the camera at a barcode.',
      style: const TextStyle(color: Colors.white54, fontSize: 13),
    );
  }

  Widget _scanButton() {
    // Alive only when the camera is idle (a scan has returned, success
    // or failure). Stippled while auto-scanning or while a lookup posts.
    final enabled = !_scanning && !_busy;
    return Center(
      child: ElevatedButton.icon(
        onPressed: enabled ? _rescan : null,
        icon: const Icon(Icons.qr_code_scanner, size: 20),
        label: const Text('Scan'),
        style: ElevatedButton.styleFrom(
          backgroundColor: _scanRed,
          foregroundColor: Colors.white,
          disabledBackgroundColor: const Color(0xFF3A2A2A),
          disabledForegroundColor: Colors.white38,
          padding: const EdgeInsets.symmetric(horizontal: 28, vertical: 12),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(10),
          ),
        ),
      ),
    );
  }
}
