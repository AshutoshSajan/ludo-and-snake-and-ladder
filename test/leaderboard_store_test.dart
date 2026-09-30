/// Tests for the SQLite-backed leaderboard store (the local fallback).
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:game_club/server/leaderboard_store.dart';
import 'package:sqlite3/sqlite3.dart';

GameResult _res(String seat, String name, int rank, {String color = 'red'}) =>
    GameResult(seatId: seat, name: name, color: color, rank: rank);

void main() {
  test('aggregates wins, games and average rank, best first', () async {
    final store = SqliteLeaderboardStore.inMemory();
    await store.recordResults(
      gameId: 'g1',
      results: [_res('ana', 'Ana', 1), _res('bo', 'Bo', 2)],
    );
    await store.recordResults(
      gameId: 'g2',
      results: [_res('bo', 'Bo', 1), _res('ana', 'Ana', 2)],
    );
    await store.recordResults(
      gameId: 'g3',
      results: [
        _res('ana', 'Ana', 1),
        _res('bo', 'Bo', 2),
        _res('cy', 'Cy', 3),
      ],
    );

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
      gameId: 'g1',
      results: [_res('ana', 'Annette', 1)],
    );
    await store.recordResults(gameId: 'g2', results: [_res('ana', 'Ana', 2)]);
    expect((await store.topPlayers()).single.name, 'Ana');
  });

  test('equal wins are ordered by better average rank', () async {
    final store = SqliteLeaderboardStore.inMemory();
    await store.recordResults(
      gameId: 'g1',
      results: [_res('x', 'X', 1), _res('y', 'Y', 2), _res('z', 'Z', 3)],
    );
    await store.recordResults(
      gameId: 'g2',
      results: [_res('y', 'Y', 1), _res('x', 'X', 2), _res('z', 'Z', 3)],
    );
    // X and Y each have 1 win and 2 games; X's avg rank (1.5) beats Y's (1.5)?
    // No — identical. Use an uneven game count: Y also plays a 3rd game.
    await store.recordResults(
      gameId: 'g3',
      results: [_res('y', 'Y', 2), _res('z', 'Z', 1)],
    );
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
      gameId: 'g1',
      results: [_res('ana', 'Ana', 1, color: 'blue')],
    );
    store.close();

    final reopened = SqliteLeaderboardStore(path);
    addTearDown(reopened.close);
    expect(await reopened.totalGames(), 1);
    final row = (await reopened.topPlayers()).single;
    expect(row.name, 'Ana');
    expect(row.wins, 1);
  });

  group('per-game boards', () {
    // The online leaderboard had no game dimension at all: every result went
    // into one merged table, so a Snakes win was indistinguishable from a Ludo
    // one and there was no Snakes board to show. These pin the split.
    GameResult snakes(String seat, String name, int rank) => GameResult(
      seatId: seat,
      name: name,
      color: 'red',
      rank: rank,
      game: 'snakes',
    );

    test(
      'a snakes win is recorded on the snakes board, not the ludo one',
      () async {
        final store = SqliteLeaderboardStore.inMemory();
        addTearDown(store.close);
        await store.recordResults(
          gameId: 'g1',
          results: [snakes('ana', 'Ana', 1)],
        );

        final snakesBoard = await store.topPlayers(game: 'snakes');
        expect(snakesBoard.single.name, 'Ana');
        expect(snakesBoard.single.wins, 1);

        // The same win must not leak onto the Ludo board.
        expect(await store.topPlayers(game: 'ludo'), isEmpty);
        expect(await store.totalGames(game: 'ludo'), 0);
        expect(await store.totalGames(game: 'snakes'), 1);
      },
    );

    test('the combined board still spans both games', () async {
      final store = SqliteLeaderboardStore.inMemory();
      addTearDown(store.close);
      await store.recordResults(
        gameId: 'g1',
        results: [_res('ana', 'Ana', 1, color: 'blue')],
      );
      await store.recordResults(gameId: 'g2', results: [snakes('bo', 'Bo', 1)]);

      final all = await store.topPlayers();
      expect(all.map((r) => r.name).toSet(), {'Ana', 'Bo'});
      expect(await store.totalGames(), 2);
    });

    test('one player keeps separate careers per game', () async {
      final store = SqliteLeaderboardStore.inMemory();
      addTearDown(store.close);
      await store.recordResults(
        gameId: 'g1',
        results: [_res('ana', 'Ana', 1, color: 'blue')],
      );
      await store.recordResults(
        gameId: 'g2',
        results: [snakes('ana', 'Ana', 2)],
      );

      final ludo = (await store.topPlayers(game: 'ludo')).single;
      final snake = (await store.topPlayers(game: 'snakes')).single;
      expect(ludo.wins, 1);
      expect(snake.wins, 0);
      expect(snake.avgRank, 2.0);
    });

    test('a database from before per-game boards gains the column', () async {
      // The deployed store is exactly this: a `results` table created without
      // `game`. CREATE TABLE IF NOT EXISTS leaves it alone, so the ALTER is the
      // only thing that upgrades it. Without it every insert naming `game`
      // fails and the leaderboard 500s.
      final tmp = await Directory.systemTemp.createTemp('ludo_lb_migrate');
      addTearDown(() => tmp.delete(recursive: true));
      final path = '${tmp.path}/old.db';

      final legacy = sqlite3.open(path);
      legacy.execute('''
        CREATE TABLE results (
          id INTEGER PRIMARY KEY AUTOINCREMENT,
          game_id TEXT NOT NULL,
          seat_id TEXT NOT NULL,
          name TEXT NOT NULL,
          color TEXT NOT NULL,
          rank INTEGER NOT NULL,
          played_at INTEGER NOT NULL
        );
        CREATE UNIQUE INDEX idx_results_game_seat ON results(game_id, seat_id);
        CREATE TABLE players (seat_id TEXT PRIMARY KEY, name TEXT NOT NULL);
      ''');
      // A row from before the column existed: its game is genuinely unknown.
      legacy.execute(
        "INSERT INTO results (game_id, seat_id, name, color, rank, played_at) "
        "VALUES ('old', 'zed', 'Zed', 'red', 1, 0)",
      );
      // The board joins results to players, so the legacy row needs its
      // display name recorded the way the old code recorded it.
      legacy.execute(
        "INSERT INTO players (seat_id, name) VALUES ('zed', 'Zed')",
      );
      legacy.close();

      final store = SqliteLeaderboardStore(path);
      addTearDown(store.close);

      // The old row survives, on the combined board only — claiming it was a
      // Ludo game would invent history.
      expect(await store.totalGames(), 1);
      expect((await store.topPlayers()).single.name, 'Zed');
      expect(await store.topPlayers(game: 'ludo'), isEmpty);
      expect(await store.topPlayers(game: 'snakes'), isEmpty);

      // And the upgraded table accepts new per-game results.
      await store.recordResults(
        gameId: 'new',
        results: [snakes('ana', 'Ana', 1)],
      );
      expect((await store.topPlayers(game: 'snakes')).single.name, 'Ana');
    });
  });
}
