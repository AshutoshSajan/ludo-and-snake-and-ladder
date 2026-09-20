/// Tests for the Turso (libSQL) leaderboard store — the remote backend that
/// lets the leaderboard survive on ephemeral free hosts.
///
/// The store talks Turso's SQL-over-HTTP API (`POST /v2/pipeline`, Bearer
/// auth). A mock [http.Client] asserts the exact wire format and feeds back
/// canned pipeline responses, so no network or Turso account is needed.
library;

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:game_club/server/leaderboard_store.dart';
import 'package:game_club/server/turso_leaderboard_store.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

GameResult _res(String seat, String name, int rank, {String color = 'red'}) =>
    GameResult(seatId: seat, name: name, color: color, rank: rank);

/// A successful pipeline response with [n] `execute` results plus `close`.
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

http.Response _pipeline(List<dynamic> results) => http.Response(
      jsonEncode({'baton': null, 'base_url': null, 'results': results}),
      200,
      headers: {'content-type': 'application/json'},
    );

// Typed wire values — the pipeline API encodes every cell as {type, value}.
Map<String, dynamic> _text(String v) => {'type': 'text', 'value': v};

/// Integers travel as strings (JSON numbers cannot hold all 64-bit ints),
/// but number-encoded integers must decode too.
Map<String, dynamic> _int(Object v) => {'type': 'integer', 'value': v};

Map<String, dynamic> _float(num v) => {'type': 'float', 'value': v};

Map<String, dynamic> _rowsResult(
        List<List<dynamic>> rows, List<String> names) =>
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
    };

/// The list of pipeline request objects carried by a captured request.
List<dynamic> _stmts(http.Request request) =>
    (jsonDecode(request.body) as Map<String, dynamic>)['requests']
        as List<dynamic>;

TursoLeaderboardStore _store(
  void Function(http.Request request) capture, {
  String url = 'https://db.turso.io',
  Future<http.Response> Function(http.Request request)? reply,
}) =>
    TursoLeaderboardStore(
      url: Uri.parse(url),
      authToken: 'tok',
      client: MockClient((req) async {
        capture(req);
        return reply != null ? reply(req) : _okExecutes(2);
      }),
    );

