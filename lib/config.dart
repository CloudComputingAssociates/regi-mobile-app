import 'package:flutter/foundation.dart' show kIsWeb;

/// Reads config exclusively from compile-time `--dart-define` values.
///
/// Auth0 requires a separate Application per platform — web/PWA uses an
/// Auth0 SPA app, Android/iOS use an Auth0 Native app. They have different
/// Client IDs and different allowed-callback rules. We carry both in env
/// (`AUTH0_CLIENT_ID_WEB`, `AUTH0_CLIENT_ID_NATIVE`) and pick at runtime
/// via `kIsWeb`. AUTH0_DOMAIN, AUTH0_AUDIENCE, API_BASE_URL are shared.
class Config {
  const Config._();

  static const String auth0Domain =
      String.fromEnvironment('AUTH0_DOMAIN');

  static const String _auth0ClientIdWeb =
      String.fromEnvironment('AUTH0_CLIENT_ID_WEB');

  static const String _auth0ClientIdNative =
      String.fromEnvironment('AUTH0_CLIENT_ID_NATIVE');

  static String get auth0ClientId =>
      kIsWeb ? _auth0ClientIdWeb : _auth0ClientIdNative;

  static const String auth0Audience =
      String.fromEnvironment('AUTH0_AUDIENCE');

  static const String apiBaseUrl =
      String.fromEnvironment('API_BASE_URL');
}
