// Public re-export. Web build picks the package:web-backed check; every other
// target gets a const-false stub. Caller imports this file as the single entry.
//
// isDesktopBrowser() answers ONE question: is this a desktop-class browser
// session (wide, non-touch, NOT an installed PWA)? It is the sole input to the
// tether-suppression predicate — a normal user in a desktop browser is the web
// cockpit, which only READS presence and must not register itself as a phone.
export 'desktop_browser_io.dart'
    if (dart.library.html) 'desktop_browser_web.dart';
