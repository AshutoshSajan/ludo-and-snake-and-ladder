/// Online Snakes & Ladders:
///
/// 1. `SnakesState` JSON roundtrip — the wire format for server snapshots
/// 2. `GameAuthority` with `game: 'snakes'` — a scripted game to completion,
///    including a ladder jump, turn enforcement, snapshot tagging, and
///    leaderboard recording
///
/// (A loopback transport test mirrors `online_server_test.dart`.)
library;

import 'dart:convert';
import 'dart:math';

import 'package:flutter_test/flutter_test.dart';

import 'package:game_club/engine/ludo/ludo_models.dart';
import 'package:game_club/engine/snakes/snakes_engine.dart';
import 'package:game_club/server/game_server.dart';
import 'package:game_club/server/leaderboard_store.dart';

/// Collects the JSON messages a member receives.
class Sink {
  final messages = <Map<String, dynamic>>[];
  void call(String json) =>
      messages.add(jsonDecode(json) as Map<String, dynamic>);
  Iterable<Map<String, dynamic>> get states =>
      messages.where((m) => m['type'] == 'state');
}

ServerMember _member(int seatIndex, String name, Sink sink) => ServerMember(
      id: 's$seatIndex',
      seatId: 's$seatIndex',
      name: name,
      color: LudoColor.values[seatIndex % 4],
      sink: sink.call,
    );

void main() {
  // -------------------------------------------------------- wire format

  group('SnakesState JSON roundtrip', () {
    test('preserves every field the client needs', () {
      final s = createSnakesState([
        SnakesPlayer(id: 'p1', name: 'Ana', tokenIndex: 0),
        SnakesPlayer(id: 'p2', name: 'Bo', tokenIndex: 1),
      ]);
      // A ladder landing has to survive the wire, so land on one — but from ON
      // the board. A pawn at the start can only enter on a 1, so 0 + 4 is no
      // longer a legal way to reach the ladder at 4.
      s.players[0].square = 17;
      rollDice(s, 4);
      applyMove(s); // 17 + 4 = square 21, a ladder up to 42
      final restored = SnakesState.fromJson(s.toJson());

      expect(restored.players.length, 2);
      expect(restored.players[0].id, 'p1');
      expect(restored.players[0].name, 'Ana');
      expect(restored.players[0].tokenIndex, 0);
      expect(restored.players[0].square, 42); // ladder applied
      expect(restored.players[1].square, 0);
      expect(restored.currentPlayerIndex, s.currentPlayerIndex);
      expect(restored.phase, s.phase);
      expect(restored.lastRoll, s.lastRoll);
      expect(restored.lastEvent, s.lastEvent);
      expect(restored.eventFrom, s.eventFrom);
      expect(restored.eventTo, s.eventTo);
      expect(restored.rankings, s.rankings);
    });

    test('game over state survives the wire', () {
      final s = createSnakesState([
        SnakesPlayer(id: 'p1', name: 'Ana', tokenIndex: 0),
        SnakesPlayer(id: 'p2', name: 'Bo', tokenIndex: 1),
      ]);
      s.players[0].square = 95;
      rollDice(s, 5);
      applyMove(s); // exactly 100 -> win
      expect(s.phase, SnakesPhase.gameOver);
      expect(s.rankings, ['p1', 'p2']);

      final restored = SnakesState.fromJson(s.toJson());
      expect(restored.phase, SnakesPhase.gameOver);
      expect(restored.rankings, ['p1', 'p2']);
      expect(restored.players[0].finished, isTrue);
    });
  });

  // ----------------------------------------------- authority (snakes room)

  group('GameAuthority snakes room', () {
    late GameAuthority authority;
    late Sink hostSink, guestSink;

    setUp(() {
      hostSink = Sink();
      guestSink = Sink();
      authority = GameAuthority(
        // Seeded PRNG: varied rolls (a constant roll eventually loops
        // through a snake forever) yet fully deterministic across runs.
        rng: Random(7),
        leaderboard: SqliteLeaderboardStore.inMemory(),
      );
    });

    Room seedRoom() {
      final room = authority.createRoom(
        _member(0, 'Ana', hostSink),
        game: 'snakes',
      );
      authority.joinRoom(room.code, _member(1, 'Bo', guestSink));
      return room;
    }

    test('room is created and tagged with the snakes game type', () {
      final room = seedRoom();
      expect(room.gameType, 'snakes');
    });

    test('scripted game plays to completion via roll/move intents', () async {
      final room = seedRoom();
      final hostSink2 = hostSink;

      // Host starts.
      authority.handleIntent(
          room: room, connectionId: 's0', msg: {'type': 'start'});
      expect(room.started, isTrue);
      expect(room.snakesState, isNotNull);
      expect(room.snakesState!.players.map((p) => p.name), ['Ana', 'Bo']);
      expect(room.snakesState!.players[0].tokenIndex, 0);
      expect(room.snakesState!.players[1].tokenIndex, 1);

      // Play until someone reaches exactly 100 (everyone rolls 3; ladder and
      // snake jumps along the way make the path irregular).
      var rolls = 0;
      while (room.snakesState!.phase != SnakesPhase.gameOver) {
        rolls++;
        expect(rolls, lessThan(500), reason: 'game must terminate');
        final state = room.snakesState!;
        final conn = state.currentPlayer.id; // == seatId == 's0'/'s1'

        // Only the current player's roll is accepted.
        authority.handleIntent(
            room: room, connectionId: conn, msg: {'type': 'roll'});

        // The roll can be spent: a pawn still off the board can only enter on
        // a 1, and the server rolls a real die. Then there is no move to make
        // and the turn has already passed, so the loop goes round again.
        if (state.phase == SnakesPhase.awaitingRoll) continue;

        expect(state.phase, SnakesPhase.awaitingMove);

        // Everyone else's roll is rejected.
        final other = conn == 's0' ? 's1' : 's0';
        final before = state.lastRoll;
        authority.handleIntent(
            room: room, connectionId: other, msg: {'type': 'roll'});
        expect(state.lastRoll, before);

        authority.handleIntent(
            room: room, connectionId: conn, msg: {'type': 'move'});
      }

      final finalState = room.snakesState!;
      expect(finalState.rankings.length, 2); // classic game: everyone ranked
      // Snapshots are tagged with the game type so clients can route them.
      expect(hostSink2.states.last['game'], 'snakes');
      // Leaderboard recorded exactly once for the finished game.
      expect(await authority.leaderboard!.totalGames(), 1);
    });

    test('move applies the engine-computed pending move and broadcasts it', () {
      final room = seedRoom();
      authority.handleIntent(
          room: room, connectionId: 's0', msg: {'type': 'start'});
      final state = room.snakesState!;
      state.players[0].square = 1; // a low square; the roll may hit a jump
      authority.handleIntent(
          room: room, connectionId: 's0', msg: {'type': 'roll'});
      // The server must resolve exactly what the pure engine prescribes —
      // including any ladder/snake jump baked into the pending move.
      final expected = pendingMove(state).to;
      final expectedEvent = pendingMove(state).jump ?? state.lastEvent;
      authority.handleIntent(
          room: room, connectionId: 's0', msg: {'type': 'move'});
      expect(state.players[0].square, expected);
      expect(state.lastEvent, expectedEvent);
      // Both members saw the tagged snapshot.
      expect(guestSink.states.last['game'], 'snakes');
    });
  });
}
