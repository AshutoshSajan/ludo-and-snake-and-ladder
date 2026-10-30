import 'package:flutter/material.dart';

/// A back press on a running game is a walk-out attempt, and walking out is a
/// statement the table deserves to hear. A raw pop would only end the session:
/// on an online table the server reads silence as a dropped link and the
/// remaining players wait on a seat that is not coming back until the timer
/// finally drops it; on a local board the whole match lives in memory and is
/// simply gone. So the back press is routed through the screen's own leave
/// flow — the confirm dialog, the forfeit, the announcement — exactly as if
/// the leave or quit button had been tapped. The others then get "left the
/// game" and, at a two-player online table, the win.
///
/// Set [active] to false when nothing is at stake any more: a board whose
/// game is already over, or offline boards whose session the back press
/// cannot lose. There the back press is plain navigation.
class LeaveGuard extends StatelessWidget {
  const LeaveGuard({
    super.key,
    required this.active,
    required this.onLeave,
    required this.child,
  });

  /// Screens with a live session intercept the gesture; anything else pops
  /// like an ordinary screen.
  final bool active;

  /// The screen's own leave flow: confirm, tell the table, get out. Called
  /// only when the system tries to pop while [active].
  final Future<void> Function() onLeave;

  final Widget child;

  @override
  Widget build(BuildContext context) {
    return PopScope(
      // The pop decision belongs to the confirm dialog, not the gesture:
      // the route leaves only after the leave flow says so.
      canPop: !active,
      onPopInvokedWithResult: (didPop, _) async {
        if (didPop || !active) return;
        await onLeave();
      },
      child: child,
    );
  }
}
