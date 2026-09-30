import 'package:flutter_test/flutter_test.dart';
import 'package:game_club/engine/snakes/snakes_engine.dart';

SnakesPlayer _p(String id, int tokenIndex, {bool ai = false}) =>
    SnakesPlayer(id: id, name: id, tokenIndex: tokenIndex, isAI: ai);

void main() {
  group('setup', () {
    test('supports 2..10 players', () {
      expect(createSnakesState([_p('a', 0), _p('b', 1)]).players.length, 2);
      expect(
        createSnakesState(
          [for (var i = 0; i < 10; i++) _p('p$i', i)],
        ).players.length,
        10,
      );
    });
  });

  group('entering the board', () {
    // Classic rules: a pawn off the board comes in on a 1, landing on square 1.
    // Without this, pendingMove's `square + roll` moved a starting pawn to
    // whatever was rolled, so a 5 opened the game with a player on square 5.

    test('a pawn off the board cannot enter on a 5', () {
      final s = createSnakesState([_p('a', 0), _p('b', 1)]);
      rollDice(s, 5);
      expect(s.players[0].square, 0,
          reason: 'a starting pawn must wait, not jump to the rolled square');
    });

    test('a wasted roll passes the turn without an awaitingMove phase', () {
      final s = createSnakesState([_p('a', 0), _p('b', 1)]);
      rollDice(s, 4);
      expect(s.phase, SnakesPhase.awaitingRoll,
          reason: 'nothing to animate, so no move phase to resolve');
      expect(s.currentPlayerIndex, 1, reason: 'the turn is spent');
      expect(s.lastEvent, 'skip');
    });

    test('every non-1 roll is refused at the start', () {
      for (var v = 2; v <= 6; v++) {
        final s = createSnakesState([_p('a', 0), _p('b', 1)]);
        rollDice(s, v);
        expect(s.players[0].square, 0, reason: 'rolled $v');
      }
    });

    test('a 1 brings the pawn in, and the ladder at 1 takes it to 38', () {
      final s = createSnakesState([_p('a', 0), _p('b', 1)]);
      rollDice(s, 1);
      expect(s.phase, SnakesPhase.awaitingMove);
      final mv = pendingMove(s);
      // Square 1 is the foot of the 1->38 ladder on this board, so entering is
      // dramatic. That is the real game, not a bug.
      expect(mv.jump, 'ladder');
      expect(mv.to, 38);
      applyMove(s);
      expect(s.players[0].square, 38);
    });

    test('the die keeps showing the roll that did nothing', () {
      // _endTurn clears lastRoll; the die is the only evidence a roll happened,
      // so a blank die would leave the player with no idea why nothing moved.
      final s = createSnakesState([_p('a', 0), _p('b', 1)]);
      rollDice(s, 3);
      expect(s.lastRoll, 3);
    });

    test('once on the board, any roll moves the pawn normally', () {
      // The rule is about the start square only, not a gate on every turn.
      final s = createSnakesState([_p('a', 0), _p('b', 1)]);
      s.players[0].square = 5;
      rollDice(s, 3);
      expect(s.phase, SnakesPhase.awaitingMove);
      applyMove(s);
      expect(s.players[0].square, 8);
    });

    test('a second player still at the start is refused independently', () {
      final s = createSnakesState([_p('a', 0), _p('b', 1)]);
      rollDice(s, 1); // a enters
      applyMove(s);
      expect(s.currentPlayerIndex, 1);
      rollDice(s, 6); // b cannot enter
      expect(s.players[1].square, 0);
    });
  });

  group('movement', () {
    test('plain roll moves the pawn and passes the turn', () {
      final s = createSnakesState([_p('a', 0), _p('b', 1)]);
      s.players[0].square = 10;
      rollDice(s, 3);
      expect(s.phase, SnakesPhase.awaitingMove);
      final mv = pendingMove(s);
      expect(mv.from, 10);
      expect(mv.to, 13);
      expect(mv.jump, isNull);
      applyMove(s);
      expect(s.players[0].square, 13);
      expect(s.currentPlayer.id, 'b');
      expect(s.phase, SnakesPhase.awaitingRoll);
    });

    test('ladder lifts the pawn', () {
      final s = createSnakesState([_p('a', 0), _p('b', 1)]);
      s.players[0].square = 0;
      rollDice(s, 1); // 0+1 = 1 -> ladder to 38
      final mv = pendingMove(s);
      expect(mv.to, 38);
      expect(mv.jump, 'ladder');
      applyMove(s);
      expect(s.players[0].square, 38);
      expect(s.lastEvent, 'ladder');
    });

    test('snake bites the pawn down', () {
      final s = createSnakesState([_p('a', 0), _p('b', 1)]);
      s.players[0].square = 13;
      rollDice(s, 3); // 13+3 = 16 -> snake to 6
      final mv = pendingMove(s);
      expect(mv.to, 6);
      expect(mv.jump, 'snake');
      applyMove(s);
      expect(s.players[0].square, 6);
      expect(s.lastEvent, 'snake');
    });

    test('overshooting 100 bounces back', () {
      final s = createSnakesState([_p('a', 0), _p('b', 1)]);
      s.players[0].square = 99;
      rollDice(s, 5); // 99+5 = 104 -> 100 - 4 = 96
      final mv = pendingMove(s);
      expect(mv.to, 96);
      applyMove(s);
      expect(s.players[0].square, 96);
      expect(s.phase, SnakesPhase.awaitingRoll); // not a win
    });
  });

  group('winning', () {
    test('exact landing on 100 wins and ends the game', () {
      final s = createSnakesState(
        [_p('a', 0), _p('b', 1), _p('c', 2)],
      );
      s.players[0].square = 80;
      rollDice(s, 5); // 80+5=85? -> ladder 80 -> 100 requires landing ON 80.
      // Instead: use square 95 with roll 5 -> 100... 95 is a snake head only
      // when landing ON it. From 95, 95+5 = 100 exactly.
      s.players[0].square = 95;
      rollDice(s, 5);
      final mv = pendingMove(s);
      expect(mv.to, 100);
      applyMove(s);
      expect(s.players[0].finished, isTrue);
      expect(s.phase, SnakesPhase.gameOver);
      expect(s.rankings.first, 'a');
      expect(s.rankings.length, 3); // everyone ranked by square
    });

     test('rankings order by final square', () {
      final s = createSnakesState([_p('a', 0), _p('b', 1)]);
      s.players[0].square = 95; // a will finish with 5
      s.players[1].square = 70; // b stays behind
      rollDice(s, 5);
      applyMove(s);
      expect(s.rankings, ['a', 'b']);
    });
  });

  group('turn rotation', () {
    test('turns cycle through all 10 players', () {
      final s = createSnakesState([for (var i = 0; i < 10; i++) _p('p$i', i)]);
      // Everyone starts on the board, not at square 0. This test is about
      // rotation; left at the start, every roll but a 1 is a spent turn that
      // never reaches a move, which would test the entry rule instead — and
      // fail whenever that rule is retuned.
      for (final p in s.players) {
        p.square = 10;
      }
      for (var i = 0; i < 10; i++) {
        expect(s.currentPlayer.id, 'p$i');
        rollDice(s, 2);
        applyMove(s);
      }
      expect(s.currentPlayer.id, 'p0'); // wrapped around
    });

    test('a spent roll at the start still rotates the turn', () {
      // The skip path advances the turn itself, so a table of players still at
      // the start cannot deadlock on a player who keeps rolling non-1s.
      final s = createSnakesState([for (var i = 0; i < 3; i++) _p('p$i', i)]);
      for (var i = 0; i < 3; i++) {
        rollDice(s, 5);
        expect(s.currentPlayerIndex, (i + 1) % 3);
      }
    });
  });
}
