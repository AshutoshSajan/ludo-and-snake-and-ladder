import 'dart:math' as math;

import 'package:flutter/foundation.dart' show mapEquals;
import 'package:flutter/material.dart';

import '../../engine/ludo/ludo_board.dart';
import '../../engine/ludo/ludo_models.dart';
import '../theme.dart';

/// Paints the classic 15x15 Ludo board: ivory playing field, lacquered
/// quadrant yards, colored home columns and a four-triangle center.
class LudoBoardPainter extends CustomPainter {
  LudoBoardPainter({
    this.highlightCells = const {},
    this.playerNames = const {},
    this.activeColor,
    this.pulse = 0,
    super.repaint,
  });
  final Set<int> highlightCells; // absolute track indices
  final Map<LudoColor, String> playerNames; // color -> seat name
  final LudoColor? activeColor; // corner that breathes on their turn
  final double pulse; // 0..1 phase of the breathing glow

  static const n = 15.0;

  static Rect cellRect(int row, int col, Size size) {
    final c = size.width / n;
    return Rect.fromLTWH(col * c, row * c, c, c);
  }

  static Offset cellCenter(int row, int col, Size size) {
    final c = size.width / n;
    return Offset((col + 0.5) * c, (row + 0.5) * c);
  }

  @override
  void paint(Canvas canvas, Size size) {
    final cell = size.width / n;

    // Ivory table.
    final bg = Paint()..color = AppColors.ivory;
    canvas.drawRRect(
      RRect.fromRectAndRadius(Offset.zero & size, Radius.circular(cell * 0.4)),
      bg,
    );

    // Yards: lacquered quadrant + white square staging area, with the
    // player name on the outer edge of the board arm (Ludo-King style).
    for (final color in LudoColor.values) {
      final o = LudoBoard.yardOrigin[color]!;
      final yard = Rect.fromLTWH(o.col * cell, o.row * cell, cell * 6, cell * 6);
      final yardRRect =
          RRect.fromRectAndRadius(yard, Radius.circular(cell * 0.35));
      final base = AppColors.ludo(color);
      final isActive = color == activeColor;
      final isDimmed = activeColor != null && !isActive;
      canvas.drawRRect(yardRRect, Paint()..color = base);

      // Inner white square: staging area for the 4 pawns.
      final inner = Rect.fromLTWH(
          o.col * cell + cell, o.row * cell + cell, cell * 4, cell * 4);
      final innerRRect =
          RRect.fromRectAndRadius(inner, Radius.circular(cell * 0.3));
      canvas.drawRRect(innerRRect, Paint()..color = AppColors.ivory);
      canvas.drawRRect(
        innerRRect,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = cell * 0.07
          ..color = base.withValues(alpha: 0.35),
      );

      // Turn lighting: active corner glows bright, others are dimmed.
      if (isDimmed) {
        canvas.drawRRect(
          yardRRect,
          Paint()..color = Colors.black.withValues(alpha: 0.22),
        );
      } else if (isActive) {
        canvas.drawRRect(
          yardRRect,
          Paint()..color = Colors.white.withValues(alpha: 0.04 + 0.08 * pulse),
        );
        canvas.drawRRect(
          innerRRect,
          Paint()
            ..style = PaintingStyle.stroke
            ..strokeWidth = cell * 0.14
            ..color = Colors.white.withValues(alpha: 0.35 + 0.55 * pulse),
        );
      }

      // Name pill on the outer edge of this color's own arm.
      final name = playerNames[color];
      if (name != null) {
        _drawNamePill(canvas, o, cell, name, base, color);
      }
    }

    // Track cells.
    final line = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.2
      ..color = AppColors.ink.withValues(alpha: 0.35);
    for (var i = 0; i < LudoBoard.track.length; i++) {
      final p = LudoBoard.track[i];
      final r = cellRect(p.row, p.col, size).deflate(0.6);
      Color? fill;
      for (final c in LudoColor.values) {
        if (LudoBoard.startIndex[c] == i) fill = AppColors.ludo(c);
      }
      if (fill != null) {
        canvas.drawRect(r, Paint()..color = fill);
      } else {
        canvas.drawRect(r, Paint()..color = AppColors.ivoryDark);
      }
      canvas.drawRect(r, line);
      if (highlightCells.contains(i)) {
        canvas.drawRect(
          r.deflate(1.5),
          Paint()
            ..color = AppColors.gold.withValues(alpha: 0.65)
            ..style = PaintingStyle.stroke
            ..strokeWidth = 3,
        );
      }
      // Star safe cells (non-start): exactly 8 steps past each start cell,
      // derived from the engine so they can never drift out of sync.
      if (LudoBoard.safeCells.contains(i) &&
          !LudoBoard.startIndex.containsValue(i)) {
        _drawStar(canvas, cellCenter(p.row, p.col, size), cell * 0.3,
            AppColors.ink.withValues(alpha: 0.7));
      }
    }

    // Home columns.
    for (final color in LudoColor.values) {
      final cells = LudoBoard.homeColumns[color]!;
      for (final p in cells) {
        final r = cellRect(p.row, p.col, size).deflate(0.6);
        canvas.drawRect(r, Paint()..color = AppColors.ludo(color));
        canvas.drawRect(r, line);
      }
    }

    // Entrance arrows: on the last main-track cell before each home column,
    // pointing into the column, colored to match it.
    for (final color in LudoColor.values) {
      final from = LudoBoard.track[LudoBoard.absCell(color, 50)];
      final to = LudoBoard.homeColumns[color]!.first;
      final dir = Offset(
          (to.col - from.col).toDouble(), (to.row - from.row).toDouble());
      _drawArrow(
        canvas,
        cellCenter(from.row, from.col, size),
        dir,
        cell * 0.36,
        AppColors.ludo(color),
      );
    }

    // Center: four triangles pointing in, spanning the 3x3 center block.
    // Each triangle matches the color of the home column that feeds into it:
    // green left arm, yellow top arm, blue right arm, red bottom arm.
    final c0 = Rect.fromLTWH(6 * cell, 6 * cell, cell * 3, cell * 3);
    final center = c0.center;
    final tl = c0.topLeft, tr = c0.topRight, bl = c0.bottomLeft, br = c0.bottomRight;
    void tri(Path path, LudoColor color) {
      canvas.drawPath(path, Paint()..color = AppColors.ludo(color));
      canvas.drawPath(path, line);
    }

    tri(Path()
      ..moveTo(tl.dx, tl.dy)
      ..lineTo(tr.dx, tr.dy)
      ..lineTo(center.dx, center.dy)
      ..close(), LudoColor.yellow);
    tri(Path()
      ..moveTo(tr.dx, tr.dy)
      ..lineTo(br.dx, br.dy)
      ..lineTo(center.dx, center.dy)
      ..close(), LudoColor.blue);
    tri(Path()
      ..moveTo(br.dx, br.dy)
      ..lineTo(bl.dx, bl.dy)
      ..lineTo(center.dx, center.dy)
      ..close(), LudoColor.red);
    tri(Path()
      ..moveTo(bl.dx, bl.dy)
      ..lineTo(tl.dx, tl.dy)
      ..lineTo(center.dx, center.dy)
      ..close(), LudoColor.green);
  }

