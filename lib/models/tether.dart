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

/// An at-most-once device command piggy-backed on a poll response. The server
/// clears it once delivered, so a given commandId is seen at most once across
/// the fleet; the client must still guard against re-handling the same id in
/// case a retry/duplicate poll surfaces it twice. `type` is the discriminator
/// (e.g. 'captureAvatar'); unknown types are ignored by the client.
class TetherCommand {
  const TetherCommand({required this.type, required this.commandId});

  final String type;
  final String commandId;

  /// Returns null unless BOTH fields are present, non-empty strings — a
  /// partial/garbled command is treated as no command rather than crashing
  /// the poll loop.
  static TetherCommand? fromJson(Map<String, dynamic> json) {
    final type = json['type'];
    final commandId = json['commandId'];
    if (type is! String || type.isEmpty) return null;
    if (commandId is! String || commandId.isEmpty) return null;
    return TetherCommand(type: type, commandId: commandId);
  }
}

/// POST /tether/poll response — ack + the (possibly drifted) poll cadence, plus
/// an optional at-most-once [command] the web cockpit fired at this device.
class TetherPollResponse {
  const TetherPollResponse({
    required this.ok,
    required this.pollIntervalSeconds,
    this.command,
  });

  final bool ok;
  final int pollIntervalSeconds;
  final TetherCommand? command;

  factory TetherPollResponse.fromJson(Map<String, dynamic> json) {
    final rawCommand = json['command'];
    return TetherPollResponse(
      ok: json['ok'] as bool,
      pollIntervalSeconds: (json['pollIntervalSeconds'] as num).toInt(),
      command: rawCommand is Map<String, dynamic>
          ? TetherCommand.fromJson(rawCommand)
          : null,
    );
  }
}
