import 'package:flutter/widgets.dart';

/// Non-web stub for [UpcScannerController]. The app deploys as a web PWA, so
/// this exists only so the project still compiles/analyzes for the VM and
/// native targets. On those platforms the scanner reports unsupported.
class UpcScannerController {
  static bool get isSupported => false;

  Widget buildPreview() => const SizedBox.shrink();

  Future<void> start({required void Function(String code) onDetect}) async {
    throw UnsupportedError('UPC scanning is only available on the web build.');
  }

  Future<void> stop() async {}

  void dispose() {}
}