  /// Draws the player name pill on the outer edge of the board arm that
  /// this color's home column runs down: red bottom, green left,
  /// yellow top, blue right. Text is rotated to read along the edge.
  void _drawNamePill(Canvas canvas, GridPos o, double cell, String name,
      Color color, LudoColor seat) {
    Offset stripC;
    double rotation = 0;
    if (seat == LudoColor.red) {
      stripC = Offset((o.col + 3) * cell, (o.row + 5.5) * cell);
    } else if (seat == LudoColor.green) {
      stripC = Offset((o.col + 0.5) * cell, (o.row + 3) * cell);
      rotation = -math.pi / 2;
    } else if (seat == LudoColor.yellow) {
      stripC = Offset((o.col + 3) * cell, (o.row + 0.5) * cell);
    } else {
      stripC = Offset((o.col + 5.5) * cell, (o.row + 3) * cell);
      rotation = math.pi / 2;
    }
    final tp = TextPainter(
      text: TextSpan(
        text: name,
        style: TextStyle(
          fontSize: cell * 0.52,
          fontWeight: FontWeight.w800,
          color: color,
        ),
      ),
      textDirection: TextDirection.ltr,
      maxLines: 1,
      ellipsis: '…',
    )..layout();
    final thickness = cell * 0.84;
    final len = math.min(tp.width + cell * 0.5, cell * 4.7);
    canvas.save();
    canvas.translate(stripC.dx, stripC.dy);
    canvas.rotate(rotation);
    final rect =
        Rect.fromCenter(center: Offset.zero, width: len, height: thickness);
    canvas.drawRRect(
      RRect.fromRectAndRadius(rect, Radius.circular(thickness / 2)),
      Paint()..color = AppColors.ivory,
    );
    canvas.drawRRect(
      RRect.fromRectAndRadius(rect, Radius.circular(thickness / 2)),
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.2
        ..color = color.withValues(alpha: 0.5),
    );
    tp.paint(canvas, Offset(-tp.width / 2, -tp.height / 2));
    canvas.restore();
  }

  /// Simple flat arrow "→" at [c] pointing along [dir]: a straight shaft
  /// with a V-shaped head, drawn as strokes.
  void _drawArrow(Canvas canvas, Offset c, Offset dir, double r, Color color) {
    final d = dir / dir.distance;
    final perp = Offset(-d.dy, d.dx);
    final tail = c - d * (r * 0.75);
    final tip = c + d * (r * 0.75);
    final headLen = r * 0.55;
    final headSpread = r * 0.55;
    final p = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = r * 0.28
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round
      ..color = color;
    canvas.drawLine(tail, tip, p);
    canvas.drawLine(tip, tip - d * headLen + perp * headSpread, p);
    canvas.drawLine(tip, tip - d * headLen - perp * headSpread, p);
  }

  void _drawStar(Canvas canvas, Offset c, double r, Color color) {
    final path = Path();
    for (var i = 0; i < 10; i++) {
      final angle = -math.pi / 2 + i * math.pi / 5;
      final rad = i.isEven ? r : r * 0.45;
      final p = Offset(c.dx + rad * math.cos(angle), c.dy + rad * math.sin(angle));
      i == 0 ? path.moveTo(p.dx, p.dy) : path.lineTo(p.dx, p.dy);
    }
    path.close();
    canvas.drawPath(path, Paint()..color = color);
  }

  @override
  bool shouldRepaint(LudoBoardPainter old) =>
      old.highlightCells.length != highlightCells.length ||
      !old.highlightCells.containsAll(highlightCells) ||
      old.activeColor != activeColor ||
      !mapEquals(old.playerNames, playerNames);
}
