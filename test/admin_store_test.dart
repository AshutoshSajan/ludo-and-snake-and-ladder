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
}
