import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../engine/ludo/ludo_board.dart';
import '../../engine/ludo/ludo_models.dart';
import '../theme.dart';

/// Paints the classic 15x15 Ludo board: ivory playing field, lacquered
/// quadrant yards, colored home columns and a four-triangle center.
class LudoBoardPainter extends CustomPainter {
  LudoBoardPainter({this.highlightCells = const {}});
  final Set<int> highlightCells; // absolute track indices

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

    // Yards.
    for (final color in LudoColor.values) {
      final o = LudoBoard.yardOrigin[color]!;
      final r = Rect.fromLTWH(o.col * cell, o.row * cell, cell * 6, cell * 6);
      canvas.drawRRect(
        RRect.fromRectAndRadius(r, Radius.circular(cell * 0.5)),
        Paint()..color = AppColors.ludo(color),
      );
      // Inner well.
      canvas.drawCircle(
        Offset(o.col * cell + cell * 3, o.row * cell + cell * 3),
        cell * 1.9,
        Paint()..color = AppColors.ivory,
      );
      canvas.drawCircle(
        Offset(o.col * cell + cell * 3, o.row * cell + cell * 3),
        cell * 1.9,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = cell * 0.08
          ..color = AppColors.ludo(color).withValues(alpha: 0.55),
      );
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
      // Star safe cells (non-start).
      if (i == 8 || i == 21 || i == 34 || i == 47) {
        _drawStar(canvas, cellCenter(p.row, p.col, size), cell * 0.3,
            AppColors.ink.withValues(alpha: 0.7));
      }
    }

    // Home columns.
    for (final color in LudoColor.values) {
      final cells = LudoBoard.homeColumns[color]!;
      for (final p in cells) {
        final r = cellRect(p.row, p.col, size).deflate(0.6);
        canvas.drawRect(r, Paint()..color = AppColors.ludo(color).withValues(alpha: 0.85));
        canvas.drawRect(r, line);
      }
    }

    // Center: four triangles pointing in, spanning the 3x3 center block.
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
      ..close(), LudoColor.green);
    tri(Path()
      ..moveTo(tr.dx, tr.dy)
      ..lineTo(br.dx, br.dy)
      ..lineTo(center.dx, center.dy)
      ..close(), LudoColor.yellow);
    tri(Path()
      ..moveTo(br.dx, br.dy)
      ..lineTo(bl.dx, bl.dy)
      ..lineTo(center.dx, center.dy)
      ..close(), LudoColor.blue);
    tri(Path()
      ..moveTo(bl.dx, bl.dy)
      ..lineTo(tl.dx, tl.dy)
      ..lineTo(center.dx, center.dy)
      ..close(), LudoColor.red);
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
      !old.highlightCells.containsAll(highlightCells);
}
