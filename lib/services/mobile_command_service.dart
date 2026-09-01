import 'dart:convert';

import 'package:http/http.dart' as http;

import '../config.dart';

class MobileCommandException implements Exception {
  MobileCommandException(this.statusCode, this.body);
  final int statusCode;
  final String body;
  @override
  String toString() => 'MobileCommandException: $statusCode $body';
}

/// One command off the mobile bus (`regi.mobile.requests`), as the api hands it
/// to the phone over HTTP. The browser can't consume Kafka, so this HTTP pull
/// is the phone's only view of the queue.
///
/// [type] is the command grammar discriminator — `camera.captureMeal`,
/// `camera.captureAvatar`, … — and decides which upload endpoint the phone
/// hits. [title]/[description] are resolved SERVER-SIDE (e.g. the meal's name)
/// so the phone can say what it's capturing without knowing the domain.
/// [payload] carries type-specific ids (e.g. `{ mealId }`).
class MobileCommand {
  const MobileCommand({
    required this.commandId,
    required this.type,
    required this.title,
    required this.description,
    required this.payload,
  });

  final String commandId;
  final String type;
  final String title;
  final String description;
  final Map<String, dynamic> payload;

  /// Meal id for a `camera.captureMeal` command; null for types that don't
  /// carry one (e.g. `camera.captureAvatar`).
  int? get mealId {
    final raw = payload['mealId'];
    return raw is num ? raw.toInt() : null;
  }

  static MobileCommand? fromJson(Map<String, dynamic> json) {
    final commandId = json['commandId'];
    final type = json['type'];
    if (commandId is! String || commandId.isEmpty) return null;
    if (type is! String || type.isEmpty) return null;
    final rawPayload = json['payload'];
    return MobileCommand(
      commandId: commandId,
      type: type,
      title: json['title'] is String ? json['title'] as String : '',
      description:
          json['description'] is String ? json['description'] as String : '',
      payload: rawPayload is Map<String, dynamic> ? rawPayload : const {},
    );
  }
}

/// Client for the phone's side of the mobile command bus. Reads the head of the
/// per-user queue and reports completion so the api can clear the entry and
/// emit a `regi.mobile.responses` event (the Kadeck round-trip).
class MobileCommandService {
  MobileCommandService({http.Client? client})
      : _client = client ?? http.Client();

  final http.Client _client;

  /// GET {base}/mobile/command/next — the oldest un-acked command for the
  /// authenticated user, or null when the queue is empty (204). A 404 is also
  /// treated as "nothing pending". Peek, not pop: the entry stays until
  /// [complete] so a cancel/failure leaves it queued for a retry (that's the
  /// persistent-queue durability the whole design is for).
  Future<MobileCommand?> getNext(String jwt) async {
    final base = Config.apiBaseUrl;
    if (base.isEmpty) {
      throw MobileCommandException(
          0, 'API_BASE_URL missing — pass via --dart-define');
    }
    final res = await _client.get(
      Uri.parse('$base/mobile/command/next'),
      headers: {
        'Authorization': 'Bearer $jwt',
        'Content-Type': 'application/json',
      },
    );
    if (res.statusCode == 204 || res.statusCode == 404) return null;
    if (res.statusCode != 200) {
      throw MobileCommandException(res.statusCode, res.body);
    }
    if (res.body.trim().isEmpty) return null;
    final decoded = jsonDecode(res.body);
    if (decoded is! Map<String, dynamic>) return null;
    return MobileCommand.fromJson(decoded);
  }

  /// POST {base}/mobile/command/{commandId}/complete — the upload succeeded;
  /// the api clears the pending entry and emits a `completed` response event.
  /// Best-effort: a failure here only means the command may resurface on the
  /// next pull (at-least-once), never a lost photo.
  Future<void> complete(String commandId, String jwt) async {
    final base = Config.apiBaseUrl;
    if (base.isEmpty) {
      throw MobileCommandException(
          0, 'API_BASE_URL missing — pass via --dart-define');
    }
    final res = await _client.post(
      Uri.parse('$base/mobile/command/$commandId/complete'),
      headers: {
        'Authorization': 'Bearer $jwt',
        'Content-Type': 'application/json',
      },
    );
    if (res.statusCode != 200 && res.statusCode != 204) {
      throw MobileCommandException(res.statusCode, res.body);
    }
  }

  void dispose() {
    _client.close();
  }
}
