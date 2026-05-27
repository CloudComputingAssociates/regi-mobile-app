import 'dart:convert';

import 'package:audioplayers/audioplayers.dart';
import 'package:http/http.dart' as http;

import '../config.dart';

/// Wraps `POST {API_BASE_URL}/tts` on the regi-api backend.
///
/// Server contract (matches schemas/tts.schema.json in regi-api):
///   Request:  { text, voice?, languageCode?, speakingRate?, useSSML? }
///   Response: { audioBase64, mimeType, sizeBytes, voiceUsed, latencyMs? }
///
/// JWT is passed per-call (same pattern as ChatService.streamChat) — caller
/// fetches a fresh token from AuthService before each synthesis.
///
/// Failure mode: throws [TtsException]. Caller decides whether to surface,
/// log, or swallow. POC currently surfaces them in the chat output.
class TtsService {
  TtsService({AudioPlayer? player}) : _player = player ?? AudioPlayer();

  final AudioPlayer _player;

  String get _baseUrl => Config.apiBaseUrl;

  /// Synthesizes [text] on the server and plays the returned MP3.
  /// Throws [TtsException] on any failure (HTTP, parse, decode, playback).
  Future<void> speak(
    String text, {
    required String jwt,
    String? voice,
    String? languageCode,
    double? speakingRate,
    bool? useSSML,
  }) async {
    if (text.trim().isEmpty) return;
    if (_baseUrl.isEmpty) {
      throw TtsException('API_BASE_URL not configured');
    }

    final body = <String, dynamic>{'text': text};
    if (voice != null) body['voice'] = voice;
    if (languageCode != null) body['languageCode'] = languageCode;
    if (speakingRate != null) body['speakingRate'] = speakingRate;
    if (useSSML != null) body['useSSML'] = useSSML;

    http.Response res;
    try {
      res = await http.post(
        Uri.parse('$_baseUrl/tts'),
        headers: {
          'Content-Type': 'application/json',
          'Authorization': 'Bearer $jwt',
        },
        body: jsonEncode(body),
      );
    } catch (e) {
      throw TtsException('Cannot reach API (network or CORS) — $e');
    }

    if (res.statusCode != 200) {
      final snippet = res.body.length > 200 ? '${res.body.substring(0, 200)}…' : res.body;
      final preamble = switch (res.statusCode) {
        404 => 'TTS endpoint not found (not deployed yet?)',
        503 => 'TTS unavailable (server-side GCP creds issue)',
        401 => 'Auth failed (JWT expired or invalid)',
        _ => 'Server error',
      };
      throw TtsException('$preamble — HTTP ${res.statusCode}: $snippet');
    }

    Map<String, dynamic> decoded;
    try {
      final raw = jsonDecode(res.body);
      if (raw is! Map<String, dynamic>) {
        throw TtsException('unexpected response shape: ${raw.runtimeType}');
      }
      decoded = raw;
    } on FormatException catch (e) {
      throw TtsException('response not JSON: $e');
    }

    final b64 = decoded['audioBase64'];
    if (b64 is! String || b64.isEmpty) {
      throw TtsException('response missing audioBase64');
    }

    try {
      final bytes = base64Decode(b64);
      // Defensive: tear down any in-flight playback before starting a new
      // one. On web, calling play() twice in close succession against the
      // same AudioPlayer can result in overlapping audio elements (the
      // previous blob URL not yet released). stop() + release-mode reset
      // guarantees the player is in a clean state per synthesis.
      await _player.stop();
      await _player.setReleaseMode(ReleaseMode.release);
      await _player.play(BytesSource(bytes));
    } catch (e) {
      throw TtsException('playback failed: $e');
    }
  }

  Future<void> stop() => _player.stop();
  void dispose() => _player.dispose();
}

class TtsException implements Exception {
  TtsException(this.message);
  final String message;
  @override
  String toString() => message;
}
