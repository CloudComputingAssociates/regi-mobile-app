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

  // Category sent with the barcode POST. Defaults to 9 (Processed). The
  // dropdown above the Name box drives this. Hardcoded from the Categories
  // table; the live source of truth is GET /api/foods/categories if we ever
  // want to fetch instead of hardcode.
  int _categoryId = 9;
  static const List<({int id, String name})> _categories = [
    (id: 1, name: 'Protein'),
    (id: 2, name: 'Fat'),
    (id: 3, name: 'Carbohydrate'),
    (id: 4, name: 'Vegetable'),
    (id: 5, name: 'Fruit'),
    (id: 6, name: 'Dairy'),
    (id: 7, name: 'Beverage'),
    (id: 8, name: 'Seasonings'),
    (id: 9, name: 'Processed'),
  ];

  // Camera live and hunting for a code. While true the Scan button is
  // stippled — there's nothing to (re)start.
  bool _scanning = false;
  // POST in flight. Also disables the Scan button and shows a spinner.
  bool _busy = false;
  // Last successful lookup. Non-null == Name box is locked to the resolved
  // product name until the user taps Scan again.
  ScannedFood? _result;

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
        categoryId: _categoryId,
      );
      if (!mounted) return;
      setState(() {
        _result = food;
        _busy = false;
        // Overlay the Name box with the resolved product name and lock it.
        _name.text = food.name;
      });
    } on UserFoodException catch (e) {
      // Any non-2xx from the barcode endpoint (we didn't get a 201/200
      // create-or-update) surfaces here. Report the status so a real 404
      // "not found" reads differently from a 500 outage.
      if (!mounted) return;
      setState(() => _busy = false);
      _toast(e.statusCode == 404
          ? 'Food not found for that barcode.'
          : 'Couldn’t add food (HTTP ${e.statusCode}).');
    } catch (_) {
      if (!mounted) return;
      setState(() => _busy = false);
      _toast('Lookup failed — check your connection and try again.');
    }
  }

  /// The Scan button. Nothing scans until this is pressed (no auto-start).
  /// On a FIRST scan we keep whatever optional Name the user typed (it's the
  /// userDescription we send). When starting over from a shown result we
  /// unlock + clear the Name so they can enter a fresh one.
  Future<void> _onScanPressed() async {
    if (_result != null) {
      setState(() {
        _result = null;
        _name.clear();
      });
    }
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
            // Step 1 — Name (optional), at the top.
            _stepRow('1', 'Name', optional: true, input: _nameInput(locked)),
            const SizedBox(height: 16),
            // Step 2 — Category (optional), underneath.
            _stepRow('2', 'Category', optional: true, input: _categoryInput()),
            const SizedBox(height: 20),
            // Step 3 — Scan. One window (live red-bar scanner now, product
            // picture later once the image block is sorted), with the Scan
            // button directly beneath it.
            Row(
              children: [
                _stepBadge('3'),
                const SizedBox(width: 10),
                const Text(
                  'Scan',
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: 15,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 10),
            _result != null ? _pictureBox() : _scannerBox(),
            const SizedBox(height: 12),
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
            // Opaque idle panel — camera stays off until Scan is pressed.
            if (!_scanning && !_busy)
              Container(
                color: Colors.black,
                alignment: Alignment.center,
                child: const Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.qr_code_scanner, color: Colors.white24, size: 64),
                    SizedBox(height: 10),
                    Text(
                      'Press Scan to start',
                      style: TextStyle(color: Colors.white38, fontSize: 13),
                    ),
                  ],
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

  /// Product image shown after a successful scan, replacing the camera. If
  /// the resolver returned no image (or a broken URL) we show a placeholder
  /// so "Take pic" is still the obvious next action.
  Widget _pictureBox() {
    final url = _result?.imageUrl;
    return AspectRatio(
      aspectRatio: 1,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(12),
        child: Stack(
          fit: StackFit.expand,
          children: [
            if (url != null)
              Image.network(
                url,
                fit: BoxFit.cover,
                // The product images live on GCS (yeh-cdn) which doesn't send
                // CORS headers, so CanvasKit's byte-fetch path fails and the
                // image never appears. `prefer` renders it through an HTML
                // <img> element instead (no CORS needed for display), which
                // is why the URL works in a browser but not via Image.network.
                webHtmlElementStrategy: WebHtmlElementStrategy.prefer,
                errorBuilder: (_, __, ___) => _noImagePlaceholder(),
                loadingBuilder: (ctx, child, progress) => progress == null
                    ? child
                    : Container(
                        color: Colors.black,
                        alignment: Alignment.center,
                        child: const CircularProgressIndicator(
                          color: _scanRed,
                        ),
                      ),
              )
            else
              _noImagePlaceholder(),
            Positioned(
              right: 10,
              bottom: 10,
              child: ElevatedButton.icon(
                onPressed: _takePic,
                icon: const Icon(Icons.photo_camera, size: 18),
                label: const Text('Take pic'),
                style: ElevatedButton.styleFrom(
                  backgroundColor: _scanRed,
                  foregroundColor: Colors.white,
                  padding: const EdgeInsets.symmetric(
                    horizontal: 16,
                    vertical: 10,
                  ),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(10),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _noImagePlaceholder() {
    return Container(
      color: Colors.black,
      alignment: Alignment.center,
      child: const Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.image_not_supported, color: Colors.white24, size: 56),
          SizedBox(height: 8),
          Text(
            'No product image',
            style: TextStyle(color: Colors.white38, fontSize: 13),
          ),
        ],
      ),
    );
  }

  /// Placeholder for now. Capturing + uploading a replacement image is the
  /// next step; it's blocked on the image-upload endpoint contract.
  Future<void> _takePic() async {
    _toast('Take pic is coming next — needs the image-upload endpoint.');
  }

  /// A numbered step row: badge + label (+ "(optional)") on the left, and
  /// the input taking the remaining width on the right. The input is
  /// intentionally NOT full-width — the label eats fixed space so the whole
  /// row, "(optional)" included, fits on a standard phone.
  Widget _stepRow(
    String number,
    String title, {
    bool optional = false,
    required Widget input,
  }) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        _stepBadge(number),
        const SizedBox(width: 10),
        Text(
          title,
          style: const TextStyle(
            color: Colors.white,
            fontSize: 15,
            fontWeight: FontWeight.w600,
          ),
        ),
        if (optional) ...[
          const SizedBox(width: 5),
          const Text(
            '(optional)',
            style: TextStyle(
              color: Colors.white38,
              fontSize: 12,
              fontStyle: FontStyle.italic,
            ),
          ),
        ],
        const SizedBox(width: 10),
        Expanded(child: input),
      ],
    );
  }

  Widget _stepBadge(String number) {
    return Container(
      width: 24,
      height: 24,
      decoration: const BoxDecoration(color: _scanRed, shape: BoxShape.circle),
      alignment: Alignment.center,
      child: Text(
        number,
        style: const TextStyle(
          color: Colors.white,
          fontSize: 13,
          fontWeight: FontWeight.bold,
        ),
      ),
    );
  }

  /// Compact Name box (step 1). Locked + shows the resolved product name
  /// after a successful scan; editable (the optional userDescription) before.
  Widget _nameInput(bool locked) {
    return TextField(
      controller: _name,
      readOnly: locked,
      style: const TextStyle(color: Colors.white, fontSize: 14),
      decoration: InputDecoration(
        isDense: true,
        filled: true,
        fillColor: _inputFill,
        hintText: locked ? null : 'e.g. Triscuits',
        hintStyle: const TextStyle(color: Colors.white54, fontSize: 12),
        contentPadding:
            const EdgeInsets.symmetric(horizontal: 10, vertical: 11),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(8),
          borderSide: BorderSide.none,
        ),
      ),
    );
  }

  /// Compact Category dropdown (step 2). Drives [_categoryId], sent with the
  /// barcode POST. Currently only the confirmed Processed=9 entry exists —
  /// see the _categories TODO.
  Widget _categoryInput() {
    return Container(
      height: 42,
      padding: const EdgeInsets.symmetric(horizontal: 10),
      decoration: BoxDecoration(
        color: _inputFill,
        borderRadius: BorderRadius.circular(8),
      ),
      child: DropdownButtonHideUnderline(
        child: DropdownButton<int>(
          value: _categoryId,
          isExpanded: true,
          isDense: true,
          dropdownColor: const Color(0xFF3A3A3A),
          iconEnabledColor: Colors.white70,
          style: const TextStyle(color: Colors.white, fontSize: 14),
          items: [
            for (final c in _categories)
              DropdownMenuItem<int>(value: c.id, child: Text(c.name)),
          ],
          onChanged: (v) {
            if (v != null) setState(() => _categoryId = v);
          },
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

  Widget _scanButton() {
    // Alive when the camera is idle — before the first scan and after a scan
    // returns (success or failure). Stippled while scanning or posting.
    final enabled = !_scanning && !_busy;
    final label = _busy
        ? 'Looking up…'
        : _scanning
            ? 'Scanning…'
            : 'Scan';
    return Center(
      child: ElevatedButton.icon(
        onPressed: enabled ? _onScanPressed : null,
        icon: const Icon(Icons.qr_code_scanner, size: 20),
        label: Text(label),
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
