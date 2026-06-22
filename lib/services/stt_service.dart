import 'dart:convert';
import 'dart:typed_data';

import 'package:http/http.dart' as http;

import '../config.dart';

/// Result of a successful POST {API_BASE_URL}/speech/stt/transcribe call.
/// Mirrors the TranscribeResponse definition in regi-api's
/// schemas/stt.schema.json. Hand-transcribed (no codegen), tolerant to
/// missing/extra fields per the model-style guideline.
class TranscribeResult {
  const TranscribeResult({
    required this.transcript,
    required this.languageCode,
    required this.durationSeconds,
  });

  final String transcript;
  final String languageCode;
  final double durationSeconds;

  factory TranscribeResult.fromJson(Map<String, dynamic> j) {
    return TranscribeResult(
      transcript: _str(j['transcript']) ?? '',
      languageCode: _str(j['languageCode']) ?? 'en-US',
      durationSeconds: _double(j['durationSeconds']) ?? 0.0,
    );
  }
}

/// Typed exception for /api/speech/stt/transcribe errors. Carries the
/// server's machine-readable [code] (e.g. 'no_speech_detected',
/// 'gcp_failed'), the human [detail], and the HTTP [httpStatus] so
/// callers can present different UX for "didn't hear you" (422) vs
/// "transcription unavailable" (502) without string-matching the body.
class SpeechError implements Exception {
  SpeechError({
    required this.code,
    required this.detail,
    required this.httpStatus,
  });

  /// Short machine-readable code from the error envelope. Sentinel
  /// 'network_error' / 'invalid_response' for client-side failures
  /// before the server's envelope is even reachable.
  final String code;

  final String detail;
  final int httpStatus;

  @override
  String toString() => 'SpeechError($httpStatus $code): $detail';
}

/// Wraps `POST {API_BASE_URL}/speech/stt/transcribe` on regi-api.
///
/// Single-shot, synchronous: the client records audio between PTT press
/// and release locally, then sends the whole blob once. There is no
/// streaming/partials path — that's the whole point of this endpoint
/// (no restart-on-silence dedup artifacts).
class SttService {
  SttService({http.Client? client}) : _client = client ?? http.Client();

  final http.Client _client;

  String get _baseUrl => Config.apiBaseUrl;

  /// Sends [audio] to the server for transcription.
  ///
  /// [format] must match the codec the recorder actually produced — see
  /// the endpoint's accepted values (opus, webm_opus, ogg_opus, m4a,
  /// wav, flac, mp3). Mismatched values are rejected server-side as
  /// 400 unsupported_format.
  ///
  /// Throws [SpeechError] on any non-200 response or network/parse
  /// failure. The server's error envelope (`{error, detail}`) is
  /// surfaced verbatim when available.
  Future<TranscribeResult> transcribe({
    required Uint8List audio,
    required String format,
    required String jwt,
    String language = 'en-US',
  }) async {
    if (_baseUrl.isEmpty) {
      throw SpeechError(
        code: 'config_missing',
        detail: 'API_BASE_URL missing — pass via --dart-define',
        httpStatus: 0,
      );
    }
    if (audio.isEmpty) {
      throw SpeechError(
        code: 'missing_audio',
        detail: 'audio buffer is empty (recorder produced 0 bytes)',
        httpStatus: 0,
      );
    }

    final req = http.MultipartRequest(
      'POST',
      Uri.parse('$_baseUrl/speech/stt/transcribe'),
    )
      ..headers['Authorization'] = 'Bearer $jwt'
      ..fields['format'] = format
      ..fields['language'] = language
      ..files.add(http.MultipartFile.fromBytes(
        'audio',
        audio,
        filename: 'recording.$format',
      ));

    http.Response res;
    try {
      final streamed = await _client.send(req);
      res = await http.Response.fromStream(streamed);
    } catch (e) {
      throw SpeechError(
        code: 'network_error',
        detail: 'cannot reach API: $e',
        httpStatus: 0,
      );
    }

    if (res.statusCode != 200) {
      throw _decodeError(res);
    }

    Map<String, dynamic> body;
    try {
      final raw = jsonDecode(res.body);
      if (raw is! Map<String, dynamic>) {
        throw SpeechError(
          code: 'invalid_response',
          detail: 'expected JSON object, got ${raw.runtimeType}',
          httpStatus: res.statusCode,
        );
      }
      body = raw;
    } on FormatException catch (e) {
      throw SpeechError(
        code: 'invalid_response',
        detail: 'response not JSON: $e',
        httpStatus: res.statusCode,
      );
    }

    return TranscribeResult.fromJson(body);
  }

  /// Decodes the server's `{error, detail}` envelope into a typed
  /// SpeechError. Falls back to a generic code if the body isn't the
  /// expected shape (still happens on infrastructure-level 5xx pages).
  SpeechError _decodeError(http.Response res) {
    String code = 'http_${res.statusCode}';
    String detail = res.body;
    try {
      final raw = jsonDecode(res.body);
      if (raw is Map<String, dynamic>) {
        final c = _str(raw['error']);
        final d = _str(raw['detail']);
        if (c != null) code = c;
        if (d != null) detail = d;
      }
    } catch (_) {
      // Non-JSON body — keep code = http_<status>, detail = raw body.
    }
    return SpeechError(
      code: code,
      detail: detail,
      httpStatus: res.statusCode,
    );
  }

  void dispose() {
    _client.close();
  }
}

String? _str(dynamic v) {
  if (v is String && v.isNotEmpty) return v;
  return null;
}

double? _double(dynamic v) {
  if (v is num) return v.toDouble();
  if (v is String) return double.tryParse(v);
  return null;
}
