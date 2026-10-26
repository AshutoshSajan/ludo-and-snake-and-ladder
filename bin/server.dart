/// Game Club — authoritative Ludo server.
///
/// Run:  dart run bin/server.dart [--port 8080] [--db FILE]
///
/// Endpoints:
///   GET  /            -> Flutter web UI when a build ships (WEB_DIR);
///                        otherwise the JSON health check below
///   GET  /health      -> JSON health check {ok, rooms, games} — the stable
///                        health URL whatever the deployment mode
///   GET  /stats       -> capacity metrics {connections, rooms, spectators}
///   GET  /rooms/lookup?code=XXXX -> owning instance id (cross-instance routing)
///   GET  /leaderboard -> top players + total games recorded
///   POST /feedback    -> player report: bug / feature request / question /
///                        other (the contact page posts here too)
///   POST /friends/state    -> full friends screen bundle (profile +
///                        friends w/ latest-message ids, requests,
///                        invites, blocks) for one seat
///   POST /friends/lookup   -> resolve a friend code / seat id to a profile
///   POST /friends/request  -> send (or match) a friend request
///   POST /friends/respond  -> accept / decline / withdraw a request
///   POST /friends/remove   -> un-friend (either side)
///   POST /friends/block    -> block a player (severs + denies contact)
///   POST /friends/unblock  -> lift a block
///   POST /friends/report   -> report a player into the admin feedback queue
///   GET  /friends/chat?seatId=&peer=&since=&limit=
///                          -> DM history page (polling reads)
///   POST /friends/chat/send -> send a DM (optional reply quote)
///   POST /friends/chat/like -> like/unlike a DM
///   POST /friends/invite   -> invite a friend to a game room
///   POST /friends/invite/respond
///                          -> accept (returns room code) / decline
///   WS   /ws?code=XXXX  -> join/create room, then JSON message protocol
///
/// Client -> server messages:
///   {type: 'hello', seatId, name, color?, game?, code?, match?, players?}  first
///   {type: 'start'}
///   {type: 'roll'}
///   {type: 'move', token: 0..3}
///   {type: 'chat', text, gif?, note?}  gif is an https image URL\n///       (text may be empty); note is the id of an uploaded voice note —
///       see POST /media/voice. Invalid ids/notes are dropped
///       server-side, never broadcast.
///   {type: 'voice', k, to, s}  P2P audio signalling: k is one of
///       offer/answer/ice/hangup, `to` is the target seatId, and `s` the
///       opaque payload. Routed only between seated members.
/// Server -> client:
///   {type: 'joined', code, color, game}
///   {type: 'lobby', capacity, seats: [{name, color}...]}
///   {type: 'state', game, state: LudoStateJson | SnakesStateJson}
///   {type: 'chat', from, color, text, gif?, note?, at}
///       from is the sender name, color their seat color ('red'…), note
///       the voice note {url, dur} when one rides the line, at the epoch
///       ms it was said — clients use these to paint chat bubbles.
///   {type: 'voice', k, from, s}  relayed signalling; from is the sender seatId
///   {type: 'error', text}
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:shelf/shelf.dart' as shelf;
import 'package:shelf/shelf_io.dart' as shelf_io;
import 'package:shelf_static/shelf_static.dart';
import 'package:shelf_web_socket/shelf_web_socket.dart';

import 'package:game_club/engine/ludo/ludo_models.dart';
import 'package:game_club/server/admin_store.dart';
import 'package:game_club/server/admin_tables.dart';
import 'package:game_club/server/game_server.dart';
import 'package:game_club/server/friend_store.dart';
import 'package:game_club/server/gif.dart';
import 'package:game_club/server/leaderboard_store.dart';
import 'package:game_club/server/media.dart';
import 'package:game_club/server/report_store.dart';
import 'package:game_club/server/room_registry.dart';
import 'package:game_club/server/web_cache.dart';
import 'package:game_club/server/turso_friend_store.dart';
import 'package:game_club/server/turso_leaderboard_store.dart';
import 'package:http/http.dart' as http;
import 'package:sqlite3/sqlite3.dart';

/// Not final so tests can swap in a fresh authority + store.
GameAuthority authority = GameAuthority();

/// Tells a seat's live socket that its friends picture moved.
///
/// The friends store is HTTP, not the room protocol, so a waiting invitee
/// in a room would otherwise learn about a new invite only on the next
/// five-second poll. The payload is intentionally empty: the app's watcher
/// reads `/friends/state` itself, keeping one source of truth. Players not
/// in a room have no socket; their poll is the delivery path.
void _pulseFriendSeat(String seatId) {
  final id = seatId.trim();
  if (id.isEmpty) return;
  for (final room in authority.rooms.values) {
    room.sendToSeat(id, <String, dynamic>{'type': 'friendPulse'});
  }
}

/// Durable admin history (presence, bans, audit, room lifecycle). Tests
/// swap in an in-memory store; main() points it at the same SQLite file
/// as the leaderboard so one DB holds everything the dashboard shows.
AdminStore adminStore = AdminStore.inMemory();

/// Player feedback queue (bug reports, feature requests, contact page).
/// Same SQLite file as [adminStore] in production; in-memory for tests.
ReportStore reportStore = ReportStore.inMemory();

/// Bearer token guarding /admin/*. Empty = admin disabled (all denied).
/// Set via ADMIN_TOKEN env. Not final so tests can set it.
String adminToken = '';

/// The configured GIF provider behind the chat GIF picker — chosen at
/// startup from KLIPY_API_KEY / GIPHY_API_KEY (+ the optional
/// GIF_PROVIDER pin). Null = search off: the picker then offers
/// paste-a-link only. Not final so tests can swap it.
GifProvider? gifProvider;

/// Outbound client for GIF-provider calls. Swappable for tests.
http.Client gifHttp = http.Client();

/// Not final so tests can swap in an in-memory store. main() replaces this
/// with the Turso store (when TURSO_DATABASE_URL is set) or the file-backed
/// store before the server starts listening.
LeaderboardStore leaderboardStore = SqliteLeaderboardStore.inMemory();

/// Where this instance's rooms are advertised for cross-instance routing.
/// main() swaps in a Turso-backed registry when TURSO_DATABASE_URL is set;
/// tests use the in-memory one.
RoomRegistry roomRegistry = InMemoryRoomRegistry();

/// The merged environment: real process variables plus .env overrides
/// (the real environment always wins). Captured at startup; tests may
/// swap it to exercise .env-only configuration such as WEB_DIR.
Map<String, String> serverEnv = const {};

/// This instance's id in the room registry (see /rooms/lookup). Settable
/// via --instance-id or INSTANCE_ID so replicas behind a load balancer are
/// individually addressable.
String instanceId = 'game-1';

/// Every open WebSocket, joined or not — the raw capacity gauge for /stats.
final _openConnections = <String>{};

final _connections = <String, String>{}; // connId -> roomCode

int _connCounter = 0;

/// Creates a room whose code is claimed in the cluster registry BEFORE the
/// room exists, so the code handed to the host always routes back to this
/// replica: a registry refusal is answered with a different code (nothing
/// to abandon — no room was ever created), never with an unroutable room.
/// A registry outage still never blocks creation — the room opens locally
/// with a self-minted token, exactly as before cluster routing, and the
/// periodic sweep claims it once the registry returns. Throws
/// [RoomRegistryException] when three consecutive codes are refused: that
/// means the registry keeps handing our codes to other replicas, and
/// creating anyway would strand the host's code on a foreign route.
Future<Room> _createClaimedRoom(
  ServerMember host, {
  required String game,
  int capacity = 4,
}) async {
  var token = newRegistryToken();
  for (var attempt = 0; attempt < 3; attempt++) {
    final code = authority.newCode();
    final bool claimed;
    try {
      claimed = await roomRegistry.register(code, instanceId, owner: token);
    } on RoomRegistryException catch (_) {
      final room = authority.createRoom(
        host,
        game: game,
        capacity: capacity,
      ); // registry down — host locally
      unawaited(
        adminStore
            .recordRoomCreated(
              code: room.code,
              game: room.gameType,
              instance: instanceId,
            )
            .catchError((Object _) {}),
      );
      return room;
    }
    if (!claimed) {
      token = newRegistryToken(); // the row belongs to another replica
      continue;
    }
    try {
      final room = authority.createRoom(
        host,
        game: game,
        capacity: capacity,
        code: code,
        registryToken: token,
      );
      unawaited(
        adminStore
            .recordRoomCreated(
              code: room.code,
              game: room.gameType,
              instance: instanceId,
            )
            .catchError((Object _) {}),
      );
      return room;
    } on StateError catch (_) {
      // Astronomically rare: a concurrent local creation took the code
      // while the remote claim was in flight (only reachable when the
      // registry had marked our row expired, letting this claim through).
      // Release OUR claim — scoped to the token, so a row that meanwhile
      // moved back to the live room's token is untouched — and hand the
      // route straight back to that room, so lookups do not go dark (and a
      // third replica cannot grab the code) until its next sweep refresh.
      // advertiseRoom re-checks the room afterwards: should it close while
      // the hand-back is in flight, the route is dropped again instead of
      // pointing at a dead room.
      await roomRegistry
          .unregister(code, owner: token)
          .catchError((Object _) {});
      final winner = authority.rooms[code];
      if (winner != null) await advertiseRoom(winner);
      token = newRegistryToken();
    }
  }
  throw RoomRegistryException(
    'every generated room code is already owned by another replica',
  );
}

/// (Re)advertises [room]'s route in the cluster registry. Every route
/// upkeep funnels through here: the claim made before the room existed,
/// the refresh when a player joins or returns, and the periodic sweep.
///
/// A route must never outlive its room. A registration is a slow round
/// trip, and the room can close while it is in flight — its close callback
/// then removes the registry row first, and this late registration would
/// restore the row (or create one) pointing at a room that no longer
/// exists, sending `/rooms/lookup` joins to a dead room until the entry
/// expires. The room is therefore re-checked once the round trip finishes,
/// and the route dropped again when it is gone. The delete is scoped to
/// the room's token, so a recycled code's newer room is never touched, and
/// a registry outage simply leaves the route to the sweep's next attempt.
Future<void> advertiseRoom(Room room) async {
  try {
    await roomRegistry.register(
      room.code,
      instanceId,
      owner: room.registryToken,
    );
  } on RoomRegistryException {
    return; // registry down — nothing was advertised; the sweep retries
  }
  if (!room.removed && authority.rooms[room.code] == room) return;
  await roomRegistry
      .unregister(room.code, owner: room.registryToken)
      .catchError((Object _) {});
}

/// The largest message a single connection may hand the protocol
/// parser, in characters of a UTF-16-ish Dart string (a few bytes less
/// than the wire frame). The biggest legitimate intent is a voice
/// note's WebRTC signalling payload, itself capped at 64 KiB inside the
/// intent handler; everything beyond this bound is parse cost and
/// retained-metadata fuel somebody else pays for — refused with an
/// error before the process does any work with it (per-connection
/// message limit, the transport half of the CWE-400 fix).
const maxIncomingMessageChars = 96 * 1024;

/// Trims and clamps a hello-carried identity string — a display name or
/// a seat id — to [max] characters. Both ride every roster broadcast to
/// every tablemate, so a bound enforced BEFORE anything retains them
/// keeps stored metadata from becoming megabyte re-serializations on
/// every later message (CWE-400). Non-string JSON arrives as [fallback]:
/// the hello path used to let a `"name": 12345` crash an uncaught cast
/// in the socket listener, which a clean default now answers instead.
String _clampIdentity(Object? value, Object fallback, int max) {
  final c = value is String ? value : fallback.toString();
  final v = c.trim();
  return v.length <= max ? v : v.substring(0, max);
}

