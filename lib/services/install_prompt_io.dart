// Non-web stub. The PWA install path only exists in a browser, so on native
// there is never an install nudge — mode is always none and prompting is a
// no-op. Mirrors the API of install_prompt_web.dart so callers stay identical.
import 'package:flutter/foundation.dart';

/// Which install affordance (if any) the current session should see.
enum InstallMode {
  /// Nothing to show — installed, unsupported, or not applicable.
  none,

  /// Chromium captured a beforeinstallprompt — show a one-tap Install button.
  androidPrompt,

  /// iOS Safari — show manual Share → Add to Home Screen instructions.
  iosInstructions,
}

class InstallPromptService extends ChangeNotifier {
  InstallMode get mode => InstallMode.none;

  Future<void> promptInstall() async {}
}
