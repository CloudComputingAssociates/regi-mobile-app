// Web impl of the install-prompt detector. Uses package:web + dart:js_interop
// (the modern, non-deprecated stack, same as mic_level_service_web.dart /
// desktop_browser_web.dart). dart:js_interop_unsafe gives getProperty/callMethod
// for the two non-standard surfaces package:web doesn't type:
//   - BeforeInstallPromptEvent.prompt()  (Chromium-only)
//   - navigator.standalone               (iOS Safari's installed flag)
import 'dart:js_interop';
import 'dart:js_interop_unsafe';

import 'package:flutter/foundation.dart';
import 'package:web/web.dart' as web;

/// Which install affordance (if any) the current session should see.
enum InstallMode {
  /// Nothing to show — installed, unsupported, or not applicable.
  none,

  /// Android browser — show an Install button (direct prompt if the browser
  /// offered one, otherwise inline Chrome-menu instructions).
  android,

  /// iOS Safari — show manual Share → Add to Home Screen instructions.
  iosInstructions,
}

class InstallPromptService extends ChangeNotifier {
  /// The stashed BeforeInstallPromptEvent, held so we can fire prompt() later
  /// from inside a user gesture. Chromium allows it to be used once; cleared
  /// after prompt() or when the app reports itself installed.
  JSObject? _deferred;
  bool _installed = false;

  /// Whether a stashed beforeinstallprompt is available to fire directly. The UI
  /// reads this to pick the Install button's behavior; it re-reads on notify, so
  /// a late-arriving event upgrades the fallback path to a direct prompt().
  bool get hasPrompt => _deferred != null;

  InstallPromptService() {
    // beforeinstallprompt: suppress the mini-infobar and stash the event so the
    // UI can offer its own prominent button. Fires only on Chromium when the
    // site is installable and not yet installed.
    web.window.addEventListener(
      'beforeinstallprompt',
      ((web.Event e) {
        e.preventDefault();
        _deferred = e as JSObject;
        notifyListeners();
      }).toJS,
    );

    // appinstalled: the install completed (via our button or the browser UI).
    // Drop the nudge for good this session.
    web.window.addEventListener(
      'appinstalled',
      ((web.Event e) {
        _installed = true;
        _deferred = null;
        notifyListeners();
      }).toJS,
    );
  }

  /// Already running as an installed app — display-mode:standalone covers
  /// Android/desktop PWAs; navigator.standalone covers iOS home-screen apps.
  bool get _isStandalone {
    if (web.window.matchMedia('(display-mode: standalone)').matches) return true;
    final raw = web.window.navigator.getProperty('standalone'.toJS);
    return raw.dartify() == true;
  }

  /// Android browser. Visibility no longer depends on beforeinstallprompt —
  /// Chrome suppresses that event after a prior dismissal, so gating on it hid
  /// the nudge on exactly the devices that most need it. The Install button
  /// itself decides direct-prompt vs. manual instructions via [hasPrompt].
  bool get _isAndroid =>
      web.window.navigator.userAgent.toLowerCase().contains('android');

  /// iOS Safari (the only iOS engine that offers Add to Home Screen). iPadOS 13+
  /// masquerades as desktop Mac, so treat a touch-capable Mac as iOS too.
  /// Excludes Chrome/Firefox for iOS (CriOS/FxiOS) — their share sheet differs.
  bool get _isIosSafari {
    final ua = web.window.navigator.userAgent.toLowerCase();
    final isIos = ua.contains('iphone') ||
        ua.contains('ipad') ||
        ua.contains('ipod') ||
        (ua.contains('macintosh') && web.window.navigator.maxTouchPoints > 0);
    if (!isIos) return false;
    final isRealSafari = ua.contains('safari') &&
        !ua.contains('crios') &&
        !ua.contains('fxios') &&
        !ua.contains('android');
    return isRealSafari;
  }

  InstallMode get mode {
    if (_installed || _isStandalone) return InstallMode.none;
    if (_isAndroid) return InstallMode.android;
    if (_isIosSafari) return InstallMode.iosInstructions;
    return InstallMode.none;
  }

  /// Fire the stashed Chromium prompt. No-op if nothing is stashed. The event is
  /// single-use, so clear it and notify so the button stops offering a dead tap.
  Future<void> promptInstall() async {
    final p = _deferred;
    if (p == null) return;
    p.callMethod('prompt'.toJS);
    _deferred = null;
    notifyListeners();
  }
}
