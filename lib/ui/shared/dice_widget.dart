import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../theme.dart';

/// A real 3D die: a projected cube that tumbles on both axes while rolling
/// and settles on the rolled face with an ease-out spin.
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

class _DiceWidgetState extends State<DiceWidget>
    with SingleTickerProviderStateMixin {
  /// Rotation (rotX, rotY) that brings each face to the front.
  static const _targets = <int, (double, double)>{
    1: (0.0, 0.0),
    2: (-math.pi / 2, 0.0),
    3: (0.0, -math.pi / 2),
    4: (0.0, math.pi / 2),
    5: (math.pi / 2, 0.0),
    6: (math.pi, 0.0),
  };
  static const double _tiltX = -0.30;
  static const double _tiltY = 0.45;
  static const double _tau = 2 * math.pi;
  static const _rollDuration = Duration(milliseconds: 1100);
  static const _settleDuration = Duration(milliseconds: 520);

  late final AnimationController _ctrl;
  bool _spinning = false;
  double _ax = _tiltX, _by = _tiltY;
  double _baseAx = 0, _baseBy = 0;
  double _scale = 1.0;
  int _shown = 1;
  double? _fromAx, _toAx, _fromBy, _toBy;

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(vsync: this, duration: _rollDuration)
      ..addListener(_tick);
    if (widget.rolling) {
      _startSpin();
    } else if (widget.value != null && widget.value != _shown) {
      _snapTo(widget.value!);
    }
  }

  @override
  void didUpdateWidget(covariant DiceWidget old) {
    super.didUpdateWidget(old);
    if (widget.rolling && !old.rolling) {
      _startSpin();
    } else if (!widget.rolling &&
        (old.rolling || widget.value != old.value) &&
        widget.value != null) {
      _settleTo(widget.value!);
    }
  }

  void _startSpin() {
    _spinning = true;
    _baseAx = _ax % _tau;
    _baseBy = _by % _tau;
    _ctrl
      ..duration = _rollDuration
      ..repeat();
  }

  void _snapTo(int v) {
    _shown = v;
    final t = _targets[v]!;
    _ax = t.$1 + _tiltX;
    _by = t.$2 + _tiltY;
  }

  void _settleTo(int v) {
    _spinning = false;
    _shown = v;
    final t = _targets[v]!;
    _fromAx = _ax;
    _fromBy = _by;
    var toAx = t.$1 + _tiltX;
    var toBy = t.$2 + _tiltY;
    // Continue spinning forward: land at least one full turn ahead.
    toAx += _tau * (((_ax - toAx) / _tau).floor() + 1);
    toBy += _tau * (((_by - toBy) / _tau).floor() + 1);
    _toAx = toAx;
    _toBy = toBy;
    _ctrl
      ..duration = _settleDuration
      ..forward(from: 0);
  }

  void _tick() {
    setState(() {
      if (_spinning) {
        final t = _ctrl.value;
        _ax = _baseAx + 2 * _tau * t;
        _by = _baseBy + 3 * _tau * t;
        _scale = 1.0 + 0.06 * math.sin(_tau * t);
      } else if (_toAx != null && _ctrl.isAnimating) {
        final t = Curves.easeOutCubic.transform(_ctrl.value);
        _ax = _lerp(_fromAx!, _toAx!, t);
        _by = _lerp(_fromBy!, _toBy!, t);
        _scale = 1.0 + 0.10 * math.sin(math.pi * t);
      }
    });
  }

  static double _lerp(double a, double b, double t) => a + (b - a) * t;

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }


  @override
  Widget build(BuildContext context) {
    final vp = widget.size * 2.6;
    return Semantics(
      button: true,
      label: 'Roll dice',
      child: GestureDetector(
        onTap: widget.enabled && !widget.rolling ? widget.onTap : null,
        child: AnimatedScale(
          scale: widget.enabled && !widget.rolling ? 1.0 : 0.94,
          duration: const Duration(milliseconds: 150),
          child: SizedBox(
            width: widget.size,
            height: widget.size,
            child: Stack(
              clipBehavior: Clip.none,
              alignment: Alignment.center,
              children: [
                Positioned(
                  left: (widget.size - vp) / 2,
                  top: (widget.size - vp) / 2,
                  width: vp,
                  height: vp,
                  child: AnimatedBuilder(
                    animation: _ctrl,
                    builder: (_, _) => CustomPaint(
                      size: Size(vp, vp),
                      painter: _CubePainter(
                        ax: _ax,
                        by: _by,
                        edge: widget.size * 0.55 * _scale,
                        accent: widget.accent,
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Minimal 3D vector with the ops the cube painter needs.
class _V {
  const _V(this.x, this.y, this.z);
  final double x, y, z;
  _V operator +(_V o) => _V(x + o.x, y + o.y, z + o.z);
  _V operator *(double s) => _V(x * s, y * s, z * s);
}

class _Face {
  _Face(this.value, this.normal, this.corners, this.pips);
  final int value;
  final _V normal;
  final List<_V> corners;
  final List<_V> pips;
}

class _CubePainter extends CustomPainter {
  _CubePainter({
    required this.ax,
    required this.by,
    required this.edge,
    required this.accent,
  });

  final double ax; // rotation around X
  final double by; // rotation around Y
  final double edge; // cube side length in px
  final Color accent;

  static const _pips = <int, List<List<double>>>{
    1: [[.5, .5]],
    2: [[.28, .28], [.72, .72]],
    3: [[.25, .25], [.5, .5], [.75, .75]],
    4: [[.28, .28], [.72, .28], [.28, .72], [.72, .72]],
    5: [[.28, .28], [.72, .28], [.5, .5], [.28, .72], [.72, .72]],
    6: [[.28, .25], [.72, .25], [.28, .5], [.72, .5], [.28, .75], [.72, .75]],
  };

  static const _shadeColor = Color(0xFFCDC5AE);

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2 - edge * 0.10);
    final h = edge / 2;

    // Ground shadow.
    canvas.drawOval(
      Rect.fromCenter(
        center: Offset(center.dx, center.dy + edge * 0.80),
        width: edge * 1.10,
        height: edge * 0.28,
      ),
      Paint()
        ..color = Colors.black.withValues(alpha: 0.28)
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 8),
    );

    final cosA = math.cos(ax), sinA = math.sin(ax);
    final cosB = math.cos(by), sinB = math.sin(by);
    final d = edge * 5.0; // camera distance for perspective

    // Rotate (Ry then Rx) and project. Larger z is closer to the viewer.
    (double, double, double) rot(_V p) {
      final x1 = p.x * cosB + p.z * sinB;
      final y1 = p.y;
      final z1 = -p.x * sinB + p.z * cosB;
      final y2 = y1 * cosA - z1 * sinA;
      final z2 = y1 * sinA + z1 * cosA;
      return (x1, y2, z2);
    }

    Offset proj((double, double, double) r) {
      final f = d / (d - r.$3);
      return Offset(center.dx + r.$1 * f, center.dy + r.$2 * f);
    }

    // Build the six faces.
    final faces = <_Face>[];
    void addFace(int value, _V n, _V o, _V u, _V v) {
      final corners = [o, o + u, o + u + v, o + v];
      final pips = [
        for (final p in _pips[value]!) o + u * p[0] + v * p[1],
      ];
      faces.add(_Face(value, n, corners, pips));
    }

    addFace(1, _V(0, 0, 1), _V(-h, -h, h), _V(2 * h, 0, 0), _V(0, 2 * h, 0));
    addFace(6, _V(0, 0, -1), _V(h, -h, -h), _V(-2 * h, 0, 0), _V(0, 2 * h, 0));
    addFace(3, _V(1, 0, 0), _V(h, -h, -h), _V(0, 0, 2 * h), _V(0, 2 * h, 0));
    addFace(4, _V(-1, 0, 0), _V(-h, -h, h), _V(0, 0, -2 * h), _V(0, 2 * h, 0));
    addFace(2, _V(0, -1, 0), _V(-h, -h, -h), _V(2 * h, 0, 0), _V(0, 0, 2 * h));
    addFace(5, _V(0, 1, 0), _V(-h, h, -h), _V(2 * h, 0, 0), _V(0, 0, 2 * h));

    // Keep only viewer-facing faces, sorted back-to-front.
    final visible = <(_Face, double, List<Offset>)>[];
    for (final f in faces) {
      final rn = rot(f.normal);
      if (rn.$3 <= 0.02) continue;
      final pts = [for (final c in f.corners) proj(rot(c))];
      final depth = rot((f.corners[0] + f.corners[2]) * 0.5).$3;
      visible.add((f, depth, pts));
    }
    visible.sort((a, b) => a.$2.compareTo(b.$2));

    final facePaint = Paint();
    final borderPaint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = edge * 0.032
      ..strokeJoin = StrokeJoin.round;
    final pipPaint = Paint();

    for (final (f, _, pts) in visible) {
      final t = 0.55 + 0.45 * rot(f.normal).$3.clamp(0.0, 1.0);
      facePaint.color = Color.lerp(_shadeColor, AppColors.ivory, t)!;
      final border =
          Color.lerp(Color.lerp(accent, Colors.black, 0.25)!, accent, t)!;
      borderPaint.color = border;
      pipPaint.color = border;

      final path = Path()..addPolygon(pts, true);
      canvas.drawPath(path, facePaint);
      canvas.drawPath(path, borderPaint);

      final pipR = edge * 0.11;
      for (final p in f.pips) {
        canvas.drawCircle(proj(rot(p)), pipR, pipPaint);
      }
    }
  }

  @override
  bool shouldRepaint(_CubePainter old) =>
      old.ax != ax || old.by != by || old.edge != edge || old.accent != accent;
}

