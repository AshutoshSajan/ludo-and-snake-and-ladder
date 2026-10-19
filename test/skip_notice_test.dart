/// The spent-roll explanations ("why did my turn pass with no move?"): the
/// engines keep the spent face and its roller for the UI, and the two
/// notice builders word it so no player reads a passed turn as a swallowed
/// tap or a stolen one.
library;

import 'package:flutter_test/flutter_test.dart';

import 'package:game_club/engine/ludo/ludo_models.dart';
import 'package:game_club/engine/ludo/ludo_rules.dart';
import 'package:game_club/engine/snakes/snakes_engine.dart' as snakes_engine;
import 'package:game_club/ui/shared/table_notice.dart';

void main() {
  group('ludo', () {
    test('a spent roll keeps its face and roller for the UI', () {
      final s = createLudoState([
        LudoPlayer(id: 'r', name: 'Red', color: LudoColor.red),
        LudoPlayer(id: 'g', name: 'Green', color: LudoColor.green),
      ]);
      rollDice(s, 1);
      expect(s.lastEvent, 'skip');
      expect(s.lastRolledValue, 1,
          reason: 'the corner die and the notice read this face');
      expect(s.lastRolledBy, 0, reason: 'red is the seat whose roll was spent');
      expect(ludoSkipNotice(s),
          'Red rolled a 1 — nothing can move; the turn passes');
    });

    test('the notice names the wallet even when the turn has moved on', () {
      final s = createLudoState([
        LudoPlayer(id: 'r', name: 'Red', color: LudoColor.red),
        LudoPlayer(id: 'g', name: 'Green', color: LudoColor.green),
      ]);
      rollDice(s, 3); // skip; the current player is green now
      expect(s.currentPlayer.id, 'g');
      expect(ludoSkipNotice(s), startsWith('Red'),
          reason: 'the speaker is the seat whose roll was spent, not whoever '
              'rolls next');
    });
  });

  group('snakes', () {
    test('names the one rule that can spend a roll', () {
      final s = snakes_engine.createSnakesState([
        snakes_engine.SnakesPlayer(id: 'a', name: 'A', tokenIndex: 0),
        snakes_engine.SnakesPlayer(id: 'b', name: 'B', tokenIndex: 1),
      ]);
      snakes_engine.rollDice(s, 4);
      expect(s.lastEvent, 'skip');
      expect(s.lastRoll, 4,
          reason: 'the die keeps the wasted face so nobody thinks it '
              'misread the roll');
      expect(snakesSkipNotice(s), 'Needs a 1 to enter — the turn passes');
    });
  });
}
