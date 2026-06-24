/// How the user activates the microphone when voice input is in play.
/// Selected in App Settings; stored in ChatState (not persisted across
/// sessions yet — add SharedPreferences write-through if/when needed).
enum VoiceMode {
  /// Hold the PTT button to talk, release to stop. Original behavior.
  pushToTalk,

  /// Tap PTT once to start recording, tap again to stop. While live,
  /// the PTT face overlays a bold red "Live" label.
  pressTalk,

  /// Mic is always listening for "Hey Regi". On detection, the AppBar
  /// mic indicator activates and STT routes to the focused field /
  /// chat input. NOT YET IMPLEMENTED — needs always-on streaming STT
  /// or a bundled keyword-spotting model. UI exposes the option; the
  /// audio pipeline change is a follow-up.
  wakeWord,
}

extension VoiceModeLabel on VoiceMode {
  String get label => switch (this) {
        VoiceMode.pushToTalk => 'PTT — press and hold',
        VoiceMode.pressTalk => 'Press to talk, press to stop',
        VoiceMode.wakeWord => "Wake word — 'Hey Regi'",
      };
}
