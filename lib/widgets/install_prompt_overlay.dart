// Full-screen install nudge for the PWA. Mounted once via MaterialApp.builder
// so it floats above every route (splash, login, chat). Two forms, driven by
// InstallPromptService: a one-tap Install button (Android/Chromium) or manual
// Share → Add to Home Screen steps (iOS Safari). Never shown when installed.
//
// Dismissal ("Continue in browser") is persisted in shared_preferences, so a
// user who declines once is not nagged on every launch. The service itself is
// platform-specific (package:web on web, inert stub elsewhere); this widget is
// plain Flutter and compiles on every target.
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../services/install_prompt.dart';

class InstallPromptOverlay extends StatefulWidget {
  const InstallPromptOverlay({super.key});

  @override
  State<InstallPromptOverlay> createState() => _InstallPromptOverlayState();
}

class _InstallPromptOverlayState extends State<InstallPromptOverlay> {
  static const _kDismissedKey = 'install.promptDismissed';
  // App dark theme (matches manifest background_color / theme_color).
  static const _bg = Color(0xFF0B1220);
  static const _accent = Color(0xFF8B1A2B);

  final InstallPromptService _service = InstallPromptService();

  // Hidden until we've read the persisted flag — avoids a flash before we know
  // the user already dismissed it.
  bool _dismissed = true;
  bool _loaded = false;

  // Android only: the user tapped Install while no beforeinstallprompt was
  // stashed, so we revealed the manual Chrome-menu fallback. Ignored the moment
  // a real event is available (direct prompt takes over).
  bool _androidFallbackShown = false;

  @override
  void initState() {
    super.initState();
    _loadDismissed();
  }

  Future<void> _loadDismissed() async {
    final prefs = await SharedPreferences.getInstance();
    if (!mounted) return;
    setState(() {
      _dismissed = prefs.getBool(_kDismissedKey) ?? false;
      _loaded = true;
    });
  }

  Future<void> _dismiss() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_kDismissedKey, true);
    if (!mounted) return;
    setState(() => _dismissed = true);
  }

  @override
  void dispose() {
    _service.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: _service,
      builder: (context, _) {
        final mode = _service.mode;
        final show = _loaded && !_dismissed && mode != InstallMode.none;
        if (!show) {
          // Present but inert — occupies the Stack slot without intercepting
          // any touch meant for the app beneath it.
          return const Positioned.fill(
            child: IgnorePointer(child: SizedBox.shrink()),
          );
        }
        return Positioned.fill(child: _interstitial(mode));
      },
    );
  }

  Widget _interstitial(InstallMode mode) {
    return Material(
      color: _bg,
      child: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _icon(),
                const SizedBox(height: 24),
                const Text(
                  'Install RegiMenu on this phone',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: 22,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 8),
                const Text(
                  'Get the full-screen app with a home-screen icon — '
                  'no app store needed.',
                  textAlign: TextAlign.center,
                  style: TextStyle(color: Colors.white70, fontSize: 15),
                ),
                const SizedBox(height: 28),
                if (mode == InstallMode.android)
                  _androidSection()
                else
                  _iosSteps(),
                const SizedBox(height: 16),
                TextButton(
                  onPressed: _dismiss,
                  child: const Text(
                    'Continue in browser',
                    style: TextStyle(color: Colors.white54, fontSize: 14),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _icon() {
    return Center(
      child: ClipRRect(
        borderRadius: BorderRadius.circular(22),
        // Served from web/icons/ — Image.network resolves against the base href
        // so it fetches the real deployed asset, not a bundled Flutter asset.
        child: Image.network(
          'icons/Icon-192.png',
          width: 96,
          height: 96,
          fit: BoxFit.cover,
          errorBuilder: (_, __, ___) => Container(
            width: 96,
            height: 96,
            color: _accent,
            alignment: Alignment.center,
            child: const Icon(Icons.restaurant_menu,
                color: Colors.white, size: 48),
          ),
        ),
      ),
    );
  }

  Widget _androidSection() {
    // A stashed event → Install fires it directly. Otherwise Install reveals the
    // Chrome-menu fallback. If the event lands late, `hasPrompt` flips true on
    // the next notify and we render the direct path regardless of prior tap.
    final direct = _service.hasPrompt;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _installButton(
          onPressed: direct
              ? _service.promptInstall
              : () => setState(() => _androidFallbackShown = true),
        ),
        if (!direct && _androidFallbackShown) ...[
          const SizedBox(height: 16),
          _androidFallback(),
        ],
      ],
    );
  }

  Widget _androidFallback() {
    return Container(
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.06),
        borderRadius: BorderRadius.circular(14),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: const [
          Icon(Icons.more_vert, color: Colors.white70, size: 22),
          SizedBox(width: 12),
          Expanded(
            child: Text(
              "Open Chrome's menu (⋮) and tap 'Install app'.",
              style: TextStyle(color: Colors.white, fontSize: 15),
            ),
          ),
        ],
      ),
    );
  }

  Widget _installButton({required VoidCallback onPressed}) {
    return FilledButton(
      onPressed: onPressed,
      style: FilledButton.styleFrom(
        backgroundColor: _accent,
        foregroundColor: Colors.white,
        padding: const EdgeInsets.symmetric(vertical: 16),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(14),
        ),
      ),
      child: const Text(
        'Install',
        style: TextStyle(fontSize: 17, fontWeight: FontWeight.w600),
      ),
    );
  }

  Widget _iosSteps() {
    return Container(
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.06),
        borderRadius: BorderRadius.circular(14),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: const [
          _Step(
            n: '1',
            icon: Icons.ios_share,
            text: 'Tap the Share button in Safari\'s toolbar.',
          ),
          SizedBox(height: 14),
          _Step(
            n: '2',
            icon: Icons.add_box_outlined,
            text: 'Choose "Add to Home Screen".',
          ),
        ],
      ),
    );
  }
}

class _Step extends StatelessWidget {
  const _Step({required this.n, required this.icon, required this.text});

  final String n;
  final IconData icon;
  final String text;

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        CircleAvatar(
          radius: 13,
          backgroundColor: const Color(0xFF8B1A2B),
          child: Text(
            n,
            style: const TextStyle(
              color: Colors.white,
              fontSize: 13,
              fontWeight: FontWeight.bold,
            ),
          ),
        ),
        const SizedBox(width: 12),
        Icon(icon, color: Colors.white70, size: 22),
        const SizedBox(width: 12),
        Expanded(
          child: Text(
            text,
            style: const TextStyle(color: Colors.white, fontSize: 15),
          ),
        ),
      ],
    );
  }
}
