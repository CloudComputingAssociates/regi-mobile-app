import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/chat_message.dart';
import '../models/input_mode.dart';
import '../services/auth_service.dart';
import '../services/chat_service.dart';
import '../services/mic_level_service.dart';
import '../services/speech_service.dart';
import '../services/tts_service.dart' show TtsService, TtsException;
import '../state/chat_state.dart';
import '../widgets/chat_input.dart';
import '../widgets/chat_output.dart';
import '../widgets/mic_level_bars.dart';
import '../widgets/ptt_button.dart';

// Pinned for v1.0: "Regi" (pronounced "Reggie"), Male — backend's
// "Michael (Male)" voice, GCP Neural2-J. Defined in regi-api at
// services/external_apis/gcp_tts_service.go. Voice selection UI is
// deferred to v1.2 (App Preferences).
// Temporarily James (Neural2-D, default) to test whether Neural2-J specifically
// is failing in this GCP project. Once confirmed, swap back to Neural2-J.
const String _pinnedVoiceId = 'en-US-Neural2-D';

class ChatScreen extends StatefulWidget {
  const ChatScreen({super.key});

  @override
  State<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends State<ChatScreen> {
  final ChatService _chat = ChatService();
  final SpeechService _speech = SpeechService();
  final TtsService _tts = TtsService();
  // Constructed but currently dormant — see _handleTalkStart for why
  // start() is not called. Kept wired (import + dispose) so re-enabling
  // is a one-line change once the recognizer/analyser conflict is solved.
  final MicLevelService _micLevels = MicLevelService();
  StreamSubscription<String>? _speechSub;
  StreamSubscription<String>? _speechStatusSub;
  // In-flight guard. Defends against any path that double-invokes
  // _sendMessage (rapid double-tap, Flutter Web onSubmitted bugs, etc.).
  bool _sending = false;

  // Persisted: once the user ticks "Don't ask again" in the Clear dialog,
  // future Clear taps skip the dialog. Reset by clearing site data.
  static const _skipClearPrefKey = 'clear_confirm_skip';
  bool _skipClearConfirm = false;

  // Prepended to EVERY user message — models drift mid-session and stop
  // honoring a one-shot directive after a few turns. The model itself
  // routes: terse for chitchat, complete for recipes/instructions.
  static const _conciseDirective =
      'For conversational questions, reply in 1-2 sentences, no preamble. '
      'For recipes, cooking instructions, or step-by-step how-tos, '
      'reply in full — list ingredients with amounts and complete steps. ';

  @override
  void initState() {
    super.initState();
    _speech.initialize();
    // Track recognizer's actual listening state so the AppBar mic icon
    // lights amber only when the recognizer is genuinely capturing audio,
    // not just when the user pressed the button. This is the "ready" cue
    // for the beginning-word cut-off issue: users learn to wait for the
    // amber glow before they start speaking. The platform recognizer emits
    // 'listening' / 'notListening' / 'done'; map both terminal states to
    // not-listening so the icon reverts promptly.
    _speechStatusSub = _speech.statuses.listen((s) {
      if (!mounted) return;
      switch (s) {
        case 'listening':
          context.read<ChatState>().setListening(true);
        case 'notListening':
        case 'done':
          context.read<ChatState>().setListening(false);
      }
    });
    _loadSkipClearPref();
  }

  Future<void> _loadSkipClearPref() async {
    final prefs = await SharedPreferences.getInstance();
    if (!mounted) return;
    setState(() {
      _skipClearConfirm = prefs.getBool(_skipClearPrefKey) ?? false;
    });
  }

  @override
  void dispose() {
    _speechSub?.cancel();
    _speechStatusSub?.cancel();
    _speech.stop();
    _speech.dispose();
    _chat.dispose();
    _tts.dispose();
    _micLevels.dispose();
    super.dispose();
  }

  Future<void> _sendMessage(String text) async {
    if (_sending) return;
    _sending = true;
    try {
      await _doSendMessage(text);
    } finally {
      _sending = false;
    }
  }

  Future<void> _doSendMessage(String text) async {
    final state = context.read<ChatState>();
    final auth = context.read<AuthService>();

    state.addMessage(TextMessage(content: text, role: MessageRole.user));

    final jwt = await auth.getAccessToken();
    if (jwt == null) {
      state.addMessage(TextMessage(
        content: 'Not authenticated. Please sign in again.',
        role: MessageRole.assistant,
      ));
      return;
    }

    final messageToSend = '$_conciseDirective$text';

    final stream = state.startAssistantStream();
    String? lastSessionStatus;
    try {
      await for (final chunk in _chat.streamChat(
        message: messageToSend,
        sessionId: state.sessionId,
        jwt: jwt,
      )) {
        if (chunk.sessionId != null && chunk.sessionId != state.sessionId) {
          state.setSessionId(chunk.sessionId);
        }
        if (chunk.sessionStatus != null) {
          lastSessionStatus = chunk.sessionStatus;
        }
        if (chunk.hasError) {
          state.appendToStream(stream, '\n[error: ${chunk.error}]');
        }
        if (chunk.hasDelta) {
          state.appendToStream(stream, chunk.delta!);
        }
      }
      state.completeStream(stream);
    } catch (e) {
      state.appendToStream(stream, '\n[error: $e]');
      state.completeStream(stream);
      return;
    }

    if (lastSessionStatus != null && lastSessionStatus != 'ACTIVE') {
      state.setSessionId(null);
      if (mounted) {
        state.addMessage(TextMessage(
          content: '[session $lastSessionStatus — starting new conversation]',
          role: MessageRole.assistant,
        ));
      }
    }

    if (state.ttsEnabled && stream.content.trim().isNotEmpty) {
      final replyText = stream.content;
      const voiceId = _pinnedVoiceId;
      final rate = state.ttsRate;
      unawaited(() async {
        final freshJwt = await auth.getAccessToken() ?? jwt;
        try {
          await _tts.speak(
            replyText,
            jwt: freshJwt,
            voice: voiceId,
            speakingRate: rate,
          );
        } on TtsException catch (e) {
          if (!mounted) return;
          context.read<ChatState>().addMessage(TextMessage(
                content: '[tts] $e',
                role: MessageRole.assistant,
              ));
        }
      }());
    }
  }

  Future<void> _handleNewChat() async {
    final state = context.read<ChatState>();
    if (state.messages.isEmpty && state.sessionId == null) return;

    bool confirmed;
    if (_skipClearConfirm) {
      confirmed = true;
    } else {
      bool dontAskAgain = false;
      final result = await showDialog<bool>(
        context: context,
        builder: (ctx) => StatefulBuilder(
          builder: (ctx, setSt) => AlertDialog(
            backgroundColor: const Color(0xFF252525),
            title: const Text(
              'Clear conversation?',
              style: TextStyle(color: Colors.white),
            ),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'The current conversation will clear from this view. '
                  'Server-side history is preserved.',
                  style: TextStyle(color: Colors.white70),
                ),
                const SizedBox(height: 12),
                InkWell(
                  onTap: () => setSt(() => dontAskAgain = !dontAskAgain),
                  child: Row(
                    children: [
                      Checkbox(
                        value: dontAskAgain,
                        onChanged: (v) =>
                            setSt(() => dontAskAgain = v ?? false),
                        activeColor: const Color(0xFF2196F3),
                        checkColor: Colors.white,
                        side: const BorderSide(color: Colors.white54),
                      ),
                      const Text(
                        "Don't ask again",
                        style: TextStyle(color: Colors.white70),
                      ),
                    ],
                  ),
                ),
              ],
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx, false),
                child: const Text(
                  'Cancel',
                  style: TextStyle(color: Colors.white70),
                ),
              ),
              TextButton(
                style: TextButton.styleFrom(
                  foregroundColor: Colors.white,
                  backgroundColor: const Color(0xFF8B1A2B),
                ),
                onPressed: () => Navigator.pop(ctx, true),
                child: const Text('Clear'),
              ),
            ],
          ),
        ),
      );
      confirmed = result == true;
      if (confirmed && dontAskAgain) {
        final prefs = await SharedPreferences.getInstance();
        await prefs.setBool(_skipClearPrefKey, true);
        if (mounted) setState(() => _skipClearConfirm = true);
      }
    }

    if (!confirmed || !mounted) return;

    final priorSessionId = state.sessionId;
    final auth = context.read<AuthService>();

    context.read<ChatState>().clearChat();

    if (priorSessionId != null && priorSessionId.isNotEmpty) {
      unawaited(() async {
        final jwt = await auth.getAccessToken();
        if (jwt == null) return;
        await _chat.closeSession(sessionId: priorSessionId, jwt: jwt);
      }());
    }
  }

  Future<void> _handleTalkStart() async {
    final state = context.read<ChatState>();
    state.setTalkActive(true);
    state.setCurrentInput('');

    final ok = await _speech.initialize();
    if (!ok) return;

    _speechSub?.cancel();
    _speechSub = _speech.listen().listen((transcript) {
      if (!mounted) return;
      context.read<ChatState>().setCurrentInput(transcript);
    });

    // NOTE: parallel MicLevelService.start() (getUserMedia + AnalyserNode)
    // is intentionally NOT called here. On at least one tested browser,
    // running a second audio capture alongside the recognizer starves it
    // of audio — the bars animate but STT stops producing transcripts.
    // The service is kept for a future fix (single-capture-with-two-
    // consumers, if/when feasible). Until then, MicLevelBars uses its
    // ripple fallback.
  }

  Future<void> _handleTalkEnd() async {
    final state = context.read<ChatState>();
    if (!state.isTalkActive) return;

    await _speech.stop();
    await _speechSub?.cancel();
    _speechSub = null;

    final transcript = state.currentInput.trim();
    state.setTalkActive(false);
    state.clearCurrentInput();

    if (transcript.isNotEmpty) {
      await _sendMessage(transcript);
    }
  }

  @override
  Widget build(BuildContext context) {
    final state = context.watch<ChatState>();
    final showPtt = state.mode == InputMode.voice;

    return Scaffold(
      backgroundColor: const Color(0xFF1B1B1B),
      appBar: AppBar(
        backgroundColor: const Color(0xFF1B1B1B),
        foregroundColor: Colors.white,
        title: Row(
          children: [
            const Text('RegiMenu'),
            const SizedBox(width: 12),
            // Mic icon goes amber ONLY when the recognizer is actually
            // listening (not just when the button was pressed). The
            // ~100-200ms delay between press and amber is the user's cue
            // that the recognizer is now ready and they can start talking.
            Icon(
              Icons.mic,
              size: 18,
              color: state.isListening
                  ? const Color(0xFFF2B33D)
                  : Colors.white24,
            ),
            const SizedBox(width: 8),
            if (state.isListening)
              const MicLevelBars(
                barCount: 11,
                color: Color(0xFFF2B33D),
                minHeight: 4,
                maxHeight: 26,
                barWidth: 2,
                spacing: 2,
              ),
          ],
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.settings),
            tooltip: 'Preferences',
            onPressed: () =>
                context.read<ChatState>().openBloom('preferences'),
          ),
          IconButton(
            icon: const Icon(Icons.clear_all),
            tooltip: 'Clear',
            onPressed: _handleNewChat,
          ),
          IconButton(
            icon: const Icon(Icons.logout),
            tooltip: 'Sign out',
            onPressed: () => context.read<AuthService>().logout(),
          ),
        ],
      ),
      body: Stack(
        children: [
          Column(
            children: [
              const Expanded(child: ChatOutput()),
              ChatInput(
                onSend: _sendMessage,
                onTalkStart: _handleTalkStart,
                onTalkEnd: _handleTalkEnd,
              ),
            ],
          ),
          if (state.activeBloom != null)
            Positioned(
              left: 16,
              right: 16,
              top: 16,
              bottom: 240,
              child: Material(
                color: Colors.transparent,
                child: Container(
                  decoration: BoxDecoration(
                    color: const Color(0xFF252525),
                    border: Border.all(color: Colors.white, width: 3),
                    borderRadius: BorderRadius.circular(20),
                  ),
                  child: Center(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          'BLOOM: ${state.activeBloom}',
                          style: const TextStyle(color: Colors.white),
                        ),
                        TextButton(
                          onPressed: () =>
                              context.read<ChatState>().closeBloom(),
                          child: const Text('Close'),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          if (showPtt)
            Positioned(
              left: 0,
              right: 0,
              bottom: 210,
              child: Center(
                child: PttButton(
                  onPressStart: _handleTalkStart,
                  onPressEnd: _handleTalkEnd,
                ),
              ),
            ),
        ],
      ),
    );
  }
}