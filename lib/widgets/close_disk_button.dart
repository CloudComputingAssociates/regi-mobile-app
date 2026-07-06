import 'package:flutter/material.dart';

/// A red circular button with a white X — the close affordance for full-screen
/// pushed screens (Journal, Food UPC scan). It replaces Material's leading back
/// arrow, which reads too much like the calendar's date-navigation arrows and
/// sits ambiguously in the top-left. This lives in the AppBar's upper-right
/// corner instead.
///
/// Sized to echo the numbered step badges on the Food UPC scan screen (the
/// "1 2 3" discs) so the two screens share one visual language. Keep [diameter]
/// in sync with that badge size.
class CloseDiskButton extends StatelessWidget {
  const CloseDiskButton({
    super.key,
    required this.onClose,
    this.diameter = 26,
  });

  final VoidCallback onClose;
  final double diameter;

  static const Color _red = Color(0xFFFF3B30);

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      label: 'Close',
      child: InkResponse(
        onTap: onClose,
        radius: diameter,
        // Padding widens the tap target past the small disc without growing
        // the disc itself, and floats it off the screen edge.
        child: Padding(
          padding: const EdgeInsets.only(left: 8, right: 12),
          child: Container(
            width: diameter,
            height: diameter,
            alignment: Alignment.center,
            decoration: const BoxDecoration(
              color: _red,
              shape: BoxShape.circle,
            ),
            child: Icon(
              Icons.close,
              size: diameter * 0.62,
              color: Colors.white,
            ),
          ),
        ),
      ),
    );
  }
}
