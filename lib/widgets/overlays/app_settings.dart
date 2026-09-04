import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../services/auth_service.dart';
import '../../services/tether_identity.dart';
import '../../services/user_profile_service.dart';

/// Left-nav-style overlay for app-wide settings.
///
/// Top of the panel greets the logged-in user by name ("Hi {displayName}!"),
/// read from GET /api/user/profile — always the JWT user, so it lets the user
/// corroborate that this phone and the web app are the same account (e.g. after
/// a tether capture round-trip). Falls back to the email's local part when no
/// display name is set, and to a plain "Hi!" if the profile can't be loaded.
///
/// Voice-input section presents the roadmap as a three-row radio
/// group: row 1 is the only functional mode (push-to-talk / hold);
/// rows 2 and 3 are V2 placeholders rendered greyed-out and
/// non-interactive. Selection state never moves off row 1. No enum
/// values, state fields, or handler branches are wired for the
/// disabled rows — they are display-only.
class AppSettings extends StatefulWidget {
  const AppSettings({super.key});

  @override
  State<AppSettings> createState() => _AppSettingsState();
}

class _AppSettingsState extends State<AppSettings> {
  static const Color _accent = Color(0xFFF2B33D);

  final UserProfileService _profiles = UserProfileService();
  final TetherIdentity _identity = TetherIdentity();
  String? _greetingName;
  int? _userId;
  int? _deviceId;

  @override
  void initState() {
    super.initState();
    _loadProfile();
  }

  @override
  void dispose() {
    _profiles.dispose();
    super.dispose();
  }

  /// Fetch the JWT user's profile for the greeting, plus the internal user id
  /// and this device's tether id so the user can corroborate identity — a
  /// tether command is keyed to {userId, deviceId}, so if a capture never
  /// arrives, comparing these two numbers to the queued command tells you
  /// instantly whether the phone and web are the same user/device.
  /// Best-effort — a failure just leaves the neutral "Hi!".
  Future<void> _loadProfile() async {
    // Capture the provider synchronously before any await (no context across gaps).
    final auth = context.read<AuthService>();
    final deviceId = await _identity.savedDeviceId();
    if (mounted) setState(() => _deviceId = deviceId);
    final jwt = await auth.getAccessToken();
    if (jwt == null) return;
    try {
      final profile = await _profiles.getProfile(jwt);
      if (!mounted) return;
      setState(() {
        _greetingName = profile.greetingName;
        _userId = profile.id;
      });
    } catch (_) {
      // Leave the fallback greeting; identity check just won't show a name.
    }
  }

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(20, 20, 20, 24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _greeting(),
          const SizedBox(height: 4),
          _identityLine(),
          const SizedBox(height: 20),
          _sectionTitle('Voice input'),
          const SizedBox(height: 10),
          _modeRow(
            title: 'Push to talk (hold)',
            selected: true,
            enabled: true,
          ),
          _modeRow(
            title: 'Conversation mode',
            subtitle: 'Coming in V2 — spoken back-and-forth with Regi.',
            enabled: false,
          ),
          _modeRow(
            title: "Wake word ('Hey Regi')",
            subtitle: 'Coming in V2 — hands-free, command-driven.',
            enabled: false,
          ),
        ],
      ),
    );
  }

  /// "Hi {name}!" greeting. The name is amber to stand out; the rest matches
  /// the panel's white type. Shows a plain "Hi!" until the profile resolves.
  Widget _greeting() {
    final name = _greetingName;
    return Text.rich(
      TextSpan(
        style: const TextStyle(
          color: Colors.white,
          fontSize: 22,
          fontWeight: FontWeight.w600,
        ),
        children: [
          const TextSpan(text: 'Hi'),
          if (name != null && name.isNotEmpty)
            TextSpan(
              text: ' $name',
              style: const TextStyle(color: _accent),
            ),
          const TextSpan(text: '!'),
        ],
      ),
    );
  }

  /// Small identity readout for corroborating the phone against the web: the
  /// internal user id and this device's tether id — the exact {userId, deviceId}
  /// a tether command is keyed to. Renders nothing until both resolve.
  Widget _identityLine() {
    final parts = <String>[
      if (_userId != null) 'user #$_userId',
      if (_deviceId != null) 'device #$_deviceId',
    ];
    if (parts.isEmpty) return const SizedBox.shrink();
    return Text(
      parts.join(' · '),
      style: const TextStyle(color: Colors.white38, fontSize: 12),
    );
  }

  /// Radio-style row. When [enabled] is false the row is wrapped in
  /// [AbsorbPointer] so it can never be tapped, and text + indicator
  /// are rendered in low-contrast grey. [selected] is meaningful only
  /// for enabled rows; disabled rows render with an empty indicator
  /// regardless.
  Widget _modeRow({
    required String title,
    String? subtitle,
    bool selected = false,
    required bool enabled,
  }) {
    final titleColor = enabled ? Colors.white : Colors.white38;
    final subtitleColor = enabled ? Colors.white70 : Colors.white24;
    final indicatorColor = enabled ? _accent : Colors.white24;
    final row = Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(top: 2, right: 12),
            child: Container(
              width: 20,
              height: 20,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                border: Border.all(color: indicatorColor, width: 2),
              ),
              alignment: Alignment.center,
              child: selected && enabled
                  ? Container(
                      width: 10,
                      height: 10,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: indicatorColor,
                      ),
                    )
                  : null,
            ),
          ),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: TextStyle(
                    color: titleColor,
                    fontSize: 14,
                    fontWeight: FontWeight.w500,
                  ),
                ),
                if (subtitle != null) ...[
                  const SizedBox(height: 2),
                  Text(
                    subtitle,
                    style: TextStyle(
                      color: subtitleColor,
                      fontSize: 12,
                      fontStyle: FontStyle.italic,
                    ),
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
    if (enabled) return row;
    return AbsorbPointer(child: row);
  }

  Widget _sectionTitle(String text) {
    return Text(
      text,
      style: const TextStyle(
        color: Colors.white,
        fontSize: 16,
        fontWeight: FontWeight.bold,
      ),
    );
  }
}