shelf.Handler wsHandler() => webSocketHandler((webSocket, _) {
  final connId = 'c${_connCounter++}';
  _openConnections.add(connId); // counted from the raw socket up
  String? roomCode;
  ServerMember? member;

  webSocket.stream.listen(
    (data) async {
      // Per-connection inbound bound BEFORE any parse work: no single
      // frame may cost the process serialization, CPU or memory beyond
      // this line. Empty frames fall through to the bad-json answer.
      if (data is String && data.length > maxIncomingMessageChars) {
        webSocket.sink.add(
          jsonEncode({'type': 'error', 'text': 'message too large'}),
        );
        return;
      }
      Map<String, dynamic> msg;
      try {
        msg = jsonDecode(data as String) as Map<String, dynamic>;
      } catch (_) {
        webSocket.sink.add(jsonEncode({'type': 'error', 'text': 'bad json'}));
        return;
      }

      // First message must be hello.
      if (member == null) {
        if (msg['type'] != 'hello') {
          webSocket.sink.add(
            jsonEncode({'type': 'error', 'text': 'say hello first'}),
          );
          return;
        }
        // Enemy input here is arbitrary JSON: both reads are typed and
        // clamped BEFORE anything retains them. The roster ships these
        // strings to every tablemate, so an oversized name or seat id
        // meant two junk intents re-shipping megabyte rosters (CWE-400);
        // a non-string JSON value is a clean default, not an uncaught
        // cast in the socket listener.
        final seatId = _clampIdentity(
          msg['seatId'],
          '',
          ServerMember.maxSeatIdChars,
        );
        final name = _clampIdentity(
          msg['name'],
          'Player',
          ServerMember.maxNameChars,
        );
        if (seatId.isEmpty) {
          webSocket.sink.add(
            jsonEncode({'type': 'error', 'text': 'seatId required'}),
          );
          return;
        }
        if (await adminStore.isBanned(seatId)) {
          webSocket.sink.add(jsonEncode({'type': 'error', 'text': 'banned'}));
          return;
        }
        unawaited(
          adminStore
              .recordPresence(
                seatId: seatId,
                name: name.isEmpty ? 'Player' : name,
              )
              .catchError((Object _) {}),
        );
        final color = LudoColor.values.firstWhere(
          (c) => c.name == msg['color'],
          orElse: () => LudoColor.red,
        );
        final code = (msg['code'] as String? ?? '').trim();
        final spectate = msg['spectate'] as bool? ?? false;
        final game = (msg['game'] as String?) == 'snakes' ? 'snakes' : 'ludo';
        final match = msg['match'] as bool? ?? false;
        // Table size the host asks to close a created room at (2..4; the
        // seats are the board's corners). Sent only by room creators —
        // joiners inherit the room's size, so an absent/odd value or any
        // join-with-code stays at today's open four-seat default.
        final players = switch (msg['players']) {
          final int n when n >= 2 && n <= 4 => n,
          _ => 4,
        };

        member = ServerMember(
          id: connId,
          seatId: seatId,
          name: name.isEmpty ? 'Player' : name,
          color: color,
          sink: (json) => webSocket.sink.add(json),
        );

        final Room room;
        if (spectate) {
          if (code.isEmpty) {
            webSocket.sink.add(
              jsonEncode({
                'type': 'error',
                'text': 'a room code is required to spectate',
              }),
            );
            return;
          }
          final watched = authority.spectateRoom(code, member!);
          if (watched == null) {
            final owner = await _foreignOwnerOf(code);
            webSocket.sink.add(
              jsonEncode({
                'type': 'error',
                'text':
                    "room '$code' not found "
                    '(or you are already playing in it)',
                'owner': ?owner,
              }),
            );
            return;
          }
          room = watched;
        } else if (code.isEmpty && match) {
          // Quick match: join the first waiting room of this game
          // type, or open one — then start as soon as two are seated.
          // Matched rooms are already claimed (they predate this
          // connection); opened ones go through _createClaimedRoom, so
          // the code the player receives always routes back here. If
          // every generated code is refused, the hello fails with an
          // error instead of stranding the player on an unroutable
          // room.
          try {
            room =
                authority.matchExisting(
                  member!,
                  game: game,
                  capacity: players,
                ) ??
                await _createClaimedRoom(
                  member!,
                  game: game,
                  capacity: players,
                );
          } on RoomRegistryException catch (_) {
            webSocket.sink.add(
              jsonEncode({
                'type': 'error',
                'text': 'could not open a room — try again in a moment',
              }),
            );
            return;
          }
          if (!room.started && room.members.length >= 2) {
            room.start();
            unawaited(
              adminStore.recordRoomStarted(room.code).catchError((Object _) {}),
            );
            // Push the initial snapshot to everyone — most importantly
            // the first player who has been waiting in the lobby.
            room.broadcastState();
          }
        } else if (code.isEmpty) {
          try {
            room = await _createClaimedRoom(
              member!,
              game: game,
              capacity: players,
            );
          } on RoomRegistryException catch (_) {
            webSocket.sink.add(
              jsonEncode({
                'type': 'error',
                'text': 'could not create a room — try again in a moment',
              }),
            );
            return;
          }
        } else {
          var joined = authority.joinWithColor(code, member!, color);
          // Not a fresh join — maybe a returning player reclaiming
          // their seat (lobby or mid-game).
          joined ??= authority.rejoinRoom(code, member!);
          if (joined == null) {
            final owner = await _foreignOwnerOf(code);
            webSocket.sink.add(
              jsonEncode({
                'type': 'error',
                'text': roomFullOrMissing(code),
                'owner': ?owner,
              }),
            );
            return;
          }
          room = joined;
        }
        // The hello above can await the registry (creation claim,
        // foreign-owner lookup), which gives the socket time to die.
        // If it did, undo the seating instead of announcing into a
        // dead connection: leaveRoom drops the just-created (empty)
        // room — closing it and unregistering the freshly claimed
        // code — or simply removes this player from a room that keeps
        // living without them.
        if (!_openConnections.contains(connId)) {
          authority.leaveRoom(room.code, connId);
          return;
        }
        roomCode = room.code;
        _connections[connId] = room.code;
        // Advertise the room immediately so a reconnect through any
        // edge can find this instance; the sweep keeps it fresh. For
        // claimed creations this is a no-op refresh under the same
        // token; for join/spectate/match paths it re-asserts a room
        // that may predate a registry outage. A refusal here is a
        // stale conflicting row for an already-live local room —
        // nothing this connection can fix, so it is ignored — and a
        // room that closes while the registration is in flight has its
        // route withdrawn again by [advertiseRoom].
        unawaited(advertiseRoom(room));
        webSocket.sink.add(
          jsonEncode({
            'type': 'joined',
            'code': room.code,
            'game': room.gameType,
            if (!spectate) 'color': member!.color.name,
            if (spectate) 'spectator': true,
          }),
        );
        room.broadcastLobbyIfChanged();
        // Who holds which corner, whether their link is live, whether the
        // table is playing for them, and who has left: the corner badges
        // and the "X left the game" notice both read this.
        room.broadcast(room.seatsJson());
        if (room.started) {
          // A mid-game rejoin or a spectator needs the current snapshot
          // to resume / watch; lobby players just wait for the broadcast
          // at start.
          webSocket.sink.add(
            jsonEncode({
              'type': 'state',
              'game': room.gameType,
              'state': room.stateJson(),
            }),
          );
        }
        return;
      }

      // Subsequent messages are game intents.
      if (roomCode != null) {
        final room = authority.rooms[roomCode];
        if (room != null) {
          authority.handleIntent(room: room, connectionId: connId, msg: msg);
          // Ship the roster only when it actually changed: the lobby lane
          // must not turn every dead letter or rejected intent into a
          // full re-serialization of stored metadata for the whole table
          // (the intent half of the CWE-400 bound — see
          // Room.broadcastLobbyIfChanged). A player who walks out in the
          // lobby still leaves everyone's seat list the moment a real
          // roster change ships it.
          room.broadcastLobbyIfChanged();
        }
      }
    },
    onDone: () {
      if (roomCode != null) authority.leaveRoom(roomCode!, connId);
      _connections.remove(connId);
      _openConnections.remove(connId);
    },
    onError: (_) {
      if (roomCode != null) authority.leaveRoom(roomCode!, connId);
      _connections.remove(connId);
      _openConnections.remove(connId);
    },
    cancelOnError: true,
  );
});

String roomFullOrMissing(String code) =>
    "room '$code' not found, already started, or full";

/// The instance that owns [code] when this replica does not. Attached to
/// "room not found" errors so the client can retry against the true owner:
/// room-affinity hashing routes by the code, but a room is created on
/// whichever replica the code-less first connection landed on, so a join
/// or reconnect carrying `?code=` can hash to a replica that never saw the
/// room. Returns null when the room is owned here, unknown cluster-wide
/// (truly gone — the plain error is definitive), or the registry is
/// unreachable (then behave exactly as before the reroute existed).
Future<String?> _foreignOwnerOf(String code) async {
  try {
    final owner = await roomRegistry.lookup(code.trim().toUpperCase());
    if (owner == null || owner == instanceId) return null;
    return owner;
  } on RoomRegistryException {
    return null;
  }
}

/// The documented JSON health check. Always served at GET /health; at GET /
/// only when no web build ships (with a build, / serves the game UI, so
/// probes must use /health).
///
/// Liveness does not depend on the leaderboard: a box whose Turso token is
/// wrong, or whose database is still waking up, is serving games perfectly
/// well, and calling it unhealthy makes the platform recycle an instance that
/// needed no recycling. So a store failure is reported *as data* — the `store`
/// field plus a `storeError` — instead of failing the probe. The friends
/// store reports the same way (`friendsStore` / `friendsError`).
Future<shelf.Response> healthHandler(shelf.Request req) async {
  Object? storeError;
  int? games;
  try {
    games = await leaderboardStore.totalGames();
  } catch (e) {
    storeError = e;
  }
  Object? friendsError;
  try {
    await friendStore.profile('');
  } catch (e) {
    friendsError = e;
  }
  return shelf.Response.ok(
    jsonEncode({
      'ok': true,
      'rooms': authority.rooms.length,
      'games': games,
      'store': leaderboardBackend,
      'friendsStore': friendsBackend,
      if (storeError != null) 'storeError': '$storeError',
      if (friendsError != null) 'friendsError': '$friendsError',
    }),
    headers: {'content-type': 'application/json'},
  );
}

/// Which leaderboard backend this instance writes to. Reported by /health and
/// /stats because the two ways the scoreboard can be broken look identical
/// from a phone — "the scores won't load" — and only one of them is fixed by
/// deploying code: without TURSO_DATABASE_URL + TURSO_AUTH_TOKEN the server
/// silently falls back to a SQLite file inside an ephemeral container, so its
/// scores reset on every restart, while a bad token fails every read outright.
String get leaderboardBackend {
  final store = leaderboardStore;
  if (store is TursoLeaderboardStore) return 'turso';
  if (store is SqliteLeaderboardStore) return 'sqlite';
  return store.runtimeType.toString();
}

/// Which friends backend this instance writes to — the same "silent reset vs
/// hard failure" distinction as [leaderboardBackend], one store over.
String get friendsBackend {
  final store = friendStore;
  if (store is TursoFriendStore) return 'turso';
  if (store is SqliteFriendStore) return 'sqlite';
  return store.runtimeType.toString();
}

