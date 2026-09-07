/// Game Club — authoritative Ludo server.
///
/// Run:  dart run bin/server.dart [--port 8080]
///
/// Endpoints:
///   GET  /            -> health check
///   WS   /ws?code=XXXX  -> join/create room, then JSON message protocol
///
/// Client -> server messages:
///   {type: 'hello', seatId, name, color?}   first message on a socket
///   {type: 'start'}
///   {type: 'roll'}
///   {type: 'move', token: 0..3}
///   {type: 'chat', text}
/// Server -> client:
///   {type: 'joined', code, color}
///   {type: 'lobby', seats: [{name, color}...]}
///   {type: 'state', state: LudoStateJson}
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

final authority = GameAuthority();

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

            member = ServerMember(
              id: connId,
              seatId: seatId,
              name: name.isEmpty ? 'Player' : name,
              color: color,
              sink: (json) => webSocket.sink.add(json),
            );

            final Room room;
            if (code.isEmpty) {
              room = authority.createRoom(member!);
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
            webSocket.sink.add(jsonEncode(
                {'type': 'joined', 'code': room.code, 'color': member!.color.name}));
            _lobby(room);
            if (room.started) {
              // A mid-game rejoin needs the current snapshot to resume;
              // lobby players just wait for the broadcast at start.
              webSocket.sink.add(jsonEncode(
                  {'type': 'state', 'state': room.state.toJson()}));
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
          if (roomCode != null) authority.removeMember(roomCode!, connId);
          _connections.remove(connId);
        },
        onError: (_) {
          if (roomCode != null) authority.removeMember(roomCode!, connId);
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
  });
}

shelf.Response _health(shelf.Request req) => shelf.Response.ok(
      jsonEncode({'ok': true, 'rooms': authority.rooms.length}),
      headers: {'content-type': 'application/json'},
    );

Future<void> main(List<String> args) async {
  var port = 8080;
  for (var i = 0; i < args.length - 1; i++) {
    if (args[i] == '--port') port = int.tryParse(args[i + 1]) ?? port;
  }

  final handler = const shelf.Pipeline()
      .addMiddleware(shelf.logRequests())
      .addHandler((req) {
        if (req.url.path == 'ws') return wsHandler()(req);
        return _health(req);
      });

  final server = await shelf_io.serve(handler, InternetAddress.anyIPv4, port);
  stdout.writeln('Game Club server listening on '
      'ws://${server.address.host}:${server.port}/ws');
}
