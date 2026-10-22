/// Geometry for the Snakes stage, pinned to the playtest request:
///
/// "snake board is too small, move the home area to the left side and make
/// its size as big as possible as per the header width."
///
/// The old stage always reserved a 76px strip under the board, so on a
/// desktop window the board was height-starved and narrower than the header
/// column. The stage now picks the orientation that gives the larger board,
/// moves the rail to the left when it does, and caps the board at the 720px
/// reading column. A phone, where the rail would shrink the board, keeps the
/// strip.
///
/// A second playtest (781x768 browser window) found the board alone centred:
/// the rail hung outside the page column while an equal band of felt sat
/// unused on the right. The rail, gap and board now centre as one group, so
/// the two side margins match and the rail stays inside the reading width.
///
/// A third playtest (phone-width window) found the 96px rail too wide for a
/// phone column; it is 64 now, so a short window that prefers the rail still
/// gets a board wider than the strip would have given it.
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

    // The whole group — rail, gap, board — is centred on the page, so the
    // rail sits inside the reading width instead of hanging into the left
    // margin while the right side carries dead felt.
    expect((m.homeRect.left + m.boardRect.right) / 2, closeTo(720, 0.5));
    expect(m.homeRect.left, closeTo(1440 - m.boardRect.right, 0.5));
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
    // The cap binds, so the group is narrower than the window and centres
    // as a unit — the board is off-centre by exactly half the rail+gap.
    expect((m.homeRect.left + m.boardRect.right) / 2, closeTo(960, 0.5));
    expect(m.homeRect.left, closeTo(1920 - m.boardRect.right, 0.5));
  });

  test('a height-limited width centres rail and board together', () {
    // The reported playtest window (781 wide). The board takes the full
    // available height, leaving a width-limited side branch: the rail used
    // to touch x=0 while 75px of dead felt sat on the right. Now both side
    // margins match and the board stays the largest square that fits.
    final m = SnakesStageMetrics.layout(
      available: const Size(781, 600),
      players: 4,
    );

    expect(m.homeOnLeft, isTrue);
    expect(m.boardSize, closeTo(600, 0.5));
    expect(m.homeRect.left, greaterThan(0));
    expect(
      m.homeRect.left,
      closeTo(m.available.width - m.boardRect.right, 0.6),
      reason: 'the rail margin and the right margin must be symmetric',
    );
    expect(m.homeRect.right, lessThanOrEqualTo(m.boardRect.left));
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

  test('the side rail is 64px wide, not a quarter of a phone column', () {
    // A short window where the rail yields the larger board. At 96px it was
    // 316px of board; the narrow rail returns 32px to the square.
    final m = SnakesStageMetrics.layout(
      available: const Size(390, 380),
      players: 4,
    );

    expect(m.homeOnLeft, isTrue);
    expect(m.homeRect.width, SnakesStageMetrics.homeRailWidth);
    expect(SnakesStageMetrics.homeRailWidth, 64);
    expect(
      m.boardSize,
      greaterThan(390 - SnakesStageMetrics.homeStripH),
      reason: 'the rail must earn its place by growing the board',
    );
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
