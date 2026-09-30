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
///   WS   /ws?code=XXXX  -> join/create room, then JSON message protocol
///
/// Client -> server messages:
///   {type: 'hello', seatId, name, color?, game?, code?, match?}  first
///   {type: 'start'}
///   {type: 'roll'}
///   {type: 'move', token: 0..3}
///   {type: 'chat', text}
/// Server -> client:
///   {type: 'joined', code, color, game}
///   {type: 'lobby', seats: [{name, color}...]}
///   {type: 'state', game, state: LudoStateJson | SnakesStateJson}
///   {type: 'chat', from, text}
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
import 'package:game_club/server/game_server.dart';
import 'package:game_club/server/leaderboard_store.dart';
import 'package:game_club/server/room_registry.dart';
import 'package:game_club/server/web_cache.dart';
import 'package:game_club/server/turso_leaderboard_store.dart';

/// Not final so tests can swap in a fresh authority + store.
GameAuthority authority = GameAuthority();

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
}) async {
  var token = newRegistryToken();
  for (var attempt = 0; attempt < 3; attempt++) {
    final code = authority.newCode();
    final bool claimed;
    try {
      claimed = await roomRegistry.register(code, instanceId, owner: token);
    } on RoomRegistryException catch (_) {
      return authority.createRoom(
        host,
        game: game,
      ); // registry down — host locally
    }
    if (!claimed) {
      token = newRegistryToken(); // the row belongs to another replica
      continue;
    }
    try {
      return authority.createRoom(
        host,
        game: game,
        code: code,
        registryToken: token,
      );
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

shelf.Handler wsHandler() => webSocketHandler((webSocket, _) {
  final connId = 'c${_connCounter++}';
  _openConnections.add(connId); // counted from the raw socket up
  String? roomCode;
  ServerMember? member;

  webSocket.stream.listen(
    (data) async {
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
        final seatId = msg['seatId'] as String? ?? '';
        final name = (msg['name'] as String? ?? 'Player').trim();
        if (seatId.isEmpty) {
          webSocket.sink.add(
            jsonEncode({'type': 'error', 'text': 'seatId required'}),
          );
          return;
        }
        final color = LudoColor.values.firstWhere(
          (c) => c.name == msg['color'],
          orElse: () => LudoColor.red,
        );
        final code = (msg['code'] as String? ?? '').trim();
        final spectate = msg['spectate'] as bool? ?? false;
        final game = (msg['game'] as String?) == 'snakes' ? 'snakes' : 'ludo';
        final match = msg['match'] as bool? ?? false;

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
                authority.matchExisting(member!, game: game) ??
                await _createClaimedRoom(member!, game: game);
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
            // Push the initial snapshot to everyone — most importantly
            // the first player who has been waiting in the lobby.
            room.broadcastState();
          }
        } else if (code.isEmpty) {
          try {
            room = await _createClaimedRoom(member!, game: game);
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
        _lobby(room);
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
          // Keep the roster fresh — in the lobby too, where a player who
          // walks out must disappear from everyone's seat list and not
          // only once a game happens to be running.
          _lobby(room);
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

void _lobby(Room room) {
  room.broadcast({
    'type': 'lobby',
    'code': room.code,
    'started': room.started,
    // The same entries the `seats` feed carries, so whichever of the two
    // arrives last cannot wipe the seat ids and statuses the other one
    // reported — two shapes for one roster is how badges start disappearing
    // at random, depending on the order the broadcasts land in.
    'seats': room.seatsJson()['seats'],
    'spectators': [for (final m in room.spectators.values) m.name],
  });
}

/// The documented JSON health check. Always served at GET /health; at GET /
/// only when no web build ships (with a build, / serves the game UI, so
/// probes must use /health).
///
/// Liveness does not depend on the leaderboard: a box whose Turso token is
/// wrong, or whose database is still waking up, is serving games perfectly
/// well, and calling it unhealthy makes the platform recycle an instance that
/// needed no recycling. So a store failure is reported *as data* — the `store`
/// field plus a `storeError` — instead of failing the probe.
Future<shelf.Response> healthHandler(shelf.Request req) async {
  Object? storeError;
  int? games;
  try {
    games = await leaderboardStore.totalGames();
  } catch (e) {
    storeError = e;
  }
  return shelf.Response.ok(
    jsonEncode({
      'ok': true,
      'rooms': authority.rooms.length,
      'games': games,
      'store': leaderboardBackend,
      if (storeError != null) 'storeError': '$storeError',
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

/// CORS for the read-only JSON API (`/health`, `/leaderboard`, `/stats`,
/// `/rooms/lookup`): the Flutter web dev server runs on another origin, so
/// without these headers a browser would fetch the data fine and then refuse
/// to hand the response to the app. WebSockets do not need a preflight, so
/// `/ws` is unaffected; writes stay rejected with 405, so `*` is safe here.
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
  'access-control-allow-methods': 'GET, OPTIONS',
  // Echoed back rather than a fixed list: a preflight that asks for a header
  // the server does not echo is rejected by the browser, and today only a
  // header-less GET is ever made. Answering what was asked keeps a future
  // request (or a dev proxy adding one) from failing as a CORS error.
  'access-control-allow-headers': ?req.headers['access-control-request-headers'],
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

  // Persistence for production runs: a hosted Turso database when
  // TURSO_DATABASE_URL + TURSO_AUTH_TOKEN are set (the leaderboard then
  // survives on ephemeral hosts), otherwise the local SQLite file. Tests
  // swap the globals.
  final turso = TursoLeaderboardStore.fromEnvironment(env);
  leaderboardStore = turso ?? SqliteLeaderboardStore(dbPath);
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
    return resp.change(headers: webCacheHeaders(req.url.path));
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
