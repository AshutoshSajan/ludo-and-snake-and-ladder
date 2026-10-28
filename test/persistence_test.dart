/// Guards the single-store rule: when Turso is configured, EVERY durable
/// store must be Turso-backed and no local SQLite file may be opened. The
/// previous split — admin/auth/feedback on the host's SQLite file,
/// leaderboard/friends/room-routing in Turso — happened because each store
/// made its own backend choice. These tests fail if that choice stops being
/// one decision.
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:game_club/server/friend_store.dart';
import 'package:game_club/server/leaderboard_store.dart';
import 'package:game_club/server/persistence.dart';
import 'package:game_club/server/room_registry.dart';
import 'package:game_club/server/turso_friend_store.dart';
import 'package:game_club/server/turso_leaderboard_store.dart';

import 'fake_turso_pipeline.dart';

const _tursoEnv = {
  'TURSO_DATABASE_URL': 'libsql://persistence-test.turso.io',
  'TURSO_AUTH_TOKEN': 'test-token',
};

void main() {
  test(
    'Turso mode backs every store with Turso and never opens SQLite',
    () async {
      final dir = Directory.systemTemp.createTempSync('persistence-turso-');
      final dbPath = '${dir.path}/ludo_leaderboard.db';
      final fake = FakeTursoPipeline();
      final client = fake.client;
      final persistence = openPersistence(
        env: _tursoEnv,
        dbPath: dbPath,
        tursoClient: client,
      );
      addTearDown(() {
        persistence.close();
        fake.dispose();
        dir.deleteSync(recursive: true);
      });

      expect(persistence.usesTurso, isTrue);
      expect(persistence.leaderboard, isA<TursoLeaderboardStore>());
      expect(persistence.friends, isA<TursoFriendStore>());
      expect(persistence.rooms, isA<TursoRoomRegistry>());
      expect(persistence.registryTtl, const Duration(seconds: 120));

      // Exercise every store family: a regression that quietly built one of
      // them on SQLite would either write to the local file or skip the
      // remote pipeline entirely.
      await persistence.ensureSchema();
      await persistence.admin.recordResult(
        gameId: 'admin-game',
        seatId: 'admin-seat',
        name: 'Asha',
        game: 'ludo',
        rank: 1,
      );
      await persistence.reports.create(category: 'bug', message: 'Dice stuck');
      await persistence.leaderboard.recordResults(
        gameId: 'board-game',
        results: [
          GameResult(seatId: 'board-seat', name: 'Ravi', color: 'red', rank: 1),
        ],
      );
      await persistence.friends.serve('friend-seat', 'Mira');
      expect(await persistence.rooms.register('ABCD', 'game-1'), isTrue);

      // The writes landed in the remote database…
      expect(
        fake.db
            .select(
              "SELECT COUNT(*) AS n FROM results WHERE game_id = 'admin-game'",
            )
            .first['n'],
        1,
      );
      expect(
        fake.db.select('SELECT COUNT(*) AS n FROM feedback').first['n'],
        1,
      );
      expect(
        fake.db
            .select(
              "SELECT COUNT(*) AS n FROM results WHERE game_id = 'board-game'",
            )
            .first['n'],
        1,
      );
      expect(
        fake.db.select('SELECT COUNT(*) AS n FROM friend_profiles').first['n'],
        1,
      );
      expect(await persistence.rooms.lookup('ABCD'), 'game-1');
      expect(fake.calls, greaterThan(0));

      // …and the local fallback was never even created.
      expect(
        File(dbPath).existsSync(),
        isFalse,
        reason: 'Turso mode must not open the local SQLite file at all',
      );
    },
  );

  test(
    'local mode opens one SQLite file and keeps every store on it',
    () async {
      final dir = Directory.systemTemp.createTempSync('persistence-local-');
      final dbPath = '${dir.path}/ludo_leaderboard.db';
      final persistence = openPersistence(env: const {}, dbPath: dbPath);
      addTearDown(() {
        persistence.close();
        dir.deleteSync(recursive: true);
      });

      expect(persistence.usesTurso, isFalse);
      expect(persistence.leaderboard, isA<SqliteLeaderboardStore>());
      expect(persistence.friends, isA<SqliteFriendStore>());
      expect(persistence.rooms, isA<InMemoryRoomRegistry>());
      expect(persistence.registryTtl, isNull);

      await persistence.ensureSchema();
      await persistence.admin.recordPresenceAt(
        seatId: 's1',
        name: 'Asha',
        atMs: 1000,
      );
      await persistence.admin.recordResult(
        gameId: 'g1',
        seatId: 's1',
        name: 'Asha',
        game: 'ludo',
        rank: 1,
      );
      await persistence.reports.create(category: 'bug', message: 'Dice stuck');
      await persistence.friends.serve('s2', 'Ravi');

      expect(File(dbPath).existsSync(), isTrue);
      expect(await persistence.reports.count(), 1);
      expect((await persistence.admin.player('s1'))!.name, 'Asha');
    },
  );

  test(
    'half a Turso configuration falls back to local instead of splitting',
    () async {
      final dir = Directory.systemTemp.createTempSync('persistence-partial-');
      final dbPath = '${dir.path}/ludo_leaderboard.db';
      final persistence = openPersistence(
        env: const {'TURSO_DATABASE_URL': 'libsql://persistence-test.turso.io'},
        dbPath: dbPath,
      );
      addTearDown(() {
        persistence.close();
        dir.deleteSync(recursive: true);
      });

      expect(persistence.usesTurso, isFalse);
      expect(persistence.leaderboard, isA<SqliteLeaderboardStore>());
      expect(persistence.friends, isA<SqliteFriendStore>());
      expect(File(dbPath).existsSync(), isTrue);
    },
  );

  test('bin/server.dart constructs no store itself', () {
    final source = File('bin/server.dart').readAsStringSync();
    expect(source, contains('openPersistence('));

    // A store constructed directly in the entrypoint is how the split
    // started. New stores belong in lib/server/persistence.dart, where the
    // Turso/local decision is made once and covered above.
    const forbidden = [
      'sqlite3.open(',
      'SqliteLeaderboardStore(',
      'SqliteFriendStore(',
      'AdminStore(',
      'AdminStore.fromDb(',
      'ReportStore(',
      'ReportStore.fromDb(',
      'TursoBackend.fromEnvironment(',
      'TursoLeaderboardStore.fromEnvironment(',
      'TursoFriendStore.fromEnvironment(',
      'TursoRoomRegistry.fromEnvironment(',
    ];
    for (final snippet in forbidden) {
      expect(
        source,
        isNot(contains(snippet)),
        reason:
            'bin/server.dart must use openPersistence() instead of '
            'constructing "$snippet" directly',
      );
    }
  });
}
