import 'package:flutter/material.dart';

import '../widgets/overlays/app_settings.dart';

/// Standalone Settings screen pushed onto the root Navigator. The
/// AppBar's auto-supplied leading ← arrow is the sole close
/// affordance. Exists so the editable-Settings panel machinery can
/// be retired later without stranding the page. Distinct from the
/// read-only UserSettings bloom.
class SettingsScreen extends StatelessWidget {
  const SettingsScreen({super.key});

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
