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
      expect(find.text('7 games recorded here'), findsOneWidget);
      expect(find.text('Ana'), findsOneWidget);
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
