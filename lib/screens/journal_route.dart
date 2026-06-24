import 'package:flutter/material.dart';

import '../widgets/overlays/journal_entry.dart';

/// Thin route shell wrapping [JournalEntry] in its own Scaffold so the
/// left-nav "Enter Journal" overlay can be a real pushed route on the
/// inner Navigator instead of a conditionally-swapped widget.
///
/// All form logic — autosave, photo upload, VoiceSink registration in
/// initState / clear in dispose — stays inside [JournalEntry]. This
/// wrapper exists only to give the route its own AppBar (with the red
/// × close affordance) and dark background.
///
/// The × tap calls `Navigator.of(context).pop()` which targets the
/// nested Navigator that pushed this route. After the pop animation,
/// the framework runs [JournalEntry]'s dispose — that handles voice
/// sink teardown, autosave-timer cancellation, focus-node disposal,
/// etc. cleanly and atomically, the way Flutter is designed to.
class JournalRoute extends StatelessWidget {
  const JournalRoute({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF1B1B1B),
      appBar: AppBar(
        backgroundColor: const Color(0xFF1B1B1B),
        foregroundColor: Colors.white,
        title: const Text('Journal Entry'),
        actions: [
          IconButton(
            icon: const Icon(Icons.close, color: Color(0xFFFF5F57)),
            tooltip: 'Close Journal',
            onPressed: () => Navigator.of(context).pop(),
          ),
        ],
      ),
      body: const JournalEntry(),
    );
  }
}
