import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../services/auth_service.dart';
import '../services/user_food_service.dart';
// Conditional: real BarcodeDetector-backed scanner on web, unsupported stub
// elsewhere. See services/upc_scanner_web.dart for why mobile_scanner can't
// read UPC codes on web.
import '../services/upc_scanner_stub.dart'
    if (dart.library.js_interop) '../services/upc_scanner_web.dart';

/// Standalone Food UPC scan screen, pushed onto the root Navigator from the
/// drawer. Owns its own camera ([UpcScannerController]) — no global state is
/// touched, mirroring the Journal screen's self-contained-mic convention.
///
/// PLATFORM: this app ships as a web PWA. Scanning uses the browser-native
/// `BarcodeDetector` API, which exists in Chrome on Android but NOT in any
/// iOS browser (all forced onto WebKit). Where it's absent we show a clear
/// "not supported" panel instead of a dead camera.
///
/// FLOW
///   • Camera auto-starts on open (scanning, Scan button disabled).
///   • Point at a UPC → first detection stops the camera and POSTs the code
///     to /userfoods/barcode (categoryId 9 = processed food for now).
///   • On success the returned product name (food.description) is dropped
///     into the read-only Name box; the Scan button comes alive.
///   • On failure a "Lookup food failure" toast shows; Scan still comes
///     alive so the user can retry.
///   • Pressing Scan re-opens the Name box for editing (optional short
///     name) and restarts the camera.
///
/// The Name box is the user's OPTIONAL short name (userDescription) BEFORE a
/// scan; AFTER a successful scan it is overwritten with the resolved product
/// name and locked until the next Scan press.
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
  final UpcScannerController _scanner = UpcScannerController();
  final TextEditingController _name = TextEditingController();

  final bool _supported = UpcScannerController.isSupported;

  // Camera live and hunting for a code. While true the Scan button is
  // stippled — there's nothing to (re)start.
  bool _scanning = false;
  // POST in flight. Also disables the Scan button and shows a spinner.
  bool _busy = false;
  // Last successful lookup. Non-null == Name box is locked to the resolved
  // product name until the user taps Scan again.
  ScannedFood? _result;

  // TEMP DIAGNOSTICS — remove once scanning is confirmed working. Bumps on
  // every raw detection; if it stays 0 while aimed at a barcode the detector
  // isn't emitting, if it climbs the pipeline works.
  int _detectCount = 0;
  String _lastRaw = '(none yet)';

  @override
  void initState() {
    super.initState();
    if (_supported) unawaited(_beginScan());
  }

  @override
  void dispose() {
    _scanner.dispose();
    _service.dispose();
    _name.dispose();
    super.dispose();
  }

  /// Opens the camera and starts detection. Shared by initial mount and the
  /// Scan (rescan) button.
  Future<void> _beginScan() async {
    try {
      await _scanner.start(onDetect: _onCode);
      if (mounted) setState(() => _scanning = true);
    } catch (e) {
      if (mounted) {
        setState(() => _scanning = false);
        _toast('Camera error: $e');
      }
    }
  }

  /// Called with the raw digits of a detected barcode. Guarded so the
  /// rapid-fire detect loop only triggers one lookup.
  void _onCode(String code) {
    setState(() {
      _detectCount++;
      _lastRaw = code;
    });
    if (!_scanning || _busy) return;
    setState(() => _scanning = false);
    unawaited(_scanner.stop());
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
  /// camera. Clears the box so the user can type a fresh optional short name
  /// before the next scan.
  Future<void> _rescan() async {
    setState(() {
      _result = null;
      _name.clear();
    });
    await _beginScan();
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
            if (_supported) ...[
              const SizedBox(height: 8),
              // TEMP diagnostic readout — remove once scanning is verified.
              Text(
                'detections: $_detectCount • last: $_lastRaw',
                style: const TextStyle(
                  color: Colors.white38,
                  fontSize: 11,
                  fontFamily: 'monospace',
                ),
              ),
            ],
            const SizedBox(height: 12),
            _nameField(locked),
            const SizedBox(height: 8),
            _resultLine(),
            const SizedBox(height: 20),
            if (_supported) _scanButton(),
          ],
        ),
      ),
    );
  }

  Widget _scannerBox() {
    if (!_supported) return _unsupportedBox();
    return AspectRatio(
      aspectRatio: 1,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(12),
        child: Stack(
          fit: StackFit.expand,
          children: [
            // The <video> platform view stays mounted for the whole screen;
            // start()/stop() swap the camera stream on it.
            _scanner.buildPreview(),
            // Red reticle — only while the camera is live, so the user knows
            // where to aim.
            if (_scanning) _redReticle(),
            // Opaque "camera off" panel between scans.
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
                color: Colors.black45,
                alignment: Alignment.center,
                child: const CircularProgressIndicator(color: _scanRed),
              ),
          ],
        ),
      ),
    );
  }

  /// Shown where `BarcodeDetector` is unavailable — notably any iOS browser
  /// (Safari, and Chrome/Edge/Firefox on iOS, all WebKit).
  Widget _unsupportedBox() {
    return AspectRatio(
      aspectRatio: 1,
      child: Container(
        decoration: BoxDecoration(
          color: Colors.black,
          borderRadius: BorderRadius.circular(12),
        ),
        alignment: Alignment.center,
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: const [
            Icon(Icons.no_photography, color: _scanRed, size: 48),
            SizedBox(height: 14),
            Text(
              'Barcode scanning isn’t supported in this browser yet.',
              textAlign: TextAlign.center,
              style: TextStyle(color: Colors.white, fontSize: 15),
            ),
            SizedBox(height: 8),
            Text(
              'Use Chrome on Android. (iPhone browsers can’t scan yet — '
              'support is coming.)',
              textAlign: TextAlign.center,
              style: TextStyle(color: Colors.white54, fontSize: 12),
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
    if (!_supported) return const SizedBox.shrink();
    return Text(
      _busy ? 'Looking up…' : 'Hold the barcode steady, filling the frame.',
      style: const TextStyle(color: Colors.white54, fontSize: 13),
    );
  }

  Widget _scanButton() {
    // Alive only when the camera is idle (a scan has returned, success or
    // failure). Stippled while auto-scanning or while a lookup posts.
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
