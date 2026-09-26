/// Authoritative online game server for Ludo.
///
/// Rooms are keyed by a 4-letter code. The server owns the dice and the
/// single game state; clients only send *intents* ('roll', 'move') which
/// are validated with the pure-Dart engine in `lib/engine/` before being
/// applied. Every applied action is broadcast to all room members as a
/// state snapshot, so clients stay dumb and cannot cheat.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io' show stderr;
import 'dart:math';

import '../engine/ludo/ludo_board.dart';
import '../engine/ludo/ludo_models.dart';
import '../engine/ludo/ludo_rules.dart';
import '../engine/snakes/snakes_engine.dart' as snakes;
import 'leaderboard_store.dart';

/// One connected participant.
class ServerMember {
  ServerMember({
    required this.id,
    required this.seatId,
    required this.name,
    required this.color,
    required this.sink,
  });

  /// Server-assigned connection id (changes on reconnect).
  final String id;

  /// Profile id — stable across reconnects; dedupes seats.
  final String seatId;
  String name;
  LudoColor color; // reassigned by the authority when a corner is unavailable
  final void Function(String json) sink; // send-to-client callback
}

/// A waiting/running game.
class Room {
  Room(this.code, {required this.rng, this.gameType = 'ludo'});

  final String code;
  final Random rng;

  /// Which game this room plays: 'ludo' or 'snakes'. Chosen by the host at
  /// room creation; joiners inherit it. Seats stay corner-color based, so
  /// both games currently seat up to 4 players.
  final String gameType;

  /// Built once at [start] from the seated members; never touched before.
  /// A [LudoState] for ludo rooms, a [snakes.SnakesState] for snakes rooms.
  late Object game;

  final Map<String, ServerMember> members = {}; // by connection id

  /// Persistent seat claims: seatId -> color. Survives disconnects so a
  /// returning player reclaims their exact seat, even mid-game.
  final Map<String, LudoColor> seatRegistry = {};

  /// Read-only watchers by connection id. They receive every broadcast but
  /// can never act, claim a seat, or count toward [full].
  final Map<String, ServerMember> spectators = {};

  /// Cancelled when someone (re)joins; fires only while the room sits empty.
  Timer? abandonTimer;

  /// Unique id for the current game — the leaderboard's dedupe key.
  String? gameId;

  /// Set once the results of [gameId] have been persisted.
  bool resultsRecorded = false;

  bool started = false;
  bool removed = false;

  bool get full => members.length >= 4;

  /// Clockwise turn order is enforced by re-sorting members into
  /// colorOrder before start.
  List<ServerMember> get orderedMembers {
    final order = LudoBoard.colorOrder;
    return [...members.values]..sort(
        (a, b) => order.indexOf(a.color).compareTo(order.indexOf(b.color)));
  }

  ServerMember? ownerOf(LudoColor color) {
    for (final m in members.values) {
      if (m.color == color) return m;
    }
    return null;
  }

  /// Build the game state from seated members (called once at start).
  void start() {
    if (gameType == 'snakes') {
      game = snakes.createSnakesState([
        for (final m in orderedMembers)
          snakes.SnakesPlayer(
            id: m.seatId,
            name: m.name,
            // Pawn palette slot derived from the corner seat color.
            tokenIndex: LudoBoard.colorOrder.indexOf(m.color),
          ),
      ]);
    } else {
      game = createLudoState([
        for (final m in orderedMembers)
          LudoPlayer(
            id: m.seatId,
            name: m.name,
            color: m.color,
          ),
      ]);
    }
    // One id per game: the store dedupes on (gameId, seatId), so a botched
    // double-completion cannot inflate a player's stats.
    gameId = '${DateTime.now().microsecondsSinceEpoch}-$code';
    resultsRecorded = false;
    started = true;
  }

  void broadcast(Map<String, dynamic> message) {
    final json = jsonEncode(message);
    for (final m in [...members.values, ...spectators.values]) {
      try {
        m.sink(json);
      } catch (_) {
        // A dead connection is pruned by the transport layer.
      }
    }
  }

