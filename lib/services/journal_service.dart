import 'dart:convert';

import 'package:http/http.dart' as http;

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

  /// POST {base}/journal. Body is [JournalEntry.toCreateJson] — writable
  /// fields only, nulls/empties dropped. The server returns the created
  /// entry (with journalEntryId, createdAt, updatedAt populated).
  Future<JournalEntry> createEntry(JournalEntry entry, String jwt) async {
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
      body: jsonEncode(entry.toCreateJson()),
    );
    if (res.statusCode != 201) {
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

  /// PUT {base}/journal/{id}/photo as multipart/form-data. Field name is
  /// `photo`. The server stores the file and returns the updated entry,
  /// whose [JournalEntry.photoSignedUrl] is the short-lived URL the bloom
  /// uses to render the just-uploaded image.
  ///
  /// Note: Content-Type is intentionally NOT set here — MultipartRequest
  /// sets it (with the correct boundary) when the request is sent.
  Future<JournalEntry> uploadPhoto(
    int journalEntryId,
    String filePath,
    String jwt,
  ) async {
    final base = Config.apiBaseUrl;
    if (base.isEmpty) {
      throw JournalException(0, 'API_BASE_URL missing — pass via --dart-define');
    }
    final req = http.MultipartRequest(
      'PUT',
      Uri.parse('$base/journal/$journalEntryId/photo'),
    );
    req.headers['Authorization'] = 'Bearer $jwt';
    req.files.add(await http.MultipartFile.fromPath('photo', filePath));

    final streamed = await _client.send(req);
    final res = await http.Response.fromStream(streamed);
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

  void dispose() {
    _client.close();
  }
}
