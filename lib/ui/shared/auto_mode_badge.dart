
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../providers/app_providers.dart';
import '../theme.dart';

/// A slowly spinning loop, marking a seat the table is playing for.
///
/// The text this replaced ("playing for them") said the same thing in more
/// words, and it cost the name's most valuable pixels in a strip that has to
/// stay scannable. The icon says "being played for you" at a glance and the
/// tooltip says it in full, so nothing is lost — it is just no longer spelled
/// out beside every name.
///
/// The spin is suppressed when the player has turned animations off, and when
/// the platform asks for reduced motion. A permanently rotating glyph is the
/// classic vestibular trigger, and it would otherwise be the one animation in
/// the app that ignores the setting that exists to stop it.
class AutoModeBadge extends ConsumerStatefulWidget {
  const AutoModeBadge({required this.seatName, this.mine = false, super.key});

  /// Whose seat this is, for the tooltip.
  final String seatName;

  /// Whether this is our own seat.
  final bool mine;

  @override
  ConsumerState<AutoModeBadge> createState() => _AutoModeBadgeState();
}

class _AutoModeBadgeState extends ConsumerState<AutoModeBadge>
    with SingleTickerProviderStateMixin {
  late final AnimationController _spin = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1400),
  );

  @override
  void initState() {
    super.initState();
    // Nothing here touches MediaQuery or ref: inherited widgets are not
    // available until after initState, and reading them from here throws.
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // First safe point to read MediaQuery.
    _sync();
  }

  void _sync() {
    final reduced = MediaQuery.maybeOf(context)?.disableAnimations ?? false;
    final on = ref.read(animationsEnabledProvider) && !reduced;
    if (on && !_spin.isAnimating) {
      _spin.repeat();
    } else if (!on && _spin.isAnimating) {
      // Stop rather than reset: pausing keeps the glyph at a readable angle
      // instead of snapping it to zero.
      _spin.stop();
    }
  }

  @override
  void dispose() {
    _spin.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // Watched so flipping the setting mid-game starts or stops the spin. The
    // sync itself is only a controller call, so running it during build is safe
    // — no setState, no frame scheduling.
    ref.watch(animationsEnabledProvider);
    _sync();
    final name = widget.mine ? 'You' : widget.seatName;
    return Tooltip(
      message: widget.mine
          ? 'You are in automatic mode — the table is playing your turns. '
              'Tap the autoplay button to take over.'
          : '$name is playing in automatic mode — the table is playing their '
              'turns.',
      child: RotationTransition(
        turns: _spin,
        child: Icon(
          Icons.sync,
          size: 13,
          color: AppColors.gold,
          semanticLabel: '$name is in automatic mode',
        ),
      ),
    );
  }
}
