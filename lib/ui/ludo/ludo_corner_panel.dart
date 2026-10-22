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
import '../shared/strike_dots.dart';
import '../shared/turn_countdown.dart';

// Kept on this library so the corner-panel tests (and any caller that already
// imports the lamp) keep finding the dots where the lamps put them.
export '../shared/strike_dots.dart' show StrikeDotsRow, ludoStrikeDots;

/// The height of one panel slab — the fixed strip a board edge hands its
/// corner panels, dice gap included.
///
/// 46 was flat starvation: the slab spent 14px on the dice gap and the
/// panel spent its chrome (padding + border) on top, leaving the
/// [TurnCountdown] a 4.8px glyph row — the count clipped to two slashes
/// and the watch icon painting past the plate rim (the playtest "timer is
/// not visible at all, watch icon is also off"). 58 prices the honest
/// ledger — plate 28 (16px glyph row + padding + border) + panel chrome
/// 15.2 + dice gap 14 — with the square board taking what remains. The
/// Ludo view's board sizing subtracts this twice, so the constant and the
/// view stay in register through it.
const ludoPanelSlab = 58.0;

/// One player-corner panel: color spot, strike dots, and — on the seat
/// whose turn it is — the turn clock, so "whose turn and how long" is
/// answered on that seat's own corner. The name is deliberately absent:
/// the yard pill painted inside the corner square on the board already
/// says who it is, and a second name plate in the lamp above it made
/// every corner read as a roster row instead of a status lamp. The phase
/// words ("Your roll, …") deliberately do NOT live here either — the
/// playtest round that placed the lamp also asked the words gone ("i
/// don't need your turn username message"): dots and a clock are the
/// whole story.
class LudoCornerPanel extends StatelessWidget {
  const LudoCornerPanel({
    super.key,
    required this.color,
    required this.misses,
    required this.onTurn,
    this.clock,
  });

  /// The corner's board color; also the panel's leading identity spot.
  final LudoColor color;

  /// Consecutive missed turns (0..[ludoStrikeDots]).
  final int misses;

  /// True for the seat that currently owns the turn: the panel answers
  /// with the clock and a gold boundary instead of a plain seat border.
  final bool onTurn;

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
  required List<({LudoColor color, int misses, bool onTurn, Widget? clock})>
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
