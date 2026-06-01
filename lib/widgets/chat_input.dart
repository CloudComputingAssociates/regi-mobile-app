import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/input_mode.dart';
import '../state/chat_state.dart';
import 'mode_slider.dart';

const _talkActiveColor = Color(0xFFF2B33D);
const _barColor = Color(0xFF3A3A3A);

class ChatInput extends StatefulWidget {
  const ChatInput({
    super.key,
    required this.onSend,
    required this.onTalkStart,
    required this.onTalkEnd,
    required this.onTtsToggle,
  });

  final void Function(String text) onSend;
  final VoidCallback onTalkStart;
  final VoidCallback onTalkEnd;

  /// Tapped on the mute button. Owner is expected to both flip the
  /// ttsEnabled flag AND abend any in-flight TTS playback so a user
  /// toggling mid-utterance gets immediate silence, not "next time".
  final VoidCallback onTtsToggle;

  @override
  State<ChatInput> createState() => _ChatInputState();
}

class _ChatInputState extends State<ChatInput> {
  final TextEditingController _controller = TextEditingController();
  final FocusNode _focusNode = FocusNode();

  @override
  void initState() {
    super.initState();
    _controller.addListener(() {
      final state = context.read<ChatState>();
      if (_controller.text != state.currentInput) {
        state.setCurrentInput(_controller.text);
      }
    });
  }

  @override
  void dispose() {
    _controller.dispose();
    _focusNode.dispose();
    super.dispose();
  }

  void _handleSend() {
    final text = _controller.text.trim();
    if (text.isEmpty) return;
    // Clear FIRST, then dispatch. If a second _handleSend fires in quick
    // succession (double-tap, or Flutter Web's known onSubmitted-double-fire
    // on Enter), the second invocation reads an empty controller and bails
    // before duplicating the message.
    _controller.clear();
    context.read<ChatState>().clearCurrentInput();
    widget.onSend(text);
  }

