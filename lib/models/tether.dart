// lib/models/tether.dart
//
// Hand-transcribed from schemas/tether.schema.json (regi-api). Dart models are
// hand-maintained (house convention) — keep in sync with the schema; do not
// invent fields. This session uses register + poll only (presence writes).

/// POST /tether/register body. deviceInstanceId is the stable per-install dedup
/// key; deviceModel + appVersion are optional.
class TetherRegisterRequest {
  const TetherRegisterRequest({
    required this.deviceInstanceId,
    required this.platform,
    required this.deviceName,
    this.deviceModel,
    this.appVersion,
  });

  final String deviceInstanceId;
  final String platform;
  final String deviceName;
  final String? deviceModel;
  final String? appVersion;

  Map<String, dynamic> toJson() => {
        'deviceInstanceId': deviceInstanceId,
        'platform': platform,
        'deviceName': deviceName,
        if (deviceModel != null) 'deviceModel': deviceModel,
        if (appVersion != null) 'appVersion': appVersion,
      };
}

/// POST /tether/register response — the durable server device id + poll cadence.
class TetherRegisterResponse {
  const TetherRegisterResponse({
    required this.deviceId,
    required this.pollIntervalSeconds,
  });

  final int deviceId;
  final int pollIntervalSeconds;

  factory TetherRegisterResponse.fromJson(Map<String, dynamic> json) =>
      TetherRegisterResponse(
        deviceId: (json['deviceId'] as num).toInt(),
        pollIntervalSeconds: (json['pollIntervalSeconds'] as num).toInt(),
      );
}

/// POST /tether/poll body — the heartbeat, keyed by the durable device id.
class TetherPollRequest {
  const TetherPollRequest({required this.deviceId});

  final int deviceId;

  Map<String, dynamic> toJson() => {'deviceId': deviceId};
}

/// POST /tether/poll response — ack + the (possibly drifted) poll cadence.
class TetherPollResponse {
  const TetherPollResponse({
    required this.ok,
    required this.pollIntervalSeconds,
  });

  final bool ok;
  final int pollIntervalSeconds;

  factory TetherPollResponse.fromJson(Map<String, dynamic> json) =>
      TetherPollResponse(
        ok: json['ok'] as bool,
        pollIntervalSeconds: (json['pollIntervalSeconds'] as num).toInt(),
      );
}
