import 'dart:convert';
import 'dart:typed_data';

import 'package:http/http.dart' as http;
import 'package:http_parser/http_parser.dart';

import '../config.dart';
import '../models/journal_entry.dart';

class JournalException implements Exception {
  JournalException(this.statusCode, this.body);
  final int statusCode;
  final String body;
  @override
  String toString() => 'JournalException: $statusCode $body';
}

/// Client for the journal endpoints. Creates an entry (POST) and uploads
/// the optional photo as a separate multipart PUT once the entry has an
/// id — server-side, photo storage is gated on the entry already
/// existing, which is why these are two calls instead of one.
class JournalService {
  JournalService({http.Client? client}) : _client = client ?? http.Client();

  final http.Client _client;

  /// POST {base}/journal — UPSERT by (userId, entryDate). The server
  /// inserts a new row (201) or overwrites the existing row for the same
  /// date (200). Both are success. Body is [JournalEntry.toUpsertJson] —
  /// a complete write-over of every mutable field; anything absent is
  /// stored as null. The response is always the full entry with
  /// journalEntryId / createdAt / updatedAt populated.
  Future<JournalEntry> upsertEntry(JournalEntry entry, String jwt) async {
    final base = Config.apiBaseUrl;
    if (base.isEmpty) {
      throw JournalException(0, 'API_BASE_URL missing — pass via --dart-define');
    }
    final res = await _client.post(
      Uri.parse('$base/journal'),
      headers: {
        'Authorization': 'Bearer $jwt',
        'Content-Type': 'application/json',
      },
      body: jsonEncode(entry.toUpsertJson()),
    );
    if (res.statusCode != 200 && res.statusCode != 201) {
      throw JournalException(res.statusCode, res.body);
    }
    final decoded = jsonDecode(res.body);
    if (decoded is! Map<String, dynamic>) {
      throw JournalException(
        res.statusCode,
        'expected JSON object, got ${decoded.runtimeType}',
      );
    }
    return JournalEntry.fromJson(decoded);
  }

  /// GET {base}/journal?from=YYYY-MM-DD&to=YYYY-MM-DD&limit=1 with the
  /// device's LOCAL calendar date on both ends. Returns the entry for
  /// today if one exists, else null. Used by the Journal overlay to
  /// pre-fill the form so a user who saved on the web sees the same
  /// state on the phone.
  ///
  /// Tolerant to two response shapes for safety:
  ///   • top-level JSON array  → entries[0]
  ///   • `{ "entries": [...] }` wrapper → wrapper.entries[0]
  /// Anything else degrades to null (no crash, no entry).
  Future<JournalEntry?> getTodayEntry(String jwt) async {
    final base = Config.apiBaseUrl;
    if (base.isEmpty) {
      throw JournalException(0, 'API_BASE_URL missing — pass via --dart-define');
    }
    final today = _localDateString(DateTime.now());
    final res = await _client.get(
      Uri.parse('$base/journal?from=$today&to=$today&limit=1'),
      headers: {
        'Authorization': 'Bearer $jwt',
        'Content-Type': 'application/json',
      },
    );
    if (res.statusCode == 404) return null;
    if (res.statusCode != 200) {
      throw JournalException(res.statusCode, res.body);
    }

    final decoded = jsonDecode(res.body);
    List<dynamic>? rows;
    if (decoded is List) {
      rows = decoded;
    } else if (decoded is Map<String, dynamic> && decoded['entries'] is List) {
      rows = decoded['entries'] as List<dynamic>;
    }
    if (rows == null || rows.isEmpty) return null;
    final first = rows.first;
    if (first is Map<String, dynamic>) return JournalEntry.fromJson(first);
    if (first is Map) return JournalEntry.fromJson(first.cast<String, dynamic>());
    return null;
  }

