/// Geometry for the Snakes stage, pinned to the playtest request:
///
/// "snake board is too small, move the home area to the left side and make
/// its size as big as possible as per the header width."
///
/// The old stage always reserved a 76px strip under the board, so on a
/// desktop window the board was height-starved and narrower than the header
/// column. The stage now picks the orientation that gives the larger board,
/// moves the rail to the left when it does, and caps the board at the 720px
/// reading column. A phone, where a 96px rail would shrink the board, keeps
/// the strip.
library;

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:game_club/ui/page_app_bar.dart' show kContentMaxWidth;
import 'package:game_club/ui/snakes/snakes_stage.dart';

void main() {
  test('a desktop window puts the rail left and gives the board its height', () {
    // The live playtest window's board area: 1440 wide, 716 tall after the
    // app bar and controls. The strip cost 76 of that height; the rail costs
    // none of it.
    final m = SnakesStageMetrics.layout(
      available: const Size(1440, 716),
      players: 4,
    );

    expect(m.homeOnLeft, isTrue);
    expect(m.boardSize, closeTo(716, 0.5));
    expect(m.boardSize, greaterThan(716 - SnakesStageMetrics.homeStripH));
    expect(m.boardSize, lessThanOrEqualTo(kContentMaxWidth));

    // The board — not board-plus-rail — is centred on the page, so it lines
    // up with the header column instead of being pushed right by the rail.
    expect(m.boardRect.center.dx, closeTo(720, 0.5));
    expect(m.homeRect.right, lessThanOrEqualTo(m.boardRect.left));
    expect(m.homeRect.top, closeTo(m.boardRect.top, 0.5));
    expect(m.homeRect.height, closeTo(m.boardRect.height, 0.5));
  });

  test('a very tall window caps the board at the header column', () {
    final m = SnakesStageMetrics.layout(
      available: const Size(1920, 1400),
      players: 4,
    );

    expect(m.homeOnLeft, isTrue, reason: 'equal boards prefer the rail');
    expect(m.boardSize, closeTo(kContentMaxWidth, 0.5));
    expect(m.boardRect.center.dx, closeTo(960, 0.5));
  });

  test('a phone keeps the strip, because the rail would shrink the board', () {
    final m = SnakesStageMetrics.layout(
      available: const Size(390, 700),
      players: 4,
    );

    expect(m.homeOnLeft, isFalse);
    expect(m.boardSize, closeTo(390, 0.5));
    expect(m.homeRect.top, greaterThanOrEqualTo(m.boardRect.bottom - 0.5));
    expect(m.homeRect.width, closeTo(m.boardRect.width, 0.5));
  });

  test('four chips sit in one column inside the rail, not one row', () {
    final m = SnakesStageMetrics.layout(
      available: const Size(1440, 716),
      players: 4,
    );

    final centers = [for (var i = 0; i < 4; i++) m.homeChipCenter(i)];
    expect(centers.map((c) => c.dx).toSet().length, 1);
    for (var i = 1; i < centers.length; i++) {
      expect(centers[i].dy, greaterThan(centers[i - 1].dy));
    }
    for (final c in centers) {
      expect(c.dx - m.chipSize / 2, greaterThanOrEqualTo(m.homeRect.left));
      expect(c.dx + m.chipSize / 2, lessThanOrEqualTo(m.homeRect.right));
      expect(c.dy - m.chipSize / 2, greaterThanOrEqualTo(m.homeRect.top));
      expect(c.dy + m.chipSize / 2, lessThanOrEqualTo(m.homeRect.bottom));
    }
  });

  test('ten chips still fit one rail without leaving the panel', () {
    // A short landscape-ish desktop area: the case that shrinks chips.
    final m = SnakesStageMetrics.layout(
      available: const Size(1000, 420),
      players: 10,
    );

    expect(m.homeOnLeft, isTrue);
    for (var i = 0; i < 10; i++) {
      final c = m.homeChipCenter(i);
      expect(c.dy - m.chipSize / 2, greaterThanOrEqualTo(m.homeRect.top));
      expect(c.dy + m.chipSize / 2, lessThanOrEqualTo(m.homeRect.bottom));
    }
  });
}