  @override
  Widget build(BuildContext context) {
    final state = context.watch<ChatState>();
    final isVoice = state.mode == InputMode.voice;

    // Voice mode: STT writes the live transcript into state.currentInput.
    // Sync into the read-only TextField via post-frame so we don't mutate
    // the controller during build.
    if (isVoice && _controller.text != state.currentInput) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        if (_controller.text == state.currentInput) return;
        _controller.value = TextEditingValue(
          text: state.currentInput,
          selection:
              TextSelection.collapsed(offset: state.currentInput.length),
        );
      });
    }

    return SafeArea(
      top: false,
      child: Container(
        color: _barColor,
        padding: const EdgeInsets.fromLTRB(8, 6, 8, 8),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // Row 1: TTS controls (left) + input mode + Talk (right)
            Row(
              children: [
                _SpeedButton(
                  rate: state.ttsRate,
                  onChanged: state.setTtsRate,
                ),
                const SizedBox(width: 6),
                _MuteButton(
                  enabled: state.ttsEnabled,
                  onTap: widget.onTtsToggle,
                ),
                const Spacer(),
                ModeSlider(
                  mode: state.mode,
                  onChanged: state.setMode,
                ),
                const SizedBox(width: 8),
                _TalkButton(
                  enabled: isVoice,
                  active: state.isTalkActive,
                  onPressStart: widget.onTalkStart,
                  onPressEnd: widget.onTalkEnd,
                ),
              ],
            ),
            const SizedBox(height: 6),
            // Row 2: text input + send
            Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _controller,
                    focusNode: _focusNode,
                    readOnly: isVoice,
                    minLines: 1,
                    maxLines: 4,
                    textInputAction: TextInputAction.send,
                    onSubmitted: (_) => _handleSend(),
                    style: const TextStyle(color: Colors.white),
                    decoration: InputDecoration(
                      filled: true,
                      fillColor: isVoice
                          ? const Color(0xFF2A2A2A)
                          : const Color(0xFF555555),
                      hintText: isVoice
                          ? 'Hold the button and speak...'
                          : 'Type a message...',
                      hintStyle: const TextStyle(color: Colors.white54),
                      contentPadding: const EdgeInsets.symmetric(
                        horizontal: 14,
                        vertical: 10,
                      ),
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(20),
                        borderSide: BorderSide.none,
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                _SquareButton(
                  icon: Icons.send,
                  tooltip: 'Send',
                  onTap: _handleSend,
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _SpeedButton extends StatelessWidget {
  const _SpeedButton({required this.rate, required this.onChanged});

  final double rate;
  final ValueChanged<double> onChanged;

  static const _presets = [0.75, 1.0, 1.25, 1.5, 1.75, 2.0];

  @override
  Widget build(BuildContext context) {
    return PopupMenuButton<double>(
      tooltip: 'Playback speed',
      onSelected: onChanged,
      color: const Color(0xFF252525),
      itemBuilder: (_) => [
        for (final p in _presets)
          PopupMenuItem<double>(
            value: p,
            child: Row(
              children: [
                if ((p - rate).abs() < 0.001)
                  const Icon(Icons.check,
                      size: 14, color: Color(0xFFF2B33D))
                else
                  const SizedBox(width: 14),
                const SizedBox(width: 6),
                Text(
                  '${p.toStringAsFixed(2)}×',
                  style: const TextStyle(color: Colors.white, fontSize: 13),
                ),
              ],
            ),
          ),
      ],
      child: Container(
        height: 36,
        padding: const EdgeInsets.symmetric(horizontal: 10),
        decoration: BoxDecoration(
          color: const Color(0xFF555555),
          borderRadius: BorderRadius.circular(8),
        ),
        alignment: Alignment.center,
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.speed, size: 14, color: Colors.white70),
            const SizedBox(width: 4),
            Text(
              '${rate.toStringAsFixed(2)}×',
              style: const TextStyle(
                color: Colors.white,
                fontSize: 12,
                fontFeatures: [FontFeature.tabularFigures()],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _MuteButton extends StatelessWidget {
  const _MuteButton({required this.enabled, required this.onTap});

  final bool enabled;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: enabled ? 'Mute spoken replies' : 'Unmute spoken replies',
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(18),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 120),
          width: 36,
          height: 36,
          decoration: BoxDecoration(
            color: enabled
                ? const Color(0xFF555555)
                : const Color(0xFF8B1A2B),
            shape: BoxShape.circle,
          ),
          alignment: Alignment.center,
          child: Icon(
            enabled ? Icons.record_voice_over : Icons.voice_over_off,
            size: 18,
            color: Colors.white,
          ),
        ),
      ),
    );
  }
}

class _SquareButton extends StatelessWidget {
  const _SquareButton({
    required this.icon,
    required this.tooltip,
    required this.onTap,
  });

  final IconData icon;
  final String tooltip;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: tooltip,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(8),
        child: Container(
          width: 44,
          height: 44,
          decoration: BoxDecoration(
            color: const Color(0xFF555555),
            borderRadius: BorderRadius.circular(8),
          ),
          alignment: Alignment.center,
          child: Icon(icon, color: Colors.white, size: 20),
        ),
      ),
    );
  }
}

class _TalkButton extends StatelessWidget {
  const _TalkButton({
    required this.enabled,
    required this.active,
    required this.onPressStart,
    required this.onPressEnd,
  });

  final bool enabled;
  final bool active;
  final VoidCallback onPressStart;
  final VoidCallback onPressEnd;

  @override
  Widget build(BuildContext context) {
    final color = !enabled
        ? const Color(0xFF333333)
        : active
            ? _talkActiveColor
            : const Color(0xFF2196F3);
    return Listener(
      behavior: HitTestBehavior.opaque,
      onPointerDown: enabled ? (_) => onPressStart() : null,
      onPointerUp: enabled ? (_) => onPressEnd() : null,
      onPointerCancel: enabled ? (_) => onPressEnd() : null,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 100),
        width: 44,
        height: 44,
        decoration: BoxDecoration(
          color: color,
          shape: BoxShape.circle,
        ),
        alignment: Alignment.center,
        child: Icon(
          Icons.mic,
          color: enabled ? Colors.white : Colors.white24,
          size: 20,
        ),
      ),
    );
  }
}
