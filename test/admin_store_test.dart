/// Admin API tests (TDD RED): presence tracking, growth stats,
/// game lifecycle records, moderation, and leaderboard edits.
///
/// These tests define the intended admin surface. They fail until the
/// implementation lands — that is the point.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:game_club/server/admin_store.dart';

void main() {
  group('AdminStore: presence', () {
    test('first ping creates a player record with firstSeen', () async {
      final store = AdminStore.inMemory();
      final before = DateTime.now().millisecondsSinceEpoch;
      await store.recordPresence(seatId: 's1', name: 'Asha');
      final player = await store.player('s1');
      expect(player, isNotNull);
      expect(player!.firstSeen, greaterThanOrEqualTo(before));
      expect(player.name, 'Asha');
    });

    test('repeat pings update name and lastSeen without moving firstSeen',
        () async {
      final store = AdminStore.inMemory();
      await store.recordPresence(seatId: 's1', name: 'Asha');
      final first = (await store.player('s1'))!.firstSeen;
      await Future<void>.delayed(const Duration(milliseconds: 5));
      await store.recordPresence(seatId: 's1', name: 'Asha R');
      final player = (await store.player('s1'))!;
      expect(player.firstSeen, first);
      expect(player.lastSeen, greaterThanOrEqualTo(first));
      expect(player.name, 'Asha R');
    });
  });

  group('AdminStore: growth stats', () {
    test('new players per day counts firstSeen buckets', () async {
      final store = AdminStore.inMemory();
      final day = DateTime.now().millisecondsSinceEpoch ~/ 86400000;
      await store.recordPresenceAt(
          seatId: 's1', name: 'A', atMs: day * 86400000 + 1000);
      await store.recordPresenceAt(
          seatId: 's2', name: 'B', atMs: day * 86400000 + 2000);
      await store.recordPresenceAt(
          seatId: 's3', name: 'C', atMs: (day - 1) * 86400000);
      final growth = await store.newPlayersPerDay(days: 2);
      expect(growth.length, 2);
      expect(growth.last.newPlayers, 2);
      expect(growth.first.newPlayers, 1);
    });
  });

  group('AdminStore: moderation', () {
    test('ban blocks, unban restores', () async {
      final store = AdminStore.inMemory();
      expect(await store.isBanned('s1'), isFalse);
      await store.ban(seatId: 's1', reason: 'spam', by: 'admin');
      expect(await store.isBanned('s1'), isTrue);
      await store.unban('s1', by: 'admin');
      expect(await store.isBanned('s1'), isFalse);
    });

    test('expired ban no longer blocks', () async {
      final store = AdminStore.inMemory();
      await store.ban(
          seatId: 's1',
          reason: 'temp',
          by: 'admin',
          untilMs: DateTime.now().millisecondsSinceEpoch - 1);
      expect(await store.isBanned('s1'), isFalse);
    });

    test('ban is audited', () async {
      final store = AdminStore.inMemory();
      await store.ban(seatId: 's1', reason: 'spam', by: 'admin');
      final log = await store.auditLog(limit: 10);
      expect(log.any((e) => e.action == 'ban' && e.seatId == 's1'), isTrue);
    });
  });

  group('AdminStore: leaderboard edits', () {
    test('rename updates display name without merging rows', () async {
      final store = AdminStore.inMemory();
      await store.recordResult(
          gameId: 'g1', seatId: 's1', name: 'Asha', game: 'ludo', rank: 1);
      await store.recordResult(
          gameId: 'g1', seatId: 's2', name: 'B', game: 'ludo', rank: 2);
      await store.renamePlayer(seatId: 's1', name: 'Asha R', by: 'admin');
      final top = await store.topPlayers();
      final renamed = top.firstWhere((e) => e.seatId == 's1');
      expect(renamed.name, 'Asha R');
      expect(top.firstWhere((e) => e.seatId == 's2').name, 'B');
    });

    test('deleteGame removes only that game', () async {
      final store = AdminStore.inMemory();
      await store.recordResult(
          gameId: 'g1', seatId: 's1', name: 'A', game: 'ludo', rank: 1);
      await store.recordResult(
          gameId: 'g2', seatId: 's1', name: 'A', game: 'ludo', rank: 2);
      await store.deleteGame('g1', by: 'admin');
      expect(await store.totalGames(), 1);
    });
  });

  group('AdminStore: credentials at rest (bcrypt)', () {
    test('new passwords are digested at the store cost', () async {
      // The stored row is the bcrypt string itself: salt AND cost are
      // self-declared in it, so verification needs nothing fetched beside
      // it. The recording seam receives the stored hash on a real
      // account's verification — the `04` is bcrypt's two-digit rendering
      // of log-rounds 4 (the value threaded for speed; production uses 12
      // through [defaultBcryptRounds]).
      final hashesSeen = <String>[];
      final store = AdminStore.inMemory(
        bcryptRounds: 4,
        verifier: (password, hash) {
          hashesSeen.add(hash);
          return true;
        },
      );
      addTearDown(store.close);
      await store.createUser(
        email: 'root@x.io',
        name: 'Root',
        password: 'long-enough-1',
        role: 'admin',
      );
      expect(await store.checkCredentials('root@x.io', 'long-enough-1'),
          isNotNull);
      expect(hashesSeen.single, startsWith(r'$2a$04$'));
    });

    test('same password, two accounts, two different salts', () async {
      final hashesSeen = <String>[];
      final store = AdminStore.inMemory(
        bcryptRounds: 4,
        verifier: (password, hash) {
          hashesSeen.add(hash);
          return true;
        },
      );
      addTearDown(store.close);
      await store.createUser(
          email: 'a@x.io', name: 'A', password: 'long-enough-1');
      await store.createUser(
          email: 'b@x.io', name: 'B', password: 'long-enough-1');
      await store.checkCredentials('a@x.io', 'long-enough-1');
      await store.checkCredentials('b@x.io', 'long-enough-1');
      expect(hashesSeen, hasLength(2));
      expect(hashesSeen[0], isNot(equals(hashesSeen[1])),
          reason: 'a fresh random salt per digest: identical passwords '
              'must not share a stored string');
    });
  });

  group('AdminStore: the session TTL knob', () {
    test('a default store sessions for the two-hour window', () async {
      // The window the login cookie's Max-Age mirrors — set from
      // ADMIN_SESSION_TTL_HOURS at boot, 2h when the environment is quiet.
      final store = AdminStore.inMemory(bcryptRounds: 4);
      addTearDown(store.close);
      expect(AdminStore.defaultSessionTtl, const Duration(hours: 2));
      expect(store.sessionTtl, AdminStore.defaultSessionTtl);
    });

    test('createSessionAt stamps every row from the one store clock', () async {
      // [atMs] is injectable so the stamp is pinned, not flaky with real
      // time: expiresAt = at + store.sessionTtl, exactly what the cookie
      // handler mirrors as Max-Age.
      final store = AdminStore.inMemory(
        bcryptRounds: 4,
        sessionTtl: const Duration(hours: 3),
      );
      addTearDown(store.close);
      final user = await store.createUser(
        email: 'root@x.io',
        name: 'Root',
        password: 'long-enough-1',
        role: 'admin',
      );
      final atMs = DateTime.now().millisecondsSinceEpoch;
      final session = await store.createSessionAt(user.id, atMs);
      expect(
        session.expiresAt,
        atMs + const Duration(hours: 3).inMilliseconds,
      );
      expect((await store.validateSession(session.token))?.id, user.id);
    });

    test('adminSessionTtlFromEnv: unset equals 2h, whole hours only', () {
      final twoHours = const Duration(hours: 2);
      expect(AdminStore.adminSessionTtlFromEnv(null), twoHours);
      expect(AdminStore.adminSessionTtlFromEnv(''), twoHours);
      expect(AdminStore.adminSessionTtlFromEnv('   '), twoHours);
      expect(AdminStore.adminSessionTtlFromEnv('2'), twoHours);
      expect(AdminStore.adminSessionTtlFromEnv(' 2 '), twoHours,
          reason: 'the deployment layer will hand over spaces some day');
      expect(AdminStore.adminSessionTtlFromEnv('24'), const Duration(hours: 24));

      // Everything else refuses to boot in main(): a silent misread would
      // stretch or shorten every admin's window at once.
      expect(AdminStore.adminSessionTtlFromEnv('2.5'), isNull);
      expect(AdminStore.adminSessionTtlFromEnv('0'), isNull);
      expect(AdminStore.adminSessionTtlFromEnv('-1'), isNull);
      expect(AdminStore.adminSessionTtlFromEnv('abc'), isNull);
      expect(AdminStore.adminSessionTtlFromEnv('2h'), isNull);
    });

    test('a session dies when its store window says so', () async {
      final store = AdminStore.inMemory(
        bcryptRounds: 4,
        sessionTtl: const Duration(milliseconds: 1),
      );
      addTearDown(store.close);
      final user = await store.createUser(
        email: 'short@x.io',
        name: 'S',
        password: 'long-enough-1',
      );
      final session = await store.createSession(user.id);
      await Future<void>.delayed(const Duration(milliseconds: 15));
      expect(await store.validateSession(session.token), isNull,
          reason: 'expiry is enforced on read, and the dead row is deleted '
              'in the same sight');
    });
  });
}
