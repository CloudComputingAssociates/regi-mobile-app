import 'dart:async';
import 'dart:js_interop';
import 'dart:js_interop_unsafe';
import 'dart:ui_web' as ui_web;

import 'package:flutter/widgets.dart';
import 'package:web/web.dart' as web;

/// Web barcode scanner backed by the browser-native `BarcodeDetector` API
/// (Chrome on Android). We open the camera ourselves with a HIGH-resolution
/// constraint — the whole reason we don't use mobile_scanner on web, whose
/// backend opens a low-res stream and decodes with ZXing-js, which can't
/// read dense 1D UPC codes. `BarcodeDetector` + a sharp 1080p frame reads
/// UPC/EAN reliably.
///
/// `BarcodeDetector` does NOT exist in WebKit, so it is absent in Safari
/// AND in Chrome/Edge/Firefox on iOS (all forced onto WebKit). Callers must
/// gate on [isSupported] and show a fallback when false.

@JS('BarcodeDetector')
extension type _BarcodeDetector._(JSObject _) implements JSObject {
  external factory _BarcodeDetector(JSObject options);
  external JSPromise<JSArray<_DetectedBarcode>> detect(JSObject source);
}

extension type _DetectedBarcode._(JSObject _) implements JSObject {
  external String get rawValue;
  external String get format;
}

class UpcScannerController {
  UpcScannerController() {
    _viewType = 'upc-scanner-view-${_seq++}';
    // Register the <video> element as a platform view once; start()/stop()
    // just swap the stream on the same element, so the preview survives a
    // rescan without re-registering.
    ui_web.platformViewRegistry.registerViewFactory(
      _viewType,
      (int viewId) => _video,
    );
  }

  static int _seq = 0;
  late final String _viewType;

  final web.HTMLVideoElement _video = web.HTMLVideoElement()
    ..autoplay = true
    ..muted = true;

  web.MediaStream? _stream;
  _BarcodeDetector? _detector;
  Timer? _loop;
  bool _detecting = false;

  /// True only where the native BarcodeDetector API exists (Android Chrome).
  static bool get isSupported => web.window.has('BarcodeDetector');

  Widget buildPreview() => HtmlElementView(viewType: _viewType);

  /// Opens the rear camera at 1080p and starts a ~4 Hz detection loop.
  /// [onDetect] fires with the raw digits of the first barcode in a frame.
  /// Throws if the API is unavailable or camera permission is denied.
  Future<void> start({required void Function(String code) onDetect}) async {
    if (!isSupported) {
      throw UnsupportedError('BarcodeDetector is not available in this browser.');
    }

    // Detector limited to retail-product symbologies.
    final options = JSObject()
      ..setProperty(
        'formats'.toJS,
        <JSAny>[
          'upc_a'.toJS,
          'upc_e'.toJS,
          'ean_13'.toJS,
          'ean_8'.toJS,
        ].toJS,
      );
    _detector = _BarcodeDetector(options);

    // Rear camera, ask for 1080p so the barcode has enough detail. `ideal`
    // (not `exact`) so a phone that can't do 1080p still gives its best.
    final videoConstraints = JSObject()
      ..setProperty('facingMode'.toJS, 'environment'.toJS)
      ..setProperty('width'.toJS, (JSObject()..setProperty('ideal'.toJS, 1920.toJS)))
      ..setProperty('height'.toJS, (JSObject()..setProperty('ideal'.toJS, 1080.toJS)));
    final constraints = web.MediaStreamConstraints(video: videoConstraints);

    final stream =
        await web.window.navigator.mediaDevices.getUserMedia(constraints).toDart;
    _stream = stream;

    _video
      ..setAttribute('playsinline', 'true')
      ..srcObject = stream;
    _video.style
      ..setProperty('width', '100%')
      ..setProperty('height', '100%')
      ..setProperty('object-fit', 'cover');
    await _video.play().toDart;

    _loop = Timer.periodic(const Duration(milliseconds: 250), (_) {
      unawaited(_tick(onDetect));
    });
  }

  Future<void> _tick(void Function(String code) onDetect) async {
    final detector = _detector;
    if (detector == null || _detecting) return;
    // readyState < HAVE_CURRENT_DATA (2) → no frame to decode yet.
    if (_video.readyState < 2) return;
    _detecting = true;
    try {
      final results = (await detector.detect(_video).toDart).toDart;
      if (results.isEmpty) return;
      final code = results.first.rawValue;
      if (code.isNotEmpty) onDetect(code);
    } catch (_) {
      // Transient decode errors are normal between reads — ignore.
    } finally {
      _detecting = false;
    }
  }

  /// Stops the detect loop and releases the camera (turns the LED off).
  Future<void> stop() async {
    _loop?.cancel();
    _loop = null;
    final stream = _stream;
    if (stream != null) {
      final tracks = stream.getTracks().toDart;
      for (final track in tracks) {
        track.stop();
      }
    }
    _stream = null;
    _video.srcObject = null;
  }

  void dispose() {
    unawaited(stop());
    _detector = null;
  }
}