/// CORS for the read-only JSON API (`/health`, `/leaderboard`, `/stats`,
/// `/rooms/lookup`) and the chat voice-note endpoints (`POST/GET
/// /media/voice`): the Flutter web dev server runs on another origin, so
/// without these headers a browser would fetch the data fine and then refuse
/// to hand the response to the app. WebSockets do not need a preflight, so
/// `/ws` is unaffected; writes stay rejected with 405, so `*` is safe here —
/// voice-note uploads are the one deliberate POST, gated by size caps and a
/// live room check rather than auth, matching the room chat they belong to.
/// No auth or cookies ride on these routes (Turso uses its own Bearer token
/// server-side), which is exactly the case `*` is meant for.
///
/// Public (not `_`-private) so the server integration tests can exercise the
/// exact middleware the deployed pipeline assembles.
shelf.Middleware get corsMiddleware =>
    (inner) => (req) async {
      if (req.method == 'OPTIONS') {
        return shelf.Response.ok('', headers: _corsHeaders(req));
      }
      final resp = await inner(req);
      return resp.change(headers: _corsHeaders(req));
    };

Map<String, String> _corsHeaders(shelf.Request req) => {
  'access-control-allow-origin': req.headers['origin'] ?? '*',
  // POST beats GET: every write route on this server (feedback, friends
  // actions, DM send) is a cross-origin POST from the web app, so the
  // preflight must advertise it or browsers refuse the real request.
  'access-control-allow-methods': 'GET, POST, OPTIONS',
  // Echoed back rather than a fixed list: a preflight that asks for a header
  // the server does not echo is rejected by the browser, and today only a
  // header-less GET or POST is ever made. Answering what was asked keeps a
  // future request (or a dev proxy adding one) from failing as a CORS error.
  'access-control-allow-headers':
      ?req.headers['access-control-request-headers'],
  'access-control-max-age': '600',
  'vary': 'Origin',
};

/// Turns a throw inside a route into an answer the client can actually read.
/// Left alone, the throw escapes to shelf's own error page: plain text, and
/// written *outside* the middleware chain, so it carries no CORS headers
/// either — a browser then reports it as a cross-origin block and the app
/// blames the connection, which is exactly how a broken Turso credential
/// looked like a dead server. Must sit inside [corsMiddleware] so the 500 it
/// produces still gets the headers, and it names the failing route because
/// the deployed log otherwise shows a 500 with nothing to trace.
///
/// A WebSocket upgrade is not a failure and must pass through untouched (see
/// the `on shelf.HijackException` clause below).
shelf.Middleware get jsonErrorMiddleware =>
    (inner) => (req) async {
      try {
        return await inner(req);
      } on shelf.HijackException {
        // Not a failure: this is how /ws tells shelf_io the socket is now a
        // WebSocket. Shelf's own guidance is that middleware capturing
        // exceptions must let it through — swallowing it here answered a
        // request whose stream no longer existed, so every single connection
        // logged a bogus "500 on GET /ws" and shelf_io then complained it had
        // been handed a response for a hijacked request. The upgrade itself
        // always worked; only the log lied.
        rethrow;
      } catch (error) {
        stdout.writeln('!! 500 on ${req.method} /${req.url.path}: $error');
        // The detail stays in the log: a store failure can quote the Turso
        // URL or token, and this route is public.
        return shelf.Response.internalServerError(
          body: jsonEncode({
            'ok': false,
            'text': 'Internal server error (see server log)',
          }),
          headers: {'content-type': 'application/json'},
        );
      }
    };

/// Capacity metrics for load balancers and dashboards. Connections counts
/// every open WebSocket (joined or not); rooms/spectators come from the
/// authority. Intentionally touches no remote store so it stays cheap —
/// unlike `/health`, which is allowed to answer even when the scoreboard
/// store is down, so a broken leaderboard never looks like a dead server.
Future<shelf.Response> statsHandler(shelf.Request req) async {
  var spectators = 0;
  for (final room in authority.rooms.values) {
    spectators += room.spectators.length;
  }
  return shelf.Response.ok(
    jsonEncode({
      'ok': true,
      'instance': instanceId,
      'connections': _openConnections.length,
      'rooms': authority.rooms.length,
      'spectators': spectators,
      'leaderboardBackend': leaderboardBackend,
      'friendsBackend': friendsBackend,
    }),
    headers: {'content-type': 'application/json'},
  );
}

/// Which instance owns a room code — the cross-instance routing hook. An
/// edge/proxy calls this when a WebSocket lands on the wrong replica and
/// forwards or 302s the client to the returned instance.
Future<shelf.Response> roomLookupHandler(shelf.Request req) async {
  if (req.method != 'GET') {
    return shelf.Response(
      405,
      body: jsonEncode({'ok': false, 'text': 'GET only'}),
      headers: {'content-type': 'application/json'},
    );
  }
  final code = (req.url.queryParameters['code'] ?? '').trim().toUpperCase();
  if (code.isEmpty) {
    return shelf.Response(
      400,
      body: jsonEncode({'ok': false, 'text': 'code query param required'}),
      headers: {'content-type': 'application/json'},
    );
  }
  final owner = await roomRegistry.lookup(code);
  if (owner == null) {
    return shelf.Response(
      404,
      body: jsonEncode({
        'ok': false,
        'text': "room '$code' unknown to the cluster",
      }),
      headers: {'content-type': 'application/json'},
    );
  }
  return shelf.Response.ok(
    jsonEncode({'ok': true, 'code': code, 'instance': owner}),
    headers: {'content-type': 'application/json'},
  );
}

Future<shelf.Response> leaderboardHandler(shelf.Request req) async {
  if (req.method != 'GET') {
    return shelf.Response(
      405,
      body: jsonEncode({'ok': false, 'text': 'GET only'}),
      headers: {'content-type': 'application/json'},
    );
  }
  // ?game=snakes (or ludo) narrows the board to one game; omitting it keeps
  // the combined board. The per-game counts are always reported so a client
  // can label the tabs ("Ludo 12 · Snakes 4") without a request per tab.
  final requested = req.url.queryParameters['game'];
  final game = switch (requested) {
    'ludo' => 'ludo',
    'snakes' => 'snakes',
    _ => null,
  };
  return shelf.Response.ok(
    jsonEncode({
      'ok': true,
      'games': await leaderboardStore.totalGames(game: game),
      'game': game ?? 'all',
      'gamesByGame': {
        'ludo': await leaderboardStore.totalGames(game: 'ludo'),
        'snakes': await leaderboardStore.totalGames(game: 'snakes'),
      },
      'players': [
        for (final e in await leaderboardStore.topPlayers(game: game))
          e.toJson(),
      ],
    }),
    headers: {'content-type': 'application/json'},
  );
}

/// True when [req] carries the configured admin bearer token. Empty
/// [adminToken] disables the whole admin surface (deny-all).
bool _legacyTokenMatch(shelf.Request req) {
  if (adminToken.isEmpty) return false;
  final header = req.headers['authorization'] ?? '';
  const prefix = 'Bearer ';
  if (!header.startsWith(prefix)) return false;
  final presented = header.substring(prefix.length).trim();
  if (presented.length != adminToken.length) return false;
  var diff = 0;
  for (var i = 0; i < presented.length; i++) {
    diff |= presented.codeUnitAt(i) ^ adminToken.codeUnitAt(i);
  }
  return diff == 0;
}

String? _presentedToken(shelf.Request req) {
  final header = req.headers['authorization'] ?? '';
  const prefix = 'Bearer ';
  if (!header.startsWith(prefix)) return null;
  final token = header.substring(prefix.length).trim();
  return token.isEmpty ? null : token;
}

/// The session's admin user, or null. Legacy ADMIN_TOKEN callers have no
/// identity — use 'admin-token' when auditing their actions.
Future<AuthUser?> adminIdentity(shelf.Request req) async {
  final token = _presentedToken(req);
  if (token == null) return null;
  try {
    final user = await adminStore.validateSession(token);
    if (user != null && user.isAdmin) return user;
  } catch (_) {}
  return null;
}

/// Authorized when the request carries a live admin session OR the legacy
/// ADMIN_TOKEN service token. The legacy path stays for automation and
/// backwards compatibility; interactive logins use sessions.
Future<bool> isAdminAuthorized(shelf.Request req) async {
  if (await adminIdentity(req) != null) return true;
  return _legacyTokenMatch(req);
}

// ------------------------------------------------------------------ login
// rate limiting: per-IP sliding window on FAILED logins only. Successes
// never count, so a correct password always works. Test-only reset via
// [resetLoginAttempts].
const _loginWindow = Duration(seconds: 60);
const _maxLoginFailures = 10;

final _loginFailures = <String, List<int>>{};

bool loginRateLimited(String ip) {
  final now = DateTime.now().millisecondsSinceEpoch;
  final cutoff = now - _loginWindow.inMilliseconds;
  final hits = (_loginFailures[ip] ?? []).where((t) => t > cutoff).toList();
  _loginFailures[ip] = hits;
  return hits.length >= _maxLoginFailures;
}

void _recordLoginFailure(String ip) {
  final now = DateTime.now().millisecondsSinceEpoch;
  _loginFailures.update(ip, (hits) => [...hits, now], ifAbsent: () => [now]);
}

/// Test-only: clears the in-memory login failure buckets.
void resetLoginAttempts() => _loginFailures.clear();

// Feedback throttling: the report/contact endpoints are unauthenticated,
// so per-IP buckets keep the queue (and the DB) from being flooded. Two
// windows: a short burst cap and a daily cap.
final _feedbackBurst = <String, List<int>>{};
final _feedbackDaily = <String, List<int>>{};
const _feedbackBurstWindow = Duration(hours: 1);
const _feedbackDailyWindow = Duration(days: 1);
const _maxFeedbackBurst = 5; // per hour per IP
const _maxFeedbackDaily = 20; // per day per IP

bool _feedbackRateLimited(String ip) {
  final now = DateTime.now().millisecondsSinceEpoch;
  bool over(Map<String, List<int>> hits, Duration window, int max) {
    final cutoff = now - window.inMilliseconds;
    final kept = (hits[ip] ?? []).where((t) => t > cutoff).toList();
    hits[ip] = kept;
    return kept.length >= max;
  }

  return over(_feedbackBurst, _feedbackBurstWindow, _maxFeedbackBurst) ||
      over(_feedbackDaily, _feedbackDailyWindow, _maxFeedbackDaily);
}

void _recordFeedbackHit(String ip) {
  final now = DateTime.now().millisecondsSinceEpoch;
  _feedbackBurst.update(ip, (h) => [...h, now], ifAbsent: () => [now]);
  _feedbackDaily.update(ip, (h) => [...h, now], ifAbsent: () => [now]);
}

/// Test-only: clears the feedback throttling buckets.
void resetFeedbackAttempts() {
  _feedbackBurst.clear();
  _feedbackDaily.clear();
}

// ----------------------------------------------------------------------------
// Friends: requests, list, DMs (like + reply), play invites. The player's
// seat id — the identity the WS hello already asserts — rides in every
// call, and the store holds per-seat caps while this layer throttles per
// IP: the same two-layer bounding the unauthenticated report endpoint uses.
// ----------------------------------------------------------------------------

/// Durable friends state. Tests swap in an in-memory store; main() points
/// it at Turso when configured, otherwise the same shared SQLite connection
/// as admin history and feedback.
FriendStore friendStore = SqliteFriendStore.inMemory();

