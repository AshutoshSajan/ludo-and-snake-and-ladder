/// The pawn's generous tap box must not move the pawn.
///
/// The tap-target change wrapped each pawn in a `max(48, 1.4*cell)` square so
/// a phone finger can hit a ~20px dot — but it kept subtracting the halves of
/// the DOT size from the box's top-left offset. The pawn then drew low-right
/// of its true cell center: on a desktop a ~14px slide, on a phone ~19px —
/// the pieces read as sitting in the bottom-right corner of every cell they
/// touched, offline and online alike (both render through this layer).
///
/// The pinned rule: the tap box's center is the pawn's anchor center — the
/// pawn art is centered inside the box, so a box centered on its cell keeps
/// the pawn centered on its cell, at every board size.
library;

import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:game_club/engine/ludo/ludo_board.dart';
import 'package:game_club/engine/ludo/ludo_models.dart';
import 'package:game_club/ui/ludo/ludo_board_painter.dart';
import 'package:game_club/ui/ludo/ludo_token_layer.dart';

void main() {
  LudoState midState() => LudoState(
    currentPlayerIndex: 0,
    players: [
      LudoPlayer(id: 'p1', name: 'R', color: LudoColor.red),
      LudoPlayer(id: 'p2', name: 'G', color: LudoColor.green),
    ],
    tokens: [
      // Red: one on a main-track cell, three in the yard.
      LudoToken(color: LudoColor.red, index: 0, pos: 7),
      for (var i = 1; i < 4; i++)
        LudoToken(color: LudoColor.red, index: i, pos: -1),
      // Green: one finished, one in the home column, two in the yard.
      LudoToken(color: LudoColor.green, index: 0, pos: 56),
      LudoToken(color: LudoColor.green, index: 1, pos: 53),
      for (var i = 2; i < 4; i++)
        LudoToken(color: LudoColor.green, index: i, pos: -1),
    ],
  );

  /// Each token's expected anchor center, replicating the layer's grouping:
  /// yard tokens nudge half a cell up-left onto the staging intersections,
  /// finished tokens rest on their color's center-finish cell, and tokens
  /// sharing a cell fan out on a small ring.
  Map<int, Offset> expectedCenters(LudoState s, double boardSize) {
    final cell = boardSize / 15;
    final grouped = <GridPos, List<LudoToken>>{};
    for (final t in s.tokens) {
      final key = t.pos == 56
          ? LudoBoard.finishedCell(t.color)
          : LudoBoard.coordFor(t.color, t.pos, t.index % 4, 1);
      grouped.putIfAbsent(key, () => []).add(t);
    }
    final expected = <int, Offset>{};
    grouped.forEach((cellPos, tokens) {
      for (var i = 0; i < tokens.length; i++) {
        var center = LudoBoardPainter.cellCenter(
          cellPos.row,
          cellPos.col,
          Size.square(boardSize),
        );
        if (tokens[i].pos == -1) center -= Offset(cell * 0.5, cell * 0.5);
        final off = tokens.length == 1
            ? Offset.zero
            : Offset(
                math.cos(2 * math.pi * i / tokens.length) * cell * 0.16,
                math.sin(2 * math.pi * i / tokens.length) * cell * 0.16,
              );
        expected[tokens[i].gid] = center + off;
      }
    });
    return expected;
  }

  Future<void> pumpAt(WidgetTester tester, double side) async {
    final s = midState();
    tester.view.physicalSize = Size(side + 120, side + 240);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        home: Center(
          child: SizedBox.square(
            dimension: side,
            child: LudoTokenLayer(
              state: s,
              boardSize: side,
              movableTokenIndices: const <int>{},
              onTapToken: (_) {},
              anim: null,
              animStep: 0,
              currentPlayerIndex: 0,
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.pump();

    final hit = LudoTokenLayer.hitTargetFor(side / 15);
    final expected = expectedCenters(s, side);
    for (final p in tester.widgetList<AnimatedPositioned>(
      find.byType(AnimatedPositioned),
    )) {
      final gid = int.parse((p.key! as ValueKey<String>).value.split('-').last);
      final drawnCenter = Offset(p.left! + hit / 2, p.top! + hit / 2);
      expect(
        drawnCenter,
        expected[gid]!,
        reason:
            'token gid $gid draws exactly on its cell anchor — a '
            'box-offset mismatch here is the pawn drifting toward the '
            'bottom-right of its cell',
      );
    }
  }

  testWidgets(
    'a phone-small board keeps pawns on their cells',
    (tester) => pumpAt(tester, 300),
  );
  testWidgets(
    'a desktop board keeps pawns on their cells',
    (tester) => pumpAt(tester, 700),
  );
}
