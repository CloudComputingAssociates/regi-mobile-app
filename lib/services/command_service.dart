import 'dart:convert';

import 'package:http/http.dart' as http;

import '../config.dart';
import '../models/utterance_result.dart';

/// Calls regi-api's utterance-classification gate.
///
/// Contract: POST {baseUrl}/command/utterance with `{ utterance: <text> }`
/// returns an `UtteranceResult`. On any failure — network error, non-200,
/// malformed JSON, missing base URL — `interpret` returns
/// [UtteranceResult.notUnderstood] so the caller falls through to the
/// existing chat pipeline. A gate failure must NEVER throw or block the
/// user from talking to Regi.
class CommandService {
  CommandService({http.Client? client}) : _client = client ?? http.Client();

  final http.Client _client;

  String get _baseUrl => Config.apiBaseUrl;

  Future<UtteranceResult> interpret({
    required String utterance,
    required String jwt,
  }) async {
    if (_baseUrl.isEmpty) return UtteranceResult.notUnderstood;
    try {
      final res = await _client.post(
        Uri.parse('$_baseUrl/command/utterance'),
        headers: {
          'Authorization': 'Bearer $jwt',
          'Content-Type': 'application/json',
        },
        body: jsonEncode({'utterance': utterance}),
      );
      if (res.statusCode != 200) {
        return UtteranceResult.notUnderstood;
      }
      final decoded = jsonDecode(res.body);
      if (decoded is! Map<String, dynamic>) {
        return UtteranceResult.notUnderstood;
      }
      return UtteranceResult.fromJson(decoded);
    } catch (_) {
      // Network, parse, or anything else — degrade to chat. By design.
      return UtteranceResult.notUnderstood;
    }
  }

  void dispose() {
    _client.close();
  }
}