final _friendActionsBurst = <String, List<int>>{};
final _friendActionsDaily = <String, List<int>>{};
final _friendChatBurst = <String, List<int>>{};
final _friendChatDaily = <String, List<int>>{};
const _maxFriendActionBurst = 40; // per hour per IP
const _maxFriendActionDaily = 200; // per day per IP
const _maxFriendChatBurst = 120; // per hour per IP
const _maxFriendChatDaily = 400; // per day per IP

bool _friendRateLimited(
  String ip, {
  required Map<String, List<int>> burst,
  required Map<String, List<int>> daily,
  required int maxBurst,
  required int maxDaily,
}) {
  final now = DateTime.now().millisecondsSinceEpoch;
  bool over(Map<String, List<int>> hits, Duration window, int max) {
    final cutoff = now - window.inMilliseconds;
    final kept = (hits[ip] ?? []).where((t) => t > cutoff).toList();
    hits[ip] = kept;
    return kept.length >= max;
  }

  return over(burst, _feedbackBurstWindow, maxBurst) ||
      over(daily, _feedbackDailyWindow, maxDaily);
}

void _recordFriendHit(
  String ip, {
  required Map<String, List<int>> burst,
  required Map<String, List<int>> daily,
}) {
  final now = DateTime.now().millisecondsSinceEpoch;
  burst.update(ip, (h) => [...h, now], ifAbsent: () => [now]);
  daily.update(ip, (h) => [...h, now], ifAbsent: () => [now]);
}

/// Test-only: clears every friend throttling bucket.
void resetFriendAttempts() {
  _friendActionsBurst.clear();
  _friendActionsDaily.clear();
  _friendChatBurst.clear();
  _friendChatDaily.clear();
}

shelf.Response _friendJson(Object body, [int status = 200]) => shelf.Response(
  status,
  body: jsonEncode(body),
  headers: {'content-type': 'application/json'},
);

shelf.Response _friendBadRequest(String text, {int code = 400}) =>
    _friendJson({'ok': false, 'text': text}, code);

Future<shelf.Response?> _friendBanned(String seatId) async {
  if (seatId.isEmpty) return null;
  try {
    if (await adminStore.isBanned(seatId)) {
      return _friendBadRequest('banned', code: 403);
    }
  } catch (_) {
    // A store outage is not a ban — reads stay available, writes too; the
    // health check reports the outage instead of a ban hiding it.
  }
  return null;
}

/// The whole friends bundle for one player: their own profile with the
/// minted friend code, accepted friends (each with the pair's latest
/// message id for unread dots), pending requests in both directions and
/// live play invites. One call = one screen of state, so the screen can
/// The players seated in the rooms [seatId] is a member of right now,
/// freshest seat names, capped — the friends screen's "At your table"
/// rows. A seat id may appear under several connections (reconnects); a
/// map keyed by seat id keeps it one row per person. Self is never her
/// own discovery; lanes already covered ([covered]) are filtered so a
/// section never re-lists someone the screen shows elsewhere.
List<Map<String, Object?>> tableRowsFor(String seatId, Set<String> covered) {
  final picked = <String, String>{};
  for (final room in authority.rooms.values) {
    final seated = room.members.values.any((m) => m.seatId == seatId);
    if (!seated) continue;
    for (final member in room.members.values) {
      if (member.seatId == seatId ||
          member.seatId.isEmpty ||
          covered.contains(member.seatId)) {
        continue;
      }
      picked.putIfAbsent(member.seatId, () => member.name);
    }
  }
  // Name-sorted so one person's row does not hop between polls, and
  // capped like every other store read: a room is four people and a
  // handful of extras, but the generosity is bounded regardless.
  final rows = [
    for (final entry
        in picked.entries.toList()..sort(
          (a, b) => a.value.toLowerCase().compareTo(b.value.toLowerCase()),
        ))
      {'seatId': entry.key, 'name': entry.value},
  ];
  return rows.length > 32 ? rows.sublist(0, 32) : rows;
}

/// poll coarsely.
Future<shelf.Response> friendsStateHandler(shelf.Request req) async {
  if (req.method != 'POST') {
    return _friendBadRequest('POST only', code: 405);
  }
  final body = await _readJsonBody(req);
  final seatId = (body['seatId'] as String? ?? '').trim();
  final name = (body['name'] as String? ?? 'Player').trim();
  if (seatId.isEmpty || name.isEmpty) {
    return _friendBadRequest('seatId and name required');
  }
  if (await _friendBanned(seatId) case final banned?) return banned;
  final profile = await friendStore.serve(seatId, name);
  unawaited(
    adminStore
        .recordPresence(seatId: profile.seatId, name: profile.name)
        .catchError((Object _) {}),
  );
  final friendEntries = await friendStore.friends(seatId);
  final incoming = await friendStore.incoming(seatId);
  final outgoing = await friendStore.outgoing(seatId);
  final blocked = await friendStore.blocks(seatId);
  // Every friend's read marker in one read: a state poll must not fan out
  // one remote round trip per friend (the ceiling is 200 friends).
  final latest = friendEntries.isEmpty
      ? const <String, int>{}
      : await friendStore.latestMessageIds(seatId);
  final friends = [
    for (final f in friendEntries)
      {...f.toJson(), 'latest': latest[f.seatId] ?? 0},
  ];
  // Table discovery: everyone seated in the rooms this caller is sitting
  // in right now, minus the people a relationship lane already covers
  // (friends, pending requests, blocks). The friends screen renders them
  // as one "At your table" section, each row opening the same actions
  // sheet the table rows use — the all-users directory is retired, so
  // this poll is the only friend-discovery surface left, and it must
  // reflect the room the caller can actually see.
  final covered = <String>{
    for (final f in friends) f['seatId'] as String,
    for (final r in incoming) r.fromSeat,
    for (final r in outgoing) r.toSeat,
    for (final b in blocked) b.blocked,
  };
  return _friendJson({
    'ok': true,
    'me': profile.toJson(),
    'friends': friends,
    'table': tableRowsFor(seatId, covered),
    'incoming': [for (final r in incoming) r.toJson()],
    'outgoing': [for (final r in outgoing) r.toJson()],
    'invites': [for (final i in await friendStore.invites(seatId)) i.toJson()],
    'blocked': [for (final b in blocked) b.toJson()],
    'time': DateTime.now().millisecondsSinceEpoch,
  });
}

/// Resolves a target for the add-friend form before the request goes out,
/// so the player sees WHOSE code they typed ("This is Swift Otter — add?")
/// rather than a friend request to an opaque id. Both code and seat id
/// resolve; a miss is 404, and the UI words it.
Future<shelf.Response> friendsLookupHandler(shelf.Request req) async {
  if (req.method != 'POST') {
    return _friendBadRequest('POST only', code: 405);
  }
  final body = await _readJsonBody(req);
  final target = await friendStore.resolveTarget(
    (body['target'] as String? ?? '').trim(),
  );
  if (target == null) {
    return _friendBadRequest('no player with that friend code', code: 404);
  }
  return _friendJson({'ok': true, 'profile': target.toJson()});
}

/// Sends (or matches, when the reverse request is standing) a friend
/// request.
Future<shelf.Response> friendsRequestHandler(shelf.Request req) async {
  if (req.method != 'POST') {
    return _friendBadRequest('POST only', code: 405);
  }
  final ip = _clientIp(req);
  if (_friendRateLimited(
    ip,
    burst: _friendActionsBurst,
    daily: _friendActionsDaily,
    maxBurst: _maxFriendActionBurst,
    maxDaily: _maxFriendActionDaily,
  )) {
    return _friendBadRequest(
      'too many friend actions — try again later',
      code: 429,
    );
  }
  final body = await _readJsonBody(req);
  final seatId = (body['seatId'] as String? ?? '');
  final target = (body['target'] as String? ?? '');
  try {
    final status = await friendStore.sendRequest(
      seatId,
      (body['name'] as String? ?? 'Player'),
      target,
      // The room context passes the seatmate's roster name: the table
      // add-friend flow targets ids, and a player who never opened the
      // friends screen still has no profile to resolve until this mints.
      targetName: (body['targetName'] as String?)?.trim(),
    );
    _recordFriendHit(
      ip,
      burst: _friendActionsBurst,
      daily: _friendActionsDaily,
    );
    return _friendJson({'ok': true, 'status': status});
  } on ArgumentError catch (e) {
    return _friendBadRequest(e.message.toString());
  } on StateError catch (e) {
    return _friendBadRequest(e.message.toString());
  }
}

/// Accepts / declines a request, withdraws a sent one, or breaks up.
Future<shelf.Response> friendsRespondHandler(shelf.Request req) async {
  if (req.method != 'POST') {
    return _friendBadRequest('POST only', code: 405);
  }
  final ip = _clientIp(req);
  if (_friendRateLimited(
    ip,
    burst: _friendActionsBurst,
    daily: _friendActionsDaily,
    maxBurst: _maxFriendActionBurst,
    maxDaily: _maxFriendActionDaily,
  )) {
    return _friendBadRequest(
      'too many friend actions — try again later',
      code: 429,
    );
  }
  final body = await _readJsonBody(req);
  final seatId = (body['seatId'] as String? ?? '').trim();
  final id = int.tryParse('${body['id']}') ?? -1;
  if (id < 0) return _friendBadRequest('id required');
  final accept = body['accept'] as bool? ?? false;
  final acting = await _friendBanned(seatId);
  if (acting != null) return acting;
  final ok = accept
      ? await friendStore.respond(seatId, id, accept: true)
      : body['withdraw'] == true
      ? await friendStore.cancel(seatId, id)
      : await friendStore.respond(seatId, id, accept: false);
  _recordFriendHit(ip, burst: _friendActionsBurst, daily: _friendActionsDaily);
  return _friendJson({'ok': ok});
}

/// Un-friends. Seat id + target seat id; one either side ends the pair.
Future<shelf.Response> friendsRemoveHandler(shelf.Request req) async {
  if (req.method != 'POST') {
    return _friendBadRequest('POST only', code: 405);
  }
  final body = await _readJsonBody(req);
  final seatId = (body['seatId'] as String? ?? '').trim();
  final target = (body['target'] as String? ?? '').trim();
  if (seatId.isEmpty || target.isEmpty) {
    return _friendBadRequest('seatId and target required');
  }
  final acting = await _friendBanned(seatId);
  if (acting != null) return acting;
  if (!await friendStore.areFriends(seatId, target)) {
    return _friendBadRequest('not friends', code: 404);
  }
  await friendStore.remove(seatId, target);
  return _friendJson({'ok': true});
}

/// Blocks a player: severs the friendship, drops pendings between them,
/// and denies all contact both ways until unblocked.
Future<shelf.Response> friendsBlockHandler(shelf.Request req) async {
  if (req.method != 'POST') {
    return _friendBadRequest('POST only', code: 405);
  }
  final body = await _readJsonBody(req);
  final seatId = (body['seatId'] as String? ?? '').trim();
  final target = (body['target'] as String? ?? '').trim();
  if (seatId.isEmpty || target.isEmpty) {
    return _friendBadRequest('seatId and target required');
  }
  if (await _friendBanned(seatId) case final banned?) return banned;
  try {
    await friendStore.block(
      seatId,
      target,
      // Roster-name mint for a tablemate with no friends profile yet —
      // the block flow must not depend on the target's menu history.
      targetName: (body['targetName'] as String?)?.trim(),
    );
    return _friendJson({'ok': true, 'blocked': true});
  } on ArgumentError catch (e) {
    return _friendBadRequest(e.message.toString());
  } on StateError catch (e) {
    return _friendBadRequest(e.message.toString());
  }
}

