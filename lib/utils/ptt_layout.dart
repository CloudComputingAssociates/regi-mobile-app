import 'package:flutter/widgets.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Shared layout constants + position persistence for the floating
/// mic / PTT disc so it lands at the same place on every screen the
/// user sees. Chat owns the drag affordance; other screens (Journal,
/// future AddFood, …) read the saved position and render at the same
/// Offset so the disc feels like one continuous artifact across the
/// app.
class PttLayout {
  static const double buttonSize = 90.0;
  static const String offsetXKey = 'ptt_offset_x';
  static const String offsetYKey = 'ptt_offset_y';
  // Default vertical inset on screens that have a bottom chat-input
  // row (currently just ChatScreen). Screens without a bottom row can
  // either pass a smaller [reservedBottom] to [clamp] or rely on the
  // saved/default position landing in a sensible spot anyway.
  static const double defaultBottomInset = 210.0;
  static const double chatInputApproxHeight = 160.0;

  static Offset defaultPosition(Size screen) {
    return Offset(
      (screen.width - buttonSize) / 2,
      screen.height - defaultBottomInset - buttonSize,
    );
  }

  /// Clamp into the visible viewport. [reservedBottom] is the vertical
  /// strip the disc must not cover (chat-input row on ChatScreen, zero
  /// on screens with no bottom chrome).
  static Offset clamp(
    Offset pos,
    Size screen, {
    double reservedBottom = 0,
  }) {
    final maxX = (screen.width - buttonSize).clamp(0.0, double.infinity);
    final maxY = (screen.height - reservedBottom - buttonSize)
        .clamp(0.0, double.infinity);
    return Offset(
      pos.dx.clamp(0.0, maxX),
      pos.dy.clamp(0.0, maxY),
    );
  }

  /// Reads the user's last-dragged position from SharedPreferences.
  /// Returns null on first run (no keys yet) so callers can fall back
  /// to [defaultPosition].
  static Future<Offset?> loadSavedPosition() async {
    final prefs = await SharedPreferences.getInstance();
    final x = prefs.getDouble(offsetXKey);
    final y = prefs.getDouble(offsetYKey);
    if (x == null || y == null) return null;
    return Offset(x, y);
  }

  static Future<void> savePosition(Offset pos) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setDouble(offsetXKey, pos.dx);
    await prefs.setDouble(offsetYKey, pos.dy);
  }
}
