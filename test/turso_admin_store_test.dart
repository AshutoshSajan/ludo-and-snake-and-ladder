/// AdminStore over Turso's HTTP pipeline: the same presence, moderation,
/// leaderboard, account and Data-tab behavior the SQLite contract proves,
/// plus the remote-specific guarantees (transaction atomicity and the
/// additive `game` column upgrade).
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:game_club/server/admin_store.dart';
import 'package:game_club/server/admin_tables.dart';
import 'package:game_club/server/sql_backend.dart';

import 'fake_turso_pipeline.dart';

AdminStore _store(FakeTursoPipeline fake) => AdminStore.fromBackend(
  TursoBackend(
    url: Uri.parse('https://admin-test.turso.io'),
    authToken: 'test-token',
    client: fake.client,
  ),
);

void main() {
  test(
    'presence, bans, audit and leaderboard rows survive a redeploy',
    () async {
      final fake = FakeTursoPipeline();
      addTearDown(fake.dispose);

      var store = _store(fake);
      await store.recordPresenceAt(seatId: 'p1', name: 'Asha', atMs: 1000);
      await store.recordPresenceAt(seatId: 'p1', name: 'Asha R', atMs: 2000);
      await store.ban(seatId: 'p2', reason: 'spam', by: 'admin');
      await store.recordResult(
        gameId: 'g1',
        seatId: 'p1',
        name: 'Asha',
        game: 'ludo',
        rank: 1,
      );
      await store.recordRoomCreated(code: 'ABCD', game: 'ludo', instance: 'i1');
      await store.recordRoomStarted('ABCD');
      await store.recordRoomClosed('ABCD', winnerSeat: 'p1', playerCount: 2);

      // A new process, a new store, the same remote database.
      store = _store(fake);
      final player = (await store.player('p1'))!;
      expect(player.name, 'Asha R');
      expect(player.firstSeen, 1000, reason: 'first_seen must not move');
      expect(player.lastSeen, 2000);
      expect(await store.isBanned('p2'), isTrue);
      expect(
        (await store.auditLog()).map((e) => e.action),
        containsAll(['ban']),
      );
      expect((await store.topPlayers()).single.wins, 1);
      expect(await store.totalGames(), 1);
      expect((await store.recentRooms()).single.status, 'closed');
      expect((await store.overview()).totalPlayers, 1);
      expect((await store.overview()).totalRooms, 1);
    },
  );

  test('ban and its audit row are one transaction', () async {
    final fake = FakeTursoPipeline();
    addTearDown(fake.dispose);
    final store = _store(fake);
    await store.ensureSchema();

    fake.failOnSql = 'INSERT INTO admin_audit';
    await expectLater(
      store.ban(seatId: 'p1', reason: 'spam', by: 'admin'),
      throwsA(isA<SqlException>()),
    );

    expect(
      fake.db.select('SELECT COUNT(*) AS n FROM admin_bans').first['n'],
      0,
      reason: 'the failed audit insert rolls the ban back too',
    );
  });

  test(
    'adds the game column to a database created before per-game boards',
    () async {
      final fake = FakeTursoPipeline();
      addTearDown(fake.dispose);
      fake.db.execute('''
      CREATE TABLE results (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        game_id TEXT NOT NULL,
        seat_id TEXT NOT NULL,
        name TEXT NOT NULL,
        color TEXT NOT NULL,
        rank INTEGER NOT NULL,
        played_at INTEGER NOT NULL
      );
      CREATE TABLE players (seat_id TEXT PRIMARY KEY, name TEXT NOT NULL);
    ''');

      final store = _store(fake);
      await store.ensureSchema();

      final columns = {
        for (final row in fake.db.select('PRAGMA table_info(results)'))
          row['name'] as String,
      };
      expect(columns, contains('game'));
      await store.recordResult(
        gameId: 'g1',
        seatId: 'p1',
        name: 'Asha',
        game: 'snakes',
        rank: 1,
      );
      expect(await store.totalGames(game: 'snakes'), 1);
    },
  );

  test('accounts and sessions work over the pipeline', () async {
    final fake = FakeTursoPipeline();
    addTearDown(fake.dispose);
    final store = _store(fake);

    expect(await store.needsSetup, isTrue);
    final user = await store.createUser(
      email: 'admin@example.com',
      name: 'Admin',
      password: 'hunter2hunter2',
      role: 'admin',
      iterations: 1000,
    );
    expect(await store.needsSetup, isFalse);

    expect(await store.checkCredentials('admin@example.com', 'wrong'), isNull);
    expect(
      (await store.checkCredentials('admin@example.com', 'hunter2hunter2'))!.id,
      user.id,
    );
    expect(await store.findUserByEmail('missing@example.com'), isNull);

    final session = await store.createSession(user.id);
    expect(
      (await store.validateSession(session.token))!.email,
      'admin@example.com',
    );
    await store.revokeSession(session.token);
    expect(await store.validateSession(session.token), isNull);
  });

  test('generic table CRUD reaches Turso and reports affected rows', () async {
    final fake = FakeTursoPipeline();
    addTearDown(fake.dispose);
    final store = _store(fake);
    final spec = tableSpec('players')!;

    await store.insertTableRow(spec, {'seat_id': 's1', 'name': 'Ana'});
    final rows = await store.tableRows(spec);
    expect(rows.single['name'], 'Ana');
    expect(await store.tableCount(spec), 1);

    expect(await store.updateTableRow(spec, 's1', {'name': 'Ana P.'}), isTrue);
    expect(await store.updateTableRow(spec, 'missing', {'name': 'x'}), isFalse);
    expect(await store.deleteTableRow(spec, 's1'), isTrue);
    expect(await store.deleteTableRow(spec, 's1'), isFalse);
    expect(await store.tableRows(spec), isEmpty);
  });
}
