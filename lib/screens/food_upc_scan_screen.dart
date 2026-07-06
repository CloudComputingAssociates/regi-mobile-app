import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:provider/provider.dart';

import '../services/auth_service.dart';
import '../services/user_food_service.dart';
import '../widgets/close_disk_button.dart';
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
  // True while we're polling the food row for the async-fetched product image
  // (imageStatus == "fetching"). Drives the "Getting image…" spinner.
  bool _fetchingImage = false;
  // A freshly-taken photo the user hasn't committed yet. While non-null the
  // picture box shows it as a preview with Retake / Use photo, and it's held
  // in memory until Save uploads it. Cleared on rescan or after a save.
  Uint8List? _pendingPhoto;
  // The category the last scan persisted server-side. The dropdown can drift
  // from this after the scan; the gap is what Save's category PATCH commits.
  int? _savedCategoryId;
  // Save (image upload + category PATCH) in flight.
  bool _saving = false;

  /// Category was changed after the scan and there's no pending photo to carry
  /// it — so it needs its own Save affordance (the AppBar check).
  bool get _categoryDirty =>
      _result != null && _savedCategoryId != null && _categoryId != _savedCategoryId;

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
        // The scan persisted this category server-side; track it so a later
        // dropdown change reads as dirty and offers a Save.
        _savedCategoryId = _categoryId;
        // Overlay the Name box with the resolved product name and lock it.
        _name.text = food.name;
      });
      // FatSecret doesn't supply product images. On a fresh scan the API kicks
      // off an async OpenFoodFacts fetch and returns imageStatus == "fetching"
      // with a still-NULL foodImage — so we poll the row until it backfills.
      // A cache-hit rescan already has the image (imageUrl != null → no poll).
      if (food.imageUrl == null && food.imageStatus == 'fetching') {
        unawaited(_pollForImage(food, jwt));
      }
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

  /// Polls the food row for the product image the API fetches asynchronously
  /// from OpenFoodFacts. The row lands with a NULL `foodImage`; the enrichment
  /// worker backfills it a moment later. We retry a handful of times, then
  /// give up and leave the "No product image" placeholder (Take pic path).
  ///
  /// Guarded by identity on [_result]: if the user rescans (or leaves) while
  /// we're polling, `_result != food` and we bail without touching state.
  Future<void> _pollForImage(ScannedFood food, String jwt) async {
    final id = food.id;
    if (id == null) return;
    if (mounted && _result == food) setState(() => _fetchingImage = true);
    try {
      for (var attempt = 0; attempt < 6; attempt++) {
        await Future.delayed(const Duration(seconds: 2));
        if (!mounted || _result != food) return;
        final url = await _service.fetchFoodImageUrl(id, jwt);
        if (!mounted || _result != food) return;
        if (url != null) {
          setState(() => food.raw['foodImage'] = url);
          return;
        }
      }
    } catch (_) {
      // Swallow — a failed poll just leaves the placeholder in place.
    } finally {
      if (mounted && _result == food) setState(() => _fetchingImage = false);
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
        _fetchingImage = false;
        _pendingPhoto = null;
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
        // No back arrow — closing is the red X disc at upper-right, so it can't
        // be mistaken for in-screen navigation.
        automaticallyImplyLeading: false,
        title: const Text('Food UPC scan'),
        actions: [
          // Save appears only for a category-only edit (a pending photo carries
          // its own "Use photo" commit, so we don't double up). It never renders
          // in a ghost-disabled state — it's here or it isn't.
          if (_categoryDirty && _pendingPhoto == null && !_saving)
            IconButton(
              tooltip: 'Save',
              icon: const Icon(Icons.check, color: _scanRed),
              onPressed: _save,
            ),
          // Close (rightmost = the corner).
          CloseDiskButton(onClose: () => Navigator.of(context).maybePop()),
        ],
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
            // Zoom slider — only when the camera advertises a zoom range. Lets
            // the user fill the frame with a short/small barcode from a
            // focusable distance instead of moving in until it blurs.
            if (_scanning && _scanner.zoomSupported) _zoomSlider(),
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

  /// Picture area shown after a successful scan, replacing the camera. Three
  /// states:
  ///   • a pending photo (just taken, not yet saved) → preview + Retake / Use
  ///     photo;
  ///   • the resolved product image (or placeholder) → + Take pic.
  /// A saving overlay covers the box while the upload/PATCH is in flight.
  Widget _pictureBox() {
    final pending = _pendingPhoto;
    final url = _result?.imageUrl;
    return AspectRatio(
      aspectRatio: 1,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(12),
        child: Stack(
          fit: StackFit.expand,
          children: [
            // Image layer.
            if (pending != null)
              Image.memory(pending, fit: BoxFit.cover)
            else if (url != null)
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
            else if (_fetchingImage)
              _fetchingImagePlaceholder()
            else
              _noImagePlaceholder(),

            // Button layer.
            if (pending != null)
              _pendingPhotoActions()
            else
              Positioned(
                right: 10,
                bottom: 10,
                child: _pictureButton(
                  onPressed: _saving ? null : _takePic,
                  icon: Icons.photo_camera,
                  label: 'Take pic',
                ),
              ),

            // Saving overlay.
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

  /// Retake / Use photo pair shown over a freshly-taken, uncommitted photo.
  /// "Use photo" is the approval — it runs the full [_save] (upload the photo,
  /// which deletes the old one + rebuilds the thumbnail server-side, plus any
  /// pending category change). "Retake" re-opens the camera.
  Widget _pendingPhotoActions() {
    return Positioned(
      left: 10,
      right: 10,
      bottom: 10,
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          _pictureButton(
            onPressed: _saving ? null : _takePic,
            icon: Icons.refresh,
            label: 'Retake',
            filled: false,
          ),
          _pictureButton(
            onPressed: _saving ? null : _save,
            icon: Icons.check,
            label: 'Use photo',
          ),
        ],
      ),
    );
  }

  /// A pill button used inside the picture box. `filled` false gives a
  /// translucent secondary (Retake) against the photo.
  Widget _pictureButton({
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

  /// Shown while the async OpenFoodFacts image fetch is in flight — the row
  /// exists but its `foodImage` hasn't backfilled yet. Falls back to
  /// [_noImagePlaceholder] once polling gives up.
  Widget _fetchingImagePlaceholder() {
    return Container(
      color: Colors.black,
      alignment: Alignment.center,
      child: const Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          CircularProgressIndicator(color: _scanRed),
          SizedBox(height: 12),
          Text(
            'Getting product image…',
            style: TextStyle(color: Colors.white38, fontSize: 13),
          ),
        ],
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

  /// Opens the device camera (via image_picker) for a still photo of the food
  /// container. On web this is a file input with `capture=environment`, so it
  /// works even on iOS Safari (unlike the barcode scanner, which needs
  /// BarcodeDetector). The shot is held in [_pendingPhoto] as a preview — it's
  /// not uploaded until the user approves it with "Use photo".
  Future<void> _takePic() async {
    try {
      final shot = await ImagePicker().pickImage(
        source: ImageSource.camera,
        maxWidth: 2048,
      );
      if (shot == null) return; // user cancelled
      final bytes = await shot.readAsBytes();
      if (!mounted) return;
      setState(() => _pendingPhoto = bytes);
    } catch (e) {
      _toast('Camera unavailable: $e');
    }
  }

  /// Commits the user's post-scan edits in one shot and reports back with a
  /// single "Food image and info updated" toast. Uploads a pending photo (the
  /// API deletes the prior image + rebuilds the thumbnail synchronously) and
  /// PATCHes the category if it drifted from what the scan saved. Name is
  /// intentionally not editable post-scan, so it never participates here.
  Future<void> _save() async {
    final food = _result;
    if (food == null || food.id == null) return;
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
      // Category first, then image: the image key is derived from the (locked)
      // description, not the category, so ordering is only about not leaving a
      // photo uploaded if the category call fails.
      if (_categoryId != _savedCategoryId) {
        await _service.updateCategory(food.id!, jwt, _categoryId);
      }
      final photo = _pendingPhoto;
      if (photo != null) {
        final url = await _service.uploadProductImage(food.id!, jwt, photo);
        if (url != null) food.raw['foodImage'] = url;
      }
      if (!mounted) return;
      setState(() {
        _savedCategoryId = _categoryId;
        _pendingPhoto = null;
        _saving = false;
      });
      _toast('Food image and info updated.');
    } on UserFoodException catch (e) {
      if (!mounted) return;
      setState(() => _saving = false);
      _toast('Save failed (HTTP ${e.statusCode}).');
    } catch (_) {
      if (!mounted) return;
      setState(() => _saving = false);
      _toast('Save failed — check your connection and try again.');
    }
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

  /// Vertical zoom slider pinned to the right edge of the live preview. Shown
  /// only when the camera advertises a zoom range (see [_scannerBox]). A zoom
  /// icon caps the top so the control reads as magnification, not brightness.
  Widget _zoomSlider() {
    final min = _scanner.zoomMin;
    final max = _scanner.zoomMax;
    final value = _scanner.zoom.clamp(min, max);
    return Positioned(
      top: 14,
      bottom: 14,
      right: 2,
      child: Column(
        children: [
          const Icon(Icons.zoom_in, color: Colors.white70, size: 22),
          Expanded(
            child: RotatedBox(
              quarterTurns: 3,
              child: SliderTheme(
                data: SliderTheme.of(context).copyWith(
                  activeTrackColor: _scanRed,
                  inactiveTrackColor: Colors.white30,
                  thumbColor: _scanRed,
                  overlayShape: const RoundSliderOverlayShape(overlayRadius: 14),
                ),
                child: Slider(
                  min: min,
                  max: max,
                  value: value,
                  onChanged: (v) {
                    unawaited(_scanner.setZoom(v));
                    setState(() {});
                  },
                ),
              ),
            ),
          ),
        ],
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