/// Lifts the caller's block on a player. `ok: true` only when one
/// actually existed — the settings screen reads it as "unblocked".
Future<shelf.Response> friendsUnblockHandler(shelf.Request req) async {
  if (req.method != 'POST') {
    return _friendBadRequest('POST only', code: 405);
  }
  final body = await _readJsonBody(req);
  final seatId = (body['seatId'] as String? ?? '').trim();
  final target = (body['target'] as String? ?? '').trim();
  if (seatId.isEmpty || target.isEmpty) {
    return _friendBadRequest('seatId and target required');
  }
  if (await _friendBanned(seatId) case final banned?) return banned;
  final ok = await friendStore.unblock(seatId, target);
  return _friendJson({'ok': ok});
}

/// Reports a player to the admin queue — same pipeline as bug reports,
/// with the 'player' category. The caller's seat id lands in `seatId`
/// (who reported) and the accused's name + seat id + the free-text reason
/// ride in the message, so admins see the pair at a glance.
Future<shelf.Response> friendsReportHandler(shelf.Request req) async {
  if (req.method != 'POST') {
    return _friendBadRequest('POST only', code: 405);
  }
  final ip = _clientIp(req);
  // Reuses the feedback flood guard: a report is a report, whoever files it.
  if (_feedbackRateLimited(ip)) {
    return _friendBadRequest(
      'too many reports — please try again later',
      code: 429,
    );
  }
  final body = await _readJsonBody(req);
  final seatId = (body['seatId'] as String? ?? '').trim();
  final target = (body['target'] as String? ?? '').trim();
  if (seatId.isEmpty || target.isEmpty) {
    return _friendBadRequest('seatId and target required');
  }
  if (await _friendBanned(seatId) case final banned?) return banned;
  final name = await reportStoreLookupName(
    target,
    body['name'] as String? ?? '',
  );
  try {
    final entry = await reportStore.create(
      category: 'player',
      source: 'report',
      title: 'Player report: $name',
      message:
          'Reported player "$name" ($target) — reason: '
          '${(body['reason'] as String? ?? '').trim()}',
      seatId: seatId,
      contact: body['contact'] as String?,
      appVersion: body['appVersion'] as String?,
    );
    _recordFeedbackHit(ip);
    return _friendJson({'ok': true, 'id': entry.id});
  } on ArgumentError catch (e) {
    return _friendBadRequest(e.message.toString());
  }
}

/// The display name for a reported player: prefer the profile's live name,
/// fall back to the one the client sent with the report.
Future<String> reportStoreLookupName(String seatId, String fallback) async {
  final profile = await friendStore.profile(seatId);
  if (profile != null && profile.name.trim().isNotEmpty) return profile.name;
  return fallback.trim().isEmpty ? seatId : fallback.trim();
}

/// DM history. GET: polling readers pass `seatId`, `peer`, and optionally
/// `since` (a message id) to pay bytes only for the gap. Unread work on
/// the client stores [FriendChatPage.latestId] as its read marker.
Future<shelf.Response> friendsChatHandler(shelf.Request req) async {
  if (req.method == 'POST') {
    return _friendBadRequest(
      'GET for reads — send messages to friends/chat/send',
      code: 405,
    );
  }
  if (req.method != 'GET') {
    return _friendBadRequest('GET only', code: 405);
  }
  final q = req.url.queryParameters;
  final seatId = (q['seatId'] ?? '').trim();
  final peer = (q['peer'] ?? '').trim();
  if (seatId.isEmpty || peer.isEmpty) {
    return _friendBadRequest('seatId and peer query params required');
  }
  if (await _friendBanned(seatId) case final banned?) return banned;
  final page = await friendStore.chat(
    seatId,
    peer,
    since: int.tryParse(q['since'] ?? ''),
    limit: int.tryParse(q['limit'] ?? '') ?? 50,
  );
  return _friendJson({
    'ok': true,
    'messages': [for (final m in page.messages) m.toJson()],
    'latest': page.latestId,
  });
}

/// Sends a DM (with an optional reply quote the caller picked).
Future<shelf.Response> friendsChatSendHandler(shelf.Request req) async {
  if (req.method != 'POST') {
    return _friendBadRequest('POST only', code: 405);
  }
  final ip = _clientIp(req);
  if (_friendRateLimited(
    ip,
    burst: _friendChatBurst,
    daily: _friendChatDaily,
    maxBurst: _maxFriendChatBurst,
    maxDaily: _maxFriendChatDaily,
  )) {
    return _friendBadRequest('slow down a moment — try again soon', code: 429);
  }
  final body = await _readJsonBody(req);
  final seatId = (body['seatId'] as String? ?? '').trim();
  final to = (body['to'] as String? ?? '').trim();
  if (seatId.isEmpty || to.isEmpty) {
    return _friendBadRequest('seatId and to required');
  }
  if (await _friendBanned(seatId) case final banned?) return banned;
  try {
    final message = await friendStore.send(
      seatId,
      to,
      body['body'] as String? ?? '',
      replyTo: (body['replyTo'] as num?)?.toInt(),
    );
    _recordFriendHit(ip, burst: _friendChatBurst, daily: _friendChatDaily);
    return _friendJson({'ok': true, 'message': message.toJson()});
  } on ArgumentError catch (e) {
    return _friendBadRequest(e.message.toString());
  } on StateError catch (e) {
    return _friendBadRequest(e.message.toString());
  }
}

/// Likes (or unlikes) a DM. Either participant may act.
Future<shelf.Response> friendsChatLikeHandler(shelf.Request req) async {
  if (req.method != 'POST') {
    return _friendBadRequest('POST only', code: 405);
  }
  final body = await _readJsonBody(req);
  final seatId = (body['seatId'] as String? ?? '').trim();
  final id = int.tryParse('${body['messageId']}') ?? -1;
  if (id < 0) return _friendBadRequest('messageId required');
  if (await _friendBanned(seatId) case final banned?) return banned;
  try {
    final message = await friendStore.like(
      seatId,
      id,
      liked: body['liked'] as bool? ?? true,
    );
    if (message == null) {
      return _friendBadRequest('message not yours', code: 404);
    }
    return _friendJson({'ok': true, 'liked': message.liked});
  } on ArgumentError catch (e) {
    return _friendBadRequest(e.message.toString());
  }
}

/// Invites a friend to a game: the caller picked Ludo or Snakes and posts
/// the game, plus the room code when (as the normal flow does) their app
/// has already opened a room for it. Game only, no code, is a "hold my
/// table" invite that gets its code later — no, it never does: the flow
/// creates the room first and links it here, so a code-less invite is a
/// rider the client made deliberately (tests, future flows).
Future<shelf.Response> friendsInviteHandler(shelf.Request req) async {
  if (req.method != 'POST') {
    return _friendBadRequest('POST only', code: 405);
  }
  final ip = _clientIp(req);
  if (_friendRateLimited(
    ip,
    burst: _friendActionsBurst,
    daily: _friendActionsDaily,
    maxBurst: _maxFriendActionBurst,
    maxDaily: _maxFriendActionDaily,
  )) {
    return _friendBadRequest(
      'too many friend actions — try again later',
      code: 429,
    );
  }
  final body = await _readJsonBody(req);
  final seatId = (body['seatId'] as String? ?? '');
  if (await _friendBanned(seatId.trim()) case final banned?) return banned;
  try {
    final invite = await friendStore.sendInvite(
      seatId,
      body['name'] as String? ?? 'Player',
      body['to'] as String? ?? '',
      body['game'] as String? ?? '',
      code: body['code'] as String?,
    );
    _recordFriendHit(
      ip,
      burst: _friendActionsBurst,
      daily: _friendActionsDaily,
    );
    // Real-time when the invitee is at a table; the app-level poll covers
    // the home screen and the friends tray.
    _pulseFriendSeat(invite.toSeat);
    return _friendJson({'ok': true, 'invite': invite.toJson()});
  } on ArgumentError catch (e) {
    return _friendBadRequest(e.message.toString());
  } on StateError catch (e) {
    return _friendBadRequest(e.message.toString());
  }
}

/// The invitee answers. Accept returns the room code (when the invite
/// carried one) so the app can join directly; decline closes it.
Future<shelf.Response> friendsInviteRespondHandler(shelf.Request req) async {
  if (req.method != 'POST') {
    return _friendBadRequest('POST only', code: 405);
  }
  final ip = _clientIp(req);
  if (_friendRateLimited(
    ip,
    burst: _friendActionsBurst,
    daily: _friendActionsDaily,
    maxBurst: _maxFriendActionBurst,
    maxDaily: _maxFriendActionDaily,
  )) {
    return _friendBadRequest(
      'too many friend actions — try again later',
      code: 429,
    );
  }
  final body = await _readJsonBody(req);
  final seatId = (body['seatId'] as String? ?? '').trim();
  if (seatId.isEmpty) return _friendBadRequest('seatId required');
  final id = int.tryParse('${body['id']}') ?? -1;
  if (id < 0) return _friendBadRequest('id required');
  if (await _friendBanned(seatId) case final banned?) return banned;
  // Accept → the room code when the invite carried one (null when it was
  // code-less); decline → null. Answering twice, or someone else's
  // invite, also resolves to null — the client re-polls state and moves
  // on, so the response shape stays uniform.
  final code = await friendStore.respondInvite(
    seatId,
    id,
    accept: body['accept'] as bool? ?? false,
  );
  _recordFriendHit(ip, burst: _friendActionsBurst, daily: _friendActionsDaily);
  return _friendJson({'ok': true, 'code': code});
}

String _clientIp(shelf.Request req) {
  final info = req.context['shelf.io.connection_info'];
  try {
    final addr = (info as dynamic).remoteAddress;
    return addr?.address as String? ?? 'unknown';
  } catch (_) {
    return 'unknown';
  }
}

Future<shelf.Response> adminStatusHandler(shelf.Request req) async {
  return shelf.Response.ok(
    jsonEncode({'ok': true, 'setupRequired': await adminStore.needsSetup}),
    headers: {'content-type': 'application/json'},
  );
}

/// One-time bootstrap: creates the FIRST account (role admin). Allowed
/// only while no users exist and only with the ADMIN_TOKEN setup secret —
/// an open first-run setup lets anyone who reaches /admin first claim the
/// instance, so the token is always required (fail closed when unset).
Future<shelf.Response> adminSetupHandler(shelf.Request req) async {
  if (!await adminStore.needsSetup) {
    return shelf.Response.forbidden(
      jsonEncode({'ok': false, 'text': 'setup already complete'}),
      headers: {'content-type': 'application/json'},
    );
  }
  if (adminToken.isEmpty) {
    return shelf.Response.forbidden(
      jsonEncode({
        'ok': false,
        'text': 'setup disabled: ADMIN_TOKEN is not configured',
      }),
      headers: {'content-type': 'application/json'},
    );
  }
  final body = await _readJsonBody(req);
  if ((body['setupToken'] as String? ?? '') != adminToken) {
    return shelf.Response.forbidden(
      jsonEncode({'ok': false, 'text': 'invalid setup token'}),
      headers: {'content-type': 'application/json'},
    );
  }
  final email = (body['email'] as String? ?? '').trim();
  final name = (body['name'] as String? ?? '').trim();
  final password = (body['password'] as String? ?? '');
  try {
    final user = await adminStore.createUser(
      email: email,
      name: name.isEmpty ? email : name,
      password: password,
      role: 'admin',
      by: 'setup',
    );
    final session = await adminStore.createSession(user.id);
    return shelf.Response.ok(
      jsonEncode({
        'ok': true,
        'token': session.token,
        'expiresAt': session.expiresAt,
        'user': user.toJson(),
      }),
      headers: {'content-type': 'application/json'},
    );
  } on ArgumentError catch (e) {
    return shelf.Response(
      400,
      body: jsonEncode({'ok': false, 'text': e.message}),
      headers: {'content-type': 'application/json'},
    );
  } on StateError catch (e) {
    return shelf.Response(
      400,
      body: jsonEncode({'ok': false, 'text': e.message}),
      headers: {'content-type': 'application/json'},
    );
  }
}

