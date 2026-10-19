/// The turn timer: the engine's `passTurn` for both boards, and the
/// authoritative enforcement — a seat that stops answering its clock gets
/// skipped turn by turn, and after five consecutive missed turns is taken
/// off the table exactly like a walk-out.
library;

import 'dart:convert';
import 'dart:math';

import 'package:flutter_test/flutter_test.dart';

import 'package:game_club/engine/ludo/ludo_models.dart';
import 'package:game_club/engine/ludo/ludo_rules.dart' as ludo;
import 'package:game_club/engine/snakes/snakes_engine.dart' as snakes_engine;
import 'package:game_club/server/game_server.dart';

ServerMember _member(LudoColor c, {required String id, required on}) =>
    ServerMember(
      id: id,
      seatId: c.name,
      name: c.label,
      color: c,
      sink: on,
    );

/// The message types a fake socket was handed, in the order they arrived.
List<String> _sentTypes(List<String> log) => [
  for (final j in log)
    (jsonDecode(j) as Map<String, dynamic>)['type'] as String,
];

/// The last payload of [type] a fake socket was handed, or null.
Map<String, dynamic>? _lastSent(List<String> log, String type) {
  for (var i = log.length - 1; i >= 0; i--) {
    final m = jsonDecode(log[i]) as Map<String, dynamic>;
    if (m['type'] == type) return m;
  }
  return null;
}

/// One seat out of a `seats` payload, by seat id.
Map<String, dynamic>? _seatIn(Map<String, dynamic>? seatsFeed, String seatId) {
  if (seatsFeed == null) return null;
  for (final s in (seatsFeed['seats'] as List).cast<Map<String, dynamic>>()) {
    if (s['seatId'] == seatId) return s;
  }
  return null;
}

