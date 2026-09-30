import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

/// A deterministic identicon for a player id.
///
/// Every player gets an avatar with nothing to upload, nothing to store, and
/// no new dependency: the pattern is derived from the id, so the same player
/// is always the same face, on every device, with no network involved. That
/// matters here because the id *is* the player's identity — the same value the
/// leaderboard groups by — so the avatar cannot drift from the player it
/// represents.
///
/// Drawn as a mirrored 5x5 grid, the standard identicon construction: a hash of
/// the id fills the cells off-centre and the left half is mirrored to the
/// right, which is what gives identicons their recognisable symmetry.
class PlayerAvatar extends StatelessWidget {
  const PlayerAvatar({
    super.key,
    required this.seed,
    this.size = 28,
    this.background,
  });

  /// The player's id. Any string works.
  final String seed;
  final double size;
  final Color? background;

  /// A stable hash, so the same seed always yields the same picture. Exposed
  /// so a test can pin that stability rather than infer it from pixels.
  @visibleForTesting
  static int stableHash(String s) {
    var h = 0x811c9dc5;
    for (final c in s.codeUnits) {
      h = (h ^ c) & 0x7fffffff;
      h = (h * 16777619) & 0x7fffffff;
    }
    return h;
  }

  @override
  Widget build(BuildContext context) {
    final h = stableHash(seed);
    // Two hues from the same hash: one for the cells, one for the backdrop, so
    // neighbouring players never blend into the same blob.
    final fg = HSLColor.fromAHSL(
      1,
      (h % 360).toDouble(),
      0.55,
      0.55,
    ).toColor();
    final bg = background ??
        HSLColor.fromAHSL(
          1,
          ((h ~/ 7) % 360).toDouble(),
          0.35,
          0.22,
        ).toColor();

    // 5x5, mirrored. Bits are consumed from a copy so the hue stays stable.
    var bits = h;
    final cells = List.generate(5, (_) => List.generate(5, (_) => false));
    for (var y = 0; y < 5; y++) {
      for (var x = 0; x < 3; x++) {
        final on = (bits & 1) == 1;
        bits = (bits >> 1) & 0x7fffffff;
        cells[y][x] = on;
        cells[y][4 - x] = on; // mirror
      }
    }
    // The centre column can be mirrored onto itself; the hash still decides it.
    return Container(
      width: size,
      height: size,
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(size * 0.22),
        border: Border.all(color: Colors.white24),
      ),
      child: CustomPaint(painter: _IdenticonPainter(cells, fg)),
    );
  }
}

class _IdenticonPainter extends CustomPainter {
  _IdenticonPainter(this.cells, this.color);

  final List<List<bool>> cells;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final cell = size.width / 5;
    final paint = Paint()..color = color;
    for (var y = 0; y < 5; y++) {
      for (var x = 0; x < 5; x++) {
        if (!cells[y][x]) continue;
        canvas.drawRRect(
          RRect.fromRectAndRadius(
            Rect.fromLTWH(x * cell, y * cell, cell, cell),
            Radius.circular(cell * 0.18),
          ),
          paint,
        );
      }
    }
  }

  @override
  bool shouldRepaint(_IdenticonPainter old) =>
      old.color != color || !listEquals(old.cells, cells);
}
