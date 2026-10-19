import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../controllers/ludo_session.dart';
import '../../engine/ludo/ludo_board.dart';
import '../../engine/ludo/ludo_models.dart';
import '../theme.dart';
import 'ludo_board_painter.dart';

/// Renders all Ludo tokens as an animated layer over the board, plus the
/// in-flight "ghost" token while a move animation is running.
///
/// Performance shape: this layer is rebuilt on *state* changes (a roll, a hop
/// step), never per frame. The per-frame work — the spinning rings under the
/// movable pawns and the ghost's hop bounce — lives inside tiny scoped
/// [AnimatedBuilder]s driven by the view's effects clock ([fx]), so the whole
/// board layout is not recomputed 60 times a second just to rotate a ring.
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
    this.fx,
    this.stepStart,
    this.hintTokenIndex,
  });

  final LudoState state;
  final double boardSize;
  final Set<int> movableTokenIndices;
  final void Function(int tokenIndex) onTapToken;
  final MoveAnim? anim;
  final int animStep;
  final int currentPlayerIndex;

  /// The view's effects clock (a 1.5s repeating 0..1 controller). Powers the
  /// ring spin and the ghost hop bounce at paint time; null keeps everything
  /// static (tests).
  final Animation<double>? fx;

  /// When the current hop step started — with [fx] it derives the bounce
  /// curve inside the ghost, which is the only piece that needs the value.
  final DateTime? stepStart;

  /// Token index highlighted by the hint button (the AI's suggested move).
  final int? hintTokenIndex;

  /// Minimum pawn tappable area: the pawn artwork is well under the 44px
  /// touch-target bar on a phone (a cell is ~26px, the pawn ~16x23), and the
  /// "I poked the pawn three times before it moved" report is exactly that.
  /// The tappable box is the pawn's own generous square instead, centered on
  /// the pawn so finger aim and visual aim agree.
  static double hitTargetFor(double cell) =>
      math.max(48.0, cell * 1.4);

  @override
  Widget build(BuildContext context) {
    final cell = boardSize / 15;
    // Two layers: everything that cannot be tapped first, tappable pawns
    // last. Stack hit-testing answers the topmost child, so a movable pawn
    // sharing a cell with idle pieces — or standing next to one with
    // overlapping 48px targets — can never be covered by a piece that
    // answers nothing. This plus the generous target is what one tap buys.
    final idleWidgets = <Widget>[];
    final movableWidgets = <Widget>[];

    // Group tokens by board cell (skipping the animating one). Yard tokens
    // use their own token index as the yard slot so the 4 pawns spread out
    // in a 2x2 grid instead of piling into one spot.
    final grouped = <GridPos, List<LudoToken>>{};
    for (final t in state.tokens) {
      if (anim != null && t.gid == anim!.tokenGid) continue;
      // Finished tokens (pos == 56) rest in their own yard slot so each
      // color's completed pieces stay in their own corner, never overlapping.
      final key = t.pos == 56
          ? LudoBoard.finishedCell(t.color)
          : LudoBoard.coordFor(t.color, t.pos, t.index % 4, 1);
      grouped.putIfAbsent(key, () => []).add(t);
    }

    grouped.forEach((cellPos, tokens) {
      for (var i = 0; i < tokens.length; i++) {
        final t = tokens[i];
        final off = _stackOffset(i, tokens.length, cell);
        var center = LudoBoardPainter.cellCenter(
            cellPos.row, cellPos.col, Size.square(boardSize));
        // Yard staging slots sit on cell centers (x.5); the white staging
        // square is centered on the yard's grid intersection, so nudge yard
        // tokens half a cell up-left to align the 2x2 grid evenly inside it.
        // Finished tokens rest on real center-finish cells — no nudge.
        if (t.pos == -1) {
          center -= Offset(cell * 0.5, cell * 0.5);
        }
        final playerIdx =
            state.players.indexWhere((p) => p.color == t.color);
        final canMove = state.phase == LudoPhase.awaitingMove &&
            playerIdx == currentPlayerIndex &&
            !state.currentPlayer.isAI &&
            t.color == state.currentPlayer.color &&
            movableTokenIndices.contains(t.index);
        final positioned = AnimatedPositioned(
          key: ValueKey('tok-${t.gid}'),
          duration: const Duration(milliseconds: 160),
          curve: Curves.easeOut,
          left: center.dx - cell * 0.30 + off.dx,
          top: center.dy - cell * 0.44 + off.dy,
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: canMove ? () => onTapToken(t.index) : null,
            child: SizedBox(
              width: hitTargetFor(cell),
              height: hitTargetFor(cell),
              child: Stack(clipBehavior: Clip.none, alignment: Alignment.center,
                  children: [
                    _tokenStack(t, cell, canMove,
                        isHint: t.index == hintTokenIndex),
                  ]),
            ),
          ),
        );
        if (canMove) {
          movableWidgets.add(positioned);
        } else {
          idleWidgets.add(positioned);
        }
      }
    });

    if (anim != null) {
      final step = animStep.clamp(0, anim!.waypoints.length - 1);
      final pos = anim!.waypoints[step];
      // Spawn hop starts in the yard (half-cell nudge); a finishing move's
      // last waypoint is the color's own center-finish triangle cell (plain
      // cell center, no nudge) — either way the ghost rests exactly where
      // the settled token will be, so the handoff has no visible slide.
      final yardAnchor = step == 0 && anim!.startInYard;
      var center = LudoBoardPainter.cellCenter(
          pos.row, pos.col, Size.square(boardSize));
      if (yardAnchor) center -= Offset(cell * 0.5, cell * 0.5);
      final t = state.tokenByGid(anim!.tokenGid);
      final color = AppColors.ludo(t.color);
      idleWidgets.add(Positioned(
        left: center.dx - cell * 0.62,
        top: center.dy - cell * 0.62,
        child: _GhostToken(
          fx: fx,
          stepStart: stepStart ?? DateTime.now(),
          stepMs: anim!.stepMs,
          cell: cell,
          color: color,
        ),
      ));
    }

    return Stack(
      clipBehavior: Clip.none,
      children: [...idleWidgets, ...movableWidgets],
    );
  }

  Offset _stackOffset(int i, int total, double cell) {
    if (total == 1) return Offset.zero;
    const maxShift = 0.16;
    final ang = 2 * math.pi * i / total;
    return Offset(math.cos(ang) * cell * maxShift,
        math.sin(ang) * cell * maxShift);
  }

  /// Pawn with a spinning indicator ring at its base — shown only when the
  /// token is actually movable (tappable), never for idle pieces. A hinted
  /// token additionally wears a soft gold halo marking the suggested move.
  Widget _tokenStack(LudoToken t, double cell, bool canMove,
      {bool isHint = false}) {
    const pw = 0.60, ph = 0.88; // pawn width/height as a fraction of a cell
    final dot = SizedBox(
      width: cell * pw,
      height: cell * ph,
      child: _tokenDot(t, cell, canMove),
    );
    if (!canMove && !isHint) return dot;
    final halo = cell * pw * 2.1;
    final ringSize = cell * pw * 1.55;
    return SizedBox(
      width: cell * pw,
      height: cell * ph,
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          if (isHint)
            Positioned(
              left: (cell * pw - halo) / 2,
              top: (cell * ph - halo) / 2,
              child: Container(
                width: halo,
                height: halo,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: AppColors.gold.withValues(alpha: 0.20),
                  border: Border.all(color: AppColors.gold, width: 2),
                ),
              ),
            ),
          if (canMove)
            Positioned(
              left: (cell * pw - ringSize) / 2,
              top: cell * ph - ringSize * 0.62,
              child: _SpinRing(
                size: ringSize,
                fx: fx,
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
    return CustomPaint(
      size: Size(cell * 0.60, cell * 0.88),
      painter: _PawnPainter(
        color: color,
        outline: canMove ? AppColors.gold : Colors.black54,
        strokeWidth: canMove ? 2.2 : 1.2,
      ),
    );
  }
}

/// The animated ghost the moving token rides: a gold ring + the pawn art,
/// pulsing once per hop. Its per-frame values (spin ring, hop scale) live
/// inside one scoped [AnimatedBuilder] so the ghost alone rebuilds while it
/// flies — the layer around it holds still off a rebuild budget of steps.
class _GhostToken extends StatelessWidget {
  const _GhostToken({
    required this.fx,
    required this.stepStart,
    required this.stepMs,
    required this.cell,
    required this.color,
  });

  final Animation<double>? fx;
  final DateTime stepStart;
  final int stepMs;
  final double cell;
  final Color color;

  @override
  Widget build(BuildContext context) {
    final body = SizedBox(
      width: cell * 1.24,
      height: cell * 1.24,
      child: Stack(
        alignment: Alignment.center,
        clipBehavior: Clip.none,
        children: [
          _SpinRing(size: cell * 1.08, fx: fx, color: AppColors.gold),
          SizedBox(
            width: cell * 0.62,
            height: cell * 0.90,
            child: CustomPaint(
              painter: _PawnPainter(
                color: color,
                outline: Colors.white,
                strokeWidth: 2,
              ),
            ),
          ),
        ],
      ),
    );
    // The ghost's one-size-pulse per hop is re-derived per clock frame
    // inside this scoped builder. Without a clock (tests, battery saver)
    // it rides at rest scale — the cell-to-cell steps still repaint it.
    final clock = fx;
    if (clock == null) return Transform.scale(scale: 1.0, child: body);
    return AnimatedBuilder(
      animation: clock,
      builder: (_, _) {
        // 0..1 progress within the current animation step.
        final withinStep =
            (DateTime.now().difference(stepStart).inMilliseconds / stepMs)
                .clamp(0.0, 1.0);
        return Transform.scale(
          scale: 1 + 0.30 * math.sin(math.pi * withinStep),
          child: body,
        );
      },
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

    // Ground shadow.
    canvas.drawOval(
      Rect.fromCenter(
        center: Offset(w / 2, h * 0.84),
        width: w * 0.82,
        height: h * 0.18,
      ),
      Paint()..color = Colors.black.withValues(alpha: 0.30),
    );

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

/// A dashed ring of three arcs that visually spins once per clock period.
/// The rotation is its own concern: with [fx] attached it keeps turning in
/// its own tiny rebuild; without one it renders static (tests, animations-off).
class _SpinRing extends StatelessWidget {
  const _SpinRing({
    required this.size,
    this.fx,
    required this.color,
  });

  final double size;
  final Animation<double>? fx;
  final Color color;

  @override
  Widget build(BuildContext context) {
    final clock = fx;
    if (clock == null) {
      return Transform.rotate(
        angle: 0,
        child: CustomPaint(
          size: Size.square(size),
          painter: _RingPainter(color: color),
        ),
      );
    }
    return AnimatedBuilder(
      animation: clock,
      builder: (_, _) => Transform.rotate(
        angle: clock.value * 2 * math.pi,
        child: CustomPaint(
          size: Size.square(size),
          painter: _RingPainter(color: color),
        ),
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
