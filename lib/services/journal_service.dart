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

  void dispose() {
    _client.close();
  }
}
