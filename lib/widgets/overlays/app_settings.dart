import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../models/voice_mode.dart';
import '../../state/chat_state.dart';

/// Left-nav-style overlay for app-wide settings. Currently exposes the
/// Voice control mode (PTT-hold / press-toggle / wake-word). Wake-word
/// is selectable but the underlying audio pipeline change is a
/// follow-up — the PTT button reflects the mode immediately, but
/// always-on listening for "Hey Regi" is not yet wired.
class AppSettings extends StatelessWidget {
  const AppSettings({super.key});

  static const Color _inputFill = Color(0xFF555555);

  @override
  Widget build(BuildContext context) {
    final state = context.watch<ChatState>();
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(20, 20, 20, 24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _sectionTitle('Voice control'),
          const SizedBox(height: 6),
          _voiceModeDropdown(context, state.voiceMode),
          if (state.voiceMode == VoiceMode.wakeWord) ...[
            const SizedBox(height: 10),
            const Text(
              'Wake-word detection is not yet active — UI selectable but '
              'the always-on listener is a follow-up.',
              style: TextStyle(
                color: Colors.white54,
                fontSize: 12,
                fontStyle: FontStyle.italic,
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _voiceModeDropdown(BuildContext context, VoiceMode current) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12),
      decoration: BoxDecoration(
        color: _inputFill,
        borderRadius: BorderRadius.circular(8),
      ),
      child: DropdownButtonHideUnderline(
        child: DropdownButton<VoiceMode>(
          value: current,
          isExpanded: true,
          dropdownColor: const Color(0xFF333333),
          iconEnabledColor: Colors.white70,
          style: const TextStyle(color: Colors.white, fontSize: 14),
          items: [
            for (final m in VoiceMode.values)
              DropdownMenuItem(
                value: m,
                child: Text(m.label),
              ),
          ],
          onChanged: (m) {
            if (m == null) return;
            context.read<ChatState>().setVoiceMode(m);
          },
        ),
      ),
    );
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
