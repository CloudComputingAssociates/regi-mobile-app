/// Routing target for the global press-and-hold mic. When a bloom (or
/// other consumer) wants live dictation, it registers a VoiceSink via
/// [ChatState.setVoiceSink]; while a sink is registered, the PTT
/// pipeline diverts transcripts here instead of sending them to chat.
/// Unregistering (sink = null) restores the chat default.
///
/// Contract:
///   • onStart  — fired once when the user begins holding PTT.
///   • onPartial — fired for every cumulative transcript update during
///     the hold (cumulative, not deltas).
///   • onFinal  — fired once when the user releases, with the final
///     captured text. The caller is responsible for whatever happens
///     next (commit to a field, etc.); the sink does NOT itself add a
///     chat message.
class VoiceSink {
  const VoiceSink({
    required this.onStart,
    required this.onPartial,
    required this.onFinal,
    this.label,
  });

  final void Function() onStart;
  final void Function(String cumulative) onPartial;
  final void Function(String finalText) onFinal;

  /// Debug-only short tag (e.g. 'Journal'). Not surfaced in UI.
  final String? label;
}
