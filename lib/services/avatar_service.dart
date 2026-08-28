import 'dart:typed_data';

import 'package:http/http.dart' as http;
import 'package:http_parser/http_parser.dart';

import '../config.dart';

class AvatarException implements Exception {
  AvatarException(this.statusCode, this.body);
  final int statusCode;
  final String body;
  @override
  String toString() => 'AvatarException: $statusCode $body';
}

/// Client for the user-avatar upload endpoint. Mirrors
/// JournalService.uploadPhoto — multipart with the raw bytes already in
/// memory (web-safe; XFile.path is a blob: URL on web and
/// MultipartFile.fromPath can't read it). No entity id: the avatar is keyed
/// by the authenticated user server-side.
class AvatarService {
  AvatarService({http.Client? client}) : _client = client ?? http.Client();

  final http.Client _client;

  /// POST {base}/image/upload/avatar as multipart/form-data. Config.apiBaseUrl
  /// already ends in /api, so this resolves to `{origin}/api/image/upload/avatar`
  /// per the API contract. Fields:
  ///   • `image`  — the JPEG bytes (field name MUST be "image")
  ///   • `source` — hard-coded "user" per the contract
  /// The part Content-Type is hard-coded to image/jpeg (image_picker re-encodes
  /// to JPEG). The overall request Content-Type (multipart with boundary) is set
  /// by MultipartRequest itself. The avatar is bound to the JWT user server-side,
  /// so NO userId is sent. Response is `{ success, cdn_url, thumbnail_url }`;
  /// nothing needs persisting (web re-hydrates via GET /user/profile), so the
  /// body is ignored beyond the status code.
  Future<void> uploadAvatar(
    Uint8List bytes,
    String filename,
    String jwt,
  ) async {
    final base = Config.apiBaseUrl;
    if (base.isEmpty) {
      throw AvatarException(0, 'API_BASE_URL missing — pass via --dart-define');
    }
    final req = http.MultipartRequest(
      'POST',
      Uri.parse('$base/image/upload/avatar'),
    )
      ..headers['Authorization'] = 'Bearer $jwt'
      ..fields['source'] = 'user'
      ..files.add(http.MultipartFile.fromBytes(
        'image',
        bytes,
        filename: filename,
        contentType: MediaType('image', 'jpeg'),
      ));
    final streamed = await req.send();
    final res = await http.Response.fromStream(streamed);
    if (res.statusCode != 200 && res.statusCode != 201) {
      throw AvatarException(res.statusCode, res.body);
    }
  }

  void dispose() {
    _client.close();
  }
}
