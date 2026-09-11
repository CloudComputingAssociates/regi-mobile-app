import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

class PttButton extends StatefulWidget {
  const PttButton({
    super.key,
    required this.onPressStart,
    required this.onPressEnd,
    this.size = 90,
    this.dragMode = false,
    this.onEnterDragMode,
    this.onExitDragMode,
    this.onDragMove,
    this.toggleMode = false,
    this.toggleActive = false,
  });

  final VoidCallback onPressStart;
  final VoidCallback onPressEnd;
  final double size;

  /// When true, press-to-talk is suppressed and pointer-move events are
  /// reported as drag deltas via [onDragMove]. Owned by the parent so the
  /// parent can also persist position and render-around layout.
  final bool dragMode;
  final VoidCallback? onEnterDragMode;
  final VoidCallback? onExitDragMode;
  final void Function(Offset delta)? onDragMove;

  /// PttMode.tapToggle: a single tap toggles recording on, the next
  /// single tap toggles it off. When this is true, the hold-to-talk
  /// pointer-down semantics are disabled — only pointer-up fires the
  /// callbacks. [toggleActive] tells the button whether it should
  /// render the "LIVE" overlay (the actual recording state lives in
  /// ChatState.isTalkActive on the parent).
  final bool toggleMode;
  final bool toggleActive;

  @override
  State<PttButton> createState() => _PttButtonState();
}

class _PttButtonState extends State<PttButton> {
  bool _pressed = false;

  // Manual double-tap detection on raw pointers. We measure cumulative
  // movement and duration of each press so a long press-to-talk (which
  // lifts well after any prior tap, and typically lasts > 300 ms) can
  // never satisfy both the gap and the tap-shape bounds — only two
  // quick, near-stationary taps qualify.
  static const _doubleTapMaxGapMs = 300;
  static const _tapMaxDurationMs = 300;
  static const _tapMaxMovementPx = 10.0;

  DateTime? _lastTapUpTime;
  DateTime? _currentPressStart;
  double _currentPressMovement = 0;

  void _handlePointerDown(PointerDownEvent event) {
    _currentPressStart = DateTime.now();
    _currentPressMovement = 0;
    if (widget.dragMode || widget.toggleMode) {
      // Drag mode AND toggle mode both suppress press-to-talk on down.
      // Toggle mode fires its on/off in pointer-up so a tap (not a
      // hold) is what flips state.
      return;
    }
    setState(() => _pressed = true);
    HapticFeedback.lightImpact();
    widget.onPressStart();
  }

  void _handlePointerMove(PointerMoveEvent event) {
    _currentPressMovement += event.delta.distance;
    if (widget.dragMode) {
      widget.onDragMove?.call(event.delta);
    }
  }

  void _handlePointerUp(PointerUpEvent event) {
    if (widget.dragMode) {
      _checkDoubleTap(exitingDrag: true);
      return;
    }
    if (widget.toggleMode) {
      // Single tap → toggle. Movement/duration check skipped (the
      // double-tap-to-drag affordance is disabled in toggle mode; to
      // reposition the button, switch to PTT mode in App Settings).
      HapticFeedback.lightImpact();
      if (widget.toggleActive) {
        widget.onPressEnd();
      } else {
        widget.onPressStart();
      }
      return;
    }
    if (!_pressed) return;
    setState(() => _pressed = false);
    widget.onPressEnd();
    _checkDoubleTap(exitingDrag: false);
  }

  void _handlePointerCancel(PointerCancelEvent event) {
    // A cancel is not a tap — clear pending first-tap state so the
    // next press-to-talk can't accidentally close a double-tap pair.
    _lastTapUpTime = null;
    if (widget.dragMode || widget.toggleMode) return;
    if (!_pressed) return;
    setState(() => _pressed = false);
    widget.onPressEnd();
  }

