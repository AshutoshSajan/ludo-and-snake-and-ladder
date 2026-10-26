/// Admin API tests: auth gate, overview, rooms history, moderation.
library;

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:game_club/engine/ludo/ludo_models.dart';
import 'package:shelf/shelf.dart' as shelf;

import 'package:game_club/server/admin_store.dart';
import 'package:game_club/server/game_server.dart';

import '../bin/server.dart'
    show
        adminOverviewHandler,
        adminPlayersHandler,
        adminRoomsHandler,
        adminAuditHandler,
        adminActionHandler,
        adminStore,
        adminToken,
        authority,
        leaderboardStore;

shelf.Request _get(String path, {String? token}) => shelf.Request(
  'GET',
  Uri.parse('http://localhost/$path'),
  headers: {if (token != null) 'authorization': 'Bearer $token'},
);

shelf.Request _post(String path, Map<String, dynamic> body, {String? token}) =>
    shelf.Request(
      'POST',
      Uri.parse('http://localhost/$path'),
      headers: {
        if (token != null) 'authorization': 'Bearer $token',
        'content-type': 'application/json',
      },
      body: Stream.fromIterable([utf8.encode(jsonEncode(body))]),
    );

Future<Map<String, dynamic>> _json(shelf.Response r) async =>
    jsonDecode(await r.readAsString()) as Map<String, dynamic>;

/// A fake-connected participant for [GameAuthority] calls: the sink list
/// is what a real socket would have been handed, in arrival order.
ServerMember _member(
  LudoColor c, {
  String? seatId,
  String? id,
  void Function(String)? on,
}) => ServerMember(
  id: id ?? seatId ?? c.name,
  seatId: seatId ?? c.name,
  name: c.label,
  color: c,
  sink: on ?? (_) {},
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('admin auth gate', () {
    test('denies without token, allows with token', () async {
      final savedStore = adminStore;
      final savedToken = adminToken;
      adminStore = AdminStore.inMemory();
      adminToken = 'secret';
      addTearDown(() {
        adminStore = savedStore;
        adminToken = savedToken;
      });

      final denied = await adminOverviewHandler(_get('admin/overview'));
      expect(denied.statusCode, 403);

      final wrong = await adminOverviewHandler(
        _get('admin/overview', token: 'nope'),
      );
      expect(wrong.statusCode, 403);

      final ok = await adminOverviewHandler(
        _get('admin/overview', token: 'secret'),
      );
      expect(ok.statusCode, 200);
      expect((await _json(ok))['ok'], isTrue);
    });

    test('empty ADMIN_TOKEN disables everything', () async {
      final savedStore = adminStore;
      final savedToken = adminToken;
      adminStore = AdminStore.inMemory();
      adminToken = '';
      addTearDown(() {
        adminStore = savedStore;
        adminToken = savedToken;
      });
      final r = await adminPlayersHandler(
        _get('admin/players', token: 'anything'),
      );
      expect(r.statusCode, 403);
    });
  });

  group('admin rooms + moderation', () {
    test('room lifecycle lands in DB and ban flows through audit', () async {
      final savedStore = adminStore;
      final savedToken = adminToken;
      final savedAuthority = authority;
      adminStore = AdminStore.inMemory();
      adminToken = 't';
      authority = GameAuthority();
      addTearDown(() {
        adminStore = savedStore;
        adminToken = savedToken;
        authority = savedAuthority;
      });

      await adminStore.recordRoomCreated(
        code: 'AB12',
        game: 'ludo',
        instance: 'game-1',
      );
      await adminStore.recordRoomStarted('AB12');
      expect(await adminStore.totalRooms(), 1);

      final rooms = await adminRoomsHandler(_get('admin/rooms', token: 't'));
      expect(rooms.statusCode, 200);
      final roomsJson = await _json(rooms);
      expect(roomsJson['totalRooms'], 1);
      expect((roomsJson['recent'] as List).single['code'], 'AB12');

      final ban = await adminActionHandler(
        _post('admin/ban', {'seatId': 's1', 'reason': 'spam'}, token: 't'),
      );
      expect(ban.statusCode, 200);
      expect(await adminStore.isBanned('s1'), isTrue);

      final audit = await adminAuditHandler(_get('admin/audit', token: 't'));
      final items = (await _json(audit))['audit'] as List;
      expect(items.any((e) => e['action'] == 'ban'), isTrue);

      // Leaderboard mirror lives in the same store: stats stay unified.
      expect(await adminStore.totalGames(), 0);
      await adminStore.recordResult(
        gameId: 'g1',
        seatId: 's1',
        name: 'A',
        game: 'ludo',
        rank: 1,
      );
      expect(await adminStore.totalGames(), 1);
      expect(leaderboardStore, isNotNull);
    });
  });

  group('rooms/close dissolves the room permanently (CWE-863 fix)', () {
    test('a former participant cannot reconnect into a closed room', () async {
      final savedStore = adminStore;
      final savedToken = adminToken;
      final savedAuthority = authority;
      adminStore = AdminStore.inMemory();
      adminToken = 't';
      final closedCodes = <String>[];
      final hostLog = <String>[];
      final guestLog = <String>[];
      final watchLog = <String>[];
      authority = GameAuthority(
        onRoomClosed: (code, token) => closedCodes.add(code),
      );
      addTearDown(() {
        adminStore = savedStore;
        adminToken = savedToken;
        authority = savedAuthority;
      });

      // A started table with two seats and a watcher — exactly the shape
      // the disconnect path deliberately preserves for reconnection, and
      // exactly the shape the old rooms/close action left recoverable.
      final room = authority.createRoom(
        _member(LudoColor.red, seatId: 'ad-host', on: hostLog.add),
      );
      final code = room.code;
      authority.joinWithColor(
        code,
        _member(LudoColor.blue, seatId: 'ad-guest', on: guestLog.add),
        LudoColor.blue,
      );
      authority.spectateRoom(
        code,
        _member(LudoColor.green, seatId: 'ad-watch', on: watchLog.add),
      );
      room.start();
      expect(authority.rooms[code], isNotNull);

      final close = await adminActionHandler(
        _post('admin/rooms/close', {'code': code}, token: 't'),
      );
      expect(close.statusCode, 200);
      expect((await _json(close))['ok'], isTrue);

      // The room stops existing: out of the live registry, marked
      // removed, with no roster left who could notice anything further.
      expect(
        authority.rooms.containsKey(code),
        isFalse,
        reason:
            'the live '
            'registry must not survive an administrative closure',
      );
      expect(room.removed, isTrue);
      expect(room.members, isEmpty);
      expect(room.spectators, isEmpty);

      // Both players and the watcher were told, and the registry claim
      // was released through the same hook natural closes use.
      expect([
        for (final j in hostLog) jsonDecode(j)['type'],
      ], contains('roomClosed'));
      expect([
        for (final j in guestLog) jsonDecode(j)['type'],
      ], contains('roomClosed'));
      expect(closedCodes, [code]);

      // The heart of the bypass: a former participant's hello with their
      // own seatId meets dead ends at every seating door.
      expect(
        authority.rejoinRoom(code, _member(LudoColor.blue, seatId: 'ad-guest')),
        isNull,
        reason: 'a closed room has no seat to reclaim',
      );
      expect(
        authority.joinWithColor(
          code,
          _member(LudoColor.yellow, seatId: 'ad-guest'),
          LudoColor.yellow,
        ),
        isNull,
      );
      expect(
        authority.joinRoom(code, _member(LudoColor.red, seatId: 'ad-host')),
        isNull,
      );
      expect(
        authority.spectateRoom(
          code,
          _member(LudoColor.green, seatId: 'ad-watch'),
        ),
        isNull,
      );

      // And the room consequently cannot be closed twice.
      final again = await adminActionHandler(
        _post('admin/rooms/close', {'code': code}, token: 't'),
      );
      expect(again.statusCode, 404);
    });

    test('an armed reconnection grace is cancelled with the room', () async {
      final savedStore = adminStore;
      final savedToken = adminToken;
      final savedAuthority = authority;
      adminStore = AdminStore.inMemory();
      adminToken = 't';
      authority = GameAuthority();
      addTearDown(() {
        adminStore = savedStore;
        adminToken = savedToken;
        authority = savedAuthority;
      });

      final room = authority.createRoom(
        _member(LudoColor.red, seatId: 'g-host'),
      );
      final code = room.code;
      authority.joinWithColor(
        code,
        _member(LudoColor.blue, seatId: 'g-guest'),
        LudoColor.blue,
      );
      authority.spectateRoom(
        code,
        _member(LudoColor.green, seatId: 'ad-green'),
      );
      room.start();

      // Everyone's link drops: with a started game and nobody connected,
      // leaveRoom arms the reconnection grace — the pending abandonment
      // that a rejoin used to be able to ride back through.
      authority.leaveRoom(code, 'g-host');
      authority.leaveRoom(code, 'g-guest');
      authority.leaveRoom(code, 'ad-green');
      expect(room.abandonTimer, isNotNull);

      final close = await adminActionHandler(
        _post('admin/rooms/close', {'code': code}, token: 't'),
      );
      expect(close.statusCode, 200);
      // The action does not report success while the room still lingers:
      // the grace is stopped and the room is gone for good.
      expect(room.abandonTimer, isNull);
      expect(authority.rooms.containsKey(code), isFalse);
      expect(room.removed, isTrue);
    });
  });
}
