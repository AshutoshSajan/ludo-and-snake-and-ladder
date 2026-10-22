/// The five-dot turn-miss ledger shared by both online boards.
///
/// The rule is the same on Ludo and Snakes (a seat that misses five turns in
/// a row is dropped), so the picture is too: green dots are turns the seat
/// still has, red dots are the ones it has spent. Ludo hosts the row on each
/// player's corner lamp; Snakes puts one row per seat above the board.
library;

import 'package:flutter/material.dart';

import '../theme.dart';

/// Five strikes live both in the turn tracker (`maxTurnMisses`, with its own
/// copy on the server) and here, drawn as dots. The count is duplicated on
/// purpose: a widget cannot reach the service layer that owns the rule, so
/// the number is pinned by the strike test — change the rule and the test
/// breaks instead of the panel drifting.
const ludoStrikeDots = 5;

/// One seat's strike dot row: five dots, missed ones red, the rest green —
/// the at-a-glance answer to "why is this seat about to be removed" that
/// every player can read from their side of the table.
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