Future<shelf.Response> adminLoginHandler(shelf.Request req) async {
  final ip = _clientIp(req);
  if (loginRateLimited(ip)) {
    return shelf.Response(
      429,
      body: jsonEncode({
        'ok': false,
        'text': 'too many attempts — wait a minute',
      }),
      headers: {'content-type': 'application/json'},
    );
  }
  final body = await _readJsonBody(req);
  final user = await adminStore.checkCredentials(
    (body['email'] as String? ?? ''),
    (body['password'] as String? ?? ''),
  );
  if (user == null) {
    _recordLoginFailure(ip);
    return shelf.Response(
      401,
      body: jsonEncode({'ok': false, 'text': 'invalid credentials'}),
      headers: {'content-type': 'application/json'},
    );
  }
  final session = await adminStore.createSession(user.id);
  return shelf.Response.ok(
    jsonEncode({
      'ok': true,
      'token': session.token,
      'expiresAt': session.expiresAt,
      'user': user.toJson(),
    }),
    headers: {'content-type': 'application/json'},
  );
}

Future<shelf.Response> adminLogoutHandler(shelf.Request req) async {
  final token = _presentedToken(req);
  if (token != null) {
    await adminStore.revokeSession(token);
  }
  return shelf.Response.ok(
    jsonEncode({'ok': true}),
    headers: {'content-type': 'application/json'},
  );
}

/// The calling session's account. Session-only: the legacy service token
/// carries no identity, so it gets a 401 here by design.
Future<shelf.Response> adminMeHandler(shelf.Request req) async {
  final user = await adminIdentity(req);
  if (user == null) {
    return shelf.Response(
      401,
      body: jsonEncode({'ok': false, 'text': 'session required'}),
      headers: {'content-type': 'application/json'},
    );
  }
  return shelf.Response.ok(
    jsonEncode({'ok': true, 'user': user.toJson()}),
    headers: {'content-type': 'application/json'},
  );
}

Future<shelf.Response> adminUsersHandler(shelf.Request req) async {
  if (!await isAdminAuthorized(req)) return _adminDenied();
  if (req.method == 'GET') {
    final users = await adminStore.listUsers();
    return shelf.Response.ok(
      jsonEncode({
        'ok': true,
        'users': [for (final u in users) u.toJson()],
      }),
      headers: {'content-type': 'application/json'},
    );
  }
  final by = (await adminIdentity(req))?.email ?? 'admin-token';
  final body = await _readJsonBody(req);
  try {
    final user = await adminStore.createUser(
      email: (body['email'] as String? ?? ''),
      name: (body['name'] as String? ?? ''),
      password: (body['password'] as String? ?? ''),
      role: (body['role'] as String? ?? 'user'),
      by: by,
    );
    return shelf.Response.ok(
      jsonEncode({'ok': true, 'user': user.toJson()}),
      headers: {'content-type': 'application/json'},
    );
  } on ArgumentError catch (e) {
    return shelf.Response(
      400,
      body: jsonEncode({'ok': false, 'text': e.message}),
      headers: {'content-type': 'application/json'},
    );
  } on StateError catch (e) {
    return shelf.Response(
      400,
      body: jsonEncode({'ok': false, 'text': e.message}),
      headers: {'content-type': 'application/json'},
    );
  }
}

shelf.Response _adminDenied() => shelf.Response.forbidden(
  jsonEncode({'ok': false, 'text': 'admin disabled or unauthorized'}),
  headers: {'content-type': 'application/json'},
);

Future<shelf.Response> adminOverviewHandler(shelf.Request req) async {
  if (!await isAdminAuthorized(req)) return _adminDenied();
  var spectators = 0;
  for (final room in authority.rooms.values) {
    spectators += room.spectators.length;
  }
  final overview = await adminStore.overview();
  final games = await leaderboardStore.totalGames();
  return shelf.Response.ok(
    jsonEncode({
      'ok': true,
      'instance': instanceId,
      'live': {
        'connections': _openConnections.length,
        'rooms': authority.rooms.length,
        'spectators': spectators,
      },
      'stored': {
        ...overview.toJson(),
        'finishedGames': games,
        'gamesByGame': {
          'ludo': await leaderboardStore.totalGames(game: 'ludo'),
          'snakes': await leaderboardStore.totalGames(game: 'snakes'),
        },
        'openFeedback': await reportStore.count(status: 'open'),
        'feedbackByCategory': reportStore.openByCategory(),
      },
      'leaderboardBackend': leaderboardBackend,
    }),
    headers: {'content-type': 'application/json'},
  );
}

Future<shelf.Response> adminPlayersHandler(shelf.Request req) async {
  if (!await isAdminAuthorized(req)) return _adminDenied();
  final limit =
      int.tryParse(req.url.queryParameters['limit'] ?? '')?.clamp(1, 500) ??
      100;
  final players = await adminStore.allPlayers(limit: limit);
  final out = <Map<String, dynamic>>[];
  for (final p in players) {
    out.add({
      'seatId': p.seatId,
      'name': p.name,
      'firstSeen': p.firstSeen,
      'lastSeen': p.lastSeen,
      'banned': await adminStore.isBanned(p.seatId),
    });
  }
  return shelf.Response.ok(
    jsonEncode({'ok': true, 'players': out}),
    headers: {'content-type': 'application/json'},
  );
}

Future<shelf.Response> adminRoomsHandler(shelf.Request req) async {
  if (!await isAdminAuthorized(req)) return _adminDenied();
  final limit =
      int.tryParse(req.url.queryParameters['limit'] ?? '')?.clamp(1, 200) ?? 50;
  final live = [
    for (final room in authority.rooms.values)
      {
        'code': room.code,
        'game': room.gameType,
        'started': room.started,
        'members': room.members.length,
        'spectators': room.spectators.length,
      },
  ];
  final recent = await adminStore.recentRooms(limit: limit);
  return shelf.Response.ok(
    jsonEncode({
      'ok': true,
      'live': live,
      'recent': [for (final r in recent) r.toJson()],
      'totalRooms': await adminStore.totalRooms(),
    }),
    headers: {'content-type': 'application/json'},
  );
}

Future<shelf.Response> adminAuditHandler(shelf.Request req) async {
  if (!await isAdminAuthorized(req)) return _adminDenied();
  final limit =
      int.tryParse(req.url.queryParameters['limit'] ?? '')?.clamp(1, 200) ?? 50;
  final log = await adminStore.auditLog(limit: limit);
  return shelf.Response.ok(
    jsonEncode({
      'ok': true,
      'audit': [
        for (final e in log)
          {
            'action': e.action,
            'seatId': e.seatId,
            'by': e.by,
            'at': e.at,
            if (e.detail != null) 'detail': e.detail,
          },
      ],
    }),
    headers: {'content-type': 'application/json'},
  );
}

Future<Map<String, dynamic>> _readJsonBody(shelf.Request req) async {
  try {
    return jsonDecode(await req.readAsString()) as Map<String, dynamic>;
  } catch (_) {
    return const {};
  }
}

/// Public: files a bug report / feature request / contact message.
/// Unauthenticated by design — every player can report — so the per-IP
/// throttle above is the flood guard and validation is strict.
Future<shelf.Response> feedbackCreateHandler(shelf.Request req) async {
  if (req.method != 'POST') {
    return shelf.Response(
      405,
      body: jsonEncode({'ok': false, 'text': 'POST only'}),
      headers: {'content-type': 'application/json'},
    );
  }
  final ip = _clientIp(req);
  if (_feedbackRateLimited(ip)) {
    return shelf.Response(
      429,
      body: jsonEncode({
        'ok': false,
        'text': 'too many reports — please try again later',
      }),
      headers: {'content-type': 'application/json'},
    );
  }
  final body = await _readJsonBody(req);
  try {
    final entry = await reportStore.create(
      category: (body['category'] as String? ?? 'other').trim(),
      source: (body['source'] as String? ?? 'report').trim(),
      title: (body['title'] as String?) ?? '',
      message: (body['message'] as String?) ?? '',
      contact: (body['contact'] as String?),
      seatId: (body['seatId'] as String?),
      gameId: (body['gameId'] as String?),
      appVersion: (body['appVersion'] as String?),
    );
    _recordFeedbackHit(ip);
    return shelf.Response.ok(
      jsonEncode({'ok': true, 'id': entry.id}),
      headers: {'content-type': 'application/json'},
    );
  } on ArgumentError catch (e) {
    return shelf.Response(
      400,
      body: jsonEncode({'ok': false, 'text': e.message.toString()}),
      headers: {'content-type': 'application/json'},
    );
  }
}

/// Admin read: the triage queue. Sorted actionable-first by default
/// (open, then critical-first priority, then newest); `sort=newest`
/// flips to pure chronology. Filters: category, status.
Future<shelf.Response> adminFeedbackHandler(shelf.Request req) async {
  if (!await isAdminAuthorized(req)) return _adminDenied();
  final q = req.url.queryParameters;
  final limit = int.tryParse(q['limit'] ?? '')?.clamp(1, 500) ?? 100;
  final entries = await reportStore.list(
    category: q['category'],
    status: q['status'],
    sort: q['sort'] == 'newest' ? 'newest' : 'priority',
    limit: limit,
    offset: int.tryParse(q['offset'] ?? '')?.clamp(0, 100000) ?? 0,
  );
  return shelf.Response.ok(
    jsonEncode({
      'ok': true,
      'feedback': [for (final e in entries) e.toJson()],
      'openCount': await reportStore.count(status: 'open'),
      'totalCount': await reportStore.count(),
      'openByCategory': reportStore.openByCategory(),
    }),
    headers: {'content-type': 'application/json'},
  );
}

/// Admin read: one page of rows from a whitelisted table (the Data tab).
Future<shelf.Response> adminTableHandler(shelf.Request req) async {
  if (!await isAdminAuthorized(req)) return _adminDenied();
  final spec = tableSpec(req.url.queryParameters['table'] ?? '');
  if (spec == null) {
    return shelf.Response(
      400,
      body: jsonEncode({'ok': false, 'text': 'unknown table'}),
      headers: {'content-type': 'application/json'},
    );
  }
  final q = req.url.queryParameters;
  final query = q['q'];
  final limit = int.tryParse(q['limit'] ?? '')?.clamp(1, 500) ?? 100;
  return shelf.Response.ok(
    jsonEncode({
      'ok': true,
      'table': spec.name,
      'pk': spec.pk,
      'columns': spec.columns,
      'editable': spec.editable.toList(),
      'insertable': spec.insertable,
      'deletable': spec.deletable,
      'rows': adminStore.tableRows(
        spec,
        limit: limit,
        offset: int.tryParse(q['offset'] ?? '')?.clamp(0, 100000) ?? 0,
        q: query,
      ),
      'total': adminStore.tableCount(spec, q: query),
    }),
    headers: {'content-type': 'application/json'},
  );
}

