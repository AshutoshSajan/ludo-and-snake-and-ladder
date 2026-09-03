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
    this.spinAngle = 0,
    this.bounce = 0,
  });

  final LudoState state;
  final double boardSize;
  final Set<int> movableTokenIndices;
  final void Function(int tokenIndex) onTapToken;
  final MoveAnim? anim;
  final int animStep;
  final int currentPlayerIndex;

  /// Rotation (radians) of the spinning ring under the current player's pawns.
  final double spinAngle;

  /// 0..1 progress within the current animation step; drives the hop bounce.
  final double bounce;

  @override
  Widget build(BuildContext context) {
    final cell = boardSize / 15;
    final widgets = <Widget>[];

    // Group tokens by board cell (skipping the animating one). Yard tokens
    // use their own token index as the yard slot so the 4 pawns spread out
    // in a 2x2 grid instead of piling into one spot.
    final grouped = <GridPos, List<LudoToken>>{};
    for (final t in state.tokens) {
      if (anim != null && t.gid == anim!.tokenGid) continue;
      final key = LudoBoard.coordFor(t.color, t.pos, t.index % 4, 1);
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
            left: center.dx - cell * 0.34 + off.dx,
            top: center.dy - cell * 0.34 + off.dy,
            child: GestureDetector(
              onTap: canMove ? () => onTapToken(t.index) : null,
              child: _tokenStack(t, cell, canMove,
                  isActivePlayer: playerIdx == currentPlayerIndex &&
                      state.phase != LudoPhase.gameOver),
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
      final t = state.tokenByGid(anim!.tokenGid);
      final color = AppColors.ludo(t.color);
      // One-size-pulse per step: grows then shrinks across each hop.
      final scale = 1 + 0.30 * math.sin(math.pi * bounce.clamp(0.0, 1.0));
      widgets.add(Positioned(
        left: center.dx - cell * 0.62,
        top: center.dy - cell * 0.62,
        child: Transform.scale(
          scale: scale,
          child: SizedBox(
            width: cell * 1.24,
            height: cell * 1.24,
            child: Stack(
              alignment: Alignment.center,
              clipBehavior: Clip.none,
              children: [
                _SpinRing(
                    size: cell * 1.08,
                    angle: spinAngle,
                    color: AppColors.gold),
                Container(
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
              ],
            ),
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

  /// Pawn with an optional spinning indicator ring sitting at its base.
  Widget _tokenStack(LudoToken t, double cell, bool canMove,
      {required bool isActivePlayer}) {
    const dotSize = 0.68;
    final dot = SizedBox(
      width: cell * dotSize,
      height: cell * dotSize,
      child: _tokenDot(t, cell, canMove),
    );
    if (!isActivePlayer) return dot;
    const ringGrow = 0.30;
    final ringSize = cell * dotSize * (1 + ringGrow);
    return SizedBox(
      width: cell * dotSize,
      height: cell * dotSize,
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          Positioned(
            left: (cell * dotSize - ringSize) / 2,
            top: (cell * dotSize - ringSize) / 2 + cell * 0.12,
            child: _SpinRing(
              size: ringSize,
              angle: spinAngle,
              color: AppColors.gold,
            ),
          ),
          dot,
        ],
      ),
    );
  }

  Widget _tokenDot(LudoToken t, double cell, bool canMove) {
    final color = AppColors.ludo(t.color);
    return Container(
      width: cell * 0.68,
      height: cell * 0.68,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.35),
            blurRadius: 3,
            offset: const Offset(0, 2),
          ),
          if (canMove)
            BoxShadow(
                color: AppColors.gold.withValues(alpha: 0.7), blurRadius: 8),
        ],
      ),
      child: CustomPaint(
        size: Size.square(cell * 0.68),
        painter: _PawnPainter(
          color: color,
          outline: canMove ? AppColors.gold : Colors.black54,
          strokeWidth: canMove ? 2.2 : 1.2,
        ),
      ),
    );
  }
}

/// Classic Ludo pawn silhouette: round head, curved neck, oval base.
class _PawnPainter extends CustomPainter {
  _PawnPainter({
    required this.color,
    required this.outline,
    required this.strokeWidth,
  });
  final Color color;
  final Color outline;
  final double strokeWidth;

  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width, h = size.height;
    final fill = Paint()..color = color;
    final line = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = strokeWidth
      ..color = outline;

    // Base oval.
    final baseRect = Rect.fromCenter(
      center: Offset(w / 2, h * 0.80),
      width: w * 0.74,
      height: h * 0.30,
    );
    // Neck/body connecting head to base.
    final body = Path()
      ..moveTo(w * 0.29, h * 0.78)
      ..quadraticBezierTo(w * 0.40, h * 0.60, w * 0.42, h * 0.42)
      ..lineTo(w * 0.58, h * 0.42)
      ..quadraticBezierTo(w * 0.60, h * 0.60, w * 0.71, h * 0.78)
      ..close();
    // Head.
    final headC = Offset(w / 2, h * 0.28);
    final headR = w * 0.19;

    canvas.drawOval(baseRect, fill);
    canvas.drawPath(body, fill);
    canvas.drawCircle(headC, headR, fill);
    canvas.drawOval(baseRect, line);
    canvas.drawPath(body, line);
    canvas.drawCircle(headC, headR, line);
    // Glossy highlight on the head.
    canvas.drawCircle(
      Offset(w * 0.44, h * 0.24),
      w * 0.055,
      Paint()..color = Colors.white.withValues(alpha: 0.75),
    );
  }

  @override
  bool shouldRepaint(_PawnPainter old) =>
      old.color != color || old.outline != outline;
}

/// A dashed ring of three arcs that visually spins via [angle].
class _SpinRing extends StatelessWidget {
  const _SpinRing({required this.size, required this.angle, required this.color});

  final double size;
  final double angle;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Transform.rotate(
      angle: angle,
      child: CustomPaint(
        size: Size.square(size),
        painter: _RingPainter(color: color),
      ),
    );
  }
}

class _RingPainter extends CustomPainter {
  _RingPainter({required this.color});
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = size.width * 0.09
      ..strokeCap = StrokeCap.round
      ..color = color;
    final rect = Offset.zero & size;
    for (var k = 0; k < 3; k++) {
      canvas.drawArc(rect.deflate(paint.strokeWidth / 2),
          k * 2 * math.pi / 3, math.pi / 2.6, false, paint);
    }
  }

  @override
  bool shouldRepaint(_RingPainter old) => old.color != color;
}
