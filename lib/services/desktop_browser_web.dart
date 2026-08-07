// Web impl of the desktop-browser check. Uses package:web (the modern,
// non-deprecated stack, same as mic_level_service_web.dart / upc_scanner_web).
//
// Product call: bias HARD toward tethering. Assume MOBILE unless the session is
// CLEARLY a desktop browser. "Clearly desktop" = ALL of:
//   1. NOT an installed PWA (display-mode:standalone) — an installed phone PWA
//      is the companion and must always tether.
//   2. No touch input (navigator.maxTouchPoints == 0) — phones/tablets have > 0.
//   3. A wide viewport (>= 1024px) — desktop cockpit width.
// A touch laptop, a narrow window, or an installed PWA all fall through to
// "mobile" → tether runs.
import 'package:web/web.dart' as web;

bool isDesktopBrowser() {
  // Installed PWA → companion, never a desktop cockpit.
  if (web.window.matchMedia('(display-mode: standalone)').matches) return false;

  // Any touch capability → treat as a mobile/tablet client.
  if (web.window.navigator.maxTouchPoints > 0) return false;

  // No touch AND wide → desktop-class browser (the web cockpit).
  return web.window.matchMedia('(min-width: 1024px)').matches;
}
