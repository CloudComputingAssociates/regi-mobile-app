import 'dart:convert';

import 'package:http/http.dart' as http;

import '../config.dart';

class SettingsException implements Exception {
  SettingsException(this.statusCode, this.body);
  final int statusCode;
  final String body;
  @override
  String toString() => 'SettingsException: $statusCode $body';
}

/// Read + per-field write client for `/user/settings`. Reads return the
/// whole record (regiMenu / dailyGoals / personalInfo). Writes target a
/// single named field via PUT `/user/settings/field` — granular writes
/// only; full-record PUT is intentionally not exposed.
class SettingsService {
  SettingsService({http.Client? client}) : _client = client ?? http.Client();

  final http.Client _client;

  Future<Map<String, dynamic>> fetchAllSettings(String jwt) async {
    final base = Config.apiBaseUrl;
    if (base.isEmpty) {
      throw SettingsException(0, 'API_BASE_URL missing — pass via --dart-define');
    }
    final res = await _client.get(
      Uri.parse('$base/user/settings'),
      headers: {
        'Authorization': 'Bearer $jwt',
        'Content-Type': 'application/json',
      },
    );
    if (res.statusCode != 200) {
      throw SettingsException(res.statusCode, res.body);
    }
    final decoded = jsonDecode(res.body);
    if (decoded is! Map<String, dynamic>) {
      throw SettingsException(
        res.statusCode,
        'expected JSON object, got ${decoded.runtimeType}',
      );
    }
    return decoded;
  }

  /// Writes a single settings field. Body shape sent to the server:
  ///   `{ "field": <string>, "value": <number> }`
  /// `value` is emitted as a JSON NUMBER, never a string. Weight fields
  /// MUST be converted to kg by the caller — backend stores kg verbatim
  /// and does no units conversion.
  ///
  /// [endpoint] defaults to the canonical path; the gate may send a
  /// fully-qualified path (e.g. `api/user/settings/field`) via
  /// `UtteranceResult.call.endpoint`, which we strip of any leading
  /// `api/` so it composes cleanly with `Config.apiBaseUrl` (which
  /// already ends in `/api`).
  Future<void> setField({
    required String field,
    required num value,
    required String jwt,
    String endpoint = '/user/settings/field',
  }) async {
    final base = Config.apiBaseUrl;
    if (base.isEmpty) {
      throw SettingsException(0, 'API_BASE_URL missing — pass via --dart-define');
    }
    final res = await _client.put(
      _resolveUrl(base, endpoint),
      headers: {
        'Authorization': 'Bearer $jwt',
        'Content-Type': 'application/json',
      },
      body: jsonEncode({'field': field, 'value': value}),
    );
    if (res.statusCode != 200) {
      throw SettingsException(res.statusCode, res.body);
    }
  }

  Uri _resolveUrl(String base, String endpoint) {
    var path = endpoint;
    if (path.startsWith('/')) path = path.substring(1);
    if (path.startsWith('api/')) path = path.substring(4);
    return Uri.parse('$base/$path');
  }

  void dispose() {
    _client.close();
  }
}
