/// Game Club — authoritative Ludo server.
///
/// Run:  dart run bin/server.dart [--port 8080] [--db FILE]
///
/// Endpoints:
///   GET  /            -> health check
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
import 'package:shelf_web_socket/shelf_web_socket.dart';

import 'package:game_club/engine/ludo/ludo_models.dart';
import 'package:game_club/server/game_server.dart';
import 'package:game_club/server/leaderboard_store.dart';
import 'package:game_club/server/turso_leaderboard_store.dart';

/// Not final so tests can swap in a fresh authority + store.
GameAuthority authority = GameAuthority();

/// Not final so tests can swap in an in-memory store. main() replaces this
/// with the Turso store (when TURSO_DATABASE_URL is set) or the file-backed
/// store before the server starts listening.
LeaderboardStore leaderboardStore = SqliteLeaderboardStore.inMemory();

final _connections = <String, String>{}; // connId -> roomCode

int _connCounter = 0;

shelf.Handler wsHandler() => webSocketHandler((webSocket, _) {
      final connId = 'c${_connCounter++}';
      String? roomCode;
      ServerMember? member;

      webSocket.stream.listen(
        (data) {
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
              webSocket.sink
                  .add(jsonEncode({'type': 'error', 'text': 'say hello first'}));
              return;
            }
            final seatId = msg['seatId'] as String? ?? '';
            final name = (msg['name'] as String? ?? 'Player').trim();
            if (seatId.isEmpty) {
              webSocket.sink
                  .add(jsonEncode({'type': 'error', 'text': 'seatId required'}));
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
                webSocket.sink.add(jsonEncode({
                  'type': 'error',
                  'text': 'a room code is required to spectate',
                }));
                return;
              }
              final watched = authority.spectateRoom(code, member!);
              if (watched == null) {
                webSocket.sink.add(jsonEncode({
                  'type': 'error',
                  'text': "room '$code' not found "
                      '(or you are already playing in it)',
                }));
                return;
              }
              room = watched;
            } else if (code.isEmpty && match) {
              // Quick match: join the first waiting room of this game
              // type, or open one — then start as soon as two are seated.
              room = authority.findMatch(member!, game: game);
              if (!room.started && room.members.length >= 2) {
                room.start();
                // Push the initial snapshot to everyone — most importantly
                // the first player who has been waiting in the lobby.
                room.broadcastState();
              }
            } else if (code.isEmpty) {
              room = authority.createRoom(member!, game: game);
            } else {
              var joined = authority.joinWithColor(code, member!, color);
              // Not a fresh join — maybe a returning player reclaiming
              // their seat (lobby or mid-game).
              joined ??= authority.rejoinRoom(code, member!);
              if (joined == null) {
                webSocket.sink.add(jsonEncode({
                  'type': 'error',
                  'text': roomFullOrMissing(code),
                }));
                return;
              }
              room = joined;
            }
            roomCode = room.code;
            _connections[connId] = room.code;
            webSocket.sink.add(jsonEncode({
              'type': 'joined',
              'code': room.code,
              'game': room.gameType,
              if (!spectate) 'color': member!.color.name,
              if (spectate) 'spectator': true,
            }));
            _lobby(room);
            if (room.started) {
              // A mid-game rejoin or a spectator needs the current snapshot
              // to resume / watch; lobby players just wait for the broadcast
              // at start.
              webSocket.sink.add(jsonEncode({
                'type': 'state',
                'game': room.gameType,
                'state': room.stateJson(),
              }));
            }
            return;
          }

          // Subsequent messages are game intents.
          if (roomCode != null) {
            final room = authority.rooms[roomCode];
            if (room != null) {
              authority.handleIntent(
                  room: room, connectionId: connId, msg: msg);
              if (room.started) _lobby(room); // keep roster fresh
            }
          }
        },
        onDone: () {
          if (roomCode != null) authority.leaveRoom(roomCode!, connId);
          _connections.remove(connId);
        },
        onError: (_) {
          if (roomCode != null) authority.leaveRoom(roomCode!, connId);
          _connections.remove(connId);
        },
        cancelOnError: true,
      );
    });

String roomFullOrMissing(String code) =>
    "room '$code' not found, already started, or full";

void _lobby(Room room) {
  room.broadcast({
    'type': 'lobby',
    'code': room.code,
    'started': room.started,
    'seats': [
      for (final m in room.orderedMembers)
        {'name': m.name, 'color': m.color.name}
    ],
    'spectators': [
      for (final m in room.spectators.values) m.name,
    ],
  });
}

Future<shelf.Response> _health(shelf.Request req) async => shelf.Response.ok(
      jsonEncode({
        'ok': true,
        'rooms': authority.rooms.length,
        'games': await leaderboardStore.totalGames(),
      }),
      headers: {'content-type': 'application/json'},
    );

Future<shelf.Response> leaderboardHandler(shelf.Request req) async {
  if (req.method != 'GET') {
    return shelf.Response(405,
        body: jsonEncode({'ok': false, 'text': 'GET only'}),
        headers: {'content-type': 'application/json'});
  }
  return shelf.Response.ok(
    jsonEncode({
      'ok': true,
      'games': await leaderboardStore.totalGames(),
      'players': [
        for (final e in await leaderboardStore.topPlayers()) e.toJson()
      ],
    }),
    headers: {'content-type': 'application/json'},
  );
}

Future<void> main(List<String> args) async {
  var port = 8080;
  var dbPath = 'ludo_leaderboard.db';
  for (var i = 0; i < args.length - 1; i++) {
    if (args[i] == '--port') port = int.tryParse(args[i + 1]) ?? port;
    if (args[i] == '--db') dbPath = args[i + 1];
  }

  // Persistence for production runs: a hosted Turso database when
  // TURSO_DATABASE_URL + TURSO_AUTH_TOKEN are set (the leaderboard then
  // survives on ephemeral hosts), otherwise the local SQLite file. Tests
  // swap the globals.
  final turso = TursoLeaderboardStore.fromEnvironment(Platform.environment);
  leaderboardStore = turso ?? SqliteLeaderboardStore(dbPath);
  authority = GameAuthority(leaderboard: leaderboardStore);

  final handler = const shelf.Pipeline()
      .addMiddleware(shelf.logRequests())
      .addHandler((req) async {
        if (req.url.path == 'ws') return wsHandler()(req);
        if (req.url.path == 'leaderboard') return leaderboardHandler(req);
        return _health(req);
      });

  final server = await shelf_io.serve(handler, InternetAddress.anyIPv4, port);
  stdout.writeln('Game Club server listening on '
      'ws://${server.address.host}:${server.port}/ws '
      '(leaderboard: ${turso != null ? 'Turso' : dbPath})');
}
