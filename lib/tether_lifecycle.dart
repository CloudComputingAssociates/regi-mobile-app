import 'dart:async';

import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';

import 'models/tether.dart';
import 'services/auth_service.dart';
import 'services/avatar_service.dart';
import 'services/desktop_browser.dart';
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
/// Tether runs by DEFAULT on every client — phone PWA (installed or in-browser),
/// native, iPad, etc. The ONLY session that is suppressed is a DESKTOP-CLASS
/// BROWSER belonging to a NON-privileged user: that's the web cockpit, which
/// only READS presence and must never register itself as a phone. Admin /
/// Developer / QA users MAY tether from a desktop browser (testing), so the
/// predicate is re-evaluated at every auth-gated point — a user who logs in as
/// Admin on desktop then starts tethering. See [_tetherSuppressed].
///
/// All register/poll failures are swallowed (debugPrint only) — a presence
/// heartbeat must never interrupt the user; the timer self-heals next tick.
class TetherLifecycle with WidgetsBindingObserver {
  TetherLifecycle(
    this._auth, {
    TetherService? service,
    TetherIdentity? identity,
    AvatarService? avatarService,
    ImagePicker? imagePicker,
    GlobalKey<ScaffoldMessengerState>? messengerKey,
  })  : _service = service ?? TetherService(),
        _identity = identity ?? TetherIdentity(),
        _avatarService = avatarService ?? AvatarService(),
        _imagePicker = imagePicker ?? ImagePicker(),
        _messengerKey = messengerKey;

  final AuthService _auth;
  final TetherService _service;
  final TetherIdentity _identity;
  final AvatarService _avatarService;
  final ImagePicker _imagePicker;

  /// Optional handle to the app-root ScaffoldMessenger so this context-less
  /// lifecycle can surface a brief toast on avatar capture success/failure.
  final GlobalKey<ScaffoldMessengerState>? _messengerKey;

  Timer? _timer;
  int _pollIntervalSeconds = _defaultPollSeconds;
  bool _started = false;
  bool _authWasAuthenticated = false;

  /// At-most-once command bookkeeping. [_handledCommandIds] dedups a commandId
  /// that a duplicate/retried poll might surface twice; [_handlingCommand]
  /// prevents a second poll tick from opening the camera again while a capture
  /// is already in flight (the loop keeps stamping every few seconds).
  final Set<String> _handledCommandIds = {};
  bool _handlingCommand = false;

  static const int _defaultPollSeconds = 3;

  /// Suppress tether ONLY for a desktop-class browser session owned by a
  /// non-privileged user (the web cockpit). Everything else — phone PWA,
  /// native, tablet, or a privileged user testing from desktop — tethers.
  /// Evaluated live (not cached) so a mid-session login as Admin flips it.
  bool get _tetherSuppressed => isDesktopBrowser() && !_auth.isPrivileged;

  /// Attach the observer + auth listener and evaluate once (covers app-start
  /// while already authenticated). Attaches on every client — the suppression
  /// decision is made per-action in [_registerStampAndLoop], not here, so a
  /// later privilege change (login as Admin) can still start the loop.
  void start() {
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
    if (!_started) return;
    _auth.removeListener(_onAuthChanged);
    WidgetsBinding.instance.removeObserver(this);
    _cancelTimer();
    _service.dispose();
    _avatarService.dispose();
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
    // Single suppression point: covers start / login-notify / resume, since all
    // three funnel through here. A non-privileged desktop browser never gets a
    // MobileDevices row.
    if (_tetherSuppressed) return;
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
    TetherPollResponse res;
    try {
      res = await _service.poll(deviceId, jwt);
    } catch (e) {
      debugPrint('TetherLifecycle: poll failed (ignored) — $e');
      // Swallow — the timer keeps running; a transient blip self-heals.
      return;
    }
    _dispatchCommand(res.command);
  }

  /// Route an at-most-once device command from a poll response. Unknown types
  /// are ignored; a commandId we've already handled (or one currently in
  /// flight) is skipped so we never double-fire the camera.
  void _dispatchCommand(TetherCommand? command) {
    if (command == null) return;
    if (_handledCommandIds.contains(command.commandId)) return;
    if (_handlingCommand) return;
    switch (command.type) {
      case 'captureAvatar':
        _handledCommandIds.add(command.commandId);
        unawaited(_handleCaptureAvatar());
        break;
      default:
        // Unknown command type — mark handled so we don't re-log it forever.
        _handledCommandIds.add(command.commandId);
        debugPrint('TetherLifecycle: ignoring unknown command ${command.type}');
    }
  }

  /// Open the camera, capture a photo, and upload it as the authenticated
  /// user's avatar. Permission denial / user-cancel returns null from the
  /// picker → abort quietly (no crash). All failures are swallowed with a
  /// debugPrint; the command is at-most-once, so on any miss the user simply
  /// retries from the web cockpit.
  Future<void> _handleCaptureAvatar() async {
    _handlingCommand = true;
    try {
      final XFile? xfile;
      try {
        // Downscale at capture: the server resizes to 720×720 + an 80×80 thumb,
        // so a ~1–2MP JPEG is plenty and stays well under the 10MB cap. These
        // params make image_picker re-encode/resize before we ever read bytes.
        xfile = await _imagePicker.pickImage(
          source: ImageSource.camera,
          maxWidth: 1280,
          maxHeight: 1280,
          imageQuality: 85,
        );
      } catch (e) {
        // Permission denied / no camera / platform error — abort quietly.
        debugPrint('TetherLifecycle: avatar capture cancelled — $e');
        return;
      }
      if (xfile == null) return; // user cancelled
      final bytes = await xfile.readAsBytes();
      final jwt = await _auth.getAccessToken();
      if (jwt == null) {
        debugPrint('TetherLifecycle: avatar upload skipped — no token');
        return;
      }
      await _avatarService.uploadAvatar(bytes, xfile.name, jwt);
      debugPrint('TetherLifecycle: avatar uploaded');
      _toast('Avatar updated');
    } catch (e) {
      debugPrint('TetherLifecycle: avatar upload failed (ignored) — $e');
      _toast('Avatar upload failed — retry from the web app');
    } finally {
      _handlingCommand = false;
    }
  }

  /// Best-effort toast via the app-root messenger. No-op if no key was wired
  /// or the messenger isn't mounted — a missed confirmation never matters.
  void _toast(String message) {
    final messenger = _messengerKey?.currentState;
    if (messenger == null) return;
    messenger
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(content: Text(message), duration: const Duration(seconds: 3)),
      );
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
