/// Tests for the cross-instance room registry:
///
/// 1. `InMemoryRoomRegistry` — the single-instance default
/// 2. `TursoRoomRegistry` — the TTL map over Turso's SQL-over-HTTP
///    pipeline API, exercised through a mock [http.Client] that asserts
///    the exact wire format (same technique as the leaderboard tests)
library;

import 'dart:async';
import 'dart:convert';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:game_club/server/room_registry.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

http.Response _pipeline(List<dynamic> results) => http.Response(
      jsonEncode({'baton': null, 'base_url': null, 'results': results}),
      200,
      headers: {'content-type': 'application/json'},
    );

Map<String, dynamic> _execResult() => {
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
    };

const Map<String, dynamic> _closeResult = {
  'type': 'ok',
  'response': {'type': 'close'},
};

http.Response _okExecutes(int n) => _pipeline([
      for (var i = 0; i < n; i++) _execResult(),
      _closeResult,
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
      _closeResult,
    ]);

/// Reply for a register pipeline: schema + GC + upsert executes, then the
/// owner SELECT — returning [instance] and its row [owner] (or no rows
/// when the instance is null) — then close.
http.Response _registerReply(String? instance, {String? owner}) => _pipeline([
      _execResult(),
      _execResult(),
      _execResult(),
      instance == null
          ? _execResult()
          : {
              'type': 'ok',
              'response': {
                'type': 'execute',
                'result': {
                  'cols': [
                    {'name': 'instance', 'decltype': 'TEXT'},
                    {'name': 'owner', 'decltype': 'TEXT'},
                  ],
                  'rows': [
                    [
                      {'type': 'text', 'value': instance},
                      owner == null
                          ? {'type': 'null', 'value': null}
                          : {'type': 'text', 'value': owner},
                    ],
                  ],
                  'affected_row_count': 0,
                  'last_insert_rowid': null,
                },
              },
            },
      _closeResult,
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
      expect(await registry.register('ABCD', 'game-1'), isTrue);
      expect(await registry.register('WXYZ', 'game-2'), isTrue);

      expect(await registry.lookup('ABCD'), 'game-1');
      expect(await registry.lookup('WXYZ'), 'game-2');
      expect(await registry.lookup('NOPE'), isNull);

      // Refreshing the same owner's claim succeeds; a different instance
      // claiming a live code is refused so routing stays stable.
      expect(await registry.register('ABCD', 'game-1'), isTrue);
      expect(await registry.register('ABCD', 'game-2'), isFalse);
      expect(await registry.lookup('ABCD'), 'game-1');

      await registry.unregister('ABCD');
      expect(await registry.lookup('ABCD'), isNull);
      // A released code can be claimed by anyone again.
      expect(await registry.register('ABCD', 'game-2'), isTrue);
    });

    test('a competing claim for a live code is refused on the same instance',
        () async {
      // Two concurrent creations on one replica can draw the same code. If
      // both claims reported success the row's owner would be replaced, and
      // the loser's cleanup — which unregisters the token it believes it
      // claimed — would delete the winner's live route: lookups would 404
      // and another replica could take the code before a refresh restored
      // it.
      final registry = InMemoryRoomRegistry();
      await registry.register('ABCD', 'game-1', owner: 'room-1');

      expect(await registry.register('ABCD', 'game-1', owner: 'room-2'),
          isFalse,
          reason: 'a live route belongs to exactly one room token');
      expect(await registry.lookup('ABCD'), 'game-1');

      // The winner's own refresh and close still work.
      expect(
          await registry.register('ABCD', 'game-1', owner: 'room-1'), isTrue);
      await registry.unregister('ABCD', owner: 'room-1');
      expect(await registry.lookup('ABCD'), isNull);

      // Only a freed code can be claimed by the other creation.
      expect(
          await registry.register('ABCD', 'game-1', owner: 'room-2'), isTrue);
    });

    test('unregister honours the room token when codes are recycled', () async {
      final registry = InMemoryRoomRegistry();
      await registry.register('ABCD', 'game-1', owner: 'room-1');

      // The old room closes and its row goes away (the scoped delete, or
      // TTL expiry + GC in the Turso registry).
      await registry.unregister('ABCD', owner: 'room-1');
      expect(await registry.lookup('ABCD'), isNull);

      // A newer room recycles the code and claims the live route.
      await registry.register('ABCD', 'game-1', owner: 'room-2');

      // A late (or retried) delete from the old close must not drop it.
      await registry.unregister('ABCD', owner: 'room-1');
      expect(await registry.lookup('ABCD'), 'game-1',
          reason: 'a stale close never erases a newer room on the same code');

      await registry.unregister('ABCD', owner: 'room-2');
      expect(await registry.lookup('ABCD'), isNull);

      // A token-less unregister stays unconditional.
      await registry.register('ABCD', 'game-1', owner: 'room-3');
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

    test(
        'register: schema, GC, conditional claim, owner select, close',
        () async {
      final requests = <http.Request>[];
      final registry = _registry(requests,
          reply: (_) async => _registerReply('game-1', owner: 'room-42'));
      expect(await registry.register('ABCD', 'game-1', owner: 'room-42'),
          isTrue);

      final stmts = _allStmts(requests);
      // Every pipeline ends by closing the stream (leaderboard-style).
      expect(stmts.last, {'type': 'close'});
      final execs = [
        for (final s in stmts)
          if ((s as Map)['type'] == 'execute') s,
      ];
      expect(execs, hasLength(4));
      final sql = [
        for (final e in execs) e['stmt']['sql'] as String,
      ];
      expect(sql.where((s) => s.startsWith('CREATE TABLE')), hasLength(1),
          reason: 'schema is replayed and idempotent');
      expect(
          sql.where((s) =>
              s.startsWith('DELETE FROM room_registry WHERE expires_at <')),
          hasLength(1),
          reason: 'expired entries are garbage-collected');
      final upsert = sql[2];
      expect(upsert, contains('ON CONFLICT(code) DO UPDATE'));
      expect(
          upsert,
          contains('WHERE (room_registry.instance = excluded.instance '
              'AND room_registry.owner IS excluded.owner)'),
          reason: 'only the owning room token may refresh a live claim — a '
              'competing creation on the same instance must not take over '
              'the row and then unregister the live route');
      expect(upsert, contains('OR room_registry.expires_at <= ?'),
          reason: 'an expired foreign entry may be taken over');
      expect(sql[3], 'SELECT instance, owner FROM room_registry WHERE code = ?',
          reason: 'the owner is re-read to verify the claim truly landed');

      final upsertArgs = execs[2]['stmt']['args'] as List<dynamic>;
      expect((upsertArgs[0] as Map)['value'], 'ABCD');
      expect((upsertArgs[1] as Map)['value'], 'game-1');
      expect((upsertArgs[2] as Map)['value'], 'room-42',
          reason: 'the room token rides along as the row owner');
      expect(int.parse('${(upsertArgs[3] as Map)['value']}'),
          greaterThan(DateTime.now().millisecondsSinceEpoch),
          reason: 'expiry is in the future (the TTL)');
      expect(
          int.parse('${(upsertArgs[4] as Map)['value']}'),
          lessThan(DateTime.now().millisecondsSinceEpoch + 1000),
          reason: 'the CAS watermark is "now"');
    });

    test('register claims a free code and refreshes its own claim', () async {
      final requests = <http.Request>[];
      final registry = _registry(requests,
          reply: (_) async => _registerReply('game-1', owner: 'room-1'));
      expect(await registry.register('ABCD', 'game-1', owner: 'room-1'), isTrue,
          reason: 'the owning room refreshes its own row');
    });

    test('register refuses a competing claim on the same instance', () async {
      // The row is ours but belongs to another room token: two creations
      // drew the same code, and accepting the second claim would let its
      // cleanup unregister the first room's live route.
      final requests = <http.Request>[];
      final registry = _registry(requests,
          reply: (_) async => _registerReply('game-1', owner: 'room-1'));
      expect(await registry.register('ABCD', 'game-1', owner: 'room-2'),
          isFalse,
          reason: 'same instance is not enough — the room token must match');
    });

    test('register refuses to overwrite a live foreign claim', () async {
      final requests = <http.Request>[];
      final registry = _registry(requests,
          reply: (_) async => _registerReply('game-9', owner: 'room-9'));
      expect(await registry.register('ABCD', 'game-1', owner: 'room-1'),
          isFalse,
          reason: 'the row still belongs to game-9 — routing must not move');
    });

    test('register reports false when the owner select comes back empty',
        () async {
      final requests = <http.Request>[];
      final registry =
          _registry(requests, reply: (_) async => _registerReply(null));
      expect(await registry.register('ABCD', 'game-1'), isFalse,
          reason: 'unknown ownership is never treated as a claim');
    });

    test('every pipeline request ends with an explicit close', () async {
      final requests = <http.Request>[];
      final registry =
          _registry(requests, reply: (_) async => _registerReply('game-1'));
      await registry.register('ABCD', 'game-1');
      await registry.lookup('ABCD');
      await registry.unregister('ABCD');
      expect(requests, hasLength(3));
      for (final r in requests) {
        final body = jsonDecode(r.body) as Map<String, dynamic>;
        expect((body['requests'] as List<dynamic>).last, {'type': 'close'},
            reason: 'the stream must be released, not left to time out');
      }
    });

    test('a pipeline that never completes is abandoned after 10s', () {
      fakeAsync((async) {
        final registry = TursoRoomRegistry(
          url: Uri.parse('libsql://routes-acme.turso.io'),
          authToken: 'tok',
          client: MockClient((req) {
            return Completer<http.Response>().future; // never completes
          }),
        );
        expectLater(
          registry.register('ABCD', 'game-1'),
          throwsA(isA<RoomRegistryException>()
              .having((e) => '$e', 'message', contains('timed out after 10s'))),
        );
        async.elapse(const Duration(seconds: 11));
      });
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

    test('unregister deletes only the row owned by the closing room', () async {
      final requests = <http.Request>[];
      await _registry(requests, reply: (_) async => _okExecutes(2))
          .unregister('ABCD', owner: 'room-7');

      final execs = [
        for (final s in _allStmts(requests))
          if ((s as Map)['type'] == 'execute') s,
      ];
      expect(execs.last['stmt']['sql'],
          'DELETE FROM room_registry WHERE code = ? AND owner IS ?',
          reason: 'scoped to the token: a recycled code must survive a '
              'stale close');
      final args = execs.last['stmt']['args'] as List<dynamic>;
      expect((args[0] as Map)['value'], 'ABCD');
      expect((args[1] as Map)['value'], 'room-7');
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