  /// GET {base}/journal/{id} — entry detail. Unlike the LIST endpoint
  /// (which by server design omits photoSignedUrl to save signing
  /// calls), this is the read path that mints a fresh V4 signed URL
  /// into the response when a photo is attached. The overlay's prefill
  /// flow calls LIST to find today's id, then this to get the URL.
  Future<JournalEntry?> getEntryById(int id, String jwt) async {
    final base = Config.apiBaseUrl;
    if (base.isEmpty) {
      throw JournalException(0, 'API_BASE_URL missing — pass via --dart-define');
    }
    final res = await _client.get(
      Uri.parse('$base/journal/$id'),
      headers: {
        'Authorization': 'Bearer $jwt',
        'Content-Type': 'application/json',
      },
    );
    if (res.statusCode == 404) return null;
    if (res.statusCode != 200) {
      throw JournalException(res.statusCode, res.body);
    }
    final decoded = jsonDecode(res.body);
    if (decoded is! Map<String, dynamic>) {
      throw JournalException(
        res.statusCode,
        'expected JSON object, got ${decoded.runtimeType}',
      );
    }
    return JournalEntry.fromJson(decoded);
  }

  /// LOCAL calendar date as YYYY-MM-DD. A user in PST opening the app at
  /// 11:30pm should see the PST date, not the UTC-rolled-over date.
  static String _localDateString(DateTime d) {
    final y = d.year.toString().padLeft(4, '0');
    final m = d.month.toString().padLeft(2, '0');
    final day = d.day.toString().padLeft(2, '0');
    return '$y-$m-$day';
  }

  /// PUT {base}/journal/{id}/photo as multipart/form-data, sending the
  /// raw bytes the caller already has in memory (the same Uint8List
  /// feeding the bloom's Image.memory preview). Bytes instead of a path
  /// keeps this web-safe — XFile.path is a blob: URL on web and
  /// MultipartFile.fromPath can't read it.
  ///
  /// Field name is `photo`. Content-Type for the part is hard-coded to
  /// image/jpeg — image_picker re-encodes to JPEG on both iOS and
  /// Android. The overall request Content-Type (multipart with boundary)
  /// is set by MultipartRequest itself.
  Future<JournalEntry> uploadPhoto(
    int journalEntryId,
    Uint8List bytes,
    String filename,
    String jwt,
  ) async {
    final base = Config.apiBaseUrl;
    if (base.isEmpty) {
      throw JournalException(0, 'API_BASE_URL missing — pass via --dart-define');
    }
    final req = http.MultipartRequest(
      'PUT',
      Uri.parse('$base/journal/$journalEntryId/photo'),
    )
      ..headers['Authorization'] = 'Bearer $jwt'
      ..files.add(http.MultipartFile.fromBytes(
        'photo',
        bytes,
        filename: filename,
        contentType: MediaType('image', 'jpeg'),
      ));
    final streamed = await req.send();
    final res = await http.Response.fromStream(streamed);
    if (res.statusCode != 200 && res.statusCode != 201) {
      throw JournalException(res.statusCode, res.body);
    }
    final decoded = jsonDecode(res.body);
    if (decoded is! Map<String, dynamic>) {
      throw JournalException(
        res.statusCode,
        'expected JSON object, got ${decoded.runtimeType}',
      );
    }
    return JournalEntry.fromJson(decoded);
  }

  /// DELETE {base}/journal/{id}/photo — removes the stored photo for the
  /// entry without touching any other field. Accepts 200 or 204 (no
  /// content) as success. The caller is responsible for refreshing the
  /// local UI (clearing _existingPhotoUrl, etc).
  Future<void> deletePhoto(int journalEntryId, String jwt) async {
    final base = Config.apiBaseUrl;
    if (base.isEmpty) {
      throw JournalException(0, 'API_BASE_URL missing — pass via --dart-define');
    }
    final res = await _client.delete(
      Uri.parse('$base/journal/$journalEntryId/photo'),
      headers: {
        'Authorization': 'Bearer $jwt',
        'Content-Type': 'application/json',
      },
    );
    if (res.statusCode != 200 &&
        res.statusCode != 204 &&
        res.statusCode != 404) {
      // 404 = already gone; treat as success.
      throw JournalException(res.statusCode, res.body);
    }
  }

  void dispose() {
    _client.close();
  }
}
