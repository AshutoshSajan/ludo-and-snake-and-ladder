/// The player-corner identity strip, standing OUTSIDE the board.
///
/// Each corner square of the board is already occupied by that corner's
/// floating dice — the widget-layer roll control sits over the yard's
/// outer edge, so anything the painter draws in that same band hides under
/// the dice on exactly the seat whose state you need to read (the playtest
/// round lost the winner's strike dots that way, and the yard name with
/// it on a phone).
///
/// The panels therefore live outside the board: top-row yards (green,
/// yellow) get theirs above the board, bottom-row yards (red, blue) below
/// it, each aligned to its own corner column and pinned to the board's
/// own square width. One panel carries the corner's color spot, its
/// turn-missed strike dots (red as they accrue), and — on the seat whose
/// turn it is — the turn clock. The name is painted on the board's yard
/// pill itself; the lamp repeats state, not identity.
library;

import 'package:flutter/material.dart';

import '../../engine/ludo/ludo_models.dart';
import '../theme.dart';
import '../shared/turn_countdown.dart';

/// Five strikes live both in the turn tracker (`maxTurnMisses`, with its
/// own copy on the server) and here, drawn as dots. The count is
/// duplicated on purpose: a widget cannot reach the service layer that
/// owns the rule, so the number is pinned by the strike test — change the
/// rule and the test breaks instead of the panel drifting.
const ludoStrikeDots = 5;

/// One corner's strike dot row: five dots, missed ones red, the rest
/// green — the at-a-glance answer to "why is this corner about to be
/// removed" that every seat can read from their side of the table.
class StrikeDotsRow extends StatelessWidget {
  const StrikeDotsRow({super.key, required this.misses});

  /// Consecutive missed turns for this seat (0..[ludoStrikeDots]).
  final int misses;

  @override
  Widget build(BuildContext context) {
    final shown = misses.clamp(0, ludoStrikeDots);
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        for (var i = 0; i < ludoStrikeDots; i++)
          Container(
            width: 9,
            height: 9,
            margin: const EdgeInsets.only(left: 3),
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              // A dot that has not been spent reads as the green that is
              // left; the spent ones turn red in seat order, so "2 of 5
              // missed" reads as two red dots.
              color: i < shown ? AppColors.danger : Colors.green.shade600,
            ),
          ),
      ],
    );
  }
}

/// One player-corner panel: color spot, strike dots, and — on the
/// seat whose turn it is — the turn clock and the phase prompt, so
/// "whose turn, what next, how long" is answered on that seat's own
/// corner. The name is deliberately absent: the yard pill painted
/// inside the corner square on the board already says who it is, and a
/// second name plate in the lamp above it made every corner read as a
/// roster row instead of a status lamp.
class LudoCornerPanel extends StatelessWidget {
  const LudoCornerPanel({
    super.key,
    required this.color,
    required this.misses,
    required this.onTurn,
    this.prompt,
    this.clock,
  });

  /// The corner's board color; also the panel's leading identity spot.
  final LudoColor color;

  /// Consecutive missed turns (0..[ludoStrikeDots]).
  final int misses;

  /// True for the seat that currently owns the turn: the panel answers
  /// with the clock and a gold boundary instead of a plain seat border.
  final bool onTurn;

  /// The phase prompt for the seat on turn ("Your roll, {name}!",
  /// "Pick a token to move", "… is thinking…") — standing beside the
  /// strike dots so the table reads the phase where it reads the turn,
  /// instead of a status line losing itself at a wide window's edge.
  final String? prompt;

  /// The live turn-clock plate ([TurnCountdown]); null when this screen
  /// has no online client (offline tables have no armed clock).
  final Widget? clock;

  @override
  Widget build(BuildContext context) {
    final border = onTurn
        ? AppColors.gold
        : AppColors.ludo(color).withAlpha(110);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.28),
        border: Border.all(
          color: border,
          width: onTurn ? 1.6 : 1,
        ),
        borderRadius: BorderRadius.circular(14),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 12,
            height: 12,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: AppColors.ludo(color),
              border: Border.all(width: 1, color: Colors.white24),
            ),
          ),
          const SizedBox(width: 9),
          StrikeDotsRow(
            key: Key('strike-dots-${color.name}'),
            misses: misses,
          ),
          // The phase prompt lives beside the dots, only ever on the
          // on-turn seat's lamp: the row the eye already checks for whose
          // turn it is gets the "what am I waiting for" in the same hair.
          if (prompt != null) ...[
            const SizedBox(width: 8),
            Text(
              prompt!,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                fontSize: 11.5,
                fontWeight: FontWeight.w700,
                color: AppColors.gold,
              ),
            ),
          ],
          ?clock,
        ],
      ),
    );
  }
}

/// One row of corner panels for one board edge (top-edge yards or
/// bottom-edge yards), each Expanded slot aligned to the corner's own
/// column — a one-panel row still hugs the correct side, and a two-panel
/// row splits the edge left/right exactly like the yards do.
List<Widget> cornerPanels({
  required bool top,
  required List<
    ({LudoColor color, int misses, bool onTurn, String? prompt, Widget? clock})
  >
  seats,
}) {
  final edge = seats.where((s) => yardIsOnTop(s.color) == top).toList()
    ..sort((a, b) => yardColumn(a.color).compareTo(yardColumn(b.color)));
  if (edge.isEmpty) return const [];
  return [
    for (final s in edge)
      Expanded(
        child: Align(
          alignment:
              yardColumn(s.color) == 0
              ? Alignment.centerLeft
              : Alignment.centerRight,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 4),
            child: LudoCornerPanel(
              key: Key('corner-panel-${s.color.name}'),
              color: s.color,
              misses: s.misses,
              onTurn: s.onTurn,
              prompt: s.prompt,
              clock: s.clock,
            ),
          ),
        ),
      ),
  ];
}

bool yardIsOnTop(LudoColor c) => c == LudoColor.green || c == LudoColor.yellow;

/// 0: the corner's yard sits in the left column of its row; 1: right.
int yardColumn(LudoColor c) => switch (c) {
  LudoColor.green || LudoColor.red => 0,
  LudoColor.yellow || LudoColor.blue => 1,
};
