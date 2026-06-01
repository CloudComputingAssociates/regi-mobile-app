import 'package:flutter/foundation.dart';

import '../models/chat_message.dart';
import '../models/input_mode.dart';

class ChatState extends ChangeNotifier {
  final List<ChatMessage> _messages = [];
  InputMode _mode = InputMode.text;
  bool _isPromptMeOn = false;
  bool _isTalkActive = false;
  bool _isListening = false;
  String? _sessionId;
  String _currentInput = '';
  bool _ttsEnabled = true;
  double _ttsRate = 1.25;
  String? _activeBloom;

  List<ChatMessage> get messages => List.unmodifiable(_messages);
  InputMode get mode => _mode;
  bool get isPromptMeOn => _isPromptMeOn;
  bool get isTalkActive => _isTalkActive;
  bool get isListening => _isListening;
  String? get sessionId => _sessionId;
  String get currentInput => _currentInput;
  bool get ttsEnabled => _ttsEnabled;
  double get ttsRate => _ttsRate;
  String? get activeBloom => _activeBloom;

  void setMode(InputMode mode) {
    if (_mode == mode) return;
    _mode = mode;
    notifyListeners();
  }

  void togglePromptMe() {
    _isPromptMeOn = !_isPromptMeOn;
    if (_isPromptMeOn && _isTalkActive) {
      _isTalkActive = false;
    }
    notifyListeners();
  }

  void setTalkActive(bool active) {
    if (_isTalkActive == active) return;
    if (active && _isPromptMeOn) return;
    _isTalkActive = active;
    notifyListeners();
  }

  void setListening(bool listening) {
    if (_isListening == listening) return;
    _isListening = listening;
    notifyListeners();
  }

  void openBloom(String key) {
    _activeBloom = key;
    notifyListeners();
  }

  void closeBloom() {
    if (_activeBloom == null) return;
    _activeBloom = null;
    notifyListeners();
  }

  void setCurrentInput(String value) {
    _currentInput = value;
    notifyListeners();
  }

  void clearCurrentInput() {
    if (_currentInput.isEmpty) return;
    _currentInput = '';
    notifyListeners();
  }

  void setSessionId(String? id) {
    _sessionId = id;
    notifyListeners();
  }

  void addMessage(ChatMessage message) {
    _messages.add(message);
    notifyListeners();
  }

  StreamingTextMessage startAssistantStream() {
    final msg = StreamingTextMessage(role: MessageRole.assistant);
    _messages.add(msg);
    notifyListeners();
    return msg;
  }

  void appendToStream(StreamingTextMessage msg, String chunk) {
    msg.append(chunk);
    notifyListeners();
  }

  void completeStream(StreamingTextMessage msg) {
    msg.isComplete = true;
    notifyListeners();
  }

  void toggleTts() {
    _ttsEnabled = !_ttsEnabled;
    notifyListeners();
  }

  /// Clamps to GCP TTS's accepted range (0.25..4.0). Practical UI range
  /// is narrower (e.g. 0.75..2.0) — clamping defends against bad input.
  void setTtsRate(double rate) {
    final clamped = rate.clamp(0.25, 4.0);
    if ((clamped - _ttsRate).abs() < 0.001) return;
    _ttsRate = clamped;
    notifyListeners();
  }

  /// Clears the visible conversation and detaches from the server-side
  /// session so the next user message starts a fresh chat. The server's
  /// stored history for the prior session is left intact (it will idle out
  /// or be reusable later); Flutter just stops referencing it.
  /// Voice selection and input mode are preserved.
  void clearChat() {
    _messages.clear();
    _sessionId = null;
    _currentInput = '';
    _isPromptMeOn = false;
    _isTalkActive = false;
    notifyListeners();
  }
}