void main() {
  group('TursoLeaderboardStore over the HTTP pipeline API', () {
    test('targets /v2/pipeline over https with a bearer token', () async {
      final requests = <http.Request>[];
      final store = _store(requests.add,
          url: 'libsql://ludo-leaderboard-acme.turso.io');
      await store.recordResults(gameId: 'g1', results: [_res('ana', 'Ana', 1)]);

      expect(requests, isNotEmpty);
      for (final r in requests) {
        expect(r.method, 'POST');
        expect(r.url.toString(),
            'https://ludo-leaderboard-acme.turso.io/v2/pipeline');
        expect(r.headers['authorization'], 'Bearer tok');
        expect(r.headers['content-type'], startsWith('application/json'));
      }
    });

    test('first write creates the schema, inserts idempotently, closes the stream',
        () async {
      final requests = <http.Request>[];
      final store = _store(requests.add);
      await store.recordResults(gameId: 'g1', results: [
        _res('ana', 'Ana', 1),
        _res('bo', 'Bo', 2, color: 'blue'),
      ]);

      // Two pipelines: schema creation, then the result writes.
      expect(requests, hasLength(2));
      expect((jsonDecode(requests[0].body) as Map)['baton'], isNull,
          reason: 'each pipeline opens a fresh stream');

      final schema = _stmts(requests[0]);
      final sqls = [
        for (final s in schema.where((s) => s['type'] == 'execute'))
          s['stmt']['sql'] as String
      ];
      expect(sqls[0], contains('CREATE TABLE IF NOT EXISTS results'));
      expect(
          sqls.where(
              (s) => s.contains('CREATE INDEX IF NOT EXISTS idx_results_seat')),
          isNotEmpty);
      expect(
          sqls.where((s) => s.contains(
              'CREATE UNIQUE INDEX IF NOT EXISTS idx_results_game_seat')),
          isNotEmpty);
      expect(sqls.last, contains('CREATE TABLE IF NOT EXISTS players'));
      expect(schema.last['type'], 'close');

      final write = _stmts(requests[1]);
      expect(write, hasLength(5)); // 2 inserts + 2 player upserts + close
      expect(write.last['type'], 'close');

      final insert = write[0]['stmt'] as Map;
      expect(insert['sql'], contains('INSERT OR IGNORE INTO results'));
      expect(
          insert['sql'],
          contains(
              '(game_id, seat_id, name, color, rank, played_at)'));
      final args = insert['args'] as List;
      expect(args[0], _text('g1'));
      expect(args[1], _text('ana'));
      expect(args[2], _text('Ana'));
      expect(args[3], _text('red'));
      expect(args[4], _int('1'),
          reason: 'integers travel as strings to keep 64-bit precision');
      expect(args[5]['type'], 'integer');
      expect(int.parse(args[5]['value'] as String), greaterThan(0));

      // Rows are written per player: insert, then the name upsert.
      final upsert = write[1]['stmt'] as Map;
      expect(
          upsert['sql'], contains('INSERT INTO players (seat_id, name)'));
      expect(upsert['sql'],
          contains('ON CONFLICT(seat_id) DO UPDATE SET name = excluded.name'));
      expect(upsert['args'], [_text('ana'), _text('Ana')]);

      final insert2 = write[2]['stmt'] as Map;
      expect(insert2['args'][1], _text('bo'));
      expect(insert2['args'][3], _text('blue'));
      expect(insert2['args'][4], _int('2'));
      expect(write[3]['stmt']['args'], [_text('bo'), _text('Bo')]);
    });

    test('later writes reuse the schema (no repeated DDL)', () async {
      final requests = <http.Request>[];
      final store = _store(requests.add);
      await store.recordResults(gameId: 'g1', results: [_res('ana', 'Ana', 1)]);
      await store.recordResults(gameId: 'g2', results: [_res('ana', 'Ana', 2)]);
      expect(requests, hasLength(3));
      expect(_stmts(requests[2]).first['stmt']['sql'],
          startsWith('INSERT OR IGNORE'));
    });

    test('parses aggregated rows into entries', () async {
      final captured = <http.Request>[];
      final store = _store(captured.add, reply: (req) async {
        return _pipeline([
          _rowsResult([
            [_text('ana'), _text('Ana'), _int('2'), _int(3), _float(4 / 3)],
            [_text('bo'), _text('Bo'), _int(1), _int('2'), _float(2.5)],
          ], [
            'seat_id',
            'name',
            'wins',
            'games',
            'avg_rank',
          ]),
          {
            'type': 'ok',
            'response': {'type': 'close'},
          },
        ]);
      });

      final rows = await store.topPlayers(limit: 10);

      final stmt = _stmts(captured.last).first['stmt'] as Map;
      expect(stmt['sql'], contains('SUM(CASE WHEN r.rank = 1 THEN 1 ELSE 0 END)'));
      expect(stmt['sql'], contains('ORDER BY wins DESC, avg_rank ASC, games DESC'));
      expect(stmt['args'], [_int('10')]);

      expect(rows, hasLength(2));
      expect(rows[0].seatId, 'ana');
      expect(rows[0].name, 'Ana');
      expect(rows[0].wins, 2);
      expect(rows[0].games, 3);
      expect(rows[0].avgRank, closeTo(4 / 3, 1e-9));
      expect(rows[1].wins, 1);
      expect(rows[1].games, 2);
      expect(rows[1].avgRank, 2.5);
    });

    test('counts distinct games', () async {
      final store = _store((_) {}, reply: (req) async {
        return _pipeline([
          _rowsResult([
            [_int('7')],
          ], ['n']),
          {
            'type': 'ok',
            'response': {'type': 'close'},
          },
        ]);
      });
      expect(await store.totalGames(), 7);
    });

    test('surfaces statement errors as TursoLeaderboardException', () async {
      final store = _store((_) {}, reply: (req) async {
        if (req.body.contains('CREATE TABLE')) return _okExecutes(4);
        return _pipeline([
          {
            'type': 'error',
            'error': {'message': 'no such table: results'},
          },
        ]);
      });
      await expectLater(
        store.totalGames(),
        throwsA(isA<TursoLeaderboardException>()
            .having((e) => e.message, 'message', contains('no such table'))),
      );
    });

    test('surfaces HTTP failures as TursoLeaderboardException', () async {
      final store = _store((_) {},
          reply: (req) async => http.Response('unauthorized', 401));
      await expectLater(
        store.recordResults(gameId: 'g1', results: [_res('ana', 'Ana', 1)]),
        throwsA(isA<TursoLeaderboardException>()
            .having((e) => e.message, 'message', contains('401'))),
      );
    });

    test('an empty result list sends nothing', () async {
      var calls = 0;
      final store = _store((_) {}, reply: (req) async {
        calls++;
        return _okExecutes(1);
      });
      await store.recordResults(gameId: 'g1', results: []);
      expect(calls, isZero);
    });

    test('a failed schema attempt is retried on the next call', () async {
      final requests = <http.Request>[];
      final store = _store(requests.add, reply: (req) async {
        return requests.length == 1 ? http.Response('boom', 500) : _okExecutes(2);
      });
      await expectLater(
        store.recordResults(gameId: 'g1', results: [_res('ana', 'Ana', 1)]),
        throwsA(isA<TursoLeaderboardException>()),
      );
      await store.recordResults(gameId: 'g1', results: [_res('ana', 'Ana', 1)]);
      // The schema pipeline ran again; the write finally went through.
      expect(requests, hasLength(3));
      expect(_stmts(requests[1]).first['stmt']['sql'],
          contains('CREATE TABLE IF NOT EXISTS results'));
      expect(_stmts(requests[2]).first['stmt']['sql'],
          contains('INSERT OR IGNORE INTO results'));
    });

    test('fromEnvironment reads the Turso CLI variable names', () async {
      expect(TursoLeaderboardStore.fromEnvironment(const {}), isNull);
      expect(
          TursoLeaderboardStore.fromEnvironment(
              const {'TURSO_DATABASE_URL': 'libsql://db.turso.io'}),
          isNull,
          reason: 'a token is required too');

      final requests = <http.Request>[];
      final store = TursoLeaderboardStore.fromEnvironment(
        const {
          'TURSO_DATABASE_URL': 'libsql://db-acme.turso.io',
          'TURSO_AUTH_TOKEN': 't0k',
        },
        client: MockClient((req) async {
          requests.add(req);
          return _okExecutes(1);
        }),
      )!;
      await store.recordResults(gameId: 'g1', results: [_res('ana', 'Ana', 1)]);
      expect(requests.first.url.toString(), 'https://db-acme.turso.io/v2/pipeline');
      expect(requests.first.headers['authorization'], 'Bearer t0k');
    });


  });
}
