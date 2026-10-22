/// The leaderboard's redesigned standings page.
///
/// The server data did not change, so these tests pin the presentation:
/// the champion is the only full-width winner card, second and third get
/// medal cards, and everyone else stays in one compact table that still fits
/// a phone. They also prove the redesign kept the exact summary line and the
/// three empty/error contracts the other test file owns.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:game_club/screens/scoreboard_screen.dart';
import 'package:game_club/services/online_client.dart';

LeaderboardRow row(String name, int wins, int games, double avg) =>
    LeaderboardRow(
      name: name,
      wins: wins,
      games: games,
      avgRank: avg,
      seatId: name.toLowerCase(),
    );

Future<void> show(
  WidgetTester tester,
  LeaderboardData data, {
  Size size = const Size(390, 844),
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(
    ProviderScope(
      child: MaterialApp(
        home: ScoreboardScreen(
          serverUrl: 'ws://localhost:8080/ws',
          load: (_) async => data,
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('the podium is champion, two medal cards, then the field', (
    tester,
  ) async {
    await show(
      tester,
      LeaderboardData(
        games: 9,
        game: 'all',
        gamesByGame: const {'ludo': 4, 'snakes': 5},
        rows: [
          row('Ana', 5, 9, 1.0),
          row('Ben', 3, 9, 2.0),
          row('Cy', 1, 9, 3.0),
          row('Di', 0, 9, 4.0),
          row('Eli', 0, 9, 5.0),
        ],
      ),
    );

    // The champion card is the one place the first name appears: the field
    // table starts at fourth, so a player is never listed twice.
    expect(find.text('CHAMPION'), findsOneWidget);
    expect(find.text('1st'), findsOneWidget);
    expect(find.text('Ana'), findsOneWidget);
    expect(find.text('Ben'), findsOneWidget);
    expect(find.text('THE REST OF THE TABLE'), findsOneWidget);
    expect(find.text('Di'), findsOneWidget);

    // The summary still names both quantities, so a tab's game count cannot
    // be read as the row count beneath it.
    expect(find.text('9 games · 5 players'), findsOneWidget);
    expect(find.text('Ludo · 4 games'), findsOneWidget);
    expect(find.text('Snakes · 5 games'), findsOneWidget);
    expect(find.text('All · 9 games'), findsOneWidget);

    expect(tester.takeException(), isNull);
  });

  testWidgets('ten players still fit one phone-width table', (tester) async {
    final rows = [
      for (var i = 1; i <= 10; i++)
        row('Player $i', 11 - i, 10, i.toDouble()),
    ];
    await show(
      tester,
      LeaderboardData(
        games: 10,
        rows: rows,
        gamesByGame: const {'ludo': 10},
      ),
    );

    // The last row is below the fold; scroll it into view rather than
    // pretending a long leaderboard is a single screen.
    await tester.scrollUntilVisible(
      find.text('Player 10'),
      180,
      scrollable: find.byType(Scrollable).last,
    );
    expect(find.text('Player 10'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets("switching tabs keeps the All count combined", (tester) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    var calls = 0;
    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          home: ScoreboardScreen(
            serverUrl: 'ws://localhost:8080/ws',
            load: (_) async {
              calls++;
              if (calls == 1) {
                return LeaderboardData(
                  games: 12,
                  game: 'all',
                  gamesByGame: const {'ludo': 7, 'snakes': 5},
                  rows: [
                    row('Ana', 6, 9, 1.3),
                    row('Ben', 3, 8, 1.9),
                    row('Cy', 2, 8, 2.3),
                  ],
                );
              }
              return LeaderboardData(
                games: 5,
                game: 'snakes',
                gamesByGame: const {'ludo': 7, 'snakes': 5},
                rows: [row('Ana', 2, 3, 1.3), row('Di', 1, 2, 2.0)],
              );
            },
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('All · 12 games'), findsOneWidget);

    await tester.tap(find.text('Snakes · 5 games'));
    await tester.pumpAndSettle();

    // The filtered response says "5 games"; that is the Snakes board, not
    // the combined board the All tab still points at.
    expect(find.text('5 games · 2 players'), findsOneWidget);
    expect(find.text('All · 12 games'), findsOneWidget);
    expect(find.text('Career results on the Snakes board'), findsOneWidget);
    expect(find.text('Ana'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('a narrow phone has no row overflow', (tester) async {
    await show(
      tester,
      LeaderboardData(
        games: 10,
        rows: [
          for (var i = 1; i <= 4; i++)
            row('A rather long player name $i', 11 - i, 10, i.toDouble()),
        ],
        gamesByGame: const {'ludo': 10, 'snakes': 0},
      ),
      size: const Size(320, 700),
    );

    await tester.scrollUntilVisible(
      find.text('THE REST OF THE TABLE'),
      160,
      scrollable: find.byType(Scrollable).last,
    );
    expect(find.text('THE REST OF THE TABLE'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('a single player is a champion card, not an empty field', (
    tester,
  ) async {
    await show(
      tester,
      LeaderboardData(
        games: 1,
        rows: [row('Solo', 1, 1, 1.0)],
      ),
    );

    expect(find.text('CHAMPION'), findsOneWidget);
    expect(find.text('Solo'), findsOneWidget);
    expect(find.text('1 win in 1 game'), findsOneWidget);
    expect(find.text('THE REST OF THE TABLE'), findsNothing);
    expect(tester.takeException(), isNull);
  });
}
