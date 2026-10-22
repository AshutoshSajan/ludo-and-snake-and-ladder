/// The online Ludo stage is one centred block: top lamp row, square board,
/// bottom lamp row.
///
/// Playtest on a portrait phone: the play area is taller than the square
/// board. The old Column pinned the two lamp rows to the play area's top and
/// bottom edges and centred the board in the flexible remainder, so the timer
/// and strike dots floated roughly 100px of empty felt away from the players
/// they describe. [ludoStageHeight] is the block's height under the new
/// layout; the view centres a SizedBox of that height, which leaves equal
/// margins outside the rows and none between a row and the board.
library;

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:game_club/ui/ludo/ludo_corner_panel.dart' show ludoPanelSlab;
import 'package:game_club/ui/ludo/ludo_view.dart'
    show ludoBoardSide, ludoStageHeight;

void main() {
  test(
    'a portrait play area gives the lamps equal margins and a full board',
    () {
      // 390x844 phone minus the app bar and seat strip: still much taller than
      // it is wide, the shape that exposed the floating lamp rows.
      const playArea = Size(390, 700);
      final board = ludoBoardSide(playArea, slab: ludoPanelSlab);
      final stage = ludoStageHeight(board, slab: ludoPanelSlab);

      // The width is the binding constraint, so the board keeps all of it and
      // the lamps cost it nothing.
      expect(board, closeTo(390, 0.5));
      expect(stage, closeTo(390 + 2 * ludoPanelSlab, 0.5));

      // The block is shorter than the play area, so centring it leaves
      // 97px of dead felt above and below — NOT between the rows and the
      // board, which is where the old layout put it.
      expect(stage, lessThan(playArea.height));
      const margin = (700 - 506) / 2;
      expect(margin, closeTo(97, 0.5));
      expect(margin, greaterThan(0));

      // Row, board, row stack exactly at the measured phone positions: the
      // top row runs 97..155, the board 155..545, the bottom row 545..603.
      // A bottom row left at the play area's edge would sit at y=642.
      final boardTop = margin + ludoPanelSlab;
      expect(boardTop, closeTo(155, 0.5));
      expect(boardTop + board, closeTo(545, 0.5));
      expect(
        boardTop + board,
        closeTo(margin + stage - ludoPanelSlab, 0.5),
        reason: 'the bottom row must sit on the board, not at the window edge',
      );
      expect(
        margin + stage,
        closeTo(playArea.height - margin, 0.5),
        reason: 'the block must sit centred, with symmetric outside margins',
      );
    },
  );

  test('a wide play area fills its height without overflowing', () {
    // Landscape desktop: the height binds, so the stage exactly fills the
    // area and the square board is the largest one that fits beside the two
    // fixed rows.
    const playArea = Size(1000, 640);
    final board = ludoBoardSide(playArea, slab: ludoPanelSlab);
    final stage = ludoStageHeight(board, slab: ludoPanelSlab);

    expect(board, closeTo(640 - 2 * ludoPanelSlab, 0.5));
    expect(stage, closeTo(playArea.height, 0.5));
    expect(stage, lessThanOrEqualTo(playArea.height + 0.5));
  });

  test('a local table reserves no lamp rows', () {
    const playArea = Size(390, 700);
    final board = ludoBoardSide(playArea, slab: 0);
    expect(board, closeTo(390, 0.5));
    expect(ludoStageHeight(board, slab: 0), closeTo(390, 0.5));
  });
}
