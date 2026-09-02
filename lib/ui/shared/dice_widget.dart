import 'dart:async';
import 'dart:math';

import 'package:flutter/material.dart';

import '../theme.dart';

/// A lacquered die that shuffles faces while [rolling] is true.
class DiceWidget extends StatefulWidget {
  const DiceWidget({
    super.key,
    required this.value,
    required this.rolling,
    required this.enabled,
    required this.onTap,
    this.size = 72,
    this.accent = AppColors.gold,
  });

  final int? value; // 1..6
  final bool rolling;
  final bool enabled;
  final VoidCallback onTap;
  final double size;
  final Color accent;

  @override
  State<DiceWidget> createState() => _DiceWidgetState();
}

class _DiceWidgetState extends State<DiceWidget> {
  int _shuffle = 1;
  Timer? _timer;
  final _rng = Random();

  @override
  void initState() {
    super.initState();
    if (widget.rolling) _startShuffle();
  }

  @override
  void didUpdateWidget(covariant DiceWidget old) {
    super.didUpdateWidget(old);
    if (widget.rolling && !old.rolling) _startShuffle();
    if (!widget.rolling) {
      _timer?.cancel();
      if (widget.value != null) _shuffle = widget.value!;
    }
  }

  void _startShuffle() {
    _timer?.cancel();
    _timer = Timer.periodic(const Duration(milliseconds: 90), (t) {
      if (mounted) setState(() => _shuffle = _rng.nextInt(6) + 1);
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      label: 'Roll dice',
      child: GestureDetector(
        onTap: widget.enabled && !widget.rolling ? widget.onTap : null,
        child: AnimatedBuilder(
          animation: const AlwaysStoppedAnimation(0),
          builder: (context, _) => AnimatedScale(
            scale: widget.enabled && !widget.rolling ? 1.0 : 0.94,
            duration: const Duration(milliseconds: 150),
            child: TweenAnimationBuilder<double>(
              tween: Tween(begin: 0, end: widget.rolling ? 1 : 0),
              duration: const Duration(milliseconds: 120),
              builder: (context, t, child) => Transform.rotate(
                angle: widget.rolling ? t * 6 : 0,
                child: child,
              ),
              child: _face(_shuffle),
            ),
          ),
        ),
      ),
    );
  }

  Widget _face(int v) => Container(
        width: widget.size,
        height: widget.size,
        decoration: BoxDecoration(
          color: AppColors.ivory,
          borderRadius: BorderRadius.circular(widget.size * 0.18),
          border: Border.all(color: widget.accent, width: 2.5),
          boxShadow: const [
            BoxShadow(color: Colors.black45, blurRadius: 8, offset: Offset(0, 4))
          ],
        ),
        child: CustomPaint(painter: _PipsPainter(v, widget.accent)),
      );
}

class _PipsPainter extends CustomPainter {
  _PipsPainter(this.value, this.color);
  final int value;
  final Color color;

  static const _layout = {
    1: [[.5, .5]],
    2: [[.28, .28], [.72, .72]],
    3: [[.25, .25], [.5, .5], [.75, .75]],
    4: [[.28, .28], [.72, .28], [.28, .72], [.72, .72]],
    5: [[.28, .28], [.72, .28], [.5, .5], [.28, .72], [.72, .72]],
    6: [[.28, .25], [.72, .25], [.28, .5], [.72, .5], [.28, .75], [.72, .75]],
  };

  @override
  void paint(Canvas canvas, Size size) {
    final r = size.width * 0.09;
    final paint = Paint()..color = color;
    for (final p in _layout[value] ?? const []) {
      canvas.drawCircle(
          Offset(p[0] * size.width, p[1] * size.height), r, paint);
    }
  }

  @override
  bool shouldRepaint(_PipsPainter old) => old.value != value || old.color != color;
}
