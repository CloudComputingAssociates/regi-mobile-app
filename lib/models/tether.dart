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

/// A device command delivered on the poll heartbeat. Delivery is
/// AT-LEAST-ONCE: the server REDELIVERS a command on every poll until the
/// device acks it (POST /tether/ack) or it TTL-expires (~300s). Clients MUST
/// de-dupe on [messageId] — the same command reappears each poll until acked,
/// which is normal, not an error. [type] is the discriminator
/// ('captureMeal' | 'captureAvatar' | …); [mealId] targets a meal for
/// captureMeal and is null otherwise.
class MobileCommand {
  const MobileCommand({
    required this.messageId,
    required this.type,
    this.mealId,
  });

  final String messageId;
  final String type;
  final int? mealId;

  /// Returns null unless messageId + type are present, non-empty strings — a
  /// malformed entry is dropped rather than crashing the poll parse.
  static MobileCommand? fromJson(Map<String, dynamic> json) {
    final messageId = json['messageId'];
    final type = json['type'];
    if (messageId is! String || messageId.isEmpty) return null;
    if (type is! String || type.isEmpty) return null;
    final rawMealId = json['mealId'];
    return MobileCommand(
      messageId: messageId,
      type: type,
      mealId: rawMealId is num ? rawMealId.toInt() : null,
    );
  }
}

/// POST /tether/poll response — presence ack + poll cadence + any pending
/// device [commands] (at-least-once; empty when nothing is queued). The
/// app-root presence loop ignores commands; the Camera panel is what polls,
/// fulfills, and acks them.
class TetherPollResponse {
  const TetherPollResponse({
    required this.ok,
    required this.pollIntervalSeconds,
    this.commands = const [],
  });

  final bool ok;
  final int pollIntervalSeconds;
  final List<MobileCommand> commands;

  factory TetherPollResponse.fromJson(Map<String, dynamic> json) {
    final rawCommands = json['commands'];
    final commands = <MobileCommand>[];
    if (rawCommands is List) {
      for (final entry in rawCommands) {
        if (entry is Map<String, dynamic>) {
          final cmd = MobileCommand.fromJson(entry);
          if (cmd != null) commands.add(cmd);
        }
      }
    }
    return TetherPollResponse(
      ok: json['ok'] as bool,
      pollIntervalSeconds: (json['pollIntervalSeconds'] as num).toInt(),
      commands: commands,
    );
  }
}
