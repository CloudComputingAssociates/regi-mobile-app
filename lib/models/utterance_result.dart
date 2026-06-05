/// Mirror of regi-api's UtteranceResult. Returned by the command gate
/// (POST /api/command/utterance) for every typed/voice utterance.
///
/// Two shapes share one type:
///   • understood == true  → app command. `command`, `widget`,
///     `renderIntent`, and (for writes) `call` describe what to do.
///   • understood == false → not an app command; Flutter falls through
///     to the normal chat pipeline. `response` may be empty.
///
/// Parsing is intentionally tolerant: a malformed/partial body never
/// throws. A gate failure must degrade silently to chat, never block
/// the user.
class UtteranceResult {
  const UtteranceResult({
    required this.understood,
    required this.response,
    this.command,
    this.widget,
    this.renderIntent,
    this.call,
    this.requiresConfirmation = false,
    this.confidence = 0.0,
  });

  final bool understood;
  final String response;
  final String? command;
  final String? widget;
  final String? renderIntent;
  final CallSpec? call;
  final bool requiresConfirmation;
  final double confidence;

  /// Sentinel returned by CommandService on any failure (network,
  /// non-200, malformed JSON). Callers should treat it as "not a
  /// command" and fall through to the chat pipeline.
  static const UtteranceResult notUnderstood = UtteranceResult(
    understood: false,
    response: '',
  );

  factory UtteranceResult.fromJson(Map<String, dynamic> j) {
    return UtteranceResult(
      understood: j['understood'] == true,
      response: _str(j['response']) ?? '',
      command: _str(j['command']),
      widget: _str(j['widget']),
      renderIntent: _str(j['renderIntent']),
      call: _callFromAny(j['call']),
      requiresConfirmation: j['requiresConfirmation'] == true,
      confidence: _doubleOrZero(j['confidence']),
    );
  }
}

class CallSpec {
  const CallSpec({
    required this.method,
    required this.endpoint,
    this.body,
  });

  /// HTTP verb (GET/PUT/POST/...).
  final String method;

  /// Path or full URL. Resolution policy lives on the caller side.
  final String endpoint;

  /// JSON-encoded body with values already substituted by the gate.
  /// Null for reads (GET).
  final String? body;

  static CallSpec? fromJson(Map<String, dynamic> j) {
    final method = _str(j['method']);
    final endpoint = _str(j['endpoint']);
    if (method == null || endpoint == null) return null;
    return CallSpec(
      method: method,
      endpoint: endpoint,
      body: _str(j['body']),
    );
  }
}

String? _str(dynamic v) {
  if (v is String && v.isNotEmpty) return v;
  return null;
}

double _doubleOrZero(dynamic v) {
  if (v is num) return v.toDouble();
  return 0.0;
}

CallSpec? _callFromAny(dynamic v) {
  if (v is Map<String, dynamic>) return CallSpec.fromJson(v);
  if (v is Map) return CallSpec.fromJson(v.cast<String, dynamic>());
  return null;
}
