# regi-mobile-app — architecture notes

Repo-level conventions for Claude (and any future contributor) working in
this codebase. Read this before touching the layout shell, the chat
input/output area, or the routing of speech/text input.

## Three visual primitives

The chat surface has THREE classes of UI artifact that can be on screen at
the same time. They are independently owned and must not be conflated.

### 1. Material Left-Nav Overlays (full-area)

- Launched from the hamburger drawer in the AppBar.
- Occupy the entire area between the AppBar and the chat-input row.
- Replace `ChatOutput` while active — the chat conversation is hidden.
- The chat-input row at the bottom stays visible and is the user's
  entry mechanism (typing + PTT for voice). Voice routes to the overlay's
  registered `VoiceSink`; the overlay decides what to do with the text
  (e.g. append to a Thoughts field).
- These are the **primitive functions of the mobile app**: things the
  user explicitly chooses to do (Add Food, Enter Journal). Always
  reachable from the drawer regardless of chat state.
- Lifecycle: `ChatState.openOverlay(key)` / `closeOverlay()`. State slot
  is independent from the bloom slot.
- Close affordance: an `×` action in the AppBar that appears only when
  an overlay is active.

### 2. Blooms (command-driven, partial)

- Launched by a typed/voice command directive (the command gate) or by a
  legacy direct trigger (e.g. AppBar gear icon → UserSettings bloom).
- Partially occlude whatever is behind them — bloom frame is a
  rounded panel that sits on top of either `ChatOutput` or an active
  overlay.
- These are **RegiMenu App features**: data-display panels backed by
  regi-api (Get User Settings, Get My Weight Setting, Get Today's Menu).
  Fully implemented on the web app; partially on mobile.
- Lifecycle: `ChatState.openBloom(key)` / `closeBloom()`. State slot is
  independent from the overlay slot.
- Close affordance: macOS-style red dot in the top-left of the bloom frame.
- A bloom can appear on top of any overlay. They are independent threads
  of execution; the overlay does not need to know about the bloom and
  vice versa.

### 3. The chat-input row + floating PTT

- The chat-input row (`ChatInput`) is always visible at the bottom.
- The floating `PttButton` is a separate `Positioned` widget. It shows
  when EITHER:
  - `state.voiceSink != null` (an overlay or bloom has registered for
    voice — PTT comes alive automatically), OR
  - `state.mode == InputMode.voice` (the user explicitly chose Voice
    mode in the slider for plain chat dictation).
- PTT visibility is NEVER force-flipped by overlay/bloom code via mode
  changes. Mode is the user's persistent preference for the chat path;
  overlays signal voice need via `setVoiceSink`. Earlier prototypes used
  an `enterVoiceCapture`/`exitVoiceCapture` mode-snapshot mechanism —
  that is gone and must not come back; it caused desync bugs where the
  slider visibly showed Text while PTT was active.

## Voice routing — `VoiceSink`

The recorder + STT pipeline lives in `ChatScreen._handleTalkStart` /
`_handleTalkEnd`. It records via `AudioRecorderService` on press, posts
the WAV blob to `/api/speech/stt/transcribe` on release, and dispatches
the resulting transcript:

- If `state.voiceSink != null` (an overlay/bloom registered one),
  transcript goes to `sink.onFinal(text)`. The chat output is NOT
  written to — overlays own their own display surface and the chat is
  often hidden anyway.
- Otherwise, transcript goes to `_sendMessage(text)` — the chat pipeline.

The `VoiceSink` contract has `onStart`/`onPartial(cumulative)`/
`onFinal(text)`. The current transport is BATCH (single-shot record →
POST → transcribe), so `onPartial` never fires; the field is retained
for the contract in case a streaming transport is added later.

## Voice transport: BATCH, not streaming

- Capture happens entirely client-side via `record` package's `startStream`.
- On press: open mic, buffer raw PCM16 @ 16kHz mono.
- On release: stop, wrap PCM in a 44-byte WAV header, POST as multipart
  to `/api/speech/stt/transcribe` with `format=wav`.
- One STT call per PTT hold. No restart-on-silence dedup, no streaming
  artifacts. There is NO live caption during the hold — the user sees
  the transcript appear at once on release. This was a deliberate trade
  for exactness over liveness (PTT means "I will tell you when I am done").

## State slots in `ChatState` for UI

```
_activeOverlay  // String? — left-nav full panel (Journal, AddFood)
_activeBloom    // String? — partial command panel (UserSettings, ...)
_voiceSink      // VoiceSink? — current voice-input target (notifies on change)
_mode           // InputMode — user's chat-path text/voice preference
```

All four are independent. An overlay can be open while a bloom is open;
voice can be routed to either or to neither (chat) depending on which
registered a sink last.

## Conventions

- Drawer ListTile labels for overlays use a plain noun phrase (no
  ellipsis): `Add Food`, `Enter Journal`. Ellipsis is reserved for
  actions that open *modals* requiring confirmation — overlays are
  destinations, not modals.
- New overlays go in `lib/widgets/overlays/`. Existing blooms in
  `lib/widgets/blooms/` stay where they are.
- An overlay/bloom that consumes voice MUST register a `VoiceSink` in
  `initState` and clear it in `dispose`. Use `context.read<ChatState>()`
  in both places (one-shot, not a `watch`).

## What lives where

| File | Purpose |
|---|---|
| `lib/state/chat_state.dart` | All four UI slots, mode, sink registration |
| `lib/services/audio_recorder.dart` | `record` wrapper + WAV header |
| `lib/services/stt_service.dart` | POST to `/api/speech/stt/transcribe` |
| `lib/services/tts_service.dart` | POST to `/api/speech/tts` (Regi's voice) |
| `lib/services/voice_sink.dart` | The `VoiceSink` contract |
| `lib/screens/chat_screen.dart` | Layout shell, drawer, talk handlers, render switch for overlay / bloom / PTT |
| `lib/widgets/overlays/*` | Left-nav full-area destinations |
| `lib/widgets/blooms/*` | Command-driven partial panels |
