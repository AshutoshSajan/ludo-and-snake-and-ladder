import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../../engine/snakes/snakes_engine.dart';
import '../theme.dart';

/// Paints the 100-square Snakes & Ladders board with ladders and snakes.
class SnakesBoardPainter extends CustomPainter {
  SnakesBoardPainter({this.highlightSquare});
  final int? highlightSquare;

  static const n = 10.0;

  /// Center of square [sq] (1..100). Square 1 is bottom-left, boustrophedon.
  static Offset squareCenter(int sq, Size size) {
    final cell = size.width / n;
    final i = sq - 1;
    final rowFromBottom = i ~/ 10;
    var col = i % 10;
    if (rowFromBottom.isOdd) col = 9 - col;
    final row = 9 - rowFromBottom;
    return Offset((col + 0.5) * cell, (row + 0.5) * cell);
  }

  @override
  void paint(Canvas canvas, Size size) {
    final cell = size.width / n;

    // Cells.
    for (var sq = 1; sq <= 100; sq++) {
      final i = sq - 1;
      final rowFromBottom = i ~/ 10;
      var col = i % 10;
      if (rowFromBottom.isOdd) col = 9 - col;
      final row = 9 - rowFromBottom;
      final rect = Rect.fromLTWH(col * cell, row * cell, cell, cell);
      final shade = (rowFromBottom + col) % 2 == 0
          ? AppColors.ivory
          : AppColors.ivoryDark;
      canvas.drawRect(rect.deflate(0.6), Paint()..color = shade);
      canvas.drawRect(
        rect.deflate(0.6),
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1
          ..color = AppColors.ink.withValues(alpha: 0.25),
      );
      if (highlightSquare == sq) {
        canvas.drawRect(
          rect.deflate(2),
          Paint()
            ..color = AppColors.gold.withValues(alpha: 0.7)
            ..style = PaintingStyle.stroke
            ..strokeWidth = 3,
        );
      }
      // Number label.
      final tp = TextPainter(
        text: TextSpan(
          text: '$sq',
          style: TextStyle(
            fontSize: cell * 0.24,
            color: AppColors.ink.withValues(alpha: 0.65),
            fontWeight: FontWeight.w600,
          ),
        ),
        textDirection: TextDirection.ltr,
      )..layout();
      tp.paint(canvas, rect.topLeft + Offset(cell * 0.08, cell * 0.06));
    }

    // Finish / start accents.
    _ring(canvas, squareCenter(100, size), cell * 0.42, AppColors.gold);
    _ring(canvas, squareCenter(1, size), cell * 0.42, AppColors.ludoGreen);

    // Ladders.
    for (final e in kSnakesLaddersJumps.entries) {
      if (e.value > e.key) _ladder(canvas, e.key, e.value, size, cell);
    }
    // Snakes.
    for (final e in kSnakesLaddersJumps.entries) {
      if (e.value < e.key) _snake(canvas, e.key, e.value, size, cell);
    }
  }

  void _ring(Canvas canvas, Offset c, double r, Color color) {
    canvas.drawCircle(
      c,
      r,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 3
        ..color = color,
    );
  }

  void _ladder(
      Canvas canvas, int from, int to, Size size, double cell) {
    final a = squareCenter(from, size);
    final b = squareCenter(to, size);
    final dir = (b - a);
    final len = dir.distance;
    final u = Offset(dir.dx / len, dir.dy / len); // along
    final p = Offset(-u.dy, u.dx); // perpendicular
    final halfW = cell * 0.14;
    final railPaint = Paint()
      ..strokeWidth = cell * 0.07
      ..color = const Color(0xFF8B5A2B);
    for (final s in [-1.0, 1.0]) {
      // Same perpendicular offset on BOTH ends -> two parallel rails.
      canvas.drawLine(
        a + p * (halfW * s) + u * (cell * 0.1),
        b + p * (halfW * s) - u * (cell * 0.1),
        railPaint,
      );
    }
    final rungs = (len / (cell * 0.55)).round();
    final rungPaint = Paint()
      ..strokeWidth = cell * 0.055
      ..color = const Color(0xFFA0703C);
    for (var i = 1; i < rungs; i++) {
      final t = i / rungs;
      final c = a + dir * t;
      canvas.drawLine(c - p * halfW, c + p * halfW, rungPaint);
    }
  }

  void _snake(Canvas canvas, int from, int to, Size size, double cell) {
    final head = squareCenter(from, size);
    final tail = squareCenter(to, size);
    final dir = tail - head;
    final len = dir.distance;
    final u = Offset(dir.dx / len, dir.dy / len);
    final p = Offset(-u.dy, u.dx);

    final path = ui.Path();
    const waves = 3.2;
    for (var i = 0; i <= 40; i++) {
      final t = i / 40;
      final amp = cell * 0.28 * math.sin(t * math.pi); // taper at ends
      final off = p * amp * math.sin(t * math.pi * 2 * waves);
      final pt = head + dir * t + off;
      i == 0 ? path.moveTo(pt.dx, pt.dy) : path.lineTo(pt.dx, pt.dy);
    }
    final paint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = cell * 0.16
      ..strokeCap = StrokeCap.round
      ..color = const Color(0xFF2E7D32).withValues(alpha: 0.9);
    canvas.drawPath(path, paint);

    // Head.
    canvas.drawCircle(head, cell * 0.14, Paint()..color = const Color(0xFF1B5E20));
    final eyePaint = Paint()..color = Colors.white;
    canvas.drawCircle(head + u * cell * 0.05 - p * cell * 0.06,
        cell * 0.035, eyePaint);
    canvas.drawCircle(head + u * cell * 0.05 + p * cell * 0.06,
        cell * 0.035, eyePaint);
  }

  @override
  bool shouldRepaint(SnakesBoardPainter old) =>
      old.highlightSquare != highlightSquare;
}
