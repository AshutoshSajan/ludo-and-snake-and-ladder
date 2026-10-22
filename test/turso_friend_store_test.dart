/// Turso-specific behavior for friends persistence: configuration, wire
/// format, redeploy durability, concurrent duplicate requests, additive
/// schema upgrades, and failure atomicity.
///
/// The shared behavior contract (profiles, requests, chat, invites, blocks,
/// caps) runs against this backend in `friend_store_test.dart`. These tests
/// cover the things only the remote backend can get wrong.
library;

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:game_club/server/turso_friend_store.dart';
import 'package:http/http.dart' as http;
import 'package:sqlite3/sqlite3.dart';

import 'fake_turso_pipeline.dart';

DateTime _fixedNow() => DateTime.fromMillisecondsSinceEpoch(1_700_000_000_000);

TursoFriendStore _store(FakeTursoPipeline fake, {DateTime Function()? clock}) =>
    TursoFriendStore(
      url: Uri.parse('https://friends-test.turso.io'),
      authToken: 'test-token',
      client: fake.client,
      clock: clock ?? _fixedNow,
    );

Future<void> _makeFriends(TursoFriendStore store, String a, String b) async {
  await store.serve(a, a);
  await store.serve(b, b);
  await store.sendRequest(a, a, b);
  await store.respond(b, (await store.incoming(b)).single.id, accept: true);
}

