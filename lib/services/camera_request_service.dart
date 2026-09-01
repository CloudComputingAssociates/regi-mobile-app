import 'dart:convert';

import 'package:http/http.dart' as http;

import '../config.dart';

class CameraRequestException implements Exception {
  CameraRequestException(this.statusCode, this.body);
  final int statusCode;
  final String body;
  @override
  String toString() => 'CameraRequestException: $statusCode $body';
}

/// A pending "take a photo of this meal" request the web app queued for this
/// device. Produced web-side to the Kafka `camera-requests` topic (gated on
/// tether presence), consumed by the api into a per-user pending store, and
/// served to the phone here — the browser can't speak Kafka, so this HTTP
/// pull is the phone's only view of the queue. [mealName] is resolved
/// server-side from the food row so the Camera screen can title itself.
class PendingMealPhoto {
  const PendingMealPhoto({required this.mealId, required this.mealName});

  final int mealId;
  final String mealName;

  static PendingMealPhoto? fromJson(Map<String, dynamic> json) {
    final rawId = json['mealId'];
    final rawName = json['mealName'];
    if (rawId is! num) return null;
    return PendingMealPhoto(
      mealId: rawId.toInt(),
      mealName: rawName is String ? rawName : '',
    );
  }
}

/// Client for the meal-photo request queue. Only reads the head of the queue;
/// the api clears the request server-side once the matching product image is
/// uploaded, so there is no explicit ack call from the phone.
class CameraRequestService {
  CameraRequestService({http.Client? client})
      : _client = client ?? http.Client();

  final http.Client _client;

  /// GET {base}/camera/pending — the latest queued meal-photo request for the
  /// authenticated user, or null when the queue is empty (204). A 404 is also
  /// treated as "nothing pending" for tolerance.
  Future<PendingMealPhoto?> getPending(String jwt) async {
    final base = Config.apiBaseUrl;
    if (base.isEmpty) {
      throw CameraRequestException(
          0, 'API_BASE_URL missing — pass via --dart-define');
    }
    final res = await _client.get(
      Uri.parse('$base/camera/pending'),
      headers: {
        'Authorization': 'Bearer $jwt',
        'Content-Type': 'application/json',
      },
    );
    if (res.statusCode == 204 || res.statusCode == 404) return null;
    if (res.statusCode != 200) {
      throw CameraRequestException(res.statusCode, res.body);
    }
    if (res.body.trim().isEmpty) return null;
    final decoded = jsonDecode(res.body);
    if (decoded is! Map<String, dynamic>) return null;
    return PendingMealPhoto.fromJson(decoded);
  }

  void dispose() {
    _client.close();
  }
}
