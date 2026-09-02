import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../controllers/ludo_session.dart';
import '../../engine/ludo/ludo_board.dart';
import '../../engine/ludo/ludo_models.dart';
import '../theme.dart';
import 'ludo_board_painter.dart';

/// Renders all Ludo tokens as an animated layer over the board, plus the
/// in-flight "ghost" token while a move animation is running.
class LudoTokenLayer extends StatelessWidget {
  const LudoTokenLayer({
    super.key,
    required this.state,
    required this.boardSize,
    required this.movableTokenIndices,
    required this.onTapToken,
    required this.anim,
    required this.animStep,
    required this.currentPlayerIndex,
  });

  final LudoState state;
  final double boardSize;
  final Set<int> movableTokenIndices;
  final void Function(int tokenIndex) onTapToken;
  final MoveAnim? anim;
  final int animStep;
  final int currentPlayerIndex;

  @override
  Widget build(BuildContext context) {
    final cell = boardSize / 15;
    final widgets = <Widget>[];

    // Group tokens by board cell (skipping the animating one).
    final grouped = <GridPos, List<LudoToken>>{};
    for (final t in state.tokens) {
      if (anim != null && t.gid == anim!.tokenGid) continue;
      final key = LudoBoard.coordFor(t.color, t.pos, 0, 1);
      grouped.putIfAbsent(key, () => []).add(t);
    }

    grouped.forEach((cellPos, tokens) {
      for (var i = 0; i < tokens.length; i++) {
        final t = tokens[i];
        final off = _stackOffset(i, tokens.length, cell);
        final center = LudoBoardPainter.cellCenter(
            cellPos.row, cellPos.col, Size.square(boardSize));
        final playerIdx =
            state.players.indexWhere((p) => p.color == t.color);
        final canMove = state.phase == LudoPhase.awaitingMove &&
            playerIdx == currentPlayerIndex &&
            !state.currentPlayer.isAI &&
            t.color == state.currentPlayer.color &&
            movableTokenIndices.contains(t.index);
        widgets.add(
          AnimatedPositioned(
            key: ValueKey('tok-${t.gid}'),
            duration: const Duration(milliseconds: 160),
            curve: Curves.easeOut,
            left: center.dx - cell * 0.31 + off.dx,
            top: center.dy - cell * 0.31 + off.dy,
            child: GestureDetector(
              onTap: canMove ? () => onTapToken(t.index) : null,
              child: _tokenDot(t, cell, canMove),
            ),
          ),
        );
      }
    });

    if (anim != null) {
      final step = animStep.clamp(0, anim!.waypoints.length - 1);
      final pos = anim!.waypoints[step];
      final center = LudoBoardPainter.cellCenter(
          pos.row, pos.col, Size.square(boardSize));
      final color =
          AppColors.ludo(state.tokenByGid(anim!.tokenGid).color);
      widgets.add(Positioned(
        left: center.dx - cell * 0.34,
        top: center.dy - cell * 0.34,
        child: Container(
          width: cell * 0.68,
          height: cell * 0.68,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: color,
            border: Border.all(color: Colors.white, width: 2),
            boxShadow: [
              BoxShadow(
                color: color.withValues(alpha: 0.6),
                blurRadius: 10,
                spreadRadius: 2,
              ),
            ],
          ),
        ),
      ));
    }

    return Stack(clipBehavior: Clip.none, children: widgets);
  }

  Offset _stackOffset(int i, int total, double cell) {
    if (total == 1) return Offset.zero;
    const maxShift = 0.16;
    final ang = 2 * math.pi * i / total;
    return Offset(math.cos(ang) * cell * maxShift,
        math.sin(ang) * cell * maxShift);
  }

  Widget _tokenDot(LudoToken t, double cell, bool canMove) {
    final color = AppColors.ludo(t.color);
    return Container(
      width: cell * 0.62,
      height: cell * 0.62,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        gradient: RadialGradient(
          colors: [color.withValues(alpha: 0.95), color],
          stops: const [0.4, 1],
        ),
        border: Border.all(
          color: canMove ? AppColors.gold : Colors.black38,
          width: canMove ? 2.5 : 1.2,
        ),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.35),
            blurRadius: 3,
            offset: const Offset(0, 2),
          ),
          if (canMove)
            BoxShadow(color: AppColors.gold.withValues(alpha: 0.7), blurRadius: 8),
        ],
      ),
      child: Icon(Icons.circle,
          size: cell * 0.18, color: Colors.white.withValues(alpha: 0.65)),
    );
  }
}
