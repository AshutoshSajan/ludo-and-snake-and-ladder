import 'package:flutter/material.dart';

import '../../engine/snakes/snakes_engine.dart';
import '../../services/online_client.dart';
import '../shared/turn_countdown.dart';
import '../theme.dart';

/// The online Snakes table's turn strip, above the board.
///
/// Playtest: the online table's only turn feedback was a white70 status line
/// and a small countdown plate below the board, under the dice — the two
/// things a player looks for ("whose turn, how long have I got") were the
/// furthest widgets from the board and the least visible. This strip sits
/// between the seat status and the stage: a coloured spot for the player on
/// turn, "Your turn" / `Waiting for <name>`, the existing phase status, and
/// the live [TurnCountdown] plate when the server armed a deadline.
class SnakesTurnHud extends StatelessWidget {
  const SnakesTurnHud({
    super.key,
    required this.client,
    required this.state,
    required this.status,
    this.onCountdownWarn,
  });

  final OnlineClient client;
  final SnakesState state;

  /// The phase line the view already derives ("Your roll!", "Moving…", …).
  final String status;

  /// Sounds the ten-second warning; wired only when this seat owns the turn.
  final VoidCallback? onCountdownWarn;

  @override
  Widget build(BuildContext context) {
    final player = state.currentPlayer;
    final color =
        AppColors.snakesColors[player.tokenIndex.clamp(
          0,
          AppColors.snakesColors.length - 1,
        )];
    // Same turn test the view uses: before the table has started, nothing is
    // "yours" yet, and a spectator never owns a turn.
    final mine =
        !client.isSpectator && client.started && player.id == client.seatId;
    final headline = state.phase == SnakesPhase.gameOver
        ? 'Game over'
        : mine
        ? 'Your turn'
        : 'Waiting for ${player.name}';

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 6, 16, 6),
      child: Container(
        key: const ValueKey('snakes-turn-hud'),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        decoration: BoxDecoration(
          color: AppColors.feltLight,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(
            color: AppColors.gold.withValues(alpha: 0.6),
            width: 1.2,
          ),
        ),
        child: Row(
          children: [
            Container(
              key: const ValueKey('snakes-turn-dot'),
              width: 16,
              height: 16,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: color,
                border: Border.all(color: Colors.white38),
              ),
            ),
            const SizedBox(width: 10),
            // The flexible middle: long names truncate instead of pushing the
            // clock off a 390px phone.
            Expanded(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    headline,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w800,
                      color: AppColors.ivory,
                    ),
                  ),
                  Text(
                    status,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontSize: 12, color: Colors.white70),
                  ),
                ],
              ),
            ),
            if (client.turnMs != null) ...[
              const SizedBox(width: 6),
              TurnCountdown(client: client, onTenSeconds: onCountdownWarn),
            ],
          ],
        ),
      ),
    );
  }
}
