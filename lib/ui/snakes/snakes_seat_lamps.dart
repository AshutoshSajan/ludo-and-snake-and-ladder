import 'package:flutter/material.dart';

import '../../engine/snakes/snakes_engine.dart';
import '../../services/online_client.dart';
import '../shared/strike_dots.dart';
import '../theme.dart';

/// Every seated player's turn-miss ledger, above the Snakes board.
///
/// Playtest: the online Snakes table named the seat on turn in the HUD but
/// never showed how close anyone was to being dropped, while Ludo had carried
/// that story in its corner lamps all along. The rule is shared, so the
/// picture is too: one lamp per seat, the seat's board colour and number on
/// the left (the same number the pawns wear), then the five green/red strike
/// dots. The seat on turn gets the gold boundary — the HUD still owns the
/// name and the clock, so the lamps stay a compact ledger instead of a second
/// roster.
class SnakesSeatLamps extends StatelessWidget {
  const SnakesSeatLamps({
    super.key,
    required this.state,
    required this.client,
  });

  final SnakesState state;
  final OnlineClient client;

  @override
  Widget build(BuildContext context) {
    // No game (the lobby owns the seats) and no running turns after the end
    // card: the lamps are live-turn state, so they leave with the turns.
    if (!client.started || state.phase == SnakesPhase.gameOver) {
      return const SizedBox.shrink();
    }
    final onTurnId = state.players.isEmpty ? null : state.currentPlayer.id;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 2, 16, 4),
      child: Wrap(
        alignment: WrapAlignment.center,
        spacing: 8,
        runSpacing: 6,
        children: [
          for (final p in state.players)
            _lamp(
              p,
              misses: client.missesOf(p.id),
              onTurn: p.id == onTurnId,
            ),
        ],
      ),
    );
  }

  Widget _lamp(SnakesPlayer p, {required int misses, required bool onTurn}) {
    final color = AppColors.snakesColors[p.tokenIndex.clamp(
      0,
      AppColors.snakesColors.length - 1,
    )];
    final label = misses == 0
        ? '${p.name}: no missed turns'
        : '${p.name}: $misses of $ludoStrikeDots turns missed';
    return Tooltip(
      message: label,
      child: Container(
        key: ValueKey('snakes-seat-lamp-${p.id}'),
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
        decoration: BoxDecoration(
          color: Colors.black.withValues(alpha: 0.28),
          border: Border.all(
            color: onTurn ? AppColors.gold : color.withAlpha(110),
            width: onTurn ? 1.6 : 1,
          ),
          borderRadius: BorderRadius.circular(12),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 18,
              height: 18,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: color,
                border: Border.all(color: Colors.white38),
              ),
              child: Text(
                '${p.tokenIndex + 1}',
                style: const TextStyle(
                  fontSize: 10,
                  height: 1,
                  color: Colors.white,
                  fontWeight: FontWeight.w800,
                ),
              ),
            ),
            const SizedBox(width: 6),
            StrikeDotsRow(
              key: ValueKey('snakes-strike-dots-${p.id}'),
              misses: misses,
            ),
          ],
        ),
      ),
    );
  }
}
