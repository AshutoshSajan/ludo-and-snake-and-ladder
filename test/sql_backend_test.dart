/// The shared SQL seam: SQLite and Turso must behave the same for the
/// stores that now sit on top of it.
library;

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:game_club/server/sql_backend.dart';

import 'fake_turso_pipeline.dart';

void main() {
  group('SqliteBackend', () {
    test('a multi-statement batch is atomic', () async {
      final backend = SqliteBackend.inMemory();
      addTearDown(backend.close);
      await backend.run([const SqlStatement('CREATE TABLE t (v TEXT)')]);

      await expectLater(
        backend.run(const [
          SqlStatement("INSERT INTO t VALUES ('a')"),
          SqlStatement('INSERT INTO missing_table VALUES (1)'),
        ]),
        throwsA(isA<SqlException>()),
      );

      final count = await backend.run(const [
        SqlStatement('SELECT COUNT(*) AS n FROM t'),
      ]);
      expect(count.first.rows.first['n'], 0);
    });

    test('reports affected rows and last insert id for writes', () async {
      final backend = SqliteBackend.inMemory();
      addTearDown(backend.close);
      await backend.run(const [
        SqlStatement('CREATE TABLE t (id INTEGER PRIMARY KEY, v TEXT)'),
      ]);

      final inserted = await backend.run(const [
        SqlStatement("INSERT INTO t (v) VALUES ('a')"),
      ]);
      expect(inserted.first.affected, 1);
      expect(inserted.first.lastInsertId, 1);

      final updated = await backend.run(const [
        SqlStatement("UPDATE t SET v = 'b' WHERE id = 1"),
      ]);
      expect(updated.first.affected, 1);

      final missing = await backend.run(const [
        SqlStatement("UPDATE t SET v = 'c' WHERE id = 99"),
      ]);
      expect(missing.first.affected, 0);
    });
  });

  group('TursoBackend', () {
    test('fromEnvironment requires both the URL and the token', () {
      expect(TursoBackend.fromEnvironment(const {}), isNull);
      expect(
        TursoBackend.fromEnvironment(const {
          'TURSO_DATABASE_URL': 'libsql://sql.turso.io',
        }),
        isNull,
      );
      expect(
        TursoBackend.fromEnvironment(const {'TURSO_AUTH_TOKEN': 'tok'}),
        isNull,
      );
    });

    test('normalizes the URL and speaks the pipeline wire format', () async {
      final fake = FakeTursoPipeline();
      addTearDown(fake.dispose);
      final backend = TursoBackend(
        url: Uri.parse('libsql://sql-test.turso.io'),
        authToken: 't0k',
        client: fake.client,
      );
      addTearDown(backend.close);

      await backend.run(const [
        SqlStatement('CREATE TABLE t (id INTEGER PRIMARY KEY, v TEXT)'),
      ]);
      final request = fake.requests.single;
      expect(request.method, 'POST');
      expect(request.url.toString(), 'https://sql-test.turso.io/v2/pipeline');
      expect(request.headers['authorization'], 'Bearer t0k');
      final body = jsonDecode(request.body) as Map<String, dynamic>;
      expect(body['baton'], isNull);
      final requests = body['requests'] as List<dynamic>;
      expect(requests, hasLength(2), reason: 'one statement plus close');
      expect((requests.first as Map)['type'], 'execute');
      expect((requests.last as Map)['type'], 'close');
    });

    test('wraps a multi-statement batch in one transaction', () async {
      final fake = FakeTursoPipeline();
      addTearDown(fake.dispose);
      final backend = TursoBackend(
        url: Uri.parse('turso://sql-test.turso.io'),
        authToken: 't0k',
        client: fake.client,
      );

      await backend.run(const [SqlStatement('CREATE TABLE t (v TEXT)')]);
      await backend.run(const [
        SqlStatement("INSERT INTO t VALUES ('a')"),
        SqlStatement("INSERT INTO t VALUES ('b')"),
      ]);

      final requests =
          (jsonDecode(fake.requests.last.body) as Map)['requests'] as List;
      expect((requests.first as Map)['stmt']['sql'], 'BEGIN IMMEDIATE');
      expect(
        ((requests[requests.length - 2] as Map)['stmt'] as Map)['sql'],
        'COMMIT',
      );
      expect((requests.last as Map)['type'], 'close');
      expect(fake.db.select('SELECT COUNT(*) AS n FROM t').first['n'], 2);
    });

    test('rolls the whole batch back when a statement fails', () async {
      final fake = FakeTursoPipeline();
      addTearDown(fake.dispose);
      final backend = TursoBackend(
        url: Uri.parse('https://sql-test.turso.io'),
        authToken: 't0k',
        client: fake.client,
      );

      await backend.run(const [SqlStatement('CREATE TABLE t (v TEXT)')]);
      fake.failOnSql = 'INSERT INTO missing';
      await expectLater(
        backend.run(const [
          SqlStatement("INSERT INTO t VALUES ('a')"),
          SqlStatement('INSERT INTO missing VALUES (1)'),
        ]),
        throwsA(isA<SqlException>()),
      );
      expect(fake.db.select('SELECT COUNT(*) AS n FROM t').first['n'], 0);
    });

    test('decodes typed cells into plain Dart values', () async {
      final fake = FakeTursoPipeline();
      addTearDown(fake.dispose);
      final backend = TursoBackend(
        url: Uri.parse('https://sql-test.turso.io'),
        authToken: 't0k',
        client: fake.client,
      );

      final result = await backend.run(const [
        SqlStatement("SELECT 42 AS n, 'x' AS s, 1.5 AS f, NULL AS z"),
      ]);
      final row = result.first.rows.first;
      expect(row['n'], 42);
      expect(row['s'], 'x');
      expect(row['f'], 1.5);
      expect(row['z'], isNull);
    });
  });
}
