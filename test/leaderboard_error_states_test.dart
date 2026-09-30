/// The leaderboard screen has three "no scores" states, and collapsing them
/// into one sent the player hunting for the wrong culprit: a server that
/// answered 500 (its own Turso store broken) reads exactly like a server that
/// is not running at all. Each state now says what it means.
library;

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:game_club/screens/scoreboard_screen.dart';
import 'package:game_club/services/online_client.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

void main() {
  Future<void> show(
    WidgetTester tester,
    Future<LeaderboardData> Function(String) load,
  ) async {
    await tester.pumpWidget(MaterialApp(
      home: ScoreboardScreen(
        serverUrl: 'ws://localhost:8080/ws',
        load: load,
      ),
    ));
    await tester.pumpAndSettle();
  }

  group('the three empty-scoreboard states stay distinct', () {
    testWidgets('a server that answered 500 is not reported as unreachable',
        (tester) async {
      // The deployed server fails exactly this way (bad Turso credentials):
      // it is up, so telling the player to start it is a dead end.
      await show(tester,
          (_) async => throw LeaderboardServerException(500, 'oops'));
      expect(find.textContaining('answered but could not load the scores'),
          findsOneWidget);
      expect(find.textContaining('HTTP 500'), findsOneWidget);
      expect(find.textContaining('Could not reach the server'), findsNothing);
      expect(find.textContaining('dart run bin/server.dart'), findsNothing);
    });

    testWidgets('a server that never answers keeps its own hint',
        (tester) async {
      await show(tester, (_) async => throw const SocketException('refused'));
      expect(find.textContaining('Could not reach the server at'),
          findsOneWidget);
      expect(find.textContaining('dart run bin/server.dart'), findsOneWidget);
      expect(find.textContaining('answered but could not load the scores'),
          findsNothing);
    });

    testWidgets('zero finished games is an empty board, not a failure',
        (tester) async {
      // A fresh server legitimately has no rows; calling it "could not reach"
      // hides a working setup behind a fake outage.
      await show(tester,
          (_) async => LeaderboardData(games: 0, rows: const []));
      expect(find.textContaining('No games finished yet'), findsOneWidget);
      expect(find.text('Retry'), findsNothing);
      expect(find.textContaining('Could not reach'), findsNothing);
    });

    testWidgets('a full board renders the players', (tester) async {
      await show(
        tester,
        (_) async => LeaderboardData(games: 7, rows: [
              LeaderboardRow(name: 'Ana', wins: 4, games: 7, avgRank: 1.4),
            ]),
      );
      expect(find.text('7 games · 1 player'), findsOneWidget);
      expect(find.text('Ana'), findsOneWidget);
    });
  });

  group('the per-game tabs label what they count', () {
    // The tabs used to read "Ludo 1", "All 12" — a bare number that reads as
    // the number of players below it. They are the number of finished games,
    // and the two differ whenever a game has more than one player, which is
    // every game. "All 12" over 9 rows looked like a broken ranking.
    testWidgets('a tab count is labelled as games, never a bare number',
        (tester) async {
      await show(
        tester,
        (_) async => LeaderboardData(
          games: 12,
          game: 'all',
          gamesByGame: const {'ludo': 1, 'snakes': 6},
          rows: [
            LeaderboardRow(name: 'Ana', wins: 1, games: 1, avgRank: 1),
            LeaderboardRow(name: 'Ben', wins: 1, games: 1, avgRank: 1),
          ],
        ),
      );
      expect(find.text('Ludo · 1 game'), findsOneWidget);
      expect(find.text('Snakes · 6 games'), findsOneWidget);
      expect(find.text('All · 12 games'), findsOneWidget);
      // The old, ambiguous wording must be gone.
      expect(find.text('All 12'), findsNothing);
      expect(find.text('Ludo 1'), findsNothing);
    });

    testWidgets('per-game counts that do not sum to the total are still games',
        (tester) async {
      // gamesByGame counts only rows tagged with a game; pre-migration rows
      // have game = '' and appear on the combined board alone. So the tabs are
      // 1 + 6 = 7 while "All" says 12, and the labels must not "correct" it.
      await show(
        tester,
        (_) async => LeaderboardData(
          games: 12,
          game: 'all',
          gamesByGame: const {'ludo': 1, 'snakes': 6},
          rows: [LeaderboardRow(name: 'Ana', wins: 1, games: 1, avgRank: 1)],
        ),
      );
      expect(find.text('All · 12 games'), findsOneWidget);
      expect(find.text('All 12'), findsNothing);
      // The summary names both quantities, so the tab's game count cannot be
      // misread as a row count.
      expect(find.text('12 games · 1 player'), findsOneWidget);
    });

    testWidgets('a server that reports no split gets no tabs', (tester) async {
      // An old server has no gamesByGame; the numbers would all read 0, which
      // is worse than no tabs at all.
      await show(
        tester,
        (_) async => LeaderboardData(
          games: 5,
          rows: [LeaderboardRow(name: 'Ana', wins: 1, games: 1, avgRank: 1)],
        ),
      );
      expect(find.text('Ludo · 0 games'), findsNothing);
      expect(find.text('All · 5 games'), findsNothing);
      expect(find.text('5 games · 1 player'), findsOneWidget);
    });
  });

  group('fetchLeaderboard failure kinds', () {
    test('a non-200 is reported as a server answer, with its status',
        () async {
      // This is the boundary where "reachable" and "unreachable" split, so
      // the classification is pinned here rather than in the widget.
      final client =
          MockClient((_) async => http.Response('Internal Server Error', 500));
      await expectLater(
        OnlineClient.fetchLeaderboard('ws://example.test/ws',
            httpClient: client),
        throwsA(isA<LeaderboardServerException>()
            .having((e) => e.statusCode, 'statusCode', 500)),
      );
    });

    test('a 200 with no rows is a result, not a failure', () async {
      final client = MockClient((_) async => http.Response(
          '{"ok":true,"games":0,"players":[]}', 200,
          headers: {'content-type': 'application/json'}));
      final data = await OnlineClient.fetchLeaderboard('ws://example.test/ws',
          httpClient: client);
      expect(data.games, 0);
      expect(data.rows, isEmpty);
    });
  });
}
