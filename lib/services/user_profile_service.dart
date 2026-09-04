import 'dart:convert';

import 'package:http/http.dart' as http;

import '../config.dart';

class UserProfileException implements Exception {
  UserProfileException(this.statusCode, this.body);
  final int statusCode;
  final String body;
  @override
  String toString() => 'UserProfileException: $statusCode $body';
}

/// The caller's account profile, GET /api/user/profile. Always the JWT user —
/// no client-supplied id — so it's the authoritative "who am I logged in as"
/// on this device. [displayName] is nullable (backfilled from the Auth0 name
/// claim server-side); [email] is always present.
class UserProfile {
  const UserProfile({
    required this.id,
    required this.email,
    this.displayName,
    this.avatarUrl,
    this.avatarThumbnailUrl,
  });

  final int id;
  final String email;
  final String? displayName;
  final String? avatarUrl;
  final String? avatarThumbnailUrl;

  /// A friendly name to greet with: the display name if set, else the local
  /// part of the email, else a neutral fallback.
  String get greetingName {
    final dn = displayName?.trim();
    if (dn != null && dn.isNotEmpty) return dn;
    final at = email.indexOf('@');
    if (at > 0) return email.substring(0, at);
    return email.isNotEmpty ? email : 'there';
  }

  factory UserProfile.fromJson(Map<String, dynamic> json) => UserProfile(
        id: (json['id'] as num).toInt(),
        email: json['email'] is String ? json['email'] as String : '',
        displayName:
            json['displayName'] is String ? json['displayName'] as String : null,
        avatarUrl:
            json['avatarUrl'] is String ? json['avatarUrl'] as String : null,
        avatarThumbnailUrl: json['avatarThumbnailUrl'] is String
            ? json['avatarThumbnailUrl'] as String
            : null,
      );
}

/// Client for the user profile endpoint.
class UserProfileService {
  UserProfileService({http.Client? client}) : _client = client ?? http.Client();

  final http.Client _client;

  /// GET {base}/user/profile — the authenticated user's profile.
  Future<UserProfile> getProfile(String jwt) async {
    final base = Config.apiBaseUrl;
    if (base.isEmpty) {
      throw UserProfileException(
          0, 'API_BASE_URL missing — pass via --dart-define');
    }
    final res = await _client.get(
      Uri.parse('$base/user/profile'),
      headers: {
        'Authorization': 'Bearer $jwt',
        'Content-Type': 'application/json',
      },
    );
    if (res.statusCode != 200) {
      throw UserProfileException(res.statusCode, res.body);
    }
    final decoded = jsonDecode(res.body);
    if (decoded is! Map<String, dynamic>) {
      throw UserProfileException(
        res.statusCode,
        'expected JSON object, got ${decoded.runtimeType}',
      );
    }
    return UserProfile.fromJson(decoded);
  }

  void dispose() {
    _client.close();
  }
}
