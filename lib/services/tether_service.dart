import 'dart:convert';

import 'package:http/http.dart' as http;

import '../config.dart';
import '../models/tether.dart';

class TetherException implements Exception {
  TetherException(this.statusCode, this.body);
  final int statusCode;
  final String body;
  @override
  String toString() => 'TetherException: $statusCode $body';
}

/// Client for the Phase 1 Mobile Tether presence write paths. Mirrors
/// Glp1Service: Config.apiBaseUrl guard, injected http.Client, JWT passed per
/// call, dispose() closes the client. All failures throw [TetherException];
/// the lifecycle driver catches and silently degrades so a flaky presence
/// backend never interrupts the user. Config.apiBaseUrl already ends in /api,
/// so paths are `$base/tether/...` — never a second /api.
class TetherService {
  TetherService({http.Client? client}) : _client = client ?? http.Client();

  final http.Client _client;

  /// POST {base}/tether/register — idempotent upsert of the caller's device by
  /// (userId, deviceInstanceId). Returns the durable deviceId + poll cadence.
  Future<TetherRegisterResponse> register(
    TetherRegisterRequest req,
    String jwt,
  ) async {
    final base = Config.apiBaseUrl;
    if (base.isEmpty) {
      throw TetherException(0, 'API_BASE_URL missing — pass via --dart-define');
    }
    final res = await _client.post(
      Uri.parse('$base/tether/register'),
      headers: {
        'Authorization': 'Bearer $jwt',
        'Content-Type': 'application/json',
      },
      body: jsonEncode(req.toJson()),
    );
    if (res.statusCode != 200 && res.statusCode != 201) {
      throw TetherException(res.statusCode, res.body);
    }
    final decoded = jsonDecode(res.body);
    if (decoded is! Map<String, dynamic>) {
      throw TetherException(
        res.statusCode,
        'expected JSON object, got ${decoded.runtimeType}',
      );
    }
    return TetherRegisterResponse.fromJson(decoded);
  }

  /// POST {base}/tether/poll — the presence heartbeat; stamps LastSeenUtc for
  /// the durable deviceId. Returns ok + the (possibly drifted) poll cadence.
  Future<TetherPollResponse> poll(int deviceId, String jwt) async {
    final base = Config.apiBaseUrl;
    if (base.isEmpty) {
      throw TetherException(0, 'API_BASE_URL missing — pass via --dart-define');
    }
    final res = await _client.post(
      Uri.parse('$base/tether/poll'),
      headers: {
        'Authorization': 'Bearer $jwt',
        'Content-Type': 'application/json',
      },
      body: jsonEncode(TetherPollRequest(deviceId: deviceId).toJson()),
    );
    if (res.statusCode != 200) {
      throw TetherException(res.statusCode, res.body);
    }
    final decoded = jsonDecode(res.body);
    if (decoded is! Map<String, dynamic>) {
      throw TetherException(
        res.statusCode,
        'expected JSON object, got ${decoded.runtimeType}',
      );
    }
    return TetherPollResponse.fromJson(decoded);
  }

  /// POST {base}/tether/ack — advance this device's cursor past a handled
  /// command so the server stops redelivering it, and publish the result to
  /// the web. Idempotent: re-acking the same messageId is a safe 200 no-op.
  /// [status] must be exactly 'done' or 'failed'. [result] is an optional
  /// opaque JSON body echoed to the web (e.g. an upload ref); omitted when null.
  Future<void> ack(
    int deviceId,
    String messageId,
    String status,
    String jwt, {
    Object? result,
  }) async {
    final base = Config.apiBaseUrl;
    if (base.isEmpty) {
      throw TetherException(0, 'API_BASE_URL missing — pass via --dart-define');
    }
    final res = await _client.post(
      Uri.parse('$base/tether/ack'),
      headers: {
        'Authorization': 'Bearer $jwt',
        'Content-Type': 'application/json',
      },
      body: jsonEncode({
        'deviceId': deviceId,
        'messageId': messageId,
        'status': status,
        if (result != null) 'result': result,
      }),
    );
    if (res.statusCode != 200) {
      throw TetherException(res.statusCode, res.body);
    }
  }

  void dispose() {
    _client.close();
  }
}