void main() {
  group('engine: passTurn', () {
    test('drops a pending roll, resets the sixes streak, and moves on', () {
      final s = ludo.createLudoState([
        LudoPlayer(id: 'a', name: 'Ana', color: LudoColor.red),
        LudoPlayer(id: 'b', name: 'Boo', color: LudoColor.green),
      ]);
      ludo.rollDice(s, 6); // sixes streak at 1, awaiting move
      expect(s.consecutiveSixes, 1);
      expect(s.phase, LudoPhase.awaitingMove);

      ludo.passTurn(s);
      expect(s.lastEvent, 'timeout',
          reason: 'the seat will read why the turn burned');
      expect(s.lastRoll, isNull, reason: 'an unanswered roll is dropped');
      expect(s.consecutiveSixes, 0,
          reason: 'a pass is not part of a sixes streak');
      expect(s.currentPlayer.id, 'b');
      expect(s.phase, LudoPhase.awaitingRoll);
    });

    test('a pass lands on the next unfinished player in order', () {
      final s = ludo.createLudoState([
        LudoPlayer(id: 'a', name: 'A', color: LudoColor.red),
        LudoPlayer(id: 'b', name: 'B', color: LudoColor.green),
        LudoPlayer(id: 'c', name: 'C', color: LudoColor.yellow),
      ]);
      expect(s.currentPlayer.id, 'a');
      ludo.passTurn(s);
      expect(s.currentPlayer.id, 'b');
      ludo.passTurn(s);
      expect(s.currentPlayer.id, 'c');
    });

    test('snakes: burns the move the seat never confirmed', () {
      final s = snakes_engine.createSnakesState([
        snakes_engine.SnakesPlayer(id: 'a', name: 'A', tokenIndex: 0),
        snakes_engine.SnakesPlayer(id: 'b', name: 'B', tokenIndex: 1),
      ]);
      snakes_engine.rollDice(s, 1); // square 0 needs a 1 to enter — one always exists
      expect(s.phase, snakes_engine.SnakesPhase.awaitingMove);
      snakes_engine.passTurn(s);
      expect(s.lastEvent, 'timeout');
      expect(s.lastRoll, isNull);
      expect(s.currentPlayer.id, 'b');
      expect(s.phase, snakes_engine.SnakesPhase.awaitingRoll);
    });
  });

  group('authority: the turn timer', () {
    GameAuthority timerAuth() => GameAuthority(
          rng: Random(9),
          turnTimer: const Duration(milliseconds: 80),
        );

    /// A two-player room mid-game, with red's turn live.
    (GameAuthority, Room) startedRoom() {
      final auth = timerAuth();
      final room = auth.createRoom(
        _member(LudoColor.red, id: 'c1', on: (_) {}),
      );
      auth.joinRoom(room.code, _member(LudoColor.green, id: 'c2', on: (_) {}));
      auth.handleIntent(room: room, connectionId: 'c1', msg: {'type': 'start'});
      return (auth, room);
    }

    test('a timed-out seat is skipped, and every clock hears about it',
        () async {
      final (auth, room) = startedRoom();
      final log = <String>[];
      // A watcher keeps receiving the wall even with the seat silent — the
      // countdown badge and the miss chip must reach bystanders too.
      auth.spectateRoom(
        room.code,
        _member(LudoColor.blue, id: 'c3', on: log.add),
      );
      expect(room.stateOrNull!.currentPlayer.id, 'red');

      await Future<void>.delayed(const Duration(milliseconds: 140));

      final s = room.stateOrNull!;
      expect(
        s.currentPlayer.id,
        'green',
        reason: 'the silent seat lost the turn it never used',
      );
      expect(s.lastEvent, 'timeout');
      expect(room.missedTurns['red'], 1);
      expect(_sentTypes(log), contains('turnMissed'));

      final timer = _lastSent(log, 'turnTimer')!;
      expect(
        (timer['turnMs'] as num?)?.toInt(),
        isPositive,
        reason: 'the next countdown ships when the seat below it is armed',
      );
    });

    test('acting on your own turn resets the streak', () async {
      final (auth, room) = startedRoom();
      // Red misses once (~80ms in), then green misses (~160ms), and the
      // turn is back with red — every seat's clock has spoken once.
      for (var i = 0;
          i < 60 && !room.missedTurns.containsKey('green');
          i++) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
      expect(room.missedTurns['red'], 1);
      expect(room.missedTurns['green'], 1);

      // Red answers, in time: the miss streak clears. One proven lapse does
      // not carry — five *consecutive* silent turns is the bar.
      auth.handleIntent(room: room, connectionId: 'c1', msg: {'type': 'roll'});
      expect(room.missedTurns.containsKey('red'), isFalse);

      // Red goes silent again: the streak restarts from zero — the record
      // eventually shows exactly one fresh miss.
      for (var i = 0; i < 60 && !room.missedTurns.containsKey('red'); i++) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
      expect(room.missedTurns['red'], 1);
    });

    test('five missed turns in a row take the seat off the table', () async {
      final (auth, room) = startedRoom();
      // Red never answers; green plays briskly enough to keep its own clock.
      for (var i = 0; i < 24 && room.stateOrNull!.phase != LudoPhase.gameOver; i++) {
        final s = room.stateOrNull!;
        if (s.currentPlayer.id == 'green') {
          auth.handleIntent(room: room, connectionId: 'c2', msg: {'type': 'roll'});
          if (room.stateOrNull!.phase == LudoPhase.awaitingMove) {
            final legal = ludo.legalMoves(room.stateOrNull!);
            if (legal.isNotEmpty) {
              auth.handleIntent(
                room: room,
                connectionId: 'c2',
                msg: {'type': 'move', 'token': legal.first.tokenIndex},
              );
            }
          }
        }
        if (room.missedTurns['red'] == 5) break;
        await Future<void>.delayed(const Duration(milliseconds: 40));
      }
      // Five misses -> forfeit -> a two-player game ends, survivor first.
      expect(room.forfeited, contains('red'));
      expect(room.leftSeats.map((l) => l.seatId), contains('red'));
      final s = room.stateOrNull!;
      expect(s.phase, LudoPhase.gameOver);
      expect(s.rankings.first, 'green',
          reason: 'the silent seat ranks last, the survivor wins');
    });

    test('the eviction announcement names the seat, not just the face', () async {
      final (auth, room) = startedRoom();
      final log = <String>[];
      // A bystander sees the wall exactly as it goes out: seat id riding
      // the left frame is what lets a client know the removal happened to
      // ITS OWN seat and exit the table with the notice instead of staring
      // at a game that dropped it.
      auth.spectateRoom(
        room.code,
        _member(LudoColor.blue, id: 'c4', on: log.add),
      );
      for (var i = 0; i < 24 && !room.forfeited.contains('red'); i++) {
        final state = room.stateOrNull!;
        if (state.currentPlayer.id == 'green') {
          auth.handleIntent(room: room, connectionId: 'c2', msg: {'type': 'roll'});
          if (room.stateOrNull!.phase == LudoPhase.awaitingMove) {
            final legal = ludo.legalMoves(room.stateOrNull!);
            if (legal.isNotEmpty) {
              auth.handleIntent(
                room: room,
                connectionId: 'c2',
                msg: {'type': 'move', 'token': legal.first.tokenIndex},
              );
            }
          }
        }
        await Future<void>.delayed(const Duration(milliseconds: 40));
      }
      final left = _lastSent(log, 'left')!;
      expect(left['reason'], 'timeout');
      expect(left['name'], 'Red');
      expect(left['seatId'], 'red',
          reason: 'no seat id means every client evicted is news about '
              'somebody else — the removed seat keeps sitting at an empty '
              'game that already crowned its winner');
    });

    test('the evicted seat itself is told while it is still a member',
        () async {
      final victim = <String>[];
      final auth = timerAuth();
      final room = auth.createRoom(
        _member(LudoColor.red, id: 'c1', on: victim.add),
      );
      auth.joinRoom(room.code, _member(LudoColor.green, id: 'c2', on: (_) {}));
      auth.handleIntent(room: room, connectionId: 'c1', msg: {'type': 'start'});

      // Green answers its clock; red answers nothing and misses its way
      // out — the playtest round where the losing seat sat on a live board
      // (its roll asked for, clock at zero) because the forfeit frames
      // only ever went to the seat that remained.
      for (var i = 0; i < 24 && !room.forfeited.contains('red'); i++) {
        if (room.stateOrNull!.currentPlayer.id == 'green') {
          auth.handleIntent(room: room, connectionId: 'c2', msg: {'type': 'roll'});
          if (room.stateOrNull!.phase == LudoPhase.awaitingMove) {
            final legal = ludo.legalMoves(room.stateOrNull!);
            if (legal.isNotEmpty) {
              auth.handleIntent(
                room: room,
                connectionId: 'c2',
                msg: {'type': 'move', 'token': legal.first.tokenIndex},
              );
            }
          }
        }
        await Future<void>.delayed(const Duration(milliseconds: 40));
      }

      final left = _lastSent(victim, 'left');
      expect(left, isNotNull,
          reason: 'the forfeit takes the seat off the roster, and no '
              'broadcast reaches a seat that is not on one — the eviction '
              'is news only its own socket can deliver');
      expect(left!['seatId'], 'red');
      expect(left['reason'], 'timeout');
      expect(_sentTypes(victim).last, 'left',
          reason: "the last frame the frozen board receives is the one "
              "that ends it");
    });

    test(
      'a third seat keeps playing after the eviction',
      () async {
        final auth = timerAuth();
        final room = auth.createRoom(_member(LudoColor.red, id: 'c1', on: (_) {}));
        auth.joinRoom(room.code, _member(LudoColor.green, id: 'c2', on: (_) {}));
        auth.joinRoom(room.code, _member(LudoColor.yellow, id: 'c3', on: (_) {}));
        auth.handleIntent(room: room, connectionId: 'c1', msg: {'type': 'start'});
        expect(room.stateOrNull!.players.length, 3);

        // Act for whoever is on turn at 10ms granularity so green and yellow
        // never meet their own 80ms deadline; red answers nothing and racks
        // up misses at one per cycle.
        final connFor = {'green': 'c2', 'yellow': 'c3'};
        for (var i = 0; i < 300 && !room.forfeited.contains('red'); i++) {
          final s = room.stateOrNull!;
          final conn = connFor[s.currentPlayer.id];
          if (conn != null) {
            auth.handleIntent(room: room, connectionId: conn, msg: {'type': 'roll'});
            if (room.stateOrNull!.phase == LudoPhase.awaitingMove) {
              final legal = ludo.legalMoves(room.stateOrNull!);
              if (legal.isNotEmpty) {
                auth.handleIntent(
                  room: room,
                  connectionId: conn,
                  msg: {'type': 'move', 'token': legal.first.tokenIndex},
                );
              }
            }
          }
          await Future<void>.delayed(const Duration(milliseconds: 10));
        }

        expect(room.forfeited, contains('red'));
        final s = room.stateOrNull!;
        expect(s.phase, isNot(LudoPhase.gameOver),
            reason: 'green and yellow keep playing rather than the game ending');
        expect(s.players.map((p) => p.id), isNot(contains('red')),
            reason: "the evicted seat's pawns are off the board");
        expect(connFor.keys, contains(s.currentPlayer.id),
            reason: 'turns keep moving between the two seats that remained');
      },
    );

    test('an autoplay seat never meets its clock', () async {
      final auth = GameAuthority(
        rng: Random(21),
        turnTimer: const Duration(milliseconds: 80),
        autoStepDelay: const Duration(milliseconds: 200),
      );
      final room = auth.createRoom(_member(LudoColor.red, id: 'c1', on: (_) {}));
      auth.joinRoom(room.code, _member(LudoColor.green, id: 'c2', on: (_) {}));
      auth.handleIntent(room: room, connectionId: 'c1', msg: {'type': 'start'});
      auth.handleIntent(room: room, connectionId: 'c1', msg: {'type': 'autoplay', 'on': true});
      auth.handleIntent(room: room, connectionId: 'c2', msg: {'type': 'autoplay', 'on': true});
      // Both seats handed over: no countdown and no misses, even though the
      // driver is slower than the timer — a driven seat is never a stalled one.
      for (var i = 0; i < 40; i++) {
        expect(room.turnDeadline, isNull,
            reason: 'no countdown badge on a seat the table drives');
        expect(room.missedTurns, isEmpty);
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
    });

    test('an emptied room holds still instead of missing nobody', () async {
      final (auth, room) = startedRoom();
      auth.leaveRoom(room.code, 'c1');
      auth.leaveRoom(room.code, 'c2');
      expect(room.turnDeadline, isNull,
          reason: 'no timer against an absent table');
      expect(room.turnTimer, isNull);
    });
  });

  group('wire: timer fields travel to clients', () {
    test('a fresh countdown reaches the table as its own message', () async {
      final log = <String>[];
      final auth = GameAuthority(
        rng: Random(5),
        turnTimer: const Duration(milliseconds: 80),
      );
      final room = auth.createRoom(
        _member(LudoColor.red, id: 'c1', on: log.add),
      );
      auth.joinRoom(room.code, _member(LudoColor.green, id: 'c2', on: log.add));
      auth.handleIntent(room: room, connectionId: 'c1', msg: {'type': 'start'});
      // The start broadcast gestured before arming, so the visible countdown
      // ships separately — the client chip depends on this one.
      final timer = _lastSent(log, 'turnTimer')!;
      expect(timer['seatId'], 'red');
      final ms = (timer['turnMs'] as num?)?.toInt();
      expect(ms, inInclusiveRange(1, 80),
          reason: 'the deadline ships as milliseconds from arm time');
    });

    test('the seats feed shows the miss count of the silent seat', () async {
      final log = <String>[];
      final auth = GameAuthority(
        rng: Random(7),
        turnTimer: const Duration(milliseconds: 80),
      );
      final room = auth.createRoom(
        _member(LudoColor.red, id: 'c1', on: log.add),
      );
      auth.joinRoom(room.code, _member(LudoColor.green, id: 'c2', on: log.add));
      auth.handleIntent(room: room, connectionId: 'c1', msg: {'type': 'start'});
      await Future<void>.delayed(const Duration(milliseconds: 140));

      final feed = _lastSent(log, 'seats')!;
      final red = _seatIn(feed, 'red')!;
      expect(red['misses'], 1);
      final green = _seatIn(feed, 'green')!;
      expect(green['misses'], isNull,
          reason: 'a clean seat carries no miss field at all');
    });
  });
}
