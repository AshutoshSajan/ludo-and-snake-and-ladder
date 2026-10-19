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

import '../engine/core/dice.dart';
import '../engine/ludo/ludo_ai.dart';
import '../engine/ludo/ludo_board.dart';
import '../engine/ludo/ludo_models.dart';
import '../engine/ludo/ludo_rules.dart';
import '../engine/snakes/snakes_engine.dart' as snakes;
import 'leaderboard_store.dart';
import 'media.dart';

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

  /// Appends a short tag derived from [seatId] when [takenNames] already
  /// contains [name], so two players who picked the same name are still
  /// distinguishable in a seat list or on the leaderboard.
  ///
  /// The tag comes from the seat id — the same value the leaderboard groups by
  /// — so it is stable for this player across games and cannot collide with a
  /// different player's. Nobody is renamed when there is no clash.
  void disambiguate(Iterable<String> takenNames) {
    final taken = takenNames.toSet();
    if (!taken.contains(name)) return;
    var hash = 0;
    for (final unit in seatId.codeUnits) {
      hash = (hash * 31 + unit) & 0x7fffffff;
    }
    final tag = (hash % 0x10000)
        .toRadixString(32)
        .toUpperCase()
        .padLeft(4, '0');
    var candidate = '$name #$tag';
    var n = 2;
    // Astronomically unlikely, but the fallback costs three lines and
    // guarantees two rows never render identically.
    while (taken.contains(candidate)) {
      candidate = '$name #$tag·$n';
      n++;
    }
    name = candidate;
  }

  String name;
  LudoColor color; // reassigned by the authority when a corner is unavailable
  final void Function(String json) sink; // send-to-client callback
}

int _registryTokenCounter = 0;

/// The corner diagonally opposite [color] on a four-corner ludo board —
/// the seat a lone player's first opponent should get, so a two-player
/// game faces across the table rather than sitting to one side.
LudoColor _acrossFrom(LudoColor color) {
  final order = LudoBoard.colorOrder;
  return order[(order.indexOf(color) + 2) % order.length];
}

/// Monotonic per-process token for [Room.registryToken]. Deliberately NOT
/// taken from a room's seeded [Random]: consuming rng values here would
/// shift every deterministic test's dice sequence.
String _nextRegistryToken() =>
    'room-${DateTime.now().microsecondsSinceEpoch}-${++_registryTokenCounter}';

/// Mints a fresh cluster-registry token for a room about to be created.
/// Public so the server can claim a code in the registry *before* the
/// [Room] exists (see bin/server.dart), then hand the same token to
/// [GameAuthority.createRoom] so the room and its row stay one identity.
String newRegistryToken() => _nextRegistryToken();

/// A waiting/running game.
class Room {
  Room(
    this.code, {
    required this.rng,
    this.gameType = 'ludo',
    this.capacity = 4,
    String? registryToken,
  }) : registryToken = registryToken ?? _nextRegistryToken();

  final String code;
  final Random rng;

  /// Which game this room plays: 'ludo' or 'snakes'. Chosen by the host at
  /// room creation; joiners inherit it. Seats stay corner-color based, so
  /// both games currently seat up to 4 players.
  final String gameType;

  /// How many players this room closes for: 2, 3 or 4 (the seats are the
  /// board's four corners). Chosen by the host at creation, joiners inherit
  /// it, and [full] cuts further joins exactly there — a host who asks for a
  /// pair gets a private table, and the lobby shows "waiting (n/size)".
  /// Defaults to 4, which is today's behaviour for every pre-existing client.
  final int capacity;

  /// Built once at [start] from the seated members; never touched before.
  /// A [LudoState] for ludo rooms, a [snakes.SnakesState] for snakes rooms.
  late Object game;

  /// Opaque token identifying THIS room in the cluster registry. Room codes
  /// are recycled the moment a room closes, so the code alone cannot tell
  /// the registry's rows apart: when this room closes, its unregister must
  /// not delete the row a newer room (same code) has already claimed.
  /// [gameId] is only assigned at [start], too late for registry rows
  /// written at room creation — hence a dedicated token minted here (or
  /// supplied by the server when the row was claimed before this room
  /// existed, so room and row share one identity).
  final String registryToken;

  final Map<String, ServerMember> members = {}; // by connection id

  /// Persistent seat claims: seatId -> color. Survives disconnects so a
  /// returning player reclaims their exact seat, even mid-game.
  final Map<String, LudoColor> seatRegistry = {};

  /// Seats the room is playing *for*: the server rolls and moves on their
  /// behalf until they switch it off (or the game ends). Server-side rather
  /// than client-side so it keeps working when the human's tab is closed,
  /// and so two clients can never both drive one seat.
  final Set<String> autoSeats = {};

  /// Seat ids that asked to leave. They are out of the game — pieces gone —
  /// and may not reclaim the seat by reconnecting, unlike a dropped link.
  final Set<String> forfeited = {};

  /// Display-only record of who walked away, so the remaining players can
  /// still see *who* went (their corner no longer exists on the board).
  final List<({String seatId, String name, LudoColor color})> leftSeats = [];

  /// Pending autoplay action. Cancelled and re-armed on every applied
  /// intent, so a human acting never races the driver.
  Timer? autoTimer;