  void broadcastState() => broadcast({
        'type': 'state',
        'game': gameType,
        'state': stateJson(),
      });

  /// The serialized game state for the wire (see [broadcastState]).
  Map<String, dynamic> stateJson() => switch (game) {
        LudoState s => s.toJson(),
        snakes.SnakesState s => s.toJson(),
        _ => throw StateError('room game not started'),
      };

  /// The ludo state, or null before [start] (or in a snakes room). Keeps
  /// intent handling from touching the [late] field too early.
  LudoState? get stateOrNull =>
      gameType == 'ludo' && started ? game as LudoState : null;

  /// The ludo state (rooms created before snakes support used this name).
  LudoState get state => game as LudoState;

  /// The snakes state, or null before [start] (or in a ludo room).
  snakes.SnakesState? get snakesState =>
      gameType == 'snakes' && started ? game as snakes.SnakesState : null;
}

/// Server-side game logic shared by the transport layer (websockets) and
/// tests (direct function calls).
class GameAuthority {
  GameAuthority({
    Random? rng,
    this.emptyRoomGrace = const Duration(minutes: 5),
    this.leaderboard,
    this.onRoomClosed,
  }) : rng = rng ?? Random.secure();

  final Random rng;

  /// How long a started room with no connected members stays recoverable.
  final Duration emptyRoomGrace;

  /// Optional persistence for finished games. Null = leaderboard disabled.
  final LeaderboardStore? leaderboard;

  /// Notified with the code of every room fully removed from [rooms] —
  /// immediately for an emptied lobby, after [emptyRoomGrace] for an
  /// abandoned started room. The registry hook uses this to unregister
  /// closed rooms right away instead of leaving stale routes to expire.
  final void Function(String code)? onRoomClosed;
  final Map<String, Room> rooms = {};

  static String _newCode() {
    const letters = 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789';
    return [
      for (var i = 0; i < 4; i++) letters[Random.secure().nextInt(letters.length)]
    ].join();
  }

  /// Creates a room and seats [host] in the first free corner. [game]
  /// selects the room's game: 'ludo' (default) or 'snakes'.
  Room createRoom(ServerMember host, {String game = 'ludo'}) {
    String code;
    do {
      code = _newCode();
    } while (rooms.containsKey(code));
    final room = Room(code, rng: rng, gameType: game);
    rooms[code] = room;
    return joinRoom(code, host)!;
  }

  /// Quick match: seats [member] in the first waiting (unstarted, not full)
  /// room playing [game], creating a fresh room when none fits. Waiting
  /// players thus pair up automatically instead of trading room codes.
  Room findMatch(ServerMember member, {String game = 'ludo'}) {
    for (final room in rooms.values) {
      if (room.gameType != game || room.started || room.full) continue;
      if (joinRoom(room.code, member) != null) return room;
    }
    return createRoom(member, game: game);
  }

  Room? joinRoom(String code, ServerMember member) {
    final room = rooms[code.toUpperCase()];
    if (room == null || room.full || room.started) return null;
    // Reject duplicate seat ids (same profile joining twice).
    if (room.members.values.any((m) => m.seatId == member.seatId)) {
      return null;
    }
    // Seat in the first free clockwise corner and bind the member to it,
    // so two members can never share a color at start().
    for (final c in LudoBoard.colorOrder) {
      if (room.ownerOf(c) == null) {
        member.color = c;
        room.members[member.id] = member;
        room.seatRegistry[member.seatId] = c;
        room.spectators.removeWhere((_, m) => m.seatId == member.seatId);
        room.abandonTimer?.cancel();
        room.abandonTimer = null;
        return room;
      }
    }
    return null;
  }

