import 'dart:async';

import 'package:flutter/material.dart';

import 'app.dart';

void main() {
  // Loud + capturable framework errors. Two channels:
  //   1. FlutterError.onError catches errors raised by the framework
  //      during build/layout/paint/gesture dispatch — re-presents them
  //      via the default red-screen handler, then prints a
  //      WEDGE-TRACE line we can grep out of the run console when a
  //      wedge reproduces.
  //   2. runZonedGuarded catches async errors that escape the zone
  //      (uncaught Futures, stream errors) — prints WEDGE-ZONE so we
  //      can distinguish them from sync framework errors.
  FlutterError.onError = (details) {
    FlutterError.presentError(details);
    debugPrint(
      'WEDGE-TRACE: ${details.exceptionAsString()}\n${details.stack}',
    );
  };
  runZonedGuarded(
    () => runApp(const RegiChatApp()),
    (e, s) => debugPrint('WEDGE-ZONE: $e\n$s'),
  );
}
