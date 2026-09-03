import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../theme.dart';

/// Podium shown when a game ends — with a pulsing trophy and confetti burst
/// celebrating the winner.
class VictoryDialog extends StatefulWidget {
  const VictoryDialog({
    super.key,
    required this.title,
    required this.rankedNames,
    required this.onRematch,
    required this.onHome,
  });

  final String title;
  final List<String> rankedNames; // winner first
  final VoidCallback onRematch;
  final VoidCallback onHome;

  @override
  State<VictoryDialog> createState() => _VictoryDialogState();
}

class _VictoryDialogState extends State<VictoryDialog>
    with SingleTickerProviderStateMixin {
  late final AnimationController _fx;
  late final List<_Confetti> _confetti;

  @override
  void initState() {
    super.initState();
    _fx = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 2400),
    )..repeat();
    final rng = math.Random(7);
    _confetti = [
      for (var i = 0; i < 60; i++)
        _Confetti(
          x: rng.nextDouble(),
          delay: rng.nextDouble(),
          speed: 0.45 + rng.nextDouble() * 0.45,
          size: 4 + rng.nextDouble() * 6,
          color: [
            AppColors.gold,
            const Color(0xFFE53935),
            const Color(0xFF43A047),
            const Color(0xFF1E88E5),
            const Color(0xFFFB8C00),
          ][rng.nextInt(5)],
        ),
    ];
  }

  @override
  void dispose() {
    _fx.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Dialog(
      clipBehavior: Clip.antiAlias,
      child: AnimatedBuilder(
        animation: _fx,
        builder: (context, _) {
          final t = _fx.value;
          return Stack(
            alignment: Alignment.topCenter,
            children: [
              Positioned.fill(
                child: CustomPaint(painter: _ConfettiPainter(_confetti, t)),
              ),
              Padding(
                padding: const EdgeInsets.all(24),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    // Winner trophy: bounce + wobble + glow.
                    Transform(
                      alignment: Alignment.center,
                      transform: Matrix4.identity()
                        ..translateByDouble(
                            0, -14 * math.sin(t * 2 * math.pi), 0, 1)
                        ..rotateZ(0.16 * math.sin(t * 2 * math.pi + 0.6))
                        ..scaleByDouble(
                            1 + 0.10 * math.sin(t * 4 * math.pi), 1, 0, 1),
                      child: const Text('🏆',
                          style: TextStyle(fontSize: 64, shadows: [
                            Shadow(color: AppColors.gold, blurRadius: 28),
                          ])),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      widget.title,
                      textAlign: TextAlign.center,
                      style:
                          Theme.of(context).textTheme.headlineSmall?.copyWith(
                                fontWeight: FontWeight.w800,
                                color: AppColors.gold,
                              ),
                    ),
                    const SizedBox(height: 16),
                    for (var i = 0; i < widget.rankedNames.length; i++)
                      Padding(
                        padding: const EdgeInsets.symmetric(vertical: 4),
                        child: Row(
                          children: [
                            SizedBox(
                              width: 36,
                              child: Text(
                                i < 3 ? _medals[i] : '${i + 1}.',
                                style: const TextStyle(fontSize: 18),
                              ),
                            ),
                            Expanded(
                              child: Text(
                                widget.rankedNames[i],
                                style: TextStyle(
                                  fontSize: i == 0 ? 18 : 15,
                                  fontWeight: i == 0
                                      ? FontWeight.w800
                                      : FontWeight.w400,
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    const SizedBox(height: 20),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                      children: [
                        OutlinedButton(
                            onPressed: widget.onHome,
                            child: const Text('Home')),
                        FilledButton(
                            onPressed: widget.onRematch,
                            child: const Text('Rematch')),
                      ],
                    ),
                  ],
                ),
              ),
            ],
          );
        },
      ),
    );
  }

  static const _medals = ['🏆', '🥈', '🥉'];
}

class _Confetti {
  _Confetti({
    required this.x,
    required this.delay,
    required this.speed,
    required this.size,
    required this.color,
  });

  final double x; // horizontal position, 0..1
  final double delay; // phase offset, 0..1
  final double speed; // fall speed multiplier
  final double size;
  final Color color;
}

class _ConfettiPainter extends CustomPainter {
  _ConfettiPainter(this.pieces, this.t);
  final List<_Confetti> pieces;
  final double t;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint();
    for (final c in pieces) {
      // Each piece falls from above the top edge to below the bottom,
      // wrapping around, swaying and tumbling as it descends.
      final progress = (t * c.speed + c.delay) % 1.2;
      final y = (progress / 1.2) * (size.height + 60) - 60;
      final sway = 18 * math.sin((t * 3 + c.delay * 9) * 2 * math.pi);
      final x = c.x * size.width + sway;
      final angle = (t * 4 + c.delay * 7) * 2 * math.pi;
      canvas.save();
      canvas.translate(x, y);
      canvas.rotate(angle);
      paint.color = c.color;
      canvas.drawRRect(
        RRect.fromRectAndRadius(
          Rect.fromCenter(
            center: Offset.zero,
            width: c.size,
            height: c.size * 0.55,
          ),
          const Radius.circular(1.5),
        ),
        paint,
      );
      canvas.restore();
    }
  }

  @override
  bool shouldRepaint(_ConfettiPainter old) => old.t != t;
}
