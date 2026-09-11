import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/chat_message.dart';
import '../state/chat_state.dart';

class ChatOutput extends StatefulWidget {
  const ChatOutput({super.key});

  @override
  State<ChatOutput> createState() => _ChatOutputState();
}

class _ChatOutputState extends State<ChatOutput> {
  final ScrollController _controller = ScrollController();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _scheduleAutoScroll() {
    // Pin to bottom on every content change (new message or streaming chunk).
    // Simpler than tracking manual-scroll intent and matches POC expectation
    // of "show me the latest." If user wants to scroll back through history,
    // they can — but new content always brings them back to the live edge.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_controller.hasClients) return;
      _controller.jumpTo(_controller.position.maxScrollExtent);
    });
  }

  @override
  Widget build(BuildContext context) {
    final state = context.watch<ChatState>();
    final messages = state.messages;

    _scheduleAutoScroll();

    if (messages.isEmpty) {
      return const SizedBox.shrink();
    }

    return ListView.builder(
      controller: _controller,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      itemCount: messages.length,
      itemBuilder: (context, i) => _renderMessage(messages[i]),
    );
  }

  Widget _renderMessage(ChatMessage message) {
    return switch (message) {
      TextMessage() => _Bubble(content: message.content, role: message.role),
      StreamingTextMessage() => _Bubble(
          content: message.content.isEmpty ? '…' : message.content,
          role: message.role,
          streaming: !message.isComplete,
        ),
      ChoiceMessage() ||
      OverlayMessage() ||
      VoiceMessage() =>
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 4),
          child: Text(
            'Unsupported message type: ${message.runtimeType}',
            style: const TextStyle(color: Colors.white38, fontSize: 12),
          ),
        ),
    };
  }
}

class _Bubble extends StatelessWidget {
  const _Bubble({
    required this.content,
    required this.role,
    this.streaming = false,
  });

  final String content;
  final MessageRole role;
  final bool streaming;

  @override
  Widget build(BuildContext context) {
    final isUser = role == MessageRole.user;
    return Align(
      alignment: isUser ? Alignment.centerRight : Alignment.centerLeft,
      child: Container(
        margin: const EdgeInsets.symmetric(vertical: 4),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        constraints: BoxConstraints(
          maxWidth: MediaQuery.of(context).size.width * 0.8,
        ),
        decoration: BoxDecoration(
          color: isUser
              ? const Color(0xFF4A4A4A) // user prompt: medium gray
              : const Color(0xFF2A2A2A), // assistant reply: darker gray
          borderRadius: BorderRadius.only(
            topLeft: const Radius.circular(16),
            topRight: const Radius.circular(16),
            bottomLeft: Radius.circular(isUser ? 16 : 4),
            bottomRight: Radius.circular(isUser ? 4 : 16),
          ),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            Flexible(
              child: Text(
                content,
                style: const TextStyle(color: Colors.white, fontSize: 15),
              ),
            ),
            if (streaming)
              const Padding(
                padding: EdgeInsets.only(left: 6),
                child: SizedBox(
                  width: 8,
                  height: 8,
                  child: _BlinkingDot(),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _BlinkingDot extends StatefulWidget {
  const _BlinkingDot();

  @override
  State<_BlinkingDot> createState() => _BlinkingDotState();
}

class _BlinkingDotState extends State<_BlinkingDot>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl =
      AnimationController(vsync: this, duration: const Duration(milliseconds: 700))
        ..repeat(reverse: true);

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return FadeTransition(
      opacity: _ctrl,
      child: Container(
        decoration: const BoxDecoration(
          color: Colors.white,
          shape: BoxShape.circle,
        ),
      ),
    );
  }
}