  /// The running turn timer for the seat on turn: armed by the authority
  /// every time the table moves, cancelled the same way. When it fires
  /// (see [GameAuthority._onTurnTimeout]) the seat's turn is skipped and a
  /// miss is recorded in [missedTurns]; five consecutive misses drop the
  /// seat from the game. Null whenever the table is not live or nobody is
  /// sitting at it — an empty room holds still, per the autoplay rule.
  Timer? turnTimer;

  /// Wall-clock the live turn deadline stands at, so [broadcastState] can
  /// attach the remaining milliseconds instead of asking clients to agree
  /// on clocks (web clients would drift server time).
  DateTime? turnDeadline;

  /// The seat the running turn clock was armed for — how [GameAuthority
  /// ._armTurnTimer] can tell "same seat, clock still running" (the
  /// rejected-intent case, where the countdown must stand) from "a new
  /// turn began" (cancel, re-arm, re-announce).
  String? turnOwner;

  /// Consecutive turn-timer misses per seat id. Reset the moment the seat
  /// rolls or moves on their own turn — five in a row without acting means
 /// the seat is out (forfeit, same as a walk-out).
  final Map<String, int> missedTurns = {};

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

  bool get full => members.length >= capacity;

  /// Clockwise turn order is enforced by re-sorting members into
  /// colorOrder before start.
  List<ServerMember> get orderedMembers {
    final order = LudoBoard.colorOrder;
    return [
      ...members.values,
    ]..sort((a, b) => order.indexOf(a.color).compareTo(order.indexOf(b.color)));
  }

  ServerMember? ownerOf(LudoColor color) {
    for (final m in members.values) {
      if (m.color == color) return m;
    }
    return null;
  }

  /// True when some live connection currently holds seat [seatId].
  bool seatIsConnected(String seatId) =>
      members.values.any((m) => m.seatId == seatId);

  /// The name to show for a seat: the live member's, else the last one seen
  /// (a seat can be claimed by someone whose link is down).
  String _displayNameFor(String seatId) {
    for (final m in [...members.values, ...spectators.values]) {
      if (m.seatId == seatId) return m.name;
    }
    for (final left in leftSeats) {
      if (left.seatId == seatId) return left.name;
    }
    return 'Player';
  }

  /// Per-seat status for the corner badges: who holds which corner, whether
  /// their link is live, whether the room is playing for them, and who has
  /// left for good. This is the message that used to be missing entirely —
  /// a departing player's dice and pieces simply stayed on the board and
  /// nobody was told why.
  Map<String, dynamic> seatsJson() => {
    'type': 'seats',
    'seats': [
      for (final entry in seatRegistry.entries)
        if (!forfeited.contains(entry.key))
          {
            'seatId': entry.key,
            'name': _displayNameFor(entry.key),
            'color': entry.value.name,
            'connected': seatIsConnected(entry.key),
            'auto': autoSeats.contains(entry.key),
            // Consecutive turn-timer misses — shown while the seat is
            // drifting toward the five-and-out rule, absent at zero so
            // quiet tables carry no extra chatter.
            if ((missedTurns[entry.key] ?? 0) > 0)
              'misses': missedTurns[entry.key],
          },
      for (final left in leftSeats)
        {
          'seatId': left.seatId,
          'name': left.name,
          'color': left.color.name,
          'connected': false,
          'auto': false,
          'left': true,
        },
    ],
  };

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
          LudoPlayer(id: m.seatId, name: m.name, color: m.color),
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

  /// Sends a message to whichever live connection currently holds
  /// [seatId]. Voice chat signalling is seat-to-seat, not broadcast: an
  /// offer belongs to the one player it names, and the seat id — not the
  /// connection — is the address, so a reconnect never re-negotiates the
  /// audio mesh. False when nobody holds the seat (they left mid-hello).
  bool sendToSeat(String seatId, Map<String, dynamic> message) {
    for (final m in members.values) {
      if (m.seatId == seatId) {
        m.sink(jsonEncode(message));
        return true;
      }
    }
    return false;
  }

