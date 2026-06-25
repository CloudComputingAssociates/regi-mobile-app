/// How the user activates the microphone when voice input is in play.
/// Selected in App Settings; stored in ChatState.
enum PttMode {
  /// Hold the PTT button to talk, release to stop. Default.
  holdToTalk,

  /// Tap PTT once to start recording, tap again to stop. While live,
  /// the PTT face overlays a bold red "LIVE" label.
  tapToggle,
}

extension PttModeLabel on PttMode {
  String get label => switch (this) {
        PttMode.holdToTalk => 'Hold to talk',
        PttMode.tapToggle => 'Tap to start / tap to stop',
      };
}
