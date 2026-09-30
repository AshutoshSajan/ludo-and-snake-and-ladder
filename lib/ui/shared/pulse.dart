import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../providers/app_providers.dart';

/// Gently breathes its child while [active].
///
/// Used to mark whose turn it is directly on the board, instead of a row of
/// player chips above it: the pawns are already on screen, so pulsing the one
/// that is on turn says the same thing where the eye already is.
///
/// Respects the "Board animations" preference (battery saver) like the rest of
/// the game, and stops its ticker entirely when inactive rather than animating
/// a no-op — an idle pulse on every seat would keep the UI awake for nothing.
class Pulse extends ConsumerStatefulWidget {
  const Pulse({
    super.key,
    required this.active,
    required this.child,
    this.scale = 1.16,
    this.period = const Duration(milliseconds: 850),
  });

  final bool active;
  final Widget child;

  /// Peak scale at the top of the breath. Kept modest so overlapping pawns on
  /// one square do not jostle.
  final double scale;
  final Duration period;

  @override
  ConsumerState<Pulse> createState() => _PulseState();
}

class _PulseState extends ConsumerState<Pulse>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl;
  late final Animation<double> _t;

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(vsync: this, duration: widget.period);
    _t = Tween<double>(
      begin: 1,
      end: widget.scale,
    ).animate(CurvedAnimation(parent: _ctrl, curve: Curves.easeInOut));
    _sync();
  }

  @override
  void didUpdateWidget(Pulse oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.active != widget.active) _sync();
  }

  void _sync() {
    final on = widget.active && ref.read(animationsEnabledProvider);
    if (on) {
      if (!_ctrl.isAnimating) _ctrl.repeat(reverse: true);
    } else {
      _ctrl.stop();
      _ctrl.value = 0; // settle at the resting size, no scale
    }
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // Watched so switching animations off mid-pulse stops it too.
    ref.watch(animationsEnabledProvider);
    return ScaleTransition(scale: _t, child: widget.child);
  }
}
