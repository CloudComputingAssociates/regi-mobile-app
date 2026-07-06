import 'package:flutter/widgets.dart';

/// Non-web stub for [UpcScannerController]. The app deploys as a web PWA, so
/// this exists only so the project still compiles/analyzes for the VM and
/// native targets. On those platforms the scanner reports unsupported.
class UpcScannerController {
  static bool get isSupported => false;

  // Camera zoom mirrors the web controller's API so the shared screen code
  // compiles for the VM/native targets. Never supported off-web.
  bool get zoomSupported => false;
  double get zoomMin => 1.0;
  double get zoomMax => 1.0;
  double get zoom => 1.0;

  Widget buildPreview() => const SizedBox.shrink();

  Future<void> start({required void Function(String code) onDetect}) async {
    throw UnsupportedError('UPC scanning is only available on the web build.');
  }

  Future<void> setZoom(double value) async {}

  Future<void> stop() async {}

  void dispose() {}
}
