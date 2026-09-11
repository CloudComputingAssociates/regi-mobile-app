import 'dart:convert';

import 'package:http/http.dart' as http;

import '../config.dart';
import '../models/glp1.dart';

class Glp1Exception implements Exception {
  Glp1Exception(this.statusCode, this.body);
  final int statusCode;
  final String body;
  @override
  String toString() => 'Glp1Exception: $statusCode $body';
}

/// Client for the GLP-1 endpoints. Mirrors JournalService:
/// Config.apiBaseUrl guard, injected http.Client, JWT passed per call,
/// dispose() closes the client. All failures throw [Glp1Exception];
/// callers are expected to catch and silently degrade so a missing /
/// flaky GLP-1 backend never breaks chat or journal.
class Glp1Service {
  Glp1Service({http.Client? client}) : _client = client ?? http.Client();

  final http.Client _client;

  /// GET {base}/glp1/status?today=YYYY-MM-DD — computed status
  /// (enabled, isInjectionDay, nextDueDate, lastInjection, activeDose,
  /// daysSince, hoursSince). The today param is the CLIENT-local
  /// calendar date so a user in PST opening the app at 11:30pm gets
  /// PST-relative isInjectionDay, not UTC-rolled-over.
  Future<Glp1Status> getStatus(String jwt, {DateTime? today}) async {
    final base = Config.apiBaseUrl;
    if (base.isEmpty) {
      throw Glp1Exception(0, 'API_BASE_URL missing — pass via --dart-define');
    }
    final isoToday = _localDateString(today ?? DateTime.now());
    final res = await _client.get(
      Uri.parse('$base/glp1/status?today=$isoToday'),
      headers: {
        'Authorization': 'Bearer $jwt',
        'Content-Type': 'application/json',
      },
    );
    if (res.statusCode != 200) {
      throw Glp1Exception(res.statusCode, res.body);
    }
    final decoded = jsonDecode(res.body);
    if (decoded is! Map<String, dynamic>) {
      throw Glp1Exception(
        res.statusCode,
        'expected JSON object, got ${decoded.runtimeType}',
      );
    }
    return Glp1Status.fromJson(decoded);
  }

  /// POST {base}/glp1/injections — UPSERT by (userId, injectionDate).
  /// Server inserts (201) or overwrites the row for the same date
  /// (200). Both are success. Body is [Glp1Injection.toUpsertJson] —
  /// brand/mg/tier are intentionally omitted so the server snapshots
  /// them from the active settings.glp1 tier at write time.
  Future<Glp1Injection> upsertInjection(
    Glp1Injection inj,
    String jwt,
  ) async {
    final base = Config.apiBaseUrl;
    if (base.isEmpty) {
      throw Glp1Exception(0, 'API_BASE_URL missing — pass via --dart-define');
    }
    final res = await _client.post(
      Uri.parse('$base/glp1/injections'),
      headers: {
        'Authorization': 'Bearer $jwt',
        'Content-Type': 'application/json',
      },
      body: jsonEncode(inj.toUpsertJson()),
    );
    if (res.statusCode != 200 && res.statusCode != 201) {
      throw Glp1Exception(res.statusCode, res.body);
    }
    final decoded = jsonDecode(res.body);
    if (decoded is! Map<String, dynamic>) {
      throw Glp1Exception(
        res.statusCode,
        'expected JSON object, got ${decoded.runtimeType}',
      );
    }
    return Glp1Injection.fromJson(decoded);
  }

  /// GET {base}/glp1/injections?from=YYYY-MM-DD&to=YYYY-MM-DD —
  /// returns the user's injections in range. Tolerant to both
  /// response shapes (top-level array or `{injections: []}` wrapper)
  /// in case the server's response envelope evolves; silently
  /// returns an empty list on malformed payloads.
  Future<List<Glp1Injection>> listInjections(
    String jwt, {
    required DateTime from,
    required DateTime to,
  }) async {
    final base = Config.apiBaseUrl;
    if (base.isEmpty) {
      throw Glp1Exception(0, 'API_BASE_URL missing — pass via --dart-define');
    }
    final fromStr = _localDateString(from);
    final toStr = _localDateString(to);
    final res = await _client.get(
      Uri.parse('$base/glp1/injections?from=$fromStr&to=$toStr'),
      headers: {
        'Authorization': 'Bearer $jwt',
        'Content-Type': 'application/json',
      },
    );
    if (res.statusCode != 200) {
      throw Glp1Exception(res.statusCode, res.body);
    }
    final decoded = jsonDecode(res.body);
    List<dynamic>? rows;
    if (decoded is List) {
      rows = decoded;
    } else if (decoded is Map<String, dynamic> &&
        decoded['injections'] is List) {
      rows = decoded['injections'] as List<dynamic>;
    }
    if (rows == null) return const [];
    return rows
        .map((r) {
          if (r is Map<String, dynamic>) return Glp1Injection.fromJson(r);
          if (r is Map) return Glp1Injection.fromJson(r.cast<String, dynamic>());
          return null;
        })
        .whereType<Glp1Injection>()
        .toList();
  }

  /// DELETE {base}/glp1/injections/{id} — accepts 200 / 204 / 404 as
  /// success (404 = already gone, idempotent).
  Future<void> deleteInjection(int id, String jwt) async {
    final base = Config.apiBaseUrl;
    if (base.isEmpty) {
      throw Glp1Exception(0, 'API_BASE_URL missing — pass via --dart-define');
    }
    final res = await _client.delete(
      Uri.parse('$base/glp1/injections/$id'),
      headers: {
        'Authorization': 'Bearer $jwt',
        'Content-Type': 'application/json',
      },
    );
    if (res.statusCode != 200 &&
        res.statusCode != 204 &&
        res.statusCode != 404) {
      throw Glp1Exception(res.statusCode, res.body);
    }
  }

  /// LOCAL calendar date as YYYY-MM-DD (mirror of
  /// JournalService._localDateString — a user in PST opening the app
  /// at 11:30pm should see the PST date, not UTC-rolled-over).
  static String _localDateString(DateTime d) {
    final y = d.year.toString().padLeft(4, '0');
    final m = d.month.toString().padLeft(2, '0');
    final day = d.day.toString().padLeft(2, '0');
    return '$y-$m-$day';
  }

  void dispose() {
    _client.close();
  }
}