void main() {
  group('configuration', () {
    test('fromEnvironment requires both the URL and the token', () {
      expect(TursoFriendStore.fromEnvironment(const {}), isNull);
      expect(
        TursoFriendStore.fromEnvironment(const {
          'TURSO_DATABASE_URL': 'libsql://friends.turso.io',
        }),
        isNull,
        reason: 'a token is required too',
      );
      expect(
        TursoFriendStore.fromEnvironment(const {'TURSO_AUTH_TOKEN': 'tok'}),
        isNull,
      );
      final store = TursoFriendStore.fromEnvironment(const {
        'TURSO_DATABASE_URL': 'libsql://friends.turso.io',
        'TURSO_AUTH_TOKEN': 'tok',
      }, client: FakeTursoPipeline().client);
      expect(store, isNotNull);
      store!.close();
    });

    test('normalizes libsql:// and sends the bearer token', () async {
      final fake = FakeTursoPipeline();
      final store = TursoFriendStore.fromEnvironment(const {
        'TURSO_DATABASE_URL': 'libsql://friends-acme.turso.io',
        'TURSO_AUTH_TOKEN': 't0k',
      }, client: fake.client)!;

      await store.serve('p1', 'A');

      expect(fake.requests, isNotEmpty);
      for (final request in fake.requests) {
        expect(request.method, 'POST');
        expect(
          request.url.toString(),
          'https://friends-acme.turso.io/v2/pipeline',
        );
        expect(request.headers['authorization'], 'Bearer t0k');
        expect(request.headers['content-type'], startsWith('application/json'));
      }
      final body = jsonDecode(fake.requests.first.body) as Map;
      expect(body['baton'], isNull, reason: 'each call opens a fresh stream');
      expect((body['requests'] as List).last['type'], 'close');

      store.close();
      fake.dispose();
    });
  });

  group('durability', () {
    test('friendships, DMs, and invites survive a redeploy', () async {
      final fake = FakeTursoPipeline();
      var store = _store(fake);

      await _makeFriends(store, 'p1', 'p2');
      final message = await store.send('p1', 'p2', 'see you after the deploy');
      final invite = await store.sendInvite(
        'p1',
        'p1',
        'p2',
        'ludo',
        code: 'ABCD',
      );
      final code = (await store.profile('p1'))!.code;
      store.close();

      // A new process, a new store, the same database.
      store = _store(fake);
      expect((await store.friends('p1')).single.seatId, 'p2');
      expect(
        (await store.chat('p1', 'p2')).messages.single.id,
        message.id,
        reason: 'DM history outlives the store instance',
      );
      expect((await store.invites('p2')).single.id, invite.id);
      expect(
        (await store.profile('p1'))!.code,
        code,
        reason: 'friend codes are permanent handles',
      );

      store.close();
      fake.dispose();
    });

    test('the whole schema is idempotent across restarts', () async {
      final fake = FakeTursoPipeline();
      var store = _store(fake);
      await store.serve('p1', 'A');
      store.close();

      store = _store(fake);
      await store.serve('p1', 'A');
      await store.serve('p2', 'B');
      expect(await store.profile('p1'), isNotNull);
      store.close();

      final tables = fake.db
          .select("SELECT name FROM sqlite_master WHERE type = 'table'")
          .map((row) => row['name'])
          .toSet();
      expect(
        tables,
        containsAll([
          'friend_profiles',
          'friendships',
          'friend_requests',
          'friend_messages',
          'friend_invites',
          'friend_blocks',
        ]),
      );
      final indexes = fake.db
          .select("SELECT name FROM sqlite_master WHERE type = 'index'")
          .map((row) => row['name'])
          .toSet();
      expect(indexes, contains('idx_friend_messages_pair'));
      expect(indexes, contains('idx_friend_blocks_blocker'));

      fake.dispose();
    });
  });

  group('concurrency and atomicity', () {
    test('concurrent duplicate requests create exactly one row', () async {
      final fake = FakeTursoPipeline();
      final store = _store(fake);
      await store.serve('p1', 'A');
      await store.serve('p2', 'B');

      final results = await Future.wait([
        for (var i = 0; i < 8; i++) store.sendRequest('p1', 'A', 'p2'),
      ]);

      expect(results, everyElement('pending'));
      expect(await store.outgoing('p1'), hasLength(1));
      expect(await store.incoming('p2'), hasLength(1));

      store.close();
      fake.dispose();
    });

    test('a failed block step rolls the transaction back', () async {
      final fake = FakeTursoPipeline();
      final store = _store(fake);
      await _makeFriends(store, 'p1', 'p2');

      fake.failOnSql = 'INSERT OR IGNORE INTO friend_blocks';
      await expectLater(
        store.block('p1', 'p2'),
        throwsA(
          isA<TursoFriendStoreException>().having(
            (e) => e.message,
            'message',
            contains('injected failure'),
          ),
        ),
      );

      // Nothing from the aborted pipeline may leak: the friendship is intact
      // and no block row exists.
      fake.failOnSql = null;
      expect(
        await store.areFriends('p1', 'p2'),
        isTrue,
        reason: 'the friendship delete must roll back',
      );
      expect(await store.isBlocked('p1', 'p2'), isFalse);

      store.close();
      fake.dispose();
    });
  });

  group('failure handling', () {
    test('HTTP failures surface as TursoFriendStoreException', () async {
      final fake = FakeTursoPipeline();
      fake.failure = http.Response('unauthorized', 401);
      final store = _store(fake);

      await expectLater(
        store.profile('p1'),
        throwsA(
          isA<TursoFriendStoreException>().having(
            (e) => e.message,
            'message',
            contains('401'),
          ),
        ),
      );

      store.close();
      fake.dispose();
    });

    test('statement failures surface instead of reporting success', () async {
      final fake = FakeTursoPipeline();
      fake.failOnSql = 'INSERT INTO friend_profiles';
      final store = _store(fake);

      await expectLater(
        store.serve('p1', 'A'),
        throwsA(
          isA<TursoFriendStoreException>().having(
            (e) => e.message,
            'message',
            contains('injected failure'),
          ),
        ),
      );
      expect(await store.profile('p1'), isNull);

      fake.failOnSql = null;
      store.close();
      fake.dispose();
    });

    test('an outage never half-writes a friend request', () async {
      final fake = FakeTursoPipeline();
      final store = _store(fake);
      await store.serve('p1', 'A');
      await store.serve('p2', 'B');

      fake.failure = http.Response('database is down', 503);
      await expectLater(
        store.sendRequest('p1', 'A', 'p2'),
        throwsA(isA<TursoFriendStoreException>()),
      );

      fake.failure = null;
      expect(await store.outgoing('p1'), isEmpty);
      expect(await store.incoming('p2'), isEmpty);

      store.close();
      fake.dispose();
    });
  });

  group('additive schema upgrades', () {
    test(
      'adds reply columns to a database created before reply quotes',
      () async {
        // The pre-reply schema, exactly as an existing deployment has it.
        final db = sqlite3.openInMemory();
        db.execute('''
        CREATE TABLE friend_messages (
          id INTEGER PRIMARY KEY AUTOINCREMENT,
          from_seat TEXT NOT NULL,
          to_seat TEXT NOT NULL,
          body TEXT NOT NULL,
          liked INTEGER NOT NULL DEFAULT 0,
          reply_to INTEGER,
          created_ms INTEGER NOT NULL
        )
      ''');
        db.execute(
          "INSERT INTO friend_messages "
          "(from_seat, to_seat, body, liked, reply_to, created_ms) "
          "VALUES ('p1', 'p2', 'old message', 0, NULL, 1)",
        );
        final fake = FakeTursoPipeline(db: db);
        final store = _store(fake);

        final page = await store.chat('p1', 'p2');

        final columns = db
            .select('SELECT name FROM pragma_table_info(?)', [
              'friend_messages',
            ])
            .map((row) => row['name'])
            .toSet();
        expect(columns, containsAll(['reply_from', 'reply_body']));
        expect(page.messages.single.body, 'old message');
        expect(page.messages.single.replyFrom, '');
        expect(page.messages.single.replyBody, '');
        expect(
          db.select('SELECT COUNT(*) AS n FROM friend_messages').first['n'],
          1,
          reason: 'the upgrade adds columns, never rows or drops',
        );

        store.close();
        fake.dispose();
      },
    );
  });
}
