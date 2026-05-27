import 'dart:async';

import 'package:speech_to_text/speech_to_text.dart' as stt;

/// Wraps the speech_to_text package and surfaces any failures via an
/// [errors] stream. Status events are surfaced too so callers can show
/// "listening / not listening / done" if useful.
class SpeechService {
  SpeechService();

  final stt.SpeechToText _speech = stt.SpeechToText();
  bool _initialized = false;
  StreamController<String>? _transcripts;
  final StreamController<String> _errors =
      StreamController<String>.broadcast();
  final StreamController<String> _statuses =
      StreamController<String>.broadcast();

  // True between listen() and stop(). The Android Google recognizer in
  // dictation mode finalizes on any short silence (it ignores pauseFor),
  // so we restart the engine each time it self-terminates while the user
  // is still meant to be talking. PTT becomes a true walkie-talkie.
  bool _keepListening = false;
  // The platform's onResult.recognizedWords covers ONLY the current engine
  // session. We snapshot the last words into _cumulative before each
  // restart, so the listener sees one continuous joined transcript.
  String _cumulative = '';
  String _currentChunk = '';

  bool get isAvailable => _speech.isAvailable;

  /// Emits human-readable error messages whenever STT init or recognition
  /// fails. Caller surfaces these in the chat output as debug lines.
  Stream<String> get errors => _errors.stream;

  /// Emits status updates ('listening', 'notListening', 'done', etc.).
  Stream<String> get statuses => _statuses.stream;

  Future<bool> initialize() async {
    if (_initialized) return _speech.isAvailable;
    try {
      _initialized = await _speech.initialize(
        onStatus: (s) {
          if (!_statuses.isClosed) _statuses.add(s);
          // Engine self-terminated (Android's silence cutoff fired). If the
          // user is still meant to be talking, snapshot the current chunk
          // and restart so PTT keeps capturing.
          if ((s == 'notListening' || s == 'done') && _keepListening) {
            _snapshotChunk();
            // Defer; the platform won't accept listen() from inside its
            // own status callback. 50ms is enough for teardown.
            Future<void>.delayed(const Duration(milliseconds: 50), () {
              if (_keepListening) _startEngine();
            });
          }
        },
        onError: (e) {
          if (!_errors.isClosed) _errors.add(e.errorMsg);
        },
      );
    } catch (e) {
      _errors.add('initialize threw: $e');
      _initialized = false;
    }
    if (!_initialized) {
      _errors.add('initialize returned false (mic permission? https? '
          'browser support? speech_to_text says isAvailable=${_speech.isAvailable})');
    }
    return _initialized;
  }

  void _snapshotChunk() {
    if (_currentChunk.isEmpty) return;
    _cumulative = _cumulative.isEmpty
        ? _currentChunk
        : '$_cumulative $_currentChunk';
    _currentChunk = '';
  }

  void _startEngine() {
    try {
      _speech.listen(
        onResult: (result) {
          final c = _transcripts;
          if (c == null || c.isClosed) return;
          _currentChunk = result.recognizedWords;
          final combined = _cumulative.isEmpty
              ? _currentChunk
              : '$_cumulative $_currentChunk';
          c.add(combined);
        },
        listenOptions: stt.SpeechListenOptions(
          listenFor: const Duration(minutes: 5),
          pauseFor: const Duration(seconds: 60),
          partialResults: true,
          cancelOnError: true,
          listenMode: stt.ListenMode.dictation,
        ),
      );
    } catch (e) {
      _errors.add('listen threw: $e');
    }
  }

  /// Begins listening; emits the cumulative transcript as it grows. The
  /// engine is auto-restarted internally when Android terminates it on
  /// silence — caller sees one continuous stream until [stop] is called.
  Stream<String> listen() {
    _transcripts?.close();
    final controller = StreamController<String>.broadcast();
    _transcripts = controller;
    _cumulative = '';
    _currentChunk = '';
    _keepListening = true;
    _startEngine();
    return controller.stream;
  }

  /// Stops listening and ensures the listener receives the full final
  /// transcript before the stream closes. Await this; by the time it
  /// returns, the last emitted transcript reflects everything captured.
  Future<void> stop() async {
    _keepListening = false;
    try {
      await _speech.stop();
    } catch (e) {
      _errors.add('stop threw: $e');
    }
    // Give the platform a beat to deliver its final onResult after stop().
    await Future<void>.delayed(const Duration(milliseconds: 250));
    _snapshotChunk();
    final c = _transcripts;
    if (c != null && !c.isClosed && _cumulative.isNotEmpty) {
      c.add(_cumulative);
    }
    await _transcripts?.close();
    _transcripts = null;
  }

  void dispose() {
    _transcripts?.close();
    _errors.close();
    _statuses.close();
  }
}
