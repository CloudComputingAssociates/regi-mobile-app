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

  /// POST {base}/image/upload/avatar as multipart/form-data. Field name is
  /// `image`; the part Content-Type is hard-coded to image/jpeg
  /// (image_picker re-encodes to JPEG). The overall request Content-Type
  /// (multipart with boundary) is set by MultipartRequest itself. The
  /// response body is ignored beyond the status code — the caller only
  /// needs to know it succeeded.
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
