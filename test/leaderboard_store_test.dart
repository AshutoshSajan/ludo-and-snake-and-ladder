/// Tests for the SQLite-backed leaderboard store (the local fallback).
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:game_club/server/leaderboard_store.dart';

GameResult _res(String seat, String name, int rank, {String color = 'red'}) =>
    GameResult(seatId: seat, name: name, color: color, rank: rank);

void main() {
  test('aggregates wins, games and average rank, best first', () async {
    final store = SqliteLeaderboardStore.inMemory();
    await store.recordResults(gameId: 'g1', results: [
      _res('ana', 'Ana', 1),
      _res('bo', 'Bo', 2),
    ]);
    await store.recordResults(gameId: 'g2', results: [
      _res('bo', 'Bo', 1),
      _res('ana', 'Ana', 2),
    ]);
    await store.recordResults(gameId: 'g3', results: [
      _res('ana', 'Ana', 1),
      _res('bo', 'Bo', 2),
      _res('cy', 'Cy', 3),
    ]);

    expect(await store.totalGames(), 3);
    final rows = await store.topPlayers();
    expect(rows.map((r) => r.name).toList(), ['Ana', 'Bo', 'Cy']);
    expect(rows[0].wins, 2);
    expect(rows[0].games, 3);
    expect(rows[0].avgRank, closeTo(4 / 3, 1e-9));
    expect(rows[1].wins, 1);
    expect(rows[2].games, 1);
  });

  test('re-recording the same gameId is ignored (idempotent)', () async {
    final store = SqliteLeaderboardStore.inMemory();
    final results = [_res('ana', 'Ana', 1), _res('bo', 'Bo', 2)];
    await store.recordResults(gameId: 'g1', results: results);
    await store.recordResults(gameId: 'g1', results: results);
    expect(await store.totalGames(), 1);
    final ana = (await store.topPlayers()).first;
    expect(ana.games, 1, reason: 'a replayed completion must not double count');
  });

  test('the latest display name wins', () async {
    final store = SqliteLeaderboardStore.inMemory();
    await store.recordResults(
        gameId: 'g1', results: [_res('ana', 'Annette', 1)]);
    await store.recordResults(gameId: 'g2', results: [_res('ana', 'Ana', 2)]);
    expect((await store.topPlayers()).single.name, 'Ana');
  });

  test('equal wins are ordered by better average rank', () async {
    final store = SqliteLeaderboardStore.inMemory();
    await store.recordResults(gameId: 'g1', results: [
      _res('x', 'X', 1), _res('y', 'Y', 2), _res('z', 'Z', 3),
    ]);
    await store.recordResults(gameId: 'g2', results: [
      _res('y', 'Y', 1), _res('x', 'X', 2), _res('z', 'Z', 3),
    ]);
    // X and Y each have 1 win and 2 games; X's avg rank (1.5) beats Y's (1.5)?
    // No — identical. Use an uneven game count: Y also plays a 3rd game.
    await store.recordResults(gameId: 'g3', results: [
      _res('y', 'Y', 2), _res('z', 'Z', 1),
    ]);
    // X: 1 win, avg (1+2)/2 = 1.5. Y: 1 win, avg (2+1+2)/3 = 1.67. X first.
    final names = (await store.topPlayers()).map((r) => r.name).toList();
    expect(names.indexOf('X'), lessThan(names.indexOf('Y')));
  });

  test('a file store persists across close/reopen', () async {
    final tmp = await Directory.systemTemp.createTemp('ludo_lb_test');
    addTearDown(() => tmp.delete(recursive: true));
    final path = '${tmp.path}/leaderboard.db';

    final store = SqliteLeaderboardStore(path);
    await store.recordResults(
        gameId: 'g1', results: [_res('ana', 'Ana', 1, color: 'blue')]);
    store.close();

    final reopened = SqliteLeaderboardStore(path);
    addTearDown(reopened.close);
    expect(await reopened.totalGames(), 1);
    final row = (await reopened.topPlayers()).single;
    expect(row.name, 'Ana');
    expect(row.wins, 1);
  });
}
