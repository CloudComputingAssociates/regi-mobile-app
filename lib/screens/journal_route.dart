import 'package:flutter/material.dart';

import '../widgets/overlays/journal_entry.dart';

/// Thin route shell wrapping [JournalEntry] in its own Scaffold so the
/// left-nav "Enter Journal" overlay can be a real pushed route on the
/// inner Navigator instead of a conditionally-swapped widget.
///
/// All form logic — autosave, photo upload, VoiceSink registration in
/// initState / clear in dispose — stays inside [JournalEntry]. This
/// wrapper exists only to give the route its own AppBar, dark
/// background, and one shared concern: dropping any field focus
/// BEFORE the pop transition starts.
///
/// Three independent triggers can close this route — the leading
/// back arrow, the iOS edge-swipe / Android system back gesture, and
/// any programmatic pop. The leading handler covers the first with
/// the earliest possible unfocus; [PopScope.onPopInvokedWithResult]
/// covers the gesture/system path; [JournalEntry.dispose] is the final
/// backstop for all of them. The duplicate unfocus calls are
/// idempotent — clearing already-null focus is a no-op.
class JournalRoute extends StatelessWidget {
  const JournalRoute({super.key});

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: true,
      onPopInvokedWithResult: (didPop, result) {
        FocusManager.instance.primaryFocus?.unfocus();
      },
      child: Scaffold(
        backgroundColor: const Color(0xFF1B1B1B),
        appBar: AppBar(
          backgroundColor: const Color(0xFF1B1B1B),
          foregroundColor: Colors.white,
          leading: IconButton(
            icon: const Icon(Icons.arrow_back),
            tooltip: 'Back',
            onPressed: () {
              // Drop focus FIRST so the pop transition starts with a
              // clean focus tree — otherwise the disposed TextField's
              // FocusNode can outlive the route briefly and leave the
              // chat-input row pointer-dead on Flutter Web.
              FocusManager.instance.primaryFocus?.unfocus();
              Navigator.of(context).maybePop();
            },
          ),
          title: const Text('Journal Entry'),
        ),
        body: const JournalEntry(),
      ),
    );
  }
}
