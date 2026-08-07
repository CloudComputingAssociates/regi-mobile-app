import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/tether.dart';

/// Per-install identity + persisted device id for the tether presence loop.
/// Backed by shared_preferences — the install id is a non-secret opaque value,
/// so no secure storage. device_info_plus / package_info_plus aren't deps, so
/// deviceModel + appVersion are omitted (null).
class TetherIdentity {
  static const _kInstanceId = 'tether.deviceInstanceId';
  static const _kDeviceId = 'tether.deviceId';

  /// Stable per-install id. Generated ONCE (128 bits from Random.secure(), hex)
  /// and reused for the life of the install — it survives logout so the same
  /// phone dedups to one MobileDevices row regardless of which user logs in.
  Future<String> deviceInstanceId() async {
    final prefs = await SharedPreferences.getInstance();
    final existing = prefs.getString(_kInstanceId);
    if (existing != null && existing.isNotEmpty) return existing;
    final id = _generateInstanceId();
    await prefs.setString(_kInstanceId, id);
    return id;
  }

  /// The durable server deviceId from the last register(), or null.
  Future<int?> savedDeviceId() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getInt(_kDeviceId);
  }

  Future<void> saveDeviceId(int deviceId) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(_kDeviceId, deviceId);
  }

  /// Build the register payload for this device. platform via
  /// defaultTargetPlatform (web-safe; the driver is mobile-only anyway).
  Future<TetherRegisterRequest> buildRegisterRequest() async {
    return TetherRegisterRequest(
      deviceInstanceId: await deviceInstanceId(),
      platform: _platform(),
      deviceName: _deviceName(),
    );
  }

  static String _platform() {
    switch (defaultTargetPlatform) {
      case TargetPlatform.iOS:
        return 'ios';
      case TargetPlatform.android:
        return 'android';
      default:
        return 'other';
    }
  }

  static String _deviceName() {
    switch (defaultTargetPlatform) {
      case TargetPlatform.iOS:
        return 'iPhone';
      case TargetPlatform.android:
        return 'Android phone';
      default:
        return 'Mobile device';
    }
  }

  /// 128 bits of secure randomness as lowercase hex. Random.secure() is the
  /// entropy source — no uuid dependency.
  static String _generateInstanceId() {
    final rnd = Random.secure();
    final bytes = List<int>.generate(16, (_) => rnd.nextInt(256));
    return bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
  }
}
