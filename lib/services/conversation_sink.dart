/// Single insertion point for the future RAG / conversation-persistence
/// subsystem. Today: no-op. Tomorrow: a background queue will vectorize
/// each turn and ship it to Weaviate (or whatever vector store wins).
///
/// Concentrating the seam here means every existing call site
/// (`sink.recordTurn(...)`) stays untouched when the real implementation
/// lands — only this file changes.
abstract class ConversationSink {
  /// Records a single conversation turn.
  ///
  /// [role] is 'user' or 'assistant'. [command] is non-null when the gate
  /// classified the user turn as an app command (e.g. 'bloom', 'set').
  /// [confidence] is the gate's self-reported confidence for that
  /// classification when known.
  void recordTurn({
    required String role,
    required String text,
    String? command,
    double? confidence,
  });
}

class NoopConversationSink implements ConversationSink {
  const NoopConversationSink();

  @override
  void recordTurn({
    required String role,
    required String text,
    String? command,
    double? confidence,
  }) {
    // TODO(rag): enqueue -> vectorize -> Weaviate.
  }
}