  void broadcastState() =>
      broadcast({
        'type': 'state',
        'game': gameType,
        'state': stateJson(),
        // The live turn timer, as milliseconds remaining measured when this
        // message was built. Clients count down locally from it — clock
        // skew between a browser tab and the server stays out of the
        // picture. Absent when the timer is not running (no game, no seat,
        // an emptied room).
        if (turnDeadline != null && started && !removed)
          'turnMs': turnDeadline!
              .difference(DateTime.now())
              .inMilliseconds
              .clamp(0, 1 << 30),
        // Consecutive turn-timer misses, so every table can see who is
        // drifting toward removal.
        if (missedTurns.isNotEmpty) 'misses': {...missedTurns},
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
/// Valid voice-signal kinds a client may route. The server never inspects
/// the payload, but the kind must be real or the message is junk.
const _voiceKinds = {'offer', 'answer', 'ice', 'hangup', 'reinvite'};

/// Chat messages may carry a GIF: a single https URL shown inline by the
/// clients. The gate is deliberately narrow — https only (a plain http
/// image is mixed content on the hosted site and renders broken), no
/// spaces/control characters (a URL with a space is a typo, not a share),
/// and a hard length cap. Anything else is silently dropped: a chat feed
/// is not a foreign-body parser.
String? _chatGif(Object? raw) {
  final value = raw as String?;
  if (value == null || value.isEmpty) return null;
  final url = Uri.tryParse(value.trim());
  if (url == null || url.scheme != 'https' || url.host.isEmpty) return null;
  if (value.length > 2000) return null;
  if (value.contains(RegExp(r'\s'))) return null;
  return value;
}

/// A voice note rides the intent as its uploaded id and becomes a
/// broadcast url from the store's own record. An id for a note that was
/// never uploaded — to this room, on this instance — is dropped: chat
/// carries nothing a room's own uploads cannot explain. Only the voice
/// kind is addressable here; a keyboard image goes the `'gif'` route.
MediaNote? _chatNote(
  MediaNoteStore store,
  String roomCode,
  Map<String, dynamic> msg,
) {
  final id = msg['note'] as String?;
  if (id == null || id.isEmpty || !mediaNoteIdPattern.hasMatch(id)) return null;
  return store.get(MediaKind.voice, roomCode, id);
}

class GameAuthority {
  GameAuthority({
    Random? rng,
    this.emptyRoomGrace = const Duration(minutes: 5),
    this.leaderboard,
    this.onRoomClosed,
    this.onRoomStarted,
    this.onGameFinished,
    this.autoStepDelay = const Duration(milliseconds: 800),
    this.turnTimer = const Duration(seconds: 30),
    this.maxTurnMisses = 5,
    MediaNoteStore? mediaNotes,
  }) : rng = rng ?? Random.secure(),
       mediaNotes = mediaNotes ?? MediaNoteStore();

  final Random rng;

  /// Chat media store: voice-note uploads land here and wait to be
  /// announced through a chat line; keyboard-image uploads share the
  /// same budget. One authority per process owns one shared store,
  /// matching how the rooms themselves live per-instance.
  final MediaNoteStore mediaNotes;

  /// How long a started room with no connected members stays recoverable.
  final Duration emptyRoomGrace;

  /// How long the autoplay driver waits before it rolls or moves for a seat
  /// that asked to be played for. A touch slower than the offline bots, so an
  /// absent player's turns still read as a game and not a race; tests pass
  /// [Duration.zero] to watch a whole table play out.
  final Duration autoStepDelay;

  /// How long the seat on turn has to act — roll, or move with the roll they
  /// hold — before the authority skips their turn for them. Thirty seconds
  /// reads as "get a dragger moving" without snatching the dice out of a
  /// slow-but-present player's hand; an autoplay seat never meets it (the
  /// driver acts within [autoStepDelay]). Tests shrink it.
  final Duration turnTimer;

  /// Consecutive turn-timer misses a seat may rack up before it is dropped
  /// from the game for good — five timed-out turns and the table plays on
  /// without them, exactly like a walk-out (the player is told why, through
  /// the same left-channel the others already see).
  final int maxTurnMisses;

  /// Optional persistence for finished games. Null = leaderboard disabled.
  final LeaderboardStore? leaderboard;

  /// Notified with the code and the registry token of every room fully
  /// removed from [rooms] — immediately for an emptied lobby, after
  /// [emptyRoomGrace] for an abandoned started room. The registry hook uses
  /// this to unregister closed rooms right away instead of leaving stale
  /// routes to expire; the token scopes the delete so a recycled code's
  /// newer room is never erased by a stale close.
  final void Function(String code, String registryToken)? onRoomClosed;

  /// Notified once when a room's game starts. The admin store uses it to
  /// mark the lifecycle row live; a null callback keeps engine tests quiet.
  final void Function(Room room)? onRoomStarted;

  /// Mirrors finished-game results into the admin DB so one database holds
  /// rooms, presence and results for stats. Fire-and-forget by the caller.
  final Future<void> Function({
    required String gameId,
    required List<GameResult> results,
  })?
  onGameFinished;

  final Map<String, Room> rooms = {};

  static String _newCode() {
    const letters = 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789';
    return [
      for (var i = 0; i < 4; i++)
        letters[Random.secure().nextInt(letters.length)],
    ].join();
  }

  /// Draws a room code that is unique among [rooms]. Callers that claim
  /// codes cluster-wide (bin/server.dart) use this to pick a candidate
  /// before asking the registry; [createRoom] uses it as a fallback.
  String newCode() {
    String code;
    do {
      code = _newCode();
    } while (rooms.containsKey(code));
    return code;
  }

  /// Creates a room and seats [host] in the first free corner. [game]
  /// selects the room's game: 'ludo' (default) or 'snakes'. [code] and
  /// [registryToken] let the caller create a room whose code was already
  /// claimed cluster-wide under that exact token (reserve-then-create):
  /// the room then only ever exists under a code this instance owns.
  /// Throws [StateError] when an explicit [code] collides with a live
  /// local room (a concurrent creation racing the remote claim).
  Room createRoom(
    ServerMember host, {
    String game = 'ludo',
    int capacity = 4,
    String? code,
    String? registryToken,
  }) {
    if (code != null && rooms.containsKey(code)) {
      throw StateError('a live room already uses code $code');
    }
    code ??= newCode();
    final room = Room(
      code,
      rng: rng,
      gameType: game,
      capacity: capacity,
      registryToken: registryToken,
    );
    rooms[code] = room;
    return joinRoom(code, host)!;
  }

  /// Seats [member] in the first waiting (unstarted, not full) room playing
  /// [game]; returns null when none fits. Only rooms that already exist
  /// here are considered — their codes are, by construction, claimed (see
  /// bin/server.dart for how fresh rooms get claimed). When [capacity] is
  /// set, only rooms close to the same table size are considered: a
  /// two-player quick match must not land in a host's four-seat room that
  /// is still waiting for friends.
  Room? matchExisting(
    ServerMember member, {
    String game = 'ludo',
    int? capacity,
  }) {
    for (final room in rooms.values) {
      if (room.gameType != game || room.started || room.full) continue;
      if (capacity != null && room.capacity != capacity) continue;
      if (joinRoom(room.code, member) != null) return room;
    }
    return null;
  }

  /// Quick match: seats [member] in the first waiting (unstarted, not full)
  /// room playing [game], creating a fresh room when none fits. Waiting
  /// players thus pair up automatically instead of trading room codes.
  Room findMatch(ServerMember member, {String game = 'ludo', int? capacity}) =>
      matchExisting(member, game: game, capacity: capacity) ??
      createRoom(member, game: game, capacity: capacity ?? 4);

  Room? joinRoom(String code, ServerMember member) {
    final room = rooms[code.toUpperCase()];
    if (room == null || room.full || room.started) return null;
    // Reject duplicate seat ids (same profile joining twice).
    if (room.members.values.any((m) => m.seatId == member.seatId)) {
      return null;
    }
    // Two players may pick the same display name, but the room and the
    // leaderboard must still tell them apart — "Asha" twice is unreadable in a
    // seat list. The seat id is already unique and is what the leaderboard
    // groups by, so a short tag derived from it disambiguates without
    // rejecting anyone or renaming somebody's identity.
    member.disambiguate(room.members.values.map((m) => m.name));
    // Seat in the first free clockwise corner and bind the member to it,
    // so two members can never share a color at start(). One exception:
    // a two-player ludo table sits *across* the board from each other (red ↔
    // yellow, blue ↔ green) the way the offline setup screen already seats
    // a pair, instead of sliding the joiner into the neighbouring corner.
    // From the third arrival on, the classic clockwise circuit fills what
    // is left, so turn order for three and four players is unchanged.
    //
    // Snakes keeps pure clockwise seating: its board is one strip with no
    // corners to face across, and a pair there must wear the same colours
    // online as they would in the offline setup screen.
    final occupied = [
      for (final c in LudoBoard.colorOrder)
        if (room.ownerOf(c) != null) c,
    ];
    if (occupied.length >= room.capacity) return null;
    final across = room.gameType == 'ludo' && occupied.length == 1
        ? _acrossFrom(occupied.single)
        : null;
    final corner = across != null && room.ownerOf(across) == null
        ? across
        : LudoBoard.colorOrder.firstWhere((c) => room.ownerOf(c) == null);
    member.color = corner;
    room.members[member.id] = member;
    room.seatRegistry[member.seatId] = corner;
    room.spectators.removeWhere((_, m) => m.seatId == member.seatId);
    room.abandonTimer?.cancel();
    room.abandonTimer = null;
    return room;
  }

  /// Attempts to seat [member] with a preferred color; picks the first
  /// free clockwise corner otherwise. Returns the room or null.
  Room? joinWithColor(String code, ServerMember member, LudoColor color) {
    final room = rooms[code.toUpperCase()];
    if (room == null || room.full || room.started) return null;
    if (room.members.values.any((m) => m.seatId == member.seatId)) return null;
    if (room.ownerOf(color) != null || room.forfeited.contains(member.seatId)) {
      return joinRoom(code, member);
    }
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
    // Someone who pressed Leave is out of that game for good — a reconnect
    // must not silently put their pieces back on a board the others have
    // already moved on from.
    if (room.forfeited.contains(member.seatId)) return null;
    room.members.removeWhere((_, m) => m.seatId == member.seatId);
    member.color = claimed;
    room.members[member.id] = member;
    room.spectators.removeWhere((_, m) => m.seatId == member.seatId);
    room.abandonTimer?.cancel();
    room.abandonTimer = null;
    room.broadcast(room.seatsJson()); // clears their "away" badge
    // Coming back wakes the driver up again: a room that went quiet froze its
    // autoplay mid-turn, and this is where the paused turn is picked back up.
    _armAutoTimer(room);
    _armTurnTimer(room);
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
    // Somebody is watching again, so a game the table was handed may resume:
    // the same rule that stopped it when the room went quiet (see _armAutoTimer).
    _armAutoTimer(room);
    _armTurnTimer(room);
    return room;
  }

  /// Drops a room without any registry notification — unlike the close
  /// paths in [leaveRoom]. For rooms that must never have existed under
  /// this code (e.g. a duplicate generated while another replica owned it,
  /// or a racing explicit-code creation in tests), unregistering would
  /// delete a row that belongs to another instance.
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
        onRoomClosed?.call(code, room.registryToken);
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
            onRoomClosed?.call(code, room.registryToken);
          }
        });
      }
    } else if (wasMember) {
      // A dropped link is not a walk-out: the seat, its dice, its pieces and
      // its autoplay setting all stay exactly where they are so the player
      // can resume, but the others are told the corner went quiet (see
      // Room.seatsJson) instead of wondering why nobody answers.
      room.broadcast(room.seatsJson());
    }
    // Re-evaluate the driver either way: a room that just went quiet stops
    // playing its handed-over turns, and one that still has people in it
    // (or a watcher) keeps going — including the seats that are on autoplay.
    _armAutoTimer(room);
    _armTurnTimer(room);
    return true;
  }

  /// Applies a client intent. The server validates everything; a rejected
  /// intent is ignored (optionally a 'reject' is sent back).
  ///
  /// Talking, leaving, and asking the table to play for you are all things a
  /// player can do *before* the host presses Start, so they are handled here,
  /// ahead of the "no game yet" guard in [_applyGameIntent]. That guard used
  /// to run first and silently dropped every intent but 'start' — which is
  /// why the lobby chat box did nothing at all: the lobby is precisely the
  /// phase where a chat box exists.
  void handleIntent({
    required Room room,
    required String connectionId,
    required Map<String, dynamic> msg,
  }) {
    final member = room.members[connectionId];
    if (member == null) return;

    switch (msg['type'] as String?) {
      case 'chat':
        final text = (msg['text'] as String? ?? '').trim();
        final gif = _chatGif(msg['gif'] as String?);
        final note = _chatNote(mediaNotes, room.code, msg);
        // A line is any of a sentence, a GIF, a voice note — or a caption
        // riding one. Nothing at all is not a message.
        if (text.isEmpty && gif == null && note == null) return;
        if (text.length > 200) return;
        room.broadcast({
          'type': 'chat',
          'from': member.name,
          // The seat id, stable across reconnects, so clients can peer at
          // a line's AUTHOR for friendship: add friend, block, report.
          // Names collide (two tabs can join with the same display name)
          // and display names get ambiguity tags, but the seat id keys
          // the friends store — the id, not the string, identifies.
          'seatId': member.seatId,
          // The seat color paints the bubble — it is how a string of text
          // becomes a person at the table.
          'color': member.color.name,
          'text': text,
          'gif': ?gif,
          // The note's url and duration come from the store, not the
          // intent: a client that invented either is silently corrected.
          if (note != null) 'note': {'url': note.urlPath, 'dur': note.durMs},
          'at': DateTime.now().millisecondsSinceEpoch,
        });
        return;

      case 'autoplay':
        _setAutoplay(room, member, msg['on'] as bool? ?? true);
        return;

      case 'voice':
        // WebRTC signalling for table voice. The payload ('s') is opaque —
        // SDP or an ICE candidate as its own JSON string — the server only
        // routes it between seats. Routing by seatId (stable across
        // reconnects) rather than connection id is the point: a dropped
        // link re-attaches to the same peer sessions, and a returning
        // player's audio mesh survives. Only seated members reach this
        // arm at all — a spectator 'voice' intent has no member and dies
        // at the switch's entry guard.
        final kind = msg['k'] as String? ?? '';
        final to = msg['to'] as String? ?? '';
        final s = msg['s'] as String? ?? '';
        if (!_voiceKinds.contains(kind) || to.isEmpty || s.isEmpty) return;
        if (to == member.seatId) return;
        if (s.length > 64 * 1024) return;
        room.sendToSeat(to, {
          'type': 'voice',
          'k': kind,
          'from': member.seatId,
          's': s,
        });
        return;

      case 'leave':
        _applyLeave(room, member);
        return;
    }

    _applyGameIntent(room: room, member: member, msg: msg);
    // Whoever's turn it is now may be a seat the table is playing for.
    _armAutoTimer(room);
    _armTurnTimer(room);
  }

  /// The dice-and-board intents, which only make sense once a game exists.
  void _applyGameIntent({
    required Room room,
    required ServerMember member,
    required Map<String, dynamic> msg,
  }) {
    final isSnakes = room.gameType == 'snakes';
    final state = isSnakes ? null : room.stateOrNull;
    final snakesState = room.snakesState;
    if (state == null && snakesState == null && msg['type'] != 'start') return;

    switch (msg['type'] as String?) {
      case 'start':
        if (!room.started && member == room.orderedMembers.first) {
          room.start();
          onRoomStarted?.call(room);
          room.broadcast(room.seatsJson());
          room.broadcastState();
        }

      case 'roll':
        if (isSnakes) {
          if (snakesState == null ||
              snakesState.phase != snakes.SnakesPhase.awaitingRoll) {
            return;
          }
          if (snakesState.currentPlayer.id != member.seatId) return;
          // The seat acted on their own turn: their miss streak ends here.
          // The bar is five *consecutive* timed-out turns, not five ever.
          room.missedTurns.remove(member.seatId);
          snakes.rollDice(snakesState, dieRoll(rng));
          room.broadcastState();
          _recordResultsIfFinished(room, snakesState);
          return;
        }
        if (state == null || state.phase != LudoPhase.awaitingRoll) return;
        if (state.currentPlayer.id != member.seatId) return;
        room.missedTurns.remove(member.seatId);
        rollDice(state, dieRoll(rng));
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
          room.missedTurns.remove(member.seatId);
          snakes.applyMove(snakesState);
          room.broadcastState();
          _recordResultsIfFinished(room, snakesState);
          return;
        }
        if (state == null || state.phase != LudoPhase.awaitingMove) return;
        if (state.currentPlayer.id != member.seatId) return;
        room.missedTurns.remove(member.seatId);
        final idx = msg['token'] as int?;
        if (idx == null || idx < 0 || idx > 3) return;
        final legal = legalMoves(state).any((m) => m.tokenIndex == idx);
        if (!legal) return; // reject illegal move silently
        applyMove(state, idx);
        room.broadcastState();
        _recordResultsIfFinished(room, state);
    }
  }

  /// Switches autoplay on or off for [member]'s seat. It lives on the server
  /// so it survives their tab closing, and so two clients can never drive the
  /// same seat. A human who changes their mind can still roll or move by
  /// hand — the driver only steps in when the turn is still pending.
  void _setAutoplay(Room room, ServerMember member, bool on) {
    if (on) {
      room.autoSeats.add(member.seatId);
    } else {
      room.autoSeats.remove(member.seatId);
    }
    room.broadcast(room.seatsJson());
    _armAutoTimer(room);
    _armTurnTimer(room);
  }

  /// A deliberate walk-out, as opposed to a dropped link: the seat's dice and
  /// pieces come off the authoritative board so they stop haunting the other
  /// players, turns skip the empty corner, everyone is told who went, and the
  /// game ends by forfeit rather than hanging on a turn that will never
  /// arrive. A finished game keeps its final board for the results screen.
  void _applyLeave(Room room, ServerMember member) {
    _forfeitSeat(
      room,
      seatId: member.seatId,
      name: member.name,
      color: member.color,
    );
  }

  /// The shared forfeit path behind both ways a seat stops playing: sending
  /// `leave` by hand, and the turn timer's five-missed-turns eviction. In one
  /// shot the seat is marked forfeited, registered in [Room.leftSeats] so the
  /// remaining players still see *who* went, its pieces come off the board,
  /// everyone gets the announcement (with [reason] so a client can say
  /// "removed — five turns missed" rather than "left the game"), and the
  /// empty-room grace rules apply exactly as for a human-initiated walk-out.
  void _forfeitSeat(
    Room room, {
    required String seatId,
    required String name,
    required LudoColor color,
    String reason = 'left',
  }) {
    if (room.forfeited.contains(seatId)) return;
    room.forfeited.add(seatId);
    room.leftSeats.add((seatId: seatId, name: name, color: color));
    room.autoSeats.remove(seatId);
    room.missedTurns.remove(seatId);
    room.members.removeWhere((_, m) => m.seatId == seatId);
    room.spectators.removeWhere((_, m) => m.seatId == seatId);
    room.broadcast({
      'type': 'left',
      'name': name,
      'color': color.name,
      'reason': reason,
    });
    room.broadcast(room.seatsJson());

    final Object? game = room.started
        ? (room.gameType == 'snakes' ? room.snakesState : room.stateOrNull)
        : null;
    if (game != null && removeSeatFromGame(game, seatId)) {
      room.broadcastState();
      _recordResultsIfFinished(room, game);
    }

    if (room.members.isEmpty &&
        room.spectators.isEmpty &&
        !room.started &&
        rooms[room.code] == room) {
      // A lobby someone just walked out of, with nobody left in it.
      rooms.remove(room.code);
      room.removed = true;
      room.autoTimer?.cancel();
      room.turnTimer?.cancel();
      onRoomClosed?.call(room.code, room.registryToken);
    } else if (room.members.isEmpty && room.started) {
      // Everyone's gone: leave the started game to [emptyRoomGrace] so the
      // walk-out can still reconnect to a board they did not finish.
      room.abandonTimer?.cancel();
      room.abandonTimer = Timer(emptyRoomGrace, () {
        if (room.members.isEmpty &&
            room.spectators.isEmpty &&
            rooms[room.code] == room) {
          room.broadcast({'type': 'roomClosed'});
          rooms.remove(room.code);
          room.removed = true;
          onRoomClosed?.call(room.code, room.registryToken);
        }
      });
    }
    // The walk-out moved the turn, and the seat that now owns it may be one
    // the table plays (the walker's own seat left [Room.autoSeats] above, but
    // an absent player's did not): hand the turn to the driver rather than
    // letting it sit there until somebody happens to send another intent.
    _armAutoTimer(room);
    _armTurnTimer(room);
  }

  /// The seat whose turn it is right now, or null when nobody's (a lobby, or
  /// a finished game).
  String? _seatOnTurn(Room room) {
    if (!room.started) return null;
    return switch (room.game) {
      LudoState s when s.phase != LudoPhase.gameOver => s.currentPlayer.id,
      snakes.SnakesState s when s.phase != snakes.SnakesPhase.gameOver =>
        s.currentPlayer.id,
      _ => null,
    };
  }

  /// (Re)arms the autoplay driver for whoever's turn it is, cancelling any
  /// step already pending so a human acting by hand and the driver never
  /// both move the same turn.
  void _armAutoTimer(Room room) {
    room.autoTimer?.cancel();
    room.autoTimer = null;
    if (room.removed) return;
    // Nobody is connected to this room at all. A table nobody is in has no
    // turn to answer and no one to answer it for, so the driver stays down
    // and the board freezes where it stands — otherwise the game plays itself
    // to the end, and can even finish and write a leaderboard row for people
    // who were not there to play it. Whoever comes back re-arms the driver
    // and the paused turn resumes (see the join/rejoin/spectate paths).
    if (room.members.isEmpty && room.spectators.isEmpty) return;
    final seatId = _seatOnTurn(room);
    if (seatId == null || !room.autoSeats.contains(seatId)) return;
    room.autoTimer = Timer(autoStepDelay, () => _autoStep(room, seatId));
  }

  /// (Re)arms the turn timer for the seat on turn, cancelling any pending
  /// one, so the countdown always measures the phase the table is actually
  /// in. Armed after every state change — a roll, a move, a walk-out, a
  /// timeout skip — the same places the driver is re-armed from.
  ///
  /// Deliberately skipped for a seat the table plays (autoplay): the driver
  /// acts within [autoStepDelay], so a 30-second badge on an auto seat would
  /// be pure decoration — and an auto seat can never stall, which is the
  /// thing the timer exists to punish. Same half as the driver's rule: an
  /// emptied room holds still rather than racking up misses against nobody.
  ///
  /// A clock already running for the same seat stands: the window is one
  /// per turn, and a rejected intent (an idle tap on the dice while it is
  /// still your turn) must not silently reset the countdown the table can
  /// see. The clock resets when the turn moves to another seat — or comes
  /// back to one after going through the rest of the table.
  void _armTurnTimer(Room room) {
    // A table that is gone (removed, never started, or nobody connected any
    // more) holds no clock at all — the emptiness beats any stand-down.
    final tableGone = room.removed ||
        !room.started ||
        (room.members.isEmpty && room.spectators.isEmpty);
    final seatId = tableGone ? null : _seatOnTurn(room);
    final driven = seatId != null && room.autoSeats.contains(seatId);
    // A clock already running for the same answerable seat stands: the
    // window is one per turn, and a rejected intent (an idle tap on the
    // dice while it is still your turn) must not silently reset the
    // countdown the table can see. The clock is torn down and re-armed
    // whenever the turn moves to another seat — or comes back to one after
    // going through the rest of the table.
    if (!tableGone &&
        !driven &&
        room.turnTimer != null &&
        room.turnDeadline != null &&
        room.turnOwner == seatId) {
      return;
    }
    room.turnTimer?.cancel();
    room.turnTimer = null;
    room.turnDeadline = null;
    room.turnOwner = null;
    if (tableGone || driven || seatId == null) return;
    // The state snapshot a roll or move just shipped was still built before
    // this arming happened, so the fresh countdown travels as its own small
    // message — this is what actually starts the visible clock at the table
    // (and it re-baselines a late rejoinder's chip to the full seat window).
    room.turnOwner = seatId;
    room.turnDeadline = DateTime.now().add(turnTimer);
    room.turnTimer = Timer(turnTimer, () => _onTurnTimeout(room, seatId));
    room.broadcast({
      'type': 'turnTimer',
      'seatId': seatId,
      'turnMs': turnTimer.inMilliseconds,
    });
  }

  /// The turn timer expired on [seatId]'s turn. Count one miss, skip the
  /// seat's turn for them — the engine's `passTurn`: the pending roll is
  /// dropped, sixes streaks reset — and drop the seat from the game entirely
  /// once they have missed [maxTurnMisses] in a row. Acting on their own
  /// turn (a roll or a move intent, see `_applyGameIntent`) resets the
  /// count, so the bar is "five consecutive silent turns", not five over a
  /// whole evening of slow-rolling.
  void _onTurnTimeout(Room room, String seatId) {
    room.turnTimer = null;
    room.turnDeadline = null;
    // A lot can happen while the clock runs: the room closed, or another
    // seat's turn already advanced (a re-arm always follows a state change,
    // so a mismatch means a stale fire — nothing to punish). And nobody is
    // ever punished against an absent table.
    if (room.removed || !identical(rooms[room.code], room)) return;
    if (room.members.isEmpty && room.spectators.isEmpty) return;
    if (_seatOnTurn(room) != seatId) return;

    final misses = (room.missedTurns[seatId] ?? 0) + 1;
    room.missedTurns[seatId] = misses;
    room.broadcast(room.seatsJson());
    room.broadcast({
      'type': 'turnMissed',
      'seatId': seatId,
      'name': room._displayNameFor(seatId),
      'count': misses,
    });

    if (misses >= maxTurnMisses) {
      // Five in a row: out. Reuse the walk-out machinery — pieces off the
      // board, turns skip the corner, the two-player table ends by forfeit
      // — with a reason the remaining players can see and understand.
      final color = room.seatRegistry[seatId];
      if (color != null) {
        _forfeitSeat(
          room,
          seatId: seatId,
          name: room._displayNameFor(seatId),
          color: color,
          reason: 'timeout',
        );
        return;
      }
    }

    switch (room.game) {
      case LudoState s:
        passTurn(s);
        room.broadcastState();
        _recordResultsIfFinished(room, s);
      case snakes.SnakesState s:
        snakes.passTurn(s);
        room.broadcastState();
        _recordResultsIfFinished(room, s);
    }
    _armTurnTimer(room);
  }

  /// One autoplay action: roll when the seat owes a roll, move when it owes
  /// a move. Ludo chooses with the same heuristic bot the offline game plays
  /// with; snakes has no choices to make, only a dice to roll.
  void _autoStep(Room room, String seatId) {
    room.autoTimer = null;
    // A lot can happen while a step is pending: the room closed, a human
    // took the seat back, or the turn moved on. Re-check everything.
    if (room.removed || !identical(rooms[room.code], room)) return;
    if (!room.autoSeats.contains(seatId)) return;
    if (_seatOnTurn(room) != seatId) return;

    switch (room.game) {
      case LudoState s:
        if (s.phase == LudoPhase.awaitingRoll) {
          rollDice(s, dieRoll(rng));
        } else if (s.phase == LudoPhase.awaitingMove) {
          final move = chooseLudoMove(s, s.currentPlayer.difficulty, rng);
          if (move == null) {
            // Nothing legal for the driver to do (a mid-game removal can
            // leave the seat's row blocked at the exact wrong moment): let
            // the engine skip the turn the same way a roll with no legal
            // move does, instead of parking the table on a dead phase.
            passTurn(s, event: 'skip');
          } else {
            applyMove(s, move.tokenIndex);
          }
        } else {
          return;
        }
        room.broadcastState();
        _recordResultsIfFinished(room, s);
      case snakes.SnakesState s:
        if (s.phase == snakes.SnakesPhase.awaitingRoll) {
          snakes.rollDice(s, dieRoll(rng));
        } else if (s.phase == snakes.SnakesPhase.awaitingMove) {
          snakes.applyMove(s);
        } else {
          return;
        }
        room.broadcastState();
        _recordResultsIfFinished(room, s);
    }
    _armAutoTimer(room);
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
              game: 'ludo',
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
              color: LudoBoard.colorOrder[p.tokenIndex.clamp(0, 3)].name,
              rank: s.rankings.indexOf(p.id) + 1,
              game: 'snakes',
            ),
        ];
      default:
        return; // game not over yet
    }

    room.resultsRecorded = true;
    // Fire-and-forget: the write must not block the turn loop, and a
    // failure must not kill the connection. Rows are idempotent per
    // (gameId, seatId), so a retried write is safe.
    unawaited(
      store.recordResults(gameId: room.gameId!, results: results).catchError((
        Object e,
      ) {
        room.resultsRecorded = false; // a later action in this room can retry
        stderr.writeln('leaderboard write failed: $e');
      }),
    );
    final mirror = onGameFinished;
    if (mirror != null) {
      unawaited(
        mirror(gameId: room.gameId!, results: results).catchError((Object e) {
          stderr.writeln('admin mirror write failed: $e');
        }),
      );
    }
  }
}