  /// Attempts to seat [member] with a preferred color; picks the first
  /// free clockwise corner otherwise. Returns the room or null.
  Room? joinWithColor(String code, ServerMember member, LudoColor color) {
    final room = rooms[code.toUpperCase()];
    if (room == null || room.full || room.started) return null;
    if (room.members.values.any((m) => m.seatId == member.seatId)) return null;
    if (room.ownerOf(color) != null) return joinRoom(code, member);
    room.members[member.id] = member;
    room.seatRegistry[member.seatId] = member.color;
    room.spectators.removeWhere((_, m) => m.seatId == member.seatId);
    room.abandonTimer?.cancel();
    room.abandonTimer = null;
    return room;
  }

  /// Seats a returning player back into their original corner. Works in the
  /// lobby and, crucially, mid-game: the seat survives the disconnect, so the
  /// game state (whose turn, tokens) keeps pointing at the same seatId. Any
  /// stale half-open connection for that seat is evicted. Returns null when
  /// the room is gone or the seatId never sat there (no seat stealing).
  Room? rejoinRoom(String code, ServerMember member) {
    final room = rooms[code.toUpperCase()];
    if (room == null) return null;
    final claimed = room.seatRegistry[member.seatId];
    if (claimed == null) return null;
    room.members.removeWhere((_, m) => m.seatId == member.seatId);
    member.color = claimed;
    room.members[member.id] = member;
    room.spectators.removeWhere((_, m) => m.seatId == member.seatId);
    room.abandonTimer?.cancel();
    room.abandonTimer = null;
    return room;
  }

  /// Adds [member] as a read-only spectator of an existing room — lobby or
  /// mid-game. Spectators never claim seats and their intents are ignored
  /// by [handleIntent]. Returns null only when the room is gone, or when
  /// [member] is already seated as a player in it.
  Room? spectateRoom(String code, ServerMember member) {
    final room = rooms[code.toUpperCase()];
    if (room == null) return null;
    if (room.members.values.any((m) => m.seatId == member.seatId)) {
      return null; // already playing here — no duplicate feeds
    }
    // One spectator connection per profile; a reconnecting watcher replaces
    // their own stale connection.
    room.spectators.removeWhere((_, m) => m.seatId == member.seatId);
    room.spectators[member.id] = member;
    room.abandonTimer?.cancel();
    room.abandonTimer = null;
    return room;
  }

  /// Drops a freshly created room whose cluster-registry claim was refused
  /// (another replica already owns the code). Unlike the close paths in
  /// [leaveRoom], the registry is NOT notified: the code's registry row —
  /// if any — belongs to the other instance, and unregistering would
  /// delete their routing entry.
  void abandonRoom(Room room) {
    rooms.remove(room.code);
    room.removed = true;
  }

  /// Removes the connection [connectionId] from a room's players or
  /// spectators. A room nobody is connected to at all is dropped right away
  /// if it never started; a started game lingers for [emptyRoomGrace] so a
  /// dropped player can still return, and watchers are told when it finally
  /// closes.
  bool leaveRoom(String code, String connectionId) {
    final room = rooms[code];
    if (room == null) return false;
    final wasMember = room.members.remove(connectionId) != null;
    if (!wasMember) room.spectators.remove(connectionId);
    if (room.members.isEmpty && room.spectators.isEmpty) {
      if (!room.started) {
        // A lobby nobody is in any more is worthless — drop it now.
        rooms.remove(code);
        room.removed = true;
        onRoomClosed?.call(code);
      } else {
        // A started game stays recoverable for a grace period so a flaky
        // connection (or the last one crashing) can still come back.
        room.abandonTimer?.cancel();
        room.abandonTimer = Timer(emptyRoomGrace, () {
          if (room.members.isEmpty &&
              room.spectators.isEmpty &&
              rooms[code] == room) {
            room.broadcast({'type': 'roomClosed'});
            rooms.remove(code);
            room.removed = true;
            onRoomClosed?.call(code);
          }
        });
      }
    }
    return true;
  }

