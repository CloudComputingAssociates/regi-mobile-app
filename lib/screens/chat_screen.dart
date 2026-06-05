import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/chat_message.dart';
import '../models/input_mode.dart';
import '../models/utterance_result.dart';
import '../services/auth_service.dart';
import '../services/chat_service.dart';
import '../services/command_service.dart';
import '../services/conversation_sink.dart';
import '../services/mic_level_service.dart';
import '../services/settings_service.dart';
import '../services/speech_service.dart';
import '../services/tts_service.dart' show TtsService, TtsException;
import '../state/chat_state.dart';
import '../utils/units.dart';
import '../widgets/chat_input.dart';
import '../widgets/chat_output.dart';
import '../widgets/mic_level_bars.dart';
import '../widgets/blooms/user_settings.dart';
import '../widgets/ptt_button.dart';

// Pinned for v1.0: "Regi" (pronounced "Reggie"), Male — backend's
// "Michael (Male)" voice, GCP Neural2-J. Defined in regi-api at
// services/external_apis/gcp_tts_service.go. Voice selection UI is
// deferred to v1.2 (App Settings).
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
  final CommandService _command = CommandService();
  final SettingsService _settings = SettingsService();
  final SpeechService _speech = SpeechService();
  final TtsService _tts = TtsService();
  // RAG seam — today a no-op. Every user/assistant turn flows through
  // recordTurn so that when the background-queue + Weaviate pipeline
  // lands, only this one binding swaps.
  final ConversationSink _sink = const NoopConversationSink();

  // Commands the client knows how to execute. The server may classify
  // an utterance as a command name we don't (yet) recognise; in that
  // case the gate verdict is treated as "not understood" and the
  // utterance degrades to the chat pipeline.
  static const Set<String> _knownCommands = {'bloom', 'set'};

  // Fields whose backend storage is kg. When the user's units are 'us'
  // the spoken value arrives in pounds and must be converted before we
  // PUT. Anything outside this set is passed through verbatim.
  static const Set<String> _kgFields = {'currentWeightKg', 'targetWeightKg'};

  // Bumped after a successful `set` write so the UserSettings bloom
  // remounts and re-fetches. Without a key change, calling
  // openBloom('UserSettings') while the bloom is already open is a
  // no-op for the panel — Flutter reuses the existing element and the
  // cached Future, so the user would see stale numbers.
  int _userSettingsRev = 0;
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

  // PTT button relocation: parent owns position + persistence; the button
  // only reports drag deltas upward.
  static const _pttOffsetXKey = 'ptt_offset_x';
  static const _pttOffsetYKey = 'ptt_offset_y';
  static const _pttButtonSize = 90.0;
  static const _pttDragInactivityTimeout = Duration(seconds: 5);
  static const _pttDefaultBottomInset = 210.0;

  Offset? _pttPosition;
  bool _pttDragMode = false;
  Timer? _pttDragTimer;

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
    _loadPttPosition();
  }

  Future<void> _loadSkipClearPref() async {
    final prefs = await SharedPreferences.getInstance();
    if (!mounted) return;
    setState(() {
      _skipClearConfirm = prefs.getBool(_skipClearPrefKey) ?? false;
    });
  }

  Future<void> _loadPttPosition() async {
    final prefs = await SharedPreferences.getInstance();
    final x = prefs.getDouble(_pttOffsetXKey);
    final y = prefs.getDouble(_pttOffsetYKey);
    if (!mounted) return;
    if (x != null && y != null) {
      setState(() => _pttPosition = Offset(x, y));
    }
  }

  @override
  void dispose() {
    _speechSub?.cancel();
    _speechStatusSub?.cancel();
    _pttDragTimer?.cancel();
    _speech.stop();
    _speech.dispose();
    _chat.dispose();
    _command.dispose();
    _settings.dispose();
    _tts.dispose();
    _micLevels.dispose();
    super.dispose();
  }

  Offset _defaultPttPosition(Size screen) {
    return Offset(
      (screen.width - _pttButtonSize) / 2,
      screen.height - _pttDefaultBottomInset - _pttButtonSize,
    );
  }

  Offset _clampPttPosition(Offset pos, Size screen) {
    final maxX = (screen.width - _pttButtonSize).clamp(0.0, double.infinity);
    final maxY = (screen.height - _pttButtonSize).clamp(0.0, double.infinity);
    return Offset(
      pos.dx.clamp(0.0, maxX),
      pos.dy.clamp(0.0, maxY),
    );
  }

  void _armPttDragTimer() {
    _pttDragTimer?.cancel();
    _pttDragTimer = Timer(_pttDragInactivityTimeout, _exitPttDragMode);
  }

  void _handlePttEnterDragMode() {
    setState(() => _pttDragMode = true);
    _armPttDragTimer();
  }

  void _exitPttDragMode() {
    _pttDragTimer?.cancel();
    _pttDragTimer = null;
    if (!mounted || !_pttDragMode) return;
    setState(() => _pttDragMode = false);
    final pos = _pttPosition;
    if (pos != null) {
      unawaited(_persistPttPosition(pos));
    }
  }

  Future<void> _persistPttPosition(Offset pos) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setDouble(_pttOffsetXKey, pos.dx);
    await prefs.setDouble(_pttOffsetYKey, pos.dy);
  }

  void _handlePttDragMove(Offset delta) {
    _armPttDragTimer();
    final screen = MediaQuery.of(context).size;
    final current = _pttPosition ?? _defaultPttPosition(screen);
    setState(() {
      _pttPosition = _clampPttPosition(current + delta, screen);
    });
  }

  // Single funnel for typed AND voice utterances. Both ChatInput.onSend
  // and _handleTalkEnd route here. The COMMAND GATE runs first; if the
  // server classifies the utterance as an app command we know how to
  // execute, we handle it and short-circuit. Anything else (not a
  // command, server unsure, gate failure, no JWT) falls through to the
  // existing chat pipeline UNCHANGED.
  Future<void> _sendMessage(String text) async {
    if (_sending) return;
    _sending = true;
    try {
      final auth = context.read<AuthService>();
      final jwt = await auth.getAccessToken();
      if (jwt == null) {
        // No JWT — can't query the gate. Hand straight to _doSendMessage
        // so the existing not-authenticated handling (user-message +
        // assistant 'Not authenticated' note) runs byte-for-byte as
        // today.
        await _doSendMessage(text);
        return;
      }

      // Command gate. Failures inside interpret() degrade silently to
      // notUnderstood — the user must never be blocked from chatting
      // because the gate is unreachable.
      final result = await _command.interpret(utterance: text, jwt: jwt);

      if (result.understood &&
          result.command != null &&
          _knownCommands.contains(result.command)) {
        await _handleCommand(text, result);
        return;
      }

      // Fall-through: not an app command. Record the user turn at the
      // RAG seam, then let the chat pipeline take it from here. We do
      // NOT call addMessage(user) here — _doSendMessage owns its own
      // user-message append and the conversation list must remain
      // single-sourced.
      _sink.recordTurn(role: 'user', text: text);
      await _doSendMessage(text);
    } finally {
      _sending = false;
    }
  }

  // Executes a command-classified utterance. The user turn is recorded
  // here (both in the visible message list and via the RAG sink) so
  // command interactions show up in conversation history alongside
  // chat turns. Regi's textual response is then displayed + spoken via
  // [_regiSay].
  Future<void> _handleCommand(String utterance, UtteranceResult r) async {
    final state = context.read<ChatState>();
    state.addMessage(TextMessage(content: utterance, role: MessageRole.user));
    _sink.recordTurn(
      role: 'user',
      text: utterance,
      command: r.command,
      confidence: r.confidence,
    );

    switch (r.command) {
      case 'bloom':
        state.openBloom(r.widget ?? 'UserSettings');
        _regiSay(r.response);
      case 'set':
        await _executeSet(r);
    }
  }

  // The 'set' command executor: GET units → convert lbs→kg if needed →
  // PUT the single field → re-bloom UserSettings (forcing a remount so
  // the panel re-fetches) → speak the gate's confirmation. On any
  // failure short of crashing — bad call body, GET fails, PUT non-200,
  // network error — we speak a short failure line and surface the
  // detail as an assistant message so the user always hears something
  // and we always leave a debug trail.
  Future<void> _executeSet(UtteranceResult r) async {
    final state = context.read<ChatState>();
    final auth = context.read<AuthService>();

    final call = r.call;
    if (call == null || call.body == null || call.body!.isEmpty) {
      _setFailed('missing call/body in gate response');
      return;
    }

    // Parse the call body. Gate currently sends value as a JSON STRING
    // (e.g. "185"); _parseSpoken accepts num OR numeric string.
    String? field;
    num? spoken;
    try {
      final decoded = jsonDecode(call.body!);
      if (decoded is Map<String, dynamic>) {
        final f = decoded['field'];
        field = (f is String && f.isNotEmpty) ? f : null;
        spoken = _parseSpoken(decoded['value']);
      }
    } catch (_) {
      // fall through to the guard below
    }
    if (field == null || spoken == null) {
      _setFailed('could not parse field/value from ${call.body}');
      return;
    }

    final jwt = await auth.getAccessToken();
    if (jwt == null) {
      _setFailed('not authenticated');
      return;
    }

    // 1) GET to read the user's stored units so we know whether the
    //    spoken number was lbs (us) or kg (metric).
    String units;
    try {
      final settings = await _settings.fetchAllSettings(jwt);
      final personal = settings['personalInfo'];
      units = (personal is Map && personal['units'] is String)
          ? personal['units'] as String
          : 'us';
    } catch (e) {
      _setFailed('could not read units: $e');
      return;
    }

    // 2) Convert if needed. Backend stores kg verbatim; client converts.
    //    For us units, weight kg fields arrive as pounds and must be
    //    divided by lbsPerKg. Non-weight fields pass through as-is.
    final valueKg = _toBackendValue(field, spoken, units);

    // 3) PUT. Endpoint comes from the gate (currently 'api/user/settings/
    //    field') so the manifest can evolve without a client release.
    try {
      await _settings.setField(
        endpoint: call.endpoint,
        field: field,
        value: valueKg,
        jwt: jwt,
      );
    } catch (e) {
      _setFailed(_formatSetError(e));
      return;
    }

    // 4) Re-bloom UserSettings. Bump the rev key so an already-open
    //    bloom is force-remounted and its FutureBuilder runs a fresh
    //    fetch — without this, openBloom on an already-open bloom is a
    //    no-op for the panel content.
    if (!mounted) return;
    setState(() => _userSettingsRev++);
    state.openBloom(r.widget ?? 'UserSettings');

    // 5) Speak the gate's confirmation. r.response is always populated
    //    for understood commands; fall back to a generic line if not.
    _regiSay(r.response.isNotEmpty ? r.response : 'Done.');
  }

  void _setFailed(String detail) {
    debugPrint('[set failed] $detail');
    _regiSay("I couldn't update that.");
    if (!mounted) return;
    context.read<ChatState>().addMessage(TextMessage(
          content: '[set] $detail',
          role: MessageRole.assistant,
        ));
  }

  // Parses the spoken value carried in r.call.body. Gate currently
  // emits it as a string; tolerate both string and num shapes so a
  // future gate revision can switch without a client change.
  num? _parseSpoken(dynamic v) {
    if (v == null) return null;
    if (v is num) return v;
    if (v is String) {
      final t = v.trim();
      if (t.isEmpty) return null;
      return num.tryParse(t);
    }
    return null;
  }

  // Returns the numeric value to send to the backend. Weight kg fields
  // under us units convert lbs→kg, rounded to 1 decimal (sensible for
  // bodyweight). Everything else passes through unchanged.
  num _toBackendValue(String field, num spoken, String units) {
    if (_kgFields.contains(field) && units == 'us') {
      final kg = lbsToKg(spoken);
      return double.parse(kg.toStringAsFixed(1));
    }
    return spoken;
  }

  // Pretty-prints a backend error for the assistant detail message.
  // The backend may return a structured body like
  //   { "error": "unsettable_field" }
  // or a plain string. Either way, surface the status + something
  // readable.
  String _formatSetError(Object error) {
    if (error is SettingsException) {
      try {
        final body = jsonDecode(error.body);
        if (body is Map && body['error'] is String) {
          return 'HTTP ${error.statusCode}: ${body['error']}';
        }
      } catch (_) {
        // body wasn't JSON; fall through to raw
      }
      return 'HTTP ${error.statusCode}: ${error.body}';
    }
    return '$error';
  }

  // Display + speak a Regi utterance. Mirrors the TTS code path in
  // _doSendMessage (same _pinnedVoiceId + state.ttsRate, same fresh-JWT
  // fetch, same TtsException handling) so command responses sound
  // identical to chat replies. No-op on empty text.
  void _regiSay(String text) {
    final trimmed = text.trim();
    if (trimmed.isEmpty) return;
    final state = context.read<ChatState>();
    state.addMessage(TextMessage(content: text, role: MessageRole.assistant));
    _sink.recordTurn(role: 'assistant', text: text);
    if (!state.ttsEnabled) return;

    final auth = context.read<AuthService>();
    final rate = state.ttsRate;
    unawaited(() async {
      final jwt = await auth.getAccessToken();
      if (jwt == null) return;
      try {
        await _tts.speak(
          text,
          jwt: jwt,
          voice: _pinnedVoiceId,
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

  // Mute button is dual-purpose: it flips the ttsEnabled flag AND abends
  // any in-flight playback. Tapping mid-utterance must silence audio
  // immediately, not just affect the NEXT reply. _tts.stop() tears down
  // the audioplayers source (releases the in-memory MP3) so the user is
  // not stuck listening to a long reply they don't want.
  void _handleTtsToggle() {
    unawaited(_tts.stop());
    context.read<ChatState>().toggleTts();
  }

  @override
  Widget build(BuildContext context) {
    final state = context.watch<ChatState>();
    final showPtt = state.mode == InputMode.voice;
    final screenSize = MediaQuery.of(context).size;
    final pttPos = _clampPttPosition(
      _pttPosition ?? _defaultPttPosition(screenSize),
      screenSize,
    );

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
            tooltip: 'Settings',
            onPressed: () =>
                context.read<ChatState>().openBloom('UserSettings'),
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
                onTtsToggle: _handleTtsToggle,
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
                child: Stack(
                  clipBehavior: Clip.none,
                  children: [
                    Positioned.fill(
                      child: Container(
                        decoration: BoxDecoration(
                          color: const Color(0xFF252525),
                          border: Border.all(color: Colors.white, width: 3),
                          borderRadius: BorderRadius.circular(20),
                        ),
                        clipBehavior: Clip.antiAlias,
                        child: state.activeBloom == 'UserSettings'
                            ? UserSettings(
                                key: ValueKey(_userSettingsRev),
                              )
                            : Center(
                                child: Text(
                                  'BLOOM: ${state.activeBloom}',
                                  style: const TextStyle(color: Colors.white),
                                ),
                              ),
                      ),
                    ),
                    // macOS-style close: tiny red circle sitting on the top-
                    // left corner of the frame. 32 px hit area, 16 px visible
                    // dot. Negative offsets push the visible dot onto the
                    // rounded border so it reads as part of the window chrome.
                    Positioned(
                      left: -10,
                      top: -10,
                      child: GestureDetector(
                        behavior: HitTestBehavior.opaque,
                        onTap: () =>
                            context.read<ChatState>().closeBloom(),
                        child: SizedBox(
                          width: 36,
                          height: 36,
                          child: Center(
                            child: Container(
                              width: 22,
                              height: 22,
                              decoration: const BoxDecoration(
                                color: Color(0xFFFF5F57),
                                shape: BoxShape.circle,
                                boxShadow: [
                                  BoxShadow(
                                    color: Colors.black45,
                                    blurRadius: 2,
                                    offset: Offset(0, 1),
                                  ),
                                ],
                              ),
                              alignment: Alignment.center,
                              child: const Icon(
                                Icons.close,
                                size: 14,
                                color: Color(0xFF4A0000),
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          if (showPtt)
            Positioned(
              left: pttPos.dx,
              top: pttPos.dy,
              child: PttButton(
                dragMode: _pttDragMode,
                onPressStart: _handleTalkStart,
                onPressEnd: _handleTalkEnd,
                onEnterDragMode: _handlePttEnterDragMode,
                onExitDragMode: _exitPttDragMode,
                onDragMove: _handlePttDragMove,
              ),
            ),
        ],
      ),
    );
  }
}