// Public re-export. Web build picks the package:web-backed detector; every other
// target gets an inert stub. Caller imports this file as the single entry.
//
// InstallPromptService answers: should we surface an "install this PWA" nudge,
// and in which form? It captures the browser's beforeinstallprompt event on
// Android/Chromium and detects iOS Safari (which has no such event and needs
// manual Add-to-Home-Screen guidance). It NEVER fires when already running
// standalone (installed) — an installed PWA is the end state, not a prompt site.
export 'install_prompt_io.dart'
    if (dart.library.html) 'install_prompt_web.dart';
