import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';

import 'services/auth_service.dart';
import 'services/tether_identity.dart';
import 'services/tether_service.dart';

/// Presence driver for Phase 1 Mobile Tether — the WRITE side that makes the
/// web indicator light up. Attached at APP ROOT so presence reflects the whole
/// app being foreground, not one screen.
///
/// While authenticated AND foreground: register (idempotent upsert) on every
/// start / login / resume — NOT only when a deviceId is missing. This handles
/// the same-phone-different-user case: user B must poll against B's deviceId,
/// not a stale one persisted for A. Persist the returned deviceId, STAMP
/// immediately (poll) so the indicator greens the instant the app is
/// foregrounded, then stamp on a repeating timer at the server-authored
/// pollIntervalSeconds (default 3s only if absent).
///
/// Backgrounding cancels the timer — presence decays on its own via the server
/// liveness window; we never call an "offline" endpoint. Logout cancels the
/// loop but keeps the durable deviceInstanceId.
///
/// MOBILE-ONLY: on web this is a hard no-op — a web build must NEVER register or
/// poll (no web MobileDevices row should ever exist).
///
/// All register/poll failures are swallowed (debugPrint only) — a presence
/// heartbeat must never interrupt the user; the timer self-heals next tick.
class TetherLifecycle with WidgetsBindingObserver {
  TetherLifecycle(
    this._auth, {
    TetherService? service,
    TetherIdentity? identity,
  })  : _service = service ?? TetherService(),
        _identity = identity ?? TetherIdentity();

  final AuthService _auth;
  final TetherService _service;
  final TetherIdentity _identity;

  Timer? _timer;
  int _pollIntervalSeconds = _defaultPollSeconds;
  bool _started = false;
  bool _authWasAuthenticated = false;

  static const int _defaultPollSeconds = 3;

  /// Attach the observer + auth listener and evaluate once (covers app-start
  /// while already authenticated). Hard no-op on web.
  void start() {
    if (kIsWeb) return;
    if (_started) return;
    _started = true;
    WidgetsBinding.instance.addObserver(this);
    _authWasAuthenticated = _auth.isAuthenticated;
    _auth.addListener(_onAuthChanged);
    if (_auth.isAuthenticated) {
      unawaited(_registerStampAndLoop());
    }
  }

  /// Detach everything. Called from the root widget's dispose().
  void dispose() {
    if (kIsWeb) return;
    if (!_started) return;
    _auth.removeListener(_onAuthChanged);
    WidgetsBinding.instance.removeObserver(this);
    _cancelTimer();
    _service.dispose();
    _started = false;
  }

  /// Bidirectional auth listener: login → start the register+stamp loop;
  /// logout → cancel the timer. deviceInstanceId is durable (never cleared).
  void _onAuthChanged() {
    final isAuth = _auth.isAuthenticated;
    if (isAuth == _authWasAuthenticated) return; // ignore token-refresh notifies
    _authWasAuthenticated = isAuth;
    if (isAuth) {
      unawaited(_registerStampAndLoop());
    } else {
      _cancelTimer();
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (kIsWeb) return;
    if (state == AppLifecycleState.resumed) {
      if (_auth.isAuthenticated) unawaited(_registerStampAndLoop());
    } else {
      // paused / inactive / detached / hidden → stop stamping; presence decays
      // via the server liveness window. No "going offline" call by design.
      _cancelTimer();
    }
  }

  /// Register (idempotent upsert on EVERY start/resume/login), persist the
  /// returned deviceId, stamp immediately, then (re)start the interval timer.
  Future<void> _registerStampAndLoop() async {
    final jwt = await _auth.getAccessToken();
    if (jwt == null) return; // not authed — no presence.
    int? deviceId;
    try {
      final req = await _identity.buildRegisterRequest();
      final reg = await _service.register(req, jwt);
      deviceId = reg.deviceId;
      _pollIntervalSeconds = reg.pollIntervalSeconds > 0
          ? reg.pollIntervalSeconds
          : _defaultPollSeconds;
      await _identity.saveDeviceId(deviceId);
    } catch (e) {
      debugPrint('TetherLifecycle: register failed (ignored) — $e');
      // Fall back to a previously-persisted deviceId so a transient register
      // blip doesn't stop presence entirely.
      deviceId = await _identity.savedDeviceId();
      if (deviceId == null) return;
    }
    await _stamp(deviceId);
    _startTimer(deviceId);
  }

  Future<void> _stamp(int deviceId) async {
    final jwt = await _auth.getAccessToken();
    if (jwt == null) {
      _cancelTimer();
      return;
    }
    try {
      await _service.poll(deviceId, jwt);
    } catch (e) {
      debugPrint('TetherLifecycle: poll failed (ignored) — $e');
      // Swallow — the timer keeps running; a transient blip self-heals.
    }
  }

  void _startTimer(int deviceId) {
    _cancelTimer();
    _timer = Timer.periodic(
      Duration(seconds: _pollIntervalSeconds),
      (_) => unawaited(_stamp(deviceId)),
    );
  }

  void _cancelTimer() {
    _timer?.cancel();
    _timer = null;
  }
}
