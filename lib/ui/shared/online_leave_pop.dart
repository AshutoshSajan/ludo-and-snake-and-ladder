import 'package:flutter/material.dart';

/// The back gesture on an online table is a walk-out attempt, and walking
/// out is a statement the table deserves to hear. A raw pop would only
/// drop the socket — the server reads silence as a dropped link, keeps the
/// seat seated for a reconnect that will never come, and the remaining
/// players wait on someone who is not coming back until the timer finally
/// drops them. So the back press is routed through the screen's own leave
/// flow — the confirm dialog, the forfeit, the announcement — exactly as
/// if the leave button had been tapped. The others then get "left the
/// game" and, at a two-player table, the win.
///
/// Set [active] to false on offline boards: there the back press is plain
/// navigation, and no one is left holding a dead table.
class OnlineLeavePop extends StatelessWidget {
  const OnlineLeavePop({
    super.key,
    required this.active,
    required this.onLeave,
    required this.child,
  });

  /// Online tables intercept the gesture; offline boards pop like screens.
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