  void _checkDoubleTap({required bool exitingDrag}) {
    final now = DateTime.now();
    final start = _currentPressStart;
    final pressMs = start == null ? 0 : now.difference(start).inMilliseconds;
    final isTap = _currentPressMovement < _tapMaxMovementPx &&
        pressMs <= _tapMaxDurationMs;
    final prior = _lastTapUpTime;
    if (isTap &&
        prior != null &&
        now.difference(prior).inMilliseconds <= _doubleTapMaxGapMs) {
      _lastTapUpTime = null;
      if (exitingDrag) {
        widget.onExitDragMode?.call();
      } else {
        widget.onEnterDragMode?.call();
      }
      return;
    }
    _lastTapUpTime = isTap ? now : null;
  }

  @override
  Widget build(BuildContext context) {
    // In toggle mode, "active" drives the same visual state as PTT
    // "pressed" — amber border + glow — so the user gets immediate
    // confirmation the toggle flipped.
    final active = _pressed || (widget.toggleMode && widget.toggleActive);
    // Listener (raw pointer events) instead of GestureDetector so we don't
    // get a spurious onTapCancel when a press exceeds Flutter's long-press
    // timeout. Press = down, release = up, no gesture-arena guessing.
    // Double-tap is detected manually above.
    return Listener(
      behavior: HitTestBehavior.opaque,
      onPointerDown: _handlePointerDown,
      onPointerMove: _handlePointerMove,
      onPointerUp: _handlePointerUp,
      onPointerCancel: _handlePointerCancel,
      child: SizedBox(
        width: widget.size,
        height: widget.size,
        child: Stack(
          clipBehavior: Clip.none,
          children: [
            AnimatedContainer(
              duration: const Duration(milliseconds: 80),
              width: widget.size,
              height: widget.size,
              transform: Matrix4.identity()..scale(active ? 0.95 : 1.0),
              transformAlignment: Alignment.center,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: const Color(0xFF2196F3),
                boxShadow: [
                  if (active)
                    BoxShadow(
                      color: const Color(0xFFF2B33D).withValues(alpha: 0.85),
                      blurRadius: 24,
                      spreadRadius: 4,
                    )
                  else
                    BoxShadow(
                      color: Colors.black.withValues(alpha: 0.25),
                      blurRadius: 8,
                      offset: const Offset(0, 2),
                    ),
                ],
                border: Border.all(
                  color: active
                      ? const Color(0xFFF2B33D)
                      : Colors.white,
                  width: 3,
                ),
              ),
              alignment: Alignment.center,
              child: ClipOval(
                child: Padding(
                  padding: EdgeInsets.all(widget.size * 0.1),
                  child: Image.asset(
                    'assets/images/ptt_fingerprint.png',
                    fit: BoxFit.contain,
                    // Fallback mic icon if the asset fails to load
                    // (Flutter web asset-bundle quirks, etc.) so the
                    // button is never an empty disc.
                    errorBuilder: (_, __, ___) => Icon(
                      Icons.mic,
                      size: widget.size * 0.5,
                      color: Colors.white,
                    ),
                  ),
                ),
              ),
            ),
            // Toggle-mode "LIVE" badge: bold red text centered over the
            // fingerprint while recording. Disappears on the next tap
            // when the toggle flips off.
            if (widget.toggleMode && widget.toggleActive)
              Positioned.fill(
                child: IgnorePointer(
                  child: Container(
                    alignment: Alignment.center,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: Colors.black.withValues(alpha: 0.45),
                    ),
                    child: const Text(
                      'LIVE',
                      style: TextStyle(
                        color: Color(0xFFFF3B30),
                        fontWeight: FontWeight.w900,
                        fontSize: 20,
                        letterSpacing: 1.5,
                      ),
                    ),
                  ),
                ),
              ),
            if (widget.dragMode)
              Positioned(
                right: -4,
                top: -4,
                child: Container(
                  padding: const EdgeInsets.all(4),
                  decoration: BoxDecoration(
                    color: const Color(0xFF1B1B1B),
                    shape: BoxShape.circle,
                    border: Border.all(
                      color: const Color(0xFFF2B33D),
                      width: 1.5,
                    ),
                  ),
                  child: const Icon(
                    Icons.open_with,
                    size: 20,
                    color: Color(0xFFF2B33D),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}
