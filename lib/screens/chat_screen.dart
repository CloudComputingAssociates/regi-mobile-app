import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/chat_message.dart';
import '../models/input_mode.dart';
import '../models/utterance_result.dart';
import '../models/ptt_mode.dart';
import '../services/audio_recorder.dart';
import '../services/auth_service.dart';
import '../services/chat_service.dart';
import '../services/command_service.dart';
import '../services/conversation_sink.dart';
import '../services/mic_level_service.dart';
import '../services/settings_service.dart';
import '../services/stt_service.dart';
import '../services/tts_service.dart' show TtsService, TtsException;
import '../state/chat_state.dart';
import '../utils/units.dart';
import '../widgets/chat_input.dart';
import '../widgets/chat_output.dart';
import '../widgets/mic_level_bars.dart';
import '../services/glp1_service.dart';
import '../utils/ptt_layout.dart';
import '../widgets/blooms/user_settings.dart';
import '../widgets/ptt_button.dart';
import 'journal_screen.dart';
import 'settings_screen.dart';

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
  final AudioRecorderService _recorder = AudioRecorderService();
  final SttService _stt = SttService();
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
  // In-flight guard. Defends against any path that double-invokes
  // _sendMessage (rapid double-tap, Flutter Web onSubmitted bugs, etc.).
  bool _sending = false;

  // Persisted: once the user ticks "Don't ask again" in the Clear dialog,
  // future Clear taps skip the dialog. Reset by clearing site data.
  static const _skipClearPrefKey = 'clear_confirm_skip';
  bool _skipClearConfirm = false;

  // One-shot guard so a rebuild during the same screen lifetime can't
  // re-fire the GLP-1 banner check. Logging the injection flips
  // isInjectionDay false server-side, so the next app entry simply
  // doesn't see a due — no local "snooze" needed.
  bool _glp1BannerChecked = false;

  // PTT button relocation: parent owns position + persistence; the
  // button only reports drag deltas upward. Layout constants + the
  // shared SharedPreferences keys live in [PttLayout] so other screens
  // (Journal, etc.) render their mic disc at the same coordinates.
  static const _pttDragInactivityTimeout = Duration(seconds: 5);

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
    _loadSkipClearPref();
    _loadPttPosition();
    // Post-frame so ScaffoldMessenger is mounted before we try to
    // show a MaterialBanner. Fires on every app entry while due —
    // logging the injection flips the server's isInjectionDay to
    // false so it stops on its own (no local "don't ask again").
    WidgetsBinding.instance.addPostFrameCallback((_) {
      unawaited(_maybeShowGlp1Banner());
    });
  }

  /// Asks regi-api whether today is a GLP-1 injection day for the
  /// signed-in user and, if so, shows a MaterialBanner with a
  /// "GO TO JOURNAL" action that pushes [JournalScreen] (same push
  /// the drawer's Enter Journal uses). Any failure — no JWT, network
  /// drop, malformed response — degrades silently so chat is never
  /// blocked by a GLP-1 outage. Single-fire per screen lifetime via
  /// [_glp1BannerChecked].
  Future<void> _maybeShowGlp1Banner() async {
    if (_glp1BannerChecked || !mounted) return;
    _glp1BannerChecked = true;
    final jwt = await context.read<AuthService>().getAccessToken();
    if (jwt == null || !mounted) return;
    final svc = Glp1Service();
    try {
      final status = await svc.getStatus(jwt);
      if (!mounted) return;
      if (!status.enabled || !status.isInjectionDay) return;
      final messenger = ScaffoldMessenger.of(context);
      messenger.showMaterialBanner(
        MaterialBanner(
          backgroundColor: const Color(0xFF252525),
          contentTextStyle: const TextStyle(color: Colors.white),
          content: const Text('GLP-1 injection due today.'),
          actions: [
            TextButton(
              onPressed: () {
                messenger.hideCurrentMaterialBanner();
                Navigator.of(context).push(
                  MaterialPageRoute(builder: (_) => const JournalScreen()),
                );
              },
              child: const Text(
                'GO TO JOURNAL',
                style: TextStyle(color: Color(0xFF2196F3)),
              ),
            ),
            TextButton(
              onPressed: messenger.hideCurrentMaterialBanner,
              child: const Text(
                'OK',
                style: TextStyle(color: Colors.white70),
              ),
            ),
          ],
        ),
      );
    } catch (_) {
      // Silent — GLP-1 banner is a courtesy, not load-bearing.
    } finally {
      svc.dispose();
    }
  }

  Future<void> _loadSkipClearPref() async {
    final prefs = await SharedPreferences.getInstance();
    if (!mounted) return;
    setState(() {
      _skipClearConfirm = prefs.getBool(_skipClearPrefKey) ?? false;
    });
  }

  Future<void> _loadPttPosition() async {
    final saved = await PttLayout.loadSavedPosition();
    if (!mounted || saved == null) return;
    setState(() => _pttPosition = saved);
  }

  @override
  void dispose() {
    _pttDragTimer?.cancel();
    unawaited(_recorder.dispose());
    _stt.dispose();
    _chat.dispose();
    _command.dispose();
    _settings.dispose();
    _tts.dispose();
    _micLevels.dispose();
    super.dispose();
  }

  Offset _defaultPttPosition(Size screen) =>
      PttLayout.defaultPosition(screen);

  /// Chat reserves the chat-input row so PTT can't cover the mute /
  /// mode / talk controls.
  Offset _clampPttPosition(Offset pos, Size screen) => PttLayout.clamp(
        pos,
        screen,
        reservedBottom: PttLayout.chatInputApproxHeight,
      );

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

  Future<void> _persistPttPosition(Offset pos) => PttLayout.savePosition(pos);

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
  // _doSendMessage (same _pinnedVoiceId, same fresh-JWT fetch, same
  // TtsException handling) so command responses sound identical to chat
  // replies. No-op on empty text.
  void _regiSay(String text) {
    final trimmed = text.trim();
    if (trimmed.isEmpty) return;
    final state = context.read<ChatState>();
    state.addMessage(TextMessage(content: text, role: MessageRole.assistant));
    _sink.recordTurn(role: 'assistant', text: text);
    if (!state.ttsEnabled) return;

    final auth = context.read<AuthService>();
    unawaited(() async {
      final jwt = await auth.getAccessToken();
      if (jwt == null) return;
      try {
        await _tts.speak(
          text,
          jwt: jwt,
          voice: _pinnedVoiceId,
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
      unawaited(() async {
        final freshJwt = await auth.getAccessToken() ?? jwt;
        try {
          await _tts.speak(
            replyText,
            jwt: freshJwt,
            voice: voiceId,
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

  // Voice capture is BATCH (record-then-transcribe), not streaming. On
  // press we open the OS mic and buffer raw PCM via [AudioRecorderService];
  // on release we ship the WAV blob to /api/speech/stt/transcribe and
  // dispatch the returned transcript. There is intentionally no live
  // captioning — that was the whole point of dropping the streaming path,
  // since restart-on-silence dedup artifacts went with it.
  //
  // All diagnostic feedback uses SnackBar (not addMessage) because when
  // an overlay is open the chat output is hidden — addMessage would
  // silently log to invisible chat. SnackBars float above the overlay.
  Future<void> _handleTalkStart() async {
    final state = context.read<ChatState>();
    state.setTalkActive(true);
    state.setListening(true);

    state.setCurrentInput('');

    bool ok;
    try {
      ok = await _recorder.start();
    } catch (e) {
      if (!mounted) return;
      state.setListening(false);
      state.setTalkActive(false);
      _toast('mic start threw: $e');
      return;
    }
    if (!ok && mounted) {
      state.setListening(false);
      state.setTalkActive(false);
      _toast('mic blocked (permission denied or device unavailable)');
    }
  }

  Future<void> _handleTalkEnd() async {
    final state = context.read<ChatState>();
    final auth = context.read<AuthService>();
    if (!state.isTalkActive) return;
    state.setTalkActive(false);

    // Single exit-cleanup: ALWAYS clear listening + drop primary focus
    // when this handler returns, no matter which branch. The unfocus is
    // defensive against the "PTT stole focus" symptom — if any TextField
    // picked up focus during the hold (e.g. via controller-text write),
    // releasing it here restores normal tap routing across the UI.
    void finish() {
      if (!mounted) return;
      state.setListening(false);
      FocusManager.instance.primaryFocus?.unfocus();
    }

    Uint8List? bytes;
    try {
      bytes = await _recorder.stop();
    } catch (e) {
      _toast('mic stop threw: $e');
      finish();
      return;
    }

    if (bytes == null || bytes.isEmpty) {
      state.clearCurrentInput();
      _toast('recorder produced 0 bytes (likely web pcm16 unsupported '
          'or zero-length press)');
      finish();
      return;
    }

    final jwt = await auth.getAccessToken();
    if (jwt == null) {
      _toast('stt: not authenticated');
      finish();
      return;
    }

    TranscribeResult result;
    try {
      result = await _stt.transcribe(
        audio: bytes,
        format: _recorder.format,
        jwt: jwt,
      );
    } on SpeechError catch (e) {
      state.clearCurrentInput();
      _toast(e.httpStatus == 422
          ? "didn't catch that — try again"
          : 'stt ${e.code}: ${e.detail}');
      finish();
      return;
    } catch (e) {
      state.clearCurrentInput();
      _toast('stt threw: $e');
      finish();
      return;
    }

    if (!mounted) return;
    final text = result.transcript.trim();
    if (text.isEmpty) {
      state.clearCurrentInput();
      _toast('stt returned empty transcript (${result.durationSeconds}s audio)');
      finish();
      return;
    }

    // Transcripts always flow into the chat pipeline now — pushed
    // screens (Journal, Settings) own their own mic and never route
    // through this handler.
    state.clearCurrentInput();
    await _sendMessage(text);
    finish();
  }

  // Floats a short debug/feedback message above whatever is on screen —
  // safe to call while an overlay is hiding chat-output. Floating
  // SnackBar so it sits above the chat-input row.
  void _toast(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).hideCurrentSnackBar();
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(msg),
        behavior: SnackBarBehavior.floating,
        duration: const Duration(seconds: 4),
      ),
    );
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
    // PTT is shown only when the user explicitly chose Voice in the
    // mode slider. Pushed screens (Journal, Settings) own their own
    // mic affordances now; they no longer register a global sink.
    final showPtt = state.mode == InputMode.voice;
    final isToggleMode = state.pttMode == PttMode.tapToggle;
    final screenSize = MediaQuery.of(context).size;
    final pttPos = _clampPttPosition(
      _pttPosition ?? _defaultPttPosition(screenSize),
      screenSize,
    );

    return Scaffold(
      backgroundColor: const Color(0xFF1B1B1B),
      drawer: Drawer(
        backgroundColor: const Color(0xFF252525),
        child: SafeArea(
          child: ListView(
            padding: EdgeInsets.zero,
            children: [
              const DrawerHeader(
                decoration: BoxDecoration(color: Color(0xFF1B1B1B)),
                child: Align(
                  alignment: Alignment.bottomLeft,
                  child: Text(
                    'RegiMenu',
                    style: TextStyle(color: Colors.white, fontSize: 20),
                  ),
                ),
              ),
              ListTile(
                leading: const Icon(Icons.add, color: Colors.white),
                title: const Text(
                  'Add Food',
                  style: TextStyle(color: Colors.white),
                ),
                onTap: () {
                  Navigator.pop(context);
                  // TODO: push AddFoodScreen onto the root navigator
                  // — same dispatch as Enter Journal below — once
                  // that screen exists.
                },
              ),
              ListTile(
                leading: const Icon(Icons.book, color: Colors.white),
                title: const Text(
                  'Enter Journal',
                  style: TextStyle(color: Colors.white),
                ),
                onTap: () {
                  Navigator.pop(context);
                  Navigator.of(context).push(
                    MaterialPageRoute(
                      builder: (_) => const JournalScreen(),
                    ),
                  );
                },
              ),
            ],
          ),
        ),
      ),
      appBar: AppBar(
        backgroundColor: const Color(0xFF1B1B1B),
        foregroundColor: Colors.white,
        // Title shrinks to the overlay's name while an overlay is open —
        // Mic-status (amber mic + level bars) sits next to the brand
        // so the "is it listening" cue is always visible. The route's
        // own AppBar supplies overlay-specific titling when an overlay
        // is pushed onto the inner Navigator.
        title: Row(
          children: [
            const Text('RegiMenu'),
            const SizedBox(width: 12),
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
          // Overlays carry their own close affordance (the back
          // arrow in the overlay panel's header bar) — no outer
          // AppBar × needed. Clear renders unconditionally; it acts
          // on the chat conversation which is always mounted
          // beneath whatever overlay is open.
          IconButton(
            icon: const Icon(Icons.clear_all),
            tooltip: 'Clear',
            onPressed: _handleNewChat,
          ),
          IconButton(
            icon: const Icon(Icons.settings),
            tooltip: 'App Settings',
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute(
                builder: (_) => const SettingsScreen(),
              ),
            ),
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
              // Journal and Settings are pushed routes on the root
              // Navigator now (see drawer / AppBar handlers above);
              // they cover the whole app, not just this Expanded.
              // Chat is just the chat, all the time.
              const Expanded(child: ChatOutput()),
              ChatInput(
                onSend: _sendMessage,
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
                                  style: const TextStyle(
                                    color: Colors.white,
                                  ),
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
                toggleMode: isToggleMode,
                toggleActive: isToggleMode && state.isTalkActive,
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

