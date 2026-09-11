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
  web.MediaStreamTrack? _videoTrack;
  _BarcodeDetector? _detector;
  Timer? _loop;
  bool _detecting = false;

  // Camera zoom, read from the live track's capabilities after start(). Short
  // "truncated" barcodes (e.g. a hot-sauce bottle) can't be framed close-up
  // without blowing past the lens's minimum focus distance; zoom lets the user
  // fill the frame from a focusable distance instead. Absent on cameras that
  // don't advertise a zoom range.
  bool _zoomSupported = false;
  double _zoomMin = 1.0;
  double _zoomMax = 1.0;
  double _zoom = 1.0;
  // Whether the camera offers a 'continuous' focus mode. Re-sent on every
  // applyConstraints call (which replaces the whole constraint set) so a zoom
  // change doesn't clobber the autofocus setting.
  bool _continuousFocus = false;

  /// True only where the native BarcodeDetector API exists (Android Chrome).
  static bool get isSupported => web.window.has('BarcodeDetector');

  /// Whether the active camera exposes a usable zoom range (min < max).
  bool get zoomSupported => _zoomSupported;
  double get zoomMin => _zoomMin;
  double get zoomMax => _zoomMax;
  double get zoom => _zoom;

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
    final videoTracks = stream.getVideoTracks().toDart;
    _videoTrack = videoTracks.isNotEmpty ? videoTracks.first : null;

    _video
      ..setAttribute('playsinline', 'true')
      ..srcObject = stream;
    _video.style
      ..setProperty('width', '100%')
      ..setProperty('height', '100%')
      ..setProperty('object-fit', 'cover');
    await _video.play().toDart;

    _tuneCamera();

    _loop = Timer.periodic(const Duration(milliseconds: 250), (_) {
      unawaited(_tick(onDetect));
    });
  }

  /// Reads the live track's capabilities and applies focus/zoom tuning that a
  /// bare getUserMedia stream leaves off. Everything here is best-effort: these
  /// are non-standard MediaStreamTrack constraints (Chrome/Android only), so we
  /// feature-detect each one and swallow rejections — scanning still works
  /// without them.
  void _tuneCamera() {
    final track = _videoTrack;
    if (track == null) return;
    final trackObj = track as JSObject;
    if (!trackObj.has('getCapabilities')) return;

    final JSObject caps;
    try {
      caps = trackObj.callMethod<JSObject>('getCapabilities'.toJS);
    } catch (_) {
      return;
    }

    // Continuous autofocus — keep the lens hunting as the phone moves in,
    // instead of locking focus and going soft up close.
    final fm = caps.getProperty<JSAny?>('focusMode'.toJS);
    if (fm != null && fm.isA<JSArray>()) {
      final modes = (fm as JSArray<JSString>).toDart.map((m) => m.toDart);
      _continuousFocus = modes.contains('continuous');
    }

    // Zoom range — expose it so the UI can offer a slider.
    final z = caps.getProperty<JSAny?>('zoom'.toJS);
    if (z != null && z.isA<JSObject>()) {
      final zo = z as JSObject;
      final min = zo.getProperty<JSAny?>('min'.toJS);
      final max = zo.getProperty<JSAny?>('max'.toJS);
      if (min != null && min.isA<JSNumber>() && max != null && max.isA<JSNumber>()) {
        _zoomMin = (min as JSNumber).toDartDouble;
        _zoomMax = (max as JSNumber).toDartDouble;
        _zoom = _zoomMin;
        _zoomSupported = _zoomMax > _zoomMin;
      }
    }

    unawaited(_applyCameraConstraints());
  }

  /// Sends the full advanced-constraint set (focusMode + zoom) to the live
  /// track. Bundled deliberately: applyConstraints REPLACES the whole set, so
  /// re-sending focusMode alongside zoom keeps autofocus from being dropped on
  /// a zoom change. Best-effort — rejections are swallowed.
  Future<void> _applyCameraConstraints() async {
    final track = _videoTrack;
    if (track == null) return;
    final advanced = <JSAny>[];
    if (_continuousFocus) {
      advanced.add(JSObject()..setProperty('focusMode'.toJS, 'continuous'.toJS));
    }
    if (_zoomSupported) {
      advanced.add(JSObject()..setProperty('zoom'.toJS, _zoom.toJS));
    }
    if (advanced.isEmpty) return;
    final root = JSObject()..setProperty('advanced'.toJS, advanced.toJS);
    try {
      await (track as JSObject)
          .callMethod<JSPromise>('applyConstraints'.toJS, root)
          .toDart;
    } catch (_) {
      // Device rejected the constraints — scanning still works without them.
    }
  }

  /// Sets the camera zoom (clamped to the advertised range). Updates [zoom]
  /// synchronously so the slider tracks the thumb even before the async
  /// constraint resolves.
  Future<void> setZoom(double value) async {
    if (!_zoomSupported) return;
    _zoom = value.clamp(_zoomMin, _zoomMax);
    await _applyCameraConstraints();
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
    _videoTrack = null;
    _zoomSupported = false;
    _continuousFocus = false;
    _zoom = _zoomMin;
    _video.srcObject = null;
  }

  void dispose() {
    unawaited(stop());
    _detector = null;
  }
}