Future<shelf.Response> adminActionHandler(shelf.Request req) async {
  if (!await isAdminAuthorized(req)) return _adminDenied();
  final by = (await adminIdentity(req))?.email ?? 'admin-token';
  final action = req.url.path.startsWith('admin/')
      ? req.url.path.substring('admin/'.length)
      : req.url.path;
  final body = await _readJsonBody(req);
  switch (action) {
    case 'ban':
      final seatId = (body['seatId'] as String? ?? '').trim();
      if (seatId.isEmpty) {
        return shelf.Response(
          400,
          body: jsonEncode({'ok': false, 'text': 'seatId required'}),
          headers: {'content-type': 'application/json'},
        );
      }
      await adminStore.ban(
        seatId: seatId,
        reason: (body['reason'] as String?) ?? 'banned',
        by: by,
        untilMs: (body['untilMs'] as num?)?.toInt(),
      );
      return shelf.Response.ok(
        jsonEncode({'ok': true}),
        headers: {'content-type': 'application/json'},
      );
    case 'unban':
      final seatId = (body['seatId'] as String? ?? '').trim();
      await adminStore.unban(seatId, by: by);
      return shelf.Response.ok(
        jsonEncode({'ok': true}),
        headers: {'content-type': 'application/json'},
      );
    case 'rename':
      final seatId = (body['seatId'] as String? ?? '').trim();
      final name = (body['name'] as String? ?? '').trim();
      if (seatId.isEmpty || name.isEmpty) {
        return shelf.Response(
          400,
          body: jsonEncode({'ok': false, 'text': 'seatId + name required'}),
          headers: {'content-type': 'application/json'},
        );
      }
      await adminStore.renamePlayer(seatId: seatId, name: name, by: by);
      return shelf.Response.ok(
        jsonEncode({'ok': true}),
        headers: {'content-type': 'application/json'},
      );
    case 'delete-game':
      final gameId = (body['gameId'] as String? ?? '').trim();
      if (gameId.isEmpty) {
        return shelf.Response(
          400,
          body: jsonEncode({'ok': false, 'text': 'gameId required'}),
          headers: {'content-type': 'application/json'},
        );
      }
      await adminStore.deleteGame(gameId, by: by);
      return shelf.Response.ok(
        jsonEncode({'ok': true}),
        headers: {'content-type': 'application/json'},
      );
    case 'rooms/close':
      final code = (body['code'] as String? ?? '').trim().toUpperCase();
      final room = authority.rooms[code];
      if (room == null) {
        return shelf.Response(
          404,
          body: jsonEncode({'ok': false, 'text': "room '$code' not found"}),
          headers: {'content-type': 'application/json'},
        );
      }
      for (final connId in room.members.keys.toList()) {
        authority.leaveRoom(code, connId);
      }
      await adminStore.recordRoomClosed(code, playerCount: 0);
      return shelf.Response.ok(
        jsonEncode({'ok': true}),
        headers: {'content-type': 'application/json'},
      );
    case 'feedback/update':
      final id = int.tryParse('${body['id']}') ?? -1;
      if (id < 0) {
        return _badAdminAction('id required');
      }
      final patch = <String, dynamic>{
        if (body['category'] != null) 'category': body['category'],
        if (body['status'] != null) 'status': body['status'],
        if (body['priority'] != null) 'priority': body['priority'],
        if (body['title'] != null) 'title': body['title'],
        if (body['message'] != null) 'message': body['message'],
        if (body['contact'] != null) 'contact': body['contact'],
        if (body['adminNotes'] != null) 'adminNotes': body['adminNotes'],
      };
      try {
        final updated = await reportStore.update(id, patch);
        if (updated == null) {
          return _badAdminAction("feedback '$id' not found", code: 404);
        }
        await adminStore.recordAdminAction(
          action: 'feedbackUpdate',
          subject: '$id',
          by: by,
          detail: patch.keys.join(','),
        );
        return shelf.Response.ok(
          jsonEncode({'ok': true, 'feedback': updated.toJson()}),
          headers: {'content-type': 'application/json'},
        );
      } on ArgumentError catch (e) {
        return _badAdminAction(e.message.toString());
      }
    case 'feedback/delete':
      final id = int.tryParse('${body['id']}') ?? -1;
      if (id < 0) {
        return _badAdminAction('id required');
      }
      final deleted = await reportStore.delete(id);
      if (!deleted) {
        return _badAdminAction("feedback '$id' not found", code: 404);
      }
      await adminStore.recordAdminAction(
        action: 'feedbackDelete',
        subject: '$id',
        by: by,
      );
      return shelf.Response.ok(
        jsonEncode({'ok': true}),
        headers: {'content-type': 'application/json'},
      );
    case 'table/insert':
      final spec = tableSpec(body['table'] as String? ?? '');
      if (spec == null) return _badAdminAction('unknown table');
      try {
        adminStore.insertTableRow(
          spec,
          (body['values'] as Map?)?.cast<String, dynamic>() ?? {},
        );
        await adminStore.recordAdminAction(
          action: 'tableInsert',
          subject: spec.name,
          by: by,
        );
        return shelf.Response.ok(
          jsonEncode({'ok': true}),
          headers: {'content-type': 'application/json'},
        );
      } on ArgumentError catch (e) {
        return _badAdminAction(e.message.toString());
      }
    case 'table/update':
      final spec = tableSpec(body['table'] as String? ?? '');
      final pk = '${body['pk'] ?? ''}';
      if (spec == null) return _badAdminAction('unknown table');
      if (pk.isEmpty) return _badAdminAction('pk required');
      try {
        final updated = await adminStore.updateTableRow(
          spec,
          pk,
          (body['values'] as Map?)?.cast<String, dynamic>() ?? {},
        );
        if (!updated) {
          return _badAdminAction('row not found', code: 404);
        }
        await adminStore.recordAdminAction(
          action: 'tableUpdate',
          subject: '${spec.name}#$pk',
          by: by,
        );
        return shelf.Response.ok(
          jsonEncode({'ok': true}),
          headers: {'content-type': 'application/json'},
        );
      } on ArgumentError catch (e) {
        return _badAdminAction(e.message.toString());
      }
    case 'table/delete':
      final spec = tableSpec(body['table'] as String? ?? '');
      final pk = '${body['pk'] ?? ''}';
      if (spec == null) return _badAdminAction('unknown table');
      if (pk.isEmpty) return _badAdminAction('pk required');
      if (!spec.deletable) {
        return _badAdminAction("table '${spec.name}' is read-only");
      }
      final deleted = await adminStore.deleteTableRow(spec, pk);
      if (!deleted) {
        return _badAdminAction('row not found', code: 404);
      }
      await adminStore.recordAdminAction(
        action: 'tableDelete',
        subject: '${spec.name}#$pk',
        by: by,
      );
      return shelf.Response.ok(
        jsonEncode({'ok': true}),
        headers: {'content-type': 'application/json'},
      );
  }
  return shelf.Response(
    404,
    body: jsonEncode({'ok': false, 'text': 'unknown admin action'}),
    headers: {'content-type': 'application/json'},
  );
}

shelf.Response _badAdminAction(String text, {int code = 400}) => shelf.Response(
  code,
  body: jsonEncode({'ok': false, 'text': text}),
  headers: {'content-type': 'application/json'},
);