/// Takes a departed seat out of a running game, so the players who stayed are
/// left with a board that matches reality: their dice and pieces are gone,
/// turns skip the empty corner, and when only one player remains the game
/// ends there and then — survivor first, walk-out last — instead of hanging
/// on a turn that will never come.
///
/// A two-player walk-out ends the game rather than emptying the board: the
/// finished board stays drawn behind the result, which is what a forfeit
/// looks like across the table too. Returns false when [seatId] is not part
/// of this game.
bool removeSeatFromGame(Object game, String seatId) {
  switch (game) {
    case LudoState s:
      final index = s.players.indexWhere((p) => p.id == seatId);
      if (index < 0 || s.phase == LudoPhase.gameOver) return index >= 0;
      if (s.players.length <= 2) {
        final winner = s.players.firstWhere((p) => p.id != seatId);
        s.rankings
          ..clear()
          ..add(winner.id)
          ..add(seatId);
        s.phase = LudoPhase.gameOver;
        s.lastRoll = null;
        s.extraRoll = false;
        return true;
      }
      final leaver = s.players[index];
      s.players.removeAt(index);
      s.tokens.removeWhere((t) => t.color == leaver.color);
      s.currentPlayerIndex = _retargetTurn(
        s.currentPlayerIndex,
        index,
        s.players.length,
      );
      s.phase = LudoPhase.awaitingRoll;
      s.lastRoll = null;
      s.extraRoll = false;
      s.consecutiveSixes = 0;
      return true;

    case snakes.SnakesState s:
      final index = s.players.indexWhere((p) => p.id == seatId);
      if (index < 0 || s.phase == snakes.SnakesPhase.gameOver) {
        return index >= 0;
      }
      if (s.players.length <= 2) {
        final winner = s.players.firstWhere((p) => p.id != seatId);
        s.rankings
          ..clear()
          ..add(winner.id)
          ..add(seatId);
        s.phase = snakes.SnakesPhase.gameOver;
        s.lastRoll = null;
        return true;
      }
      s.players.removeAt(index);
      s.currentPlayerIndex = _retargetTurn(
        s.currentPlayerIndex,
        index,
        s.players.length,
      );
      s.phase = snakes.SnakesPhase.awaitingRoll;
      s.lastRoll = null;
      return true;
  }
  return false;
}

/// Where [current] lands once the seat at [removed] is lifted out of a
/// [total]-seat turn rotation: the seat after the departed one takes the
/// turn, and everyone behind it shifts up a place.
int _retargetTurn(int current, int removed, int total) {
  if (total <= 0) return 0;
  return (current > removed ? current - 1 : current) % total;
}
