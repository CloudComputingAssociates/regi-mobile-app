Here's the updated CLAUDE.md:

regi-mobile-app — architecture notes
Repo-level conventions for Claude (and any future contributor) working in this codebase. Read this before touching the layout shell, the chat input/output area, or the routing of speech/text input.
Three visual primitives
The chat surface has THREE classes of UI artifact that can be on screen at the same time. They are independently owned and must not be conflated.
1. Screens (full-screen pushed routes)

Launched from the hamburger drawer in the AppBar.
Full-screen Navigator.push routes — they take over the entire display with their own Scaffold and AppBar.
The chat surface (ChatOutput + ChatInput + PTT) is fully off-screen while a Screen is active. There is no shared state between a Screen and the chat path.
These are the primitive functions of the mobile app: things the user explicitly chooses to do (Add Food, Enter Journal). Always reachable from the drawer regardless of chat state.
Each Screen owns its own mic (AudioRecorderService, SttService), its own focus nodes, and its own voice wiring. It does NOT register a VoiceSink on ChatState and does NOT touch global state during its lifecycle.
Lifecycle: Navigator.push / back arrow (framework-owned). No ChatState slot.
Close affordance: the auto back arrow in the Screen's own AppBar.
Live in lib/screens/.

2. Blooms (command-driven, partial)

Launched by a typed/voice command directive (the command gate) or by a legacy direct trigger (e.g. AppBar gear icon → UserSettings bloom).
Partially occlude whatever is behind them — bloom frame is a rounded panel that sits on top of ChatOutput.
These are RegiMenu App features: data-display panels backed by regi-api (Get User Settings, Get My Weight Setting, Get Today's Menu). Fully implemented on the web app; partially on mobile.
Lifecycle: ChatState.openBloom(key) / closeBloom(). State slot is independent from all other slots.
Close affordance: macOS-style red dot in the top-left of the bloom frame.
Live in lib/widgets/blooms/.

3. The chat-input row + floating PTT

The chat-input row (ChatInput) is always visible at the bottom of the chat surface.
The floating PttButton is a separate Positioned widget. It shows when state.mode == InputMode.voice (the user explicitly chose Voice mode in the slider for plain chat dictation).
PTT visibility is NEVER force-flipped by screen or bloom code. Mode is the user's persistent preference for the chat path only. Screens own their own mic — they do not affect PTT visibility.
Do NOT reintroduce voiceSink-driven PTT visibility (state.voiceSink != null || ...). That pattern is gone.

Voice routing
Each surface owns its own pipeline. There is no shared sink.
Chat surface (ChatScreen._handleTalkStart / _handleTalkEnd): records via AudioRecorderService on press, posts the WAV blob to /api/speech/stt/transcribe on release, transcript always goes to _sendMessage(text).
Screens (e.g. JournalScreen): own their own AudioRecorderService and SttService instances. The hold-to-talk mic is a Listener-wrapped button inside the screen, hardwired to the screen's own target field. Transcript is dispatched locally — nothing in ChatState is touched.
The VoiceSink contract (lib/services/voice_sink.dart) and ChatState.setVoiceSink / voiceSink are deleted. Do not reintroduce them.
Voice transport: BATCH, not streaming

Capture happens entirely client-side via record package's startStream.
On press: open mic, buffer raw PCM16 @ 16kHz mono.
On release: stop, wrap PCM in a 44-byte WAV header, POST as multipart to /api/speech/stt/transcribe with format=wav.
One STT call per PTT hold. No restart-on-silence dedup, no streaming artifacts. There is NO live caption during the hold — the user sees the transcript appear at once on release. This was a deliberate trade for exactness over liveness (PTT means "I will tell you when I am done").

State slots in ChatState for UI
_activeBloom    // String? — partial command panel (UserSettings, ...)
_mode           // InputMode — user's chat-path text/voice preference
These are the only two UI slots. _activeOverlay and _voiceSink are deleted. Do not add them back.
Conventions

Drawer ListTile labels for screens use a plain noun phrase (no ellipsis): Add Food, Enter Journal. Ellipsis is reserved for actions that open modals requiring confirmation — screens are destinations, not modals.
New screens go in lib/screens/. Existing blooms in lib/widgets/blooms/ stay where they are.
A screen that needs voice MUST own its own AudioRecorderService and SttService. It MUST NOT register a VoiceSink on ChatState.
A bloom that needs voice may register a VoiceSink if that pattern is reintroduced in future — but check here first; the current implementation has no bloom-level voice.

No ghost-disabled colored AppBar actions
The colored primary AppBar actions appear when actionable and disappear when not — never render in a greyed/half-opacity "disabled" state. A persistent muddy colored icon is visual noise. Plain inline form icons (e.g. a trash icon next to a Thoughts field) MAY use a normal greyed/brightened pattern — that's standard form-control behavior, not a ghost action.
When colored icons sit alongside other AppBar actions, prefer stroke-style glyphs (Icons.check, Icons.close) over filled-disc variants so they match peer icons' visual weight.
Workflow conventions for Claude

Builds: Claude MAY run flutter build / flutter analyze / flutter test to verify changes compile and pass.
Commits: Claude NEVER runs git commit. After every set of code changes, Claude provides a TERSE commit message (one line, lower-case, imperative) for the user to copy. The user owns the commit.
Cross-project edits: Claude NEVER modifies files outside this project (e.g. regi-api, regi-web). If a change requires work in a sibling repo, Claude SUGGESTS the change in prose. The user may then explicitly ask for a ready-to-paste prompt for that other project.

What lives where
FilePurposelib/state/chat_state.dartBloom slot, mode, message list, session, TTS togglelib/services/audio_recorder.dartrecord wrapper + WAV headerlib/services/stt_service.dartPOST to /api/speech/stt/transcribelib/services/tts_service.dartPOST to /api/speech/tts (Regi's voice)lib/screens/chat_screen.dartLayout shell, drawer, talk handlers, bloom render, PTTlib/screens/journal_screen.dartJournal entry form — owns its own mic, focus, voice wiringlib/screens/settings_screen.dartApp settings — wraps AppSettings widgetlib/widgets/blooms/Command-driven partial panelslib/widgets/overlays/app_settings.dartAppSettings widget (hosted by SettingsScreen)