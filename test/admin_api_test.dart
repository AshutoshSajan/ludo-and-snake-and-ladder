/// Admin API tests: auth gate, overview, rooms history, moderation.
library;

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
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

      final rooms = await adminRoomsHandler(
        _get('admin/rooms', token: 't'),
      );
      expect(rooms.statusCode, 200);
      final roomsJson = await _json(rooms);
      expect(roomsJson['totalRooms'], 1);
      expect((roomsJson['recent'] as List).single['code'], 'AB12');

      final ban = await adminActionHandler(
        _post('admin/ban', {'seatId': 's1', 'reason': 'spam'}, token: 't'),
      );
      expect(ban.statusCode, 200);
      expect(await adminStore.isBanned('s1'), isTrue);

      final audit = await adminAuditHandler(
        _get('admin/audit', token: 't'),
      );
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
}
