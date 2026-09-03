import 'package:flutter_test/flutter_test.dart';
import 'package:game_club/engine/ludo/ludo_board.dart';
import 'package:game_club/engine/ludo/ludo_models.dart';
import 'package:game_club/engine/ludo/ludo_rules.dart';

LudoPlayer _p(LudoColor c, {bool ai = false}) => LudoPlayer(
      id: 'id-${c.name}',
      name: c.label,
      color: c,
      isAI: ai,
    );

LudoState _state({int players = 4}) {
  final colors = LudoBoard.colorOrder.take(players).toList();
  return createLudoState([for (final c in colors) _p(c)]);
}

void main() {
  group('initial state', () {
    test('creates 4 players x 4 tokens, all in base, red starts', () {
      final s = _state();
      expect(s.players.length, 4);
      expect(s.tokens.length, 16);
      expect(s.tokens.every((t) => t.inBase), isTrue);
      expect(s.currentPlayer.color, LudoColor.red);
      expect(s.phase, LudoPhase.awaitingRoll);
    });

    test('supports 2 and 3 players', () {
      expect(_state(players: 2).tokens.length, 8);
      expect(_state(players: 3).tokens.length, 12);
    });
  });

  group('rolling and entering the board', () {
    test('non-6 with all tokens in base skips the turn', () {
      final s = _state();
      rollDice(s, 3);
      expect(s.lastEvent, 'skip');
      expect(s.currentPlayer.color, LudoColor.green);
      expect(s.phase, LudoPhase.awaitingRoll);
    });

    test('6 lets a token leave base, grants extra roll', () {
      final s = _state();
      rollDice(s, 6);
      expect(s.phase, LudoPhase.awaitingMove);
      final moves = legalMoves(s);
      expect(moves.length, 4);
      expect(moves.every((m) => m.from == -1 && m.to == 0), isTrue);
      expect(applyMove(s, 0), isNull);
      expect(s.tokensOf(0).first.pos, 0);
      expect(s.phase, LudoPhase.awaitingRoll);
      expect(s.currentPlayer.color, LudoColor.red);
      expect(s.extraRoll, isTrue);
    });

    test('token moves along its own track perspective', () {
      final s = _state();
      s.tokensOf(0).first.pos = 5;
      rollDice(s, 4);
      applyMove(s, 0);
      expect(s.tokensOf(0).first.pos, 9);
      // Red at r=9 -> abs track cell (42+9)%52 = 51 = (8, 1).
      expect(LudoBoard.coordFor(LudoColor.red, 9, 0, 1), const GridPos(8, 1));
      expect(s.currentPlayer.color, LudoColor.green);
    });

    test('three consecutive sixes forfeit the turn', () {
      final s = _state();
      rollDice(s, 6);
      applyMove(s, 0);
      rollDice(s, 6);
      applyMove(s, 1);
      rollDice(s, 6);
      expect(s.lastEvent, 'tripleSix');
      expect(s.currentPlayer.color, LudoColor.green);
    });
  });


  group('captures and safe cells', () {
    test('landing on an enemy token captures it, grants extra roll', () {
      final s = _state();
      // Green sits on abs 47 -> green r = (47 - 3) % 52 = 44.
      s.tokensOf(1)[0].pos = 44;
      // Red at r=2, roll 3 -> lands abs 47 where green sits.
      s.tokensOf(0)[0].pos = 2;
      rollDice(s, 3);
      final captured = applyMove(s, 0);
      expect(captured, 1 * 4 + 0);
      expect(s.tokensOf(1)[0].inBase, isTrue);
      expect(s.lastEvent, 'capture');
      expect(s.extraRoll, isTrue);
      expect(s.currentPlayer.color, LudoColor.red);
    });

    test('no capture on star cells', () {
      final s = _state();
      s.tokensOf(0)[0].pos = 5; // roll 3 -> abs 8 (star)
      s.tokensOf(1)[0].pos = 47; // green on abs 8
      rollDice(s, 3);
      expect(applyMove(s, 0), isNull);
      expect(s.tokensOf(1)[0].pos, 47);
    });

    test('own start cell is safe from capture', () {
      final s = _state();
      s.tokensOf(1)[0].pos = 0; // green on abs 3 (its start, safe)
      s.tokensOf(0)[0].pos = 13;
      rollDice(s, 2);
      expect(applyMove(s, 0), isNull);
      expect(s.tokensOf(1)[0].pos, 0);
    });
  });

  group('blocks', () {
    test('enemy block cannot be landed on or passed', () {
      final s = _state();
      s.tokensOf(1)[0].pos = 42; // block on abs 45
      s.tokensOf(1)[1].pos = 42;
      s.tokensOf(0)[0].pos = 2; // roll 5 passes abs 45
      rollDice(s, 5);
      expect(legalMoves(s), isEmpty);
      expect(s.lastEvent, 'skip');
    });

    test('single enemy token can be passed over', () {
      final s = _state();
      s.tokensOf(1)[0].pos = 42; // single enemy on abs 45
      s.tokensOf(0)[0].pos = 2;
      rollDice(s, 5);
      expect(legalMoves(s).map((m) => m.tokenIndex), contains(0));
    });
  });

  group('home column and exact finish', () {
    test('token enters home column after 51 steps', () {
      final s = _state();
      final t = s.tokensOf(0).first;
      t.pos = 50;
      rollDice(s, 1);
      applyMove(s, 0);
      expect(t.pos, 51);
      expect(t.inHomeColumn, isTrue);
    });

    test('overshooting home is illegal', () {
      final s = _state();
      s.tokensOf(0).first.pos = 54;
      rollDice(s, 3);
      expect(legalMoves(s).any((m) => m.tokenIndex == 0), isFalse);
    });

    test('exact roll finishes a token at home', () {
      final s = _state();
      s.tokensOf(0).first.pos = 54;
      rollDice(s, 2);
      applyMove(s, 0);
      expect(s.tokensOf(0).first.isHome, isTrue);
      expect(s.lastEvent, 'home');
      expect(s.extraRoll, isTrue);
    });
  });

  group('winning', () {
    test('final token home finishes player; 2 players -> game over', () {
      final s = _state(players: 2);
      s.currentPlayerIndex = 1;
      for (var i = 0; i < 4; i++) {
        s.tokensOf(1)[i].pos = i == 0 ? 55 : 56;
      }
      rollDice(s, 1);
      applyMove(s, 0);
      expect(s.players[1].finished, isTrue);
      expect(s.rankings.first, 'id-green');
      expect(s.phase, LudoPhase.gameOver);
      expect(s.rankings, ['id-green', 'id-red']);
    });
  });

  group('board geometry', () {
    test('track has 52 cells; color starts are safe', () {
      expect(LudoBoard.track.length, 52);
      for (final c in LudoColor.values) {
        expect(LudoBoard.safeCells.contains(LudoBoard.startIndex[c]!), isTrue);
      }
    });

    test('coordFor maps base, track, home column, center', () {
      expect(LudoBoard.coordFor(LudoColor.red, -1, 0, 4), const GridPos(11, 2));
      expect(LudoBoard.coordFor(LudoColor.red, 0, 0, 1), const GridPos(13, 6));
      expect(LudoBoard.coordFor(LudoColor.red, 51, 0, 1), const GridPos(13, 7));
      expect(LudoBoard.coordFor(LudoColor.red, 55, 0, 1), const GridPos(9, 7));
      expect(LudoBoard.coordFor(LudoColor.red, 56, 0, 1), LudoBoard.center);
    });

    test('home columns point inward for every color', () {
      expect(LudoBoard.coordFor(LudoColor.green, 51, 0, 1), const GridPos(7, 1));
      expect(
          LudoBoard.coordFor(LudoColor.yellow, 51, 0, 1), const GridPos(1, 7));
      expect(LudoBoard.coordFor(LudoColor.blue, 51, 0, 1), const GridPos(7, 13));
    });
  });
}
