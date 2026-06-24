import 'package:flutter/material.dart';

import '../widgets/overlays/app_settings.dart';

/// Thin route shell wrapping [AppSettings] in its own Scaffold so the
/// AppBar gear icon can push a real route onto the inner Navigator —
/// same dispatch pattern as [JournalRoute]. Auto-supplied leading ←
/// back arrow is the sole close affordance.
class SettingsRoute extends StatelessWidget {
  const SettingsRoute({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF1B1B1B),
      appBar: AppBar(
        backgroundColor: const Color(0xFF1B1B1B),
        foregroundColor: Colors.white,
        title: const Text('Settings'),
      ),
      body: const AppSettings(),
    );
  }
}
