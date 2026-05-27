import 'dart:async';

import 'package:auth0_flutter/auth0_flutter.dart';
import 'package:auth0_flutter/auth0_flutter_web.dart';
import 'package:flutter/foundation.dart';

import '../config.dart';

class AuthService extends ChangeNotifier {
  AuthService();

  Auth0? _auth0Native;
  Auth0Web? _auth0Web;
  Credentials? _credentials;
  bool _initialized = false;

  bool get isAuthenticated => _credentials != null;
  UserProfile? get currentUser => _credentials?.user;

  String get _domain => Config.auth0Domain;
  String get _clientId => Config.auth0ClientId;
  String get _audience => Config.auth0Audience;

  Future<void> initialize() async {
    if (_initialized) return;
    if (_domain.isEmpty || _clientId.isEmpty) {
      throw StateError(
        'AUTH0_DOMAIN / AUTH0_CLIENT_ID missing — '
        'pass via --dart-define (or set in Netlify env vars).',
      );
    }

    if (kIsWeb) {
      _auth0Web = Auth0Web(_domain, _clientId);
      final creds = await _auth0Web!.onLoad(
        audience: _audience.isNotEmpty ? _audience : null,
      );
      if (creds != null) {
        _credentials = creds;
      }
    } else {
      _auth0Native = Auth0(_domain, _clientId);
      // Silent restore: if a refresh token from a prior session is still in
      // the keystore, hasValidCredentials() refreshes it and returns true with
      // no UI. Native users only see the Auth0 login page on first launch or
      // after explicit logout.
      try {
        final manager = _auth0Native!.credentialsManager;
        if (await manager.hasValidCredentials()) {
          _credentials = await manager.credentials();
        }
      } catch (_) {
        // No stored creds, or refresh failed — fall through to login screen.
      }
    }

    _initialized = true;
    notifyListeners();
  }

  Future<void> login() async {
    await initialize();
    if (kIsWeb) {
      await _auth0Web!.loginWithRedirect(
        redirectUrl: Uri.base.origin,
        audience: _audience.isNotEmpty ? _audience : null,
      );
    } else {
      final creds = await _auth0Native!
          .webAuthentication(scheme: 'com.regimenu.app')
          .login(
            audience: _audience.isNotEmpty ? _audience : null,
            scopes: const {'openid', 'profile', 'email', 'offline_access'},
          );
      await _auth0Native!.credentialsManager.storeCredentials(creds);
      _credentials = creds;
      notifyListeners();
    }
  }

  Future<void> logout() async {
    if (kIsWeb) {
      await _auth0Web!.logout(returnToUrl: Uri.base.origin);
    } else {
      await _auth0Native!.webAuthentication(scheme: 'com.regimenu.app').logout();
      await _auth0Native!.credentialsManager.clearCredentials();
    }
    _credentials = null;
    notifyListeners();
  }

  Future<String?> getAccessToken() async {
    if (_credentials == null) return null;
    final expires = _credentials!.expiresAt;
    if (expires.isAfter(DateTime.now().add(const Duration(seconds: 30)))) {
      return _credentials!.accessToken;
    }
    if (kIsWeb) {
      final refreshed = await _auth0Web!.credentials(
        audience: _audience.isNotEmpty ? _audience : null,
      );
      _credentials = refreshed;
      notifyListeners();
      return refreshed.accessToken;
    } else {
      final refreshed = await _auth0Native!.credentialsManager.credentials();
      _credentials = refreshed;
      notifyListeners();
      return refreshed.accessToken;
    }
  }
}
