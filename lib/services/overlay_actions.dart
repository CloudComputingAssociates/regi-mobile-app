import 'package:flutter/foundation.dart';

/// Bridge between a left-nav overlay and the global AppBar. Overlays
/// (e.g. Journal) register an [OverlayActions] in [ChatState] so the
/// AppBar can render a Save action that fires the overlay's save flow,
/// driven by the overlay's own dirty state.
///
/// Mirrors the [VoiceSink] pattern: lifecycle is owned by the overlay
/// (register in initState, clear in dispose). ChatState notifies on
/// changes so the AppBar rebuilds when canSave flips.
@immutable
class OverlayActions {
  const OverlayActions({
    required this.onSave,
    required this.canSave,
  });

  /// Fired by the AppBar's Save action. Owner runs whatever save flow
  /// makes sense for the overlay (build payload, POST, close on success).
  final VoidCallback onSave;

  /// Controls whether the AppBar Save icon is enabled. Typically
  /// `_isDirty && !_isSaving` in the overlay.
  final bool canSave;
}
