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

/// Fetch-only client for `GET /user/settings`. Returns the raw decoded
/// response (regiMenu / dailyGoals / personalInfo). No PUT — editing
/// lives at app.regimenu.com.
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

  void dispose() {
    _client.close();
  }
}
