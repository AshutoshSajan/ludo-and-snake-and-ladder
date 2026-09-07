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
import 'dart:math';

import '../engine/ludo/ludo_board.dart';
import '../engine/ludo/ludo_models.dart';
import '../engine/ludo/ludo_rules.dart';

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
  Room(this.code, {required this.rng});

  final String code;
  final Random rng;

  /// Built once at [start] from the seated members; never touched before.
  late LudoState state;
  final Map<String, ServerMember> members = {}; // by connection id

  /// Persistent seat claims: seatId -> color. Survives disconnects so a
  /// returning player reclaims their exact seat, even mid-game.
  final Map<String, LudoColor> seatRegistry = {};

  /// Cancelled when someone (re)joins; fires only while the room sits empty.
  Timer? abandonTimer;

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
    final players = [
      for (final m in orderedMembers)
        LudoPlayer(
          id: m.seatId,
          name: m.name,
          color: m.color,
        ),
    ];
    state = createLudoState(players);
    started = true;
  }

  void broadcast(Map<String, dynamic> message) {
    final json = jsonEncode(message);
    for (final m in members.values) {
      try {
        m.sink(json);
      } catch (_) {
        // A dead connection is pruned by the transport layer.
      }
    }
  }

  void broadcastState() =>
      broadcast({'type': 'state', 'state': state.toJson()});

  /// The state, or null before [start] has built it. Keeps intent
  /// handling from touching the [late] field too early.
  LudoState? get stateOrNull => started ? state : null;
}

/// Server-side game logic shared by the transport layer (websockets) and
/// tests (direct function calls).
class GameAuthority {
  GameAuthority({Random? rng, this.emptyRoomGrace = const Duration(minutes: 5)})
      : rng = rng ?? Random.secure();

  final Random rng;

  /// How long a started room with no connected members stays recoverable.
  final Duration emptyRoomGrace;
  final Map<String, Room> rooms = {};

  static String _newCode() {
    const letters = 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789';
    return [
      for (var i = 0; i < 4; i++) letters[Random.secure().nextInt(letters.length)]
    ].join();
  }

  /// Creates a room and seats [host] in the first free corner.
  Room createRoom(ServerMember host) {
    String code;
    do {
      code = _newCode();
    } while (rooms.containsKey(code));
    final room = Room(code, rng: rng);
    rooms[code] = room;
    return joinRoom(code, host)!;
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
    room.abandonTimer?.cancel();
    room.abandonTimer = null;
    return room;
  }

  bool removeMember(String code, String connectionId) {
    final room = rooms[code];
    if (room == null) return false;
    room.members.remove(connectionId);
    if (room.members.isEmpty) {
      if (!room.started) {
        // A lobby nobody is in any more is worthless — drop it now.
        rooms.remove(code);
        room.removed = true;
      } else {
        // A started game stays recoverable for a grace period so a flaky
        // connection (or the last one crashing) can still come back.
        room.abandonTimer?.cancel();
        room.abandonTimer = Timer(emptyRoomGrace, () {
          if (room.members.isEmpty && rooms[code] == room) {
            rooms.remove(code);
            room.removed = true;
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
    final state = room.stateOrNull;
    if (state == null && msg['type'] != 'start') return;

    switch (msg['type'] as String?) {
      case 'start':
        if (!room.started && member == room.orderedMembers.first) {
          room.start();
          room.broadcastState();
        }

      case 'roll':
        if (state == null || state.phase != LudoPhase.awaitingRoll) return;
        if (state.currentPlayer.id != member.seatId) return;
        rollDice(state, rng.nextInt(6) + 1);
        room.broadcastState();

      case 'move':
        if (state == null || state.phase != LudoPhase.awaitingMove) return;
        if (state.currentPlayer.id != member.seatId) return;
        final idx = msg['token'] as int?;
        if (idx == null || idx < 0 || idx > 3) return;
        final legal = legalMoves(state).any((m) => m.tokenIndex == idx);
        if (!legal) return; // reject illegal move silently
        applyMove(state, idx);
        room.broadcastState();

      case 'chat':
        final text = (msg['text'] as String? ?? '').trim();
        if (text.isEmpty || text.length > 200) return;
        room.broadcast(
            {'type': 'chat', 'from': member.name, 'text': text});
    }
  }
}