Future<void> main(List<String> args) async {
  var port = 8080;
  var dbPath = 'ludo_leaderboard.db';
  var portArg = false;
  for (var i = 0; i < args.length - 1; i++) {
    if (args[i] == '--port') {
      port = int.tryParse(args[i + 1]) ?? port;
      portArg = true;
    }
    if (args[i] == '--db') dbPath = args[i + 1];
    if (args[i] == '--instance-id') instanceId = args[i + 1];
  }

  // Local development convenience: a .env file next to the server supplies
  // TURSO_DATABASE_URL / TURSO_AUTH_TOKEN / PORT / INSTANCE_ID without
  // shell exports. Real environment variables always win over .env.
  final env = _loadEnvironment();
  // Expose the merged environment to getters like [webDir], so .env-only
  // settings (e.g. WEB_DIR) are honored too — the real environment still
  // wins because _loadEnvironment merges .env under Platform.environment.
  serverEnv = env;

  if (!portArg) port = int.tryParse(env['PORT'] ?? '') ?? port;
  instanceId = env['INSTANCE_ID']?.trim().isNotEmpty == true
      ? env['INSTANCE_ID']!.trim()
      : instanceId;

  // GIF search for table chat: the provider layer picks Klipy or GIPHY
  // from the environment (GIF_PROVIDER pins one explicitly). Without
  // any key the picker degrades to paste-a-link (see lib/server/gif.dart).
  gifProvider = selectGifProvider(
    klipyKey: (env['KLIPY_API_KEY'] ?? '').trim(),
    giphyKey: (env['GIPHY_API_KEY'] ?? '').trim(),
    preferred: env['GIF_PROVIDER'] ?? '',
  );

  // Persistence for production runs: a hosted Turso database when
  // TURSO_DATABASE_URL + TURSO_AUTH_TOKEN are set (the leaderboard then
  // survives on ephemeral hosts), otherwise the local SQLite file. Tests
  // swap the globals.
  final turso = TursoLeaderboardStore.fromEnvironment(env);
  leaderboardStore = turso ?? SqliteLeaderboardStore(dbPath);
  // Admin history lives in the same SQLite file so one DB holds players,
  // bans, audit and room lifecycle beside the leaderboard rows. When the
  // leaderboard is Turso-backed the file still exists locally for admin
  // history (single-replica deployments); multi-replica admin history
  // needs a shared store.
  try {
    adminStore.close();
  } catch (_) {}
  // One shared SQLite connection for admin history + feedback: the
  // generic Data-tab CRUD reaches every whitelisted table through
  // [adminStore], so the tables must live on the same connection (and
  // file) the feature stores own.
  final sharedDb = sqlite3.open(dbPath);
  adminStore = AdminStore.fromDb(sharedDb);
  reportStore = ReportStore.fromDb(sharedDb);
  // Friends state: Turso when configured, so friendships, requests, DMs and
  // invites survive a redeploy on an ephemeral host; otherwise the shared
  // SQLite file. The local friend tables are created either way — the admin
  // Data tab whitelists them and reaches them through [sharedDb], so they
  // must exist on that connection even when Turso is the store of record
  // (they receive no writes then).
  friendStore.close();
  final localFriendStore = SqliteFriendStore.fromDb(sharedDb);
  final tursoFriends = TursoFriendStore.fromEnvironment(env);
  friendStore = tursoFriends ?? localFriendStore;
  adminToken = (env['ADMIN_TOKEN'] ?? '').trim();
  authority = GameAuthority(
    leaderboard: leaderboardStore,
    // Closing a room unregisters it from the cluster registry at once, so
    // /rooms/lookup stops routing joins to rooms this instance dropped.
    // The delete is scoped to the closing room's token: its code can be
    // recycled into a new room before the slow Turso delete lands, and
    // that live room's route must survive.
    onRoomClosed: (code, registryToken) {
      roomRegistry
          .unregister(code, owner: registryToken)
          .catchError((Object _) {});
      unawaited(adminStore.recordRoomClosed(code).catchError((Object _) {}));
    },
    onRoomStarted: (room) {
      unawaited(
        adminStore.recordRoomStarted(room.code).catchError((Object _) {}),
      );
    },
    onGameFinished: ({required String gameId, required results}) async {
      for (final r in results) {
        await adminStore.recordResult(
          gameId: gameId,
          seatId: r.seatId,
          name: r.name,
          game: r.game,
          rank: r.rank,
          color: r.color,
        );
      }
      Room? finished;
      for (final rm in authority.rooms.values) {
        if (rm.gameId == gameId) {
          finished = rm;
          break;
        }
      }
      String? winner;
      for (final r in results) {
        if (r.rank == 1) {
          winner = r.seatId;
          break;
        }
      }
      if (finished != null) {
        await adminStore.recordRoomClosed(
          finished.code,
          winnerSeat: winner,
          playerCount: results.length,
        );
      }
    },
  );

  // Same env vars drive the cross-instance room registry: with Turso,
  // rooms are discoverable by every replica behind the load balancer;
  // without it, the in-memory registry keeps single-instance behavior.
  final tursoRegistry = TursoRoomRegistry.fromEnvironment(env);
  roomRegistry = tursoRegistry ?? InMemoryRoomRegistry();

  // Keep the registry truthful: refresh every live room's TTL. Rooms are
  // unregistered the moment they close (onRoomClosed above); entries from a
  // crashed instance self-expire once their TTL passes. The cadence must
  // stay well under the TTL — sweeping no more often than the TTL would
  // let live rooms expire between sweeps (lookups 404 for rooms that
  // still exist).
  Timer.periodic(registryRefreshInterval(tursoRegistry?.ttl), (_) {
    for (final room in authority.rooms.values) {
      // A room can close mid-round-trip; advertiseRoom withdraws the route
      // again when that happens, so the sweep never revives a dead room.
      unawaited(advertiseRoom(room));
    }
  });

  final handler = const shelf.Pipeline()
      .addMiddleware(shelf.logRequests())
      .addMiddleware(corsMiddleware)
      .addMiddleware(jsonErrorMiddleware)
      .addHandler((req) async {
        // Chat media: the uploads (fresh bytes into a live room's store)
        // and the playback (a stored note out again) are path-family
        // routes — the id lives in the path, not the switch's labels.
        if (req.url.path == 'media/voice') {
          return voiceNoteUpload(
            req,
            store: authority.mediaNotes,
            roomIsLive: authority.rooms.containsKey,
          );
        }
        if (req.url.path == 'media/image') {
          return imageNoteUpload(
            req,
            store: authority.mediaNotes,
            roomIsLive: authority.rooms.containsKey,
          );
        }
        if (req.url.path.startsWith('media/voice/') ||
            req.url.path.startsWith('media/image/')) {
          return mediaNoteServe(req, store: authority.mediaNotes);
        }
        switch (req.url.path) {
          case 'ws':
            return wsHandler()(req);
          case 'leaderboard':
            return leaderboardHandler(req);
          case 'stats':
            return statsHandler(req);
          case 'rooms/lookup':
            return roomLookupHandler(req);
          case 'health':
            return healthHandler(req);
          case 'media/gif':
          // Compat alias for clients already shipped on the Tenor era —
          // the same provider serves them; nothing client-side breaks.
          case 'media/tenor':
            return gifSearchHandler(req, provider: gifProvider);
          case 'feedback':
            return feedbackCreateHandler(req);
          case 'friends/state':
            return friendsStateHandler(req);
          case 'friends/lookup':
            return friendsLookupHandler(req);
          case 'friends/players':
            // Retired: discovery lives at the table now — every seated
            // row carries the add. The server-wide player enumeration was
            // removed with the directory screen.
            return _friendBadRequest('not found', code: 404);
          case 'friends/request':
            return friendsRequestHandler(req);
          case 'friends/respond':
            return friendsRespondHandler(req);
          case 'friends/remove':
            return friendsRemoveHandler(req);
          case 'friends/chat':
            return friendsChatHandler(req);
          case 'friends/chat/send':
            return friendsChatSendHandler(req);
          case 'friends/chat/like':
            return friendsChatLikeHandler(req);
          case 'friends/invite':
            return friendsInviteHandler(req);
          case 'friends/invite/respond':
            return friendsInviteRespondHandler(req);
          case 'friends/block':
            return friendsBlockHandler(req);
          case 'friends/unblock':
            return friendsUnblockHandler(req);
          case 'friends/report':
            return friendsReportHandler(req);
          case 'admin/status':
            return adminStatusHandler(req);
          case 'admin/me':
            return adminMeHandler(req);
          case 'admin/users':
            return adminUsersHandler(req);
          case 'admin/setup':
            if (req.method != 'POST') {
              return shelf.Response(
                405,
                body: jsonEncode({'ok': false, 'text': 'POST only'}),
                headers: {'content-type': 'application/json'},
              );
            }
            return adminSetupHandler(req);
          case 'admin/login':
            if (req.method != 'POST') {
              return shelf.Response(
                405,
                body: jsonEncode({'ok': false, 'text': 'POST only'}),
                headers: {'content-type': 'application/json'},
              );
            }
            return adminLoginHandler(req);
          case 'admin/logout':
            if (req.method != 'POST') {
              return shelf.Response(
                405,
                body: jsonEncode({'ok': false, 'text': 'POST only'}),
                headers: {'content-type': 'application/json'},
              );
            }
            return adminLogoutHandler(req);
          case 'admin/overview':
            return adminOverviewHandler(req);
          case 'admin/players':
            return adminPlayersHandler(req);
          case 'admin/rooms':
            return adminRoomsHandler(req);
          case 'admin/audit':
            return adminAuditHandler(req);
          case 'admin/feedback':
            return adminFeedbackHandler(req);
          case 'admin/table':
            return adminTableHandler(req);
          case 'admin/ban':
          case 'admin/unban':
          case 'admin/rename':
          case 'admin/delete-game':
          case 'admin/rooms/close':
          case 'admin/feedback/update':
          case 'admin/feedback/delete':
          case 'admin/table/insert':
          case 'admin/table/update':
          case 'admin/table/delete':
            if (req.method != 'POST') {
              return shelf.Response(
                405,
                body: jsonEncode({'ok': false, 'text': 'POST only'}),
                headers: {'content-type': 'application/json'},
              );
            }
            return adminActionHandler(req);
        }
        // Serve the Flutter web build when one ships with the image, so a
        // single deployed service hosts both the game UI and the server
        // (the web client's same-origin default then just works). Existing
        // but empty builds are ignored to catch a half-uploaded copy.
        final staticHandler = _webStaticHandler();
        if (staticHandler != null && req.method == 'GET') {
          return staticHandler(req);
        }
        // No web build: keep the historical JSON health response at /, so
        // API-only deployments behave exactly as before.
        return healthHandler(req);
      });

  final server = await shelf_io.serve(handler, InternetAddress.anyIPv4, port);
  stdout.writeln(
    'Game Club server listening on '
    'ws://${server.address.host}:${server.port}/ws '
    '(instance: $instanceId, '
    'leaderboard: ${turso != null ? 'Turso' : dbPath}, '
    'friends: ${tursoFriends != null ? 'Turso' : dbPath}, '
    'room registry: ${tursoRegistry != null ? 'Turso' : 'in-memory'}, '
    'web UI: ${webDir != null ? 'served from $webDir' : 'not found'})',
  );

  // Prove the store is actually reachable, and say so out loud. The deployed
  // leaderboard spent a long time answering 500 because the runtime image had
  // no CA certificates, so every TLS handshake to Turso failed. Nothing at
  // boot said so: the server started, announced "leaderboard: Turso", and the
  // only symptom was a HandshakeException buried in a 500 on some later
  // request — which reads exactly like a revoked token and sends the debugging
  // after the credentials instead of after the image. One line here names it.
  if (turso != null) {
    try {
      final games = await leaderboardStore.totalGames();
      stdout.writeln('Turso reachable: $games game(s) recorded.');
    } catch (e) {
      stderr.writeln(
        '!! Turso is NOT reachable: $e\n'
        '   If this says CERTIFICATE_VERIFY_FAILED, the runtime image is '
        'missing ca-certificates (debian:bookworm-slim ships no '
        '/etc/ssl/certs) — fix the Dockerfile, not the token.',
      );
    }
  }

  // The friends store gets the same one-line proof. A Turso-backed friends
  // store that cannot reach its database must fail loudly here rather than
  // look healthy until the first player opens the Friends screen.
  if (tursoFriends != null) {
    try {
      await friendStore.profile('');
      stdout.writeln('Turso friends store reachable.');
    } catch (e) {
      stderr.writeln(
        '!! Turso friends store is NOT reachable: $e\n'
        '   Fix the connection (or the CA certificates) before players '
        'start adding friends.',
      );
    }
  }
}

/// A static handler for a Flutter web build (`flutter build web`), or null
/// when WEB_DIR (default build/web) has no index.html.
shelf.Handler? _webStaticHandler() {
  final dir = webDir;
  if (dir == null) return null;
  // Wrapped rather than configured: this version of shelf_static has no
  // header hook, so the policy is applied to whatever it returns.
  final inner = createStaticHandler(dir, defaultDocument: 'index.html');
  return (req) async {
    final resp = await inner(req);
    if (resp.statusCode != 404) {
      return resp.change(headers: webCacheHeaders(req.url.path));
    }
    // SPA fallback for client routes (/admin): an extensionless path is a
    // route, not a missing asset — answer with the shell so a refresh or
    // deep link boots the app and Flutter's '/admin' route takes over.
    // Paths with an extension (/assets/x, /canvaskit/y) stay 404.
    final path = req.url.path;
    final name = path.split('/').last;
    if (name.contains('.')) {
      return resp.change(headers: webCacheHeaders(path));
    }
    final shellResp = await inner(
      shelf.Request(req.method, Uri.parse('http://localhost/index.html')),
    );
    return shellResp.change(headers: webCacheHeaders('index.html'));
  };
}

String? get webDir {
  // Real environment wins over .env, mirroring _loadEnvironment's merge.
  final path =
      Platform.environment['WEB_DIR'] ?? serverEnv['WEB_DIR'] ?? 'build/web';
  if (!Directory(path).existsSync()) return null;
  if (File('$path/index.html').existsSync()) return path;
  return null;
}

/// How often the server re-registers its live rooms in the cluster
/// registry. Must stay well under the registry TTL — sweeping no more
/// often than the TTL would let live rooms expire between sweeps
/// (`/rooms/lookup` would 404 for rooms that still exist). A third of
/// the TTL leaves room for roughly two missed sweeps, clamped to a
/// valid, bounded timer period of [1 s, 30 s] (30 s keeps the historical
/// default cadence for the 120 s TTL).
Duration registryRefreshInterval(Duration? ttl) {
  var refresh = Duration(
    seconds: (ttl ?? const Duration(seconds: 120)).inSeconds ~/ 3,
  );
  if (refresh < const Duration(seconds: 1)) {
    refresh = const Duration(seconds: 1);
  }
  if (refresh > const Duration(seconds: 30)) {
    refresh = const Duration(seconds: 30);
  }
  return refresh;
}

/// KEY=VALUE lines from an optional .env file, merged under the real
/// process environment (which always wins). Malformed lines are skipped.
Map<String, String> _loadEnvironment() {
  final env = {...Platform.environment};
  try {
    final file = File('.env');
    if (!file.existsSync()) return env;
    for (final raw in file.readAsLinesSync()) {
      final line = raw.trim();
      if (line.isEmpty || line.startsWith('#')) continue;
      final eq = line.indexOf('=');
      if (eq <= 0) continue;
      var value = line.substring(eq + 1).trim();
      final key = line.substring(0, eq).trim();
      if (value.length >= 2 &&
          ((value.startsWith('"') && value.endsWith('"')) ||
              (value.startsWith("'") && value.endsWith("'")))) {
        value = value.substring(1, value.length - 1);
      }
      env.putIfAbsent(key, () => value);
    }
  } catch (_) {
    // A broken .env must never keep the server from starting.
  }
  return env;
}
