import 'package:flutter/material.dart';

/// Left-nav-style overlay for app-wide settings.
///
/// Voice-input section presents the roadmap as a three-row radio
/// group: row 1 is the only functional mode (push-to-talk / hold);
/// rows 2 and 3 are V2 placeholders rendered greyed-out and
/// non-interactive. Selection state never moves off row 1. No enum
/// values, state fields, or handler branches are wired for the
/// disabled rows — they are display-only.
class AppSettings extends StatelessWidget {
  const AppSettings({super.key});

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(20, 20, 20, 24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _sectionTitle('Voice input'),
          const SizedBox(height: 10),
          _modeRow(
            title: 'Push to talk (hold)',
            selected: true,
            enabled: true,
          ),
          _modeRow(
            title: 'Conversation mode',
            subtitle: 'Coming in V2 — spoken back-and-forth with Regi.',
            enabled: false,
          ),
          _modeRow(
            title: "Wake word ('Hey Regi')",
            subtitle: 'Coming in V2 — hands-free, command-driven.',
            enabled: false,
          ),
        ],
      ),
    );
  }

  /// Radio-style row. When [enabled] is false the row is wrapped in
  /// [AbsorbPointer] so it can never be tapped, and text + indicator
  /// are rendered in low-contrast grey. [selected] is meaningful only
  /// for enabled rows; disabled rows render with an empty indicator
  /// regardless.
  Widget _modeRow({
    required String title,
    String? subtitle,
    bool selected = false,
    required bool enabled,
  }) {
    final titleColor = enabled ? Colors.white : Colors.white38;
    final subtitleColor = enabled ? Colors.white70 : Colors.white24;
    final indicatorColor =
        enabled ? const Color(0xFFF2B33D) : Colors.white24;
    final row = Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(top: 2, right: 12),
            child: Container(
              width: 20,
              height: 20,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                border: Border.all(color: indicatorColor, width: 2),
              ),
              alignment: Alignment.center,
              child: selected && enabled
                  ? Container(
                      width: 10,
                      height: 10,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: indicatorColor,
                      ),
                    )
                  : null,
            ),
          ),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: TextStyle(
                    color: titleColor,
                    fontSize: 14,
                    fontWeight: FontWeight.w500,
                  ),
                ),
                if (subtitle != null) ...[
                  const SizedBox(height: 2),
                  Text(
                    subtitle,
                    style: TextStyle(
                      color: subtitleColor,
                      fontSize: 12,
                      fontStyle: FontStyle.italic,
                    ),
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
    if (enabled) return row;
    return AbsorbPointer(child: row);
  }

  Widget _sectionTitle(String text) {
    return Text(
      text,
      style: const TextStyle(
        color: Colors.white,
        fontSize: 16,
        fontWeight: FontWeight.bold,
      ),
    );
  }
}
