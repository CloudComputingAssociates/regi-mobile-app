import 'dart:convert';

import 'package:http/http.dart' as http;

import '../config.dart';

class UserFoodException implements Exception {
  UserFoodException(this.statusCode, this.body);
  final int statusCode;
  final String body;
  @override
  String toString() => 'UserFoodException: $statusCode $body';
}

/// Result of a successful barcode lookup. Only the handful of fields the
/// scan screen renders today are lifted out; the raw decoded `food` map is
/// kept around so the beautification pass tomorrow can pull nutrition
/// facts / image URLs without a service change.
class ScannedFood {
  ScannedFood({
    required this.id,
    required this.name,
    required this.shortDescription,
    required this.upcCode,
    required this.raw,
  });

  /// Server food id.
  final int? id;

  /// The resolved product name — `food.description`. This is the "Name"
  /// the screen surfaces after a scan.
  final String name;

  /// The user-supplied short name echoed back — `food.shortDescription`.
  final String? shortDescription;

  final String? upcCode;

  /// Full decoded `food` object for later use.
  final Map<String, dynamic> raw;

  /// Full-size product image from the resolver, or null if absent/empty.
  String? get imageUrl => _nonEmpty(raw['foodImage']);

  /// Thumbnail product image, or null if absent/empty.
  String? get thumbnailUrl => _nonEmpty(raw['foodImageThumbnail']);

  static String? _nonEmpty(dynamic v) {
    final s = v?.toString().trim();
    return (s == null || s.isEmpty) ? null : s;
  }

  factory ScannedFood.fromFood(Map<String, dynamic> food) {
    return ScannedFood(
      id: food['id'] is int ? food['id'] as int : null,
      name: (food['description'] ?? '').toString(),
      shortDescription: food['shortDescription']?.toString(),
      upcCode: food['upcCode']?.toString(),
      raw: food,
    );
  }
}

/// Client for the user-foods endpoints. Today it only does the barcode
/// upsert used by the Food UPC scan screen.
class UserFoodService {
  UserFoodService({http.Client? client}) : _client = client ?? http.Client();

  final http.Client _client;

  /// POST {base}/userfoods/barcode — looks the UPC up server-side (UPC
  /// resolver + nutrition), creates/updates the user's food row, and
  /// returns the resolved food wrapped in `{ "food": {...} }`.
  ///
  /// [userDescription] is the user's optional short name; sent only when
  /// non-empty. [categoryId] defaults to 9 (processed food) per the
  /// current product decision — the scan screen has no category picker yet.
  Future<ScannedFood> lookupByBarcode(
    String upcCode,
    String jwt, {
    String? userDescription,
    int categoryId = 9,
  }) async {
    final base = Config.apiBaseUrl;
    if (base.isEmpty) {
      throw UserFoodException(0, 'API_BASE_URL missing — pass via --dart-define');
    }
    final body = <String, dynamic>{
      'upcCode': upcCode,
      'categoryId': categoryId,
    };
    final desc = userDescription?.trim();
    if (desc != null && desc.isNotEmpty) {
      body['userDescription'] = desc;
    }

    final res = await _client.post(
      Uri.parse('$base/userfoods/barcode'),
      headers: {
        'Authorization': 'Bearer $jwt',
        'Content-Type': 'application/json',
      },
      body: jsonEncode(body),
    );
    if (res.statusCode != 200 && res.statusCode != 201) {
      throw UserFoodException(res.statusCode, res.body);
    }

    final decoded = jsonDecode(res.body);
    // Tolerate both `{ "food": {...} }` and a bare food object.
    Map<String, dynamic>? food;
    if (decoded is Map<String, dynamic>) {
      if (decoded['food'] is Map) {
        food = (decoded['food'] as Map).cast<String, dynamic>();
      } else if (decoded.containsKey('description')) {
        food = decoded;
      }
    }
    if (food == null) {
      throw UserFoodException(
        res.statusCode,
        'unexpected response shape: ${res.body}',
      );
    }
    return ScannedFood.fromFood(food);
  }

  void dispose() => _client.close();
}