  /// Applies a client intent. The server validates everything; a rejected
  /// intent is ignored (optionally a 'reject' is sent back).
  void handleIntent({
    required Room room,
    required String connectionId,
    required Map<String, dynamic> msg,
  }) {
    final member = room.members[connectionId];
    if (member == null) return;
    final isSnakes = room.gameType == 'snakes';
    final state = isSnakes ? null : room.stateOrNull;
    final snakesState = room.snakesState;
    if (state == null && snakesState == null && msg['type'] != 'start') return;

    switch (msg['type'] as String?) {
      case 'start':
        if (!room.started && member == room.orderedMembers.first) {
          room.start();
          room.broadcastState();
        }

      case 'roll':
        if (isSnakes) {
          if (snakesState == null ||
              snakesState.phase != snakes.SnakesPhase.awaitingRoll) {
            return;
          }
          if (snakesState.currentPlayer.id != member.seatId) return;
          snakes.rollDice(snakesState, rng.nextInt(6) + 1);
          room.broadcastState();
          _recordResultsIfFinished(room, snakesState);
          return;
        }
        if (state == null || state.phase != LudoPhase.awaitingRoll) return;
        if (state.currentPlayer.id != member.seatId) return;
        rollDice(state, rng.nextInt(6) + 1);
        room.broadcastState();
        _recordResultsIfFinished(room, state);

      case 'move':
        if (isSnakes) {
          // Snakes & Ladders has exactly one move per roll — no choice to
          // validate, just resolve it for the current player.
          if (snakesState == null ||
              snakesState.phase != snakes.SnakesPhase.awaitingMove) {
            return;
          }
          if (snakesState.currentPlayer.id != member.seatId) return;
          snakes.applyMove(snakesState);
          room.broadcastState();
          _recordResultsIfFinished(room, snakesState);
          return;
        }
        if (state == null || state.phase != LudoPhase.awaitingMove) return;
        if (state.currentPlayer.id != member.seatId) return;
        final idx = msg['token'] as int?;
        if (idx == null || idx < 0 || idx > 3) return;
        final legal = legalMoves(state).any((m) => m.tokenIndex == idx);
        if (!legal) return; // reject illegal move silently
        applyMove(state, idx);
        room.broadcastState();
        _recordResultsIfFinished(room, state);

      case 'chat':
        final text = (msg['text'] as String? ?? '').trim();
        if (text.isEmpty || text.length > 200) return;
        room.broadcast(
            {'type': 'chat', 'from': member.name, 'text': text});
    }
  }

  /// Persists the result when a game just reached completion. A no-op
  /// without a leaderboard store, before start, or once already recorded.
  void _recordResultsIfFinished(Room room, Object state) {
    final store = leaderboard;
    if (store == null || room.gameId == null || room.resultsRecorded) return;

    List<GameResult>? results;
    switch (state) {
      case LudoState s when s.phase == LudoPhase.gameOver:
        final rankings = s.rankings;
        if (rankings.length < s.players.length) return;
        results = [
          for (final p in s.players)
            GameResult(
              seatId: p.id,
              name: p.name,
              color: p.color.name,
              rank: rankings.indexOf(p.id) + 1,
            ),
        ];
      case snakes.SnakesState s when s.phase == snakes.SnakesPhase.gameOver:
        // The classic ruleset ranks everyone the moment the first pawn
        // reaches square 100, so all players should be present.
        if (s.rankings.length < s.players.length) return;
        results = [
          for (final p in s.players)
            GameResult(
              seatId: p.id,
              name: p.name,
              // Pawn slot -> corner seat color, stable across reconnects.
              color: LudoBoard
                  .colorOrder[p.tokenIndex.clamp(0, 3)]
                  .name,
              rank: s.rankings.indexOf(p.id) + 1,
            ),
        ];
      default:
        return; // game not over yet
    }

    room.resultsRecorded = true;
    // Fire-and-forget: the write must not block the turn loop, and a
    // failure must not kill the connection. Rows are idempotent per
    // (gameId, seatId), so a retried write is safe.
    unawaited(store
        .recordResults(gameId: room.gameId!, results: results)
        .catchError((Object e) {
      room.resultsRecorded = false; // a later action in this room can retry
      stderr.writeln('leaderboard write failed: $e');
    }));
  }
}

