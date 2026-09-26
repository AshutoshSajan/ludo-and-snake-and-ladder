/// Tests for the cross-instance room registry:
///
/// 1. `InMemoryRoomRegistry` — the single-instance default
/// 2. `TursoRoomRegistry` — the TTL map over Turso's SQL-over-HTTP
///    pipeline API, exercised through a mock [http.Client] that asserts
///    the exact wire format (same technique as the leaderboard tests)
library;

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:game_club/server/room_registry.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

http.Response _pipeline(List<dynamic> results) => http.Response(
      jsonEncode({'baton': null, 'base_url': null, 'results': results}),
      200,
      headers: {'content-type': 'application/json'},
    );

http.Response _okExecutes(int n) => _pipeline([
      for (var i = 0; i < n; i++)
        {
          'type': 'ok',
          'response': {
            'type': 'execute',
            'result': {
              'cols': <dynamic>[],
              'rows': <dynamic>[],
              'affected_row_count': 1,
              'last_insert_rowid': null,
            },
          },
        },
      {
        'type': 'ok',
        'response': {'type': 'close'},
      },
    ]);

http.Response _rowsResult(List<List<dynamic>> rows, List<String> names) =>
    _pipeline([
      {
        'type': 'ok',
        'response': {
          'type': 'execute',
          'result': {
            'cols': [
              for (final n in names)
                {'name': n, 'decltype': 'TEXT'},
            ],
            'rows': rows,
            'affected_row_count': 0,
            'last_insert_rowid': null,
          },
        },
      },
      {
        'type': 'ok',
        'response': {'type': 'close'},
      },
    ]);

/// All pipeline request objects carried by the captured requests, in order.
List<dynamic> _allStmts(List<http.Request> requests) => [
      for (final r in requests)
        ...(jsonDecode(r.body) as Map<String, dynamic>)['requests']
            as List<dynamic>,
    ];

TursoRoomRegistry _registry(
  List<http.Request> requests, {
  Future<http.Response> Function(http.Request request)? reply,
  String url = 'libsql://routes-acme.turso.io',
}) =>
    TursoRoomRegistry(
      url: Uri.parse(url),
      authToken: 'tok',
      client: MockClient((req) async {
        requests.add(req);
        return reply != null ? reply(req) : _okExecutes(3);
      }),
    );

void main() {
  group('InMemoryRoomRegistry', () {
    test('registers, looks up, and unregisters rooms', () async {
      final registry = InMemoryRoomRegistry();
      await registry.register('ABCD', 'game-1');
      await registry.register('WXYZ', 'game-2');

      expect(await registry.lookup('ABCD'), 'game-1');
      expect(await registry.lookup('WXYZ'), 'game-2');
      expect(await registry.lookup('NOPE'), isNull);

      await registry.register('ABCD', 'game-2'); // refresh/move
      expect(await registry.lookup('ABCD'), 'game-2');

      await registry.unregister('ABCD');
      expect(await registry.lookup('ABCD'), isNull);
    });
  });

  group('TursoRoomRegistry over the HTTP pipeline API', () {
    test('targets /v2/pipeline over https with a bearer token', () async {
      final requests = <http.Request>[];
      await _registry(requests).register('ABCD', 'game-1');

      expect(requests, hasLength(1));
      final r = requests.single;
      expect(r.url.toString(), 'https://routes-acme.turso.io/v2/pipeline');
      expect(r.headers['authorization'], 'Bearer tok');
      expect(r.headers['content-type'], startsWith('application/json'));
    });

    test('register creates the table, GCs expired rows, and upserts a TTL',
        () async {
      final requests = <http.Request>[];
      await _registry(requests, reply: (_) async => _okExecutes(3))
          .register('ABCD', 'game-1');

      final sql = [
        for (final s in _allStmts(requests))
          (s as Map)['stmt']['sql'] as String,
      ];
      expect(sql.where((s) => s.startsWith('CREATE TABLE')), hasLength(1),
          reason: 'schema is replayed and idempotent');
      expect(
          sql.where((s) =>
              s.startsWith('DELETE FROM room_registry WHERE expires_at <')),
          hasLength(1),
          reason: 'expired entries are garbage-collected');
      final upsert = sql.lastWhere((s) => s.startsWith('INSERT INTO'));
      expect(upsert, contains('ON CONFLICT(code) DO UPDATE'));

      final args = _allStmts(requests).last['stmt']['args'] as List<dynamic>;
      final values = args.map((a) => (a as Map)['value']).toList();
      expect(values[0], 'ABCD');
      expect(values[1], 'game-1');
      expect(int.parse('${values[2]}'),
          greaterThan(DateTime.now().millisecondsSinceEpoch),
          reason: 'expiry is in the future (the TTL)');
    });

    test('lookup returns the owning instance for a known code', () async {
      final requests = <http.Request>[];
      final registry = _registry(requests,
          reply: (_) async => _rowsResult([
                [
                  {'type': 'text', 'value': 'game-2'}
                ],
              ], ['instance']));

      expect(await registry.lookup('ABCD'), 'game-2');
    });

    test('lookup returns null when the code is unknown or expired', () async {
      final requests = <http.Request>[];
      final registry =
          _registry(requests, reply: (_) async => _rowsResult([], ['instance']));

      expect(await registry.lookup('NOPE'), isNull);
    });

    test('unregister deletes the mapping', () async {
      final requests = <http.Request>[];
      await _registry(requests, reply: (_) async => _okExecutes(2))
          .unregister('ABCD');

      final sql = [
        for (final s in _allStmts(requests))
          (s as Map)['stmt']['sql'] as String,
      ];
      expect(sql.last, 'DELETE FROM room_registry WHERE code = ?');
      final args = _allStmts(requests).last['stmt']['args'] as List<dynamic>;
      expect((args.single as Map)['value'], 'ABCD');
    });

    test('a failed pipeline step surfaces as RoomRegistryException',
        () async {
      final requests = <http.Request>[];
      final registry = _registry(
          requests,
          reply: (_) async => _pipeline([
                {
                  'type': 'error',
                  'error': {'message': 'boom'},
                },
              ]));

      await expectLater(
        registry.register('ABCD', 'game-1'),
        throwsA(isA<RoomRegistryException>()),
      );
    });

    test('fromEnvironment falls back to null without env config', () {
      expect(TursoRoomRegistry.fromEnvironment({}), isNull);
      expect(
        TursoRoomRegistry.fromEnvironment(
            {'TURSO_DATABASE_URL': 'libsql://db.turso.io'}),
        isNull,
        reason: 'a token is required too',
      );
    });
  });
}
