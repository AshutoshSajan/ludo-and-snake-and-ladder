import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:game_club/main.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  testWidgets('app boots to home with both game cards', (tester) async {
    SharedPreferences.setMockInitialValues({});
    await tester.pumpWidget(const ProviderScope(child: GameClubApp()));
    await tester.pumpAndSettle();

    expect(find.text('Game Club'), findsOneWidget);
    expect(find.text('Ludo'), findsOneWidget);
    expect(find.text('Snakes & Ladders'), findsOneWidget);
    // Leaderboard, Play Online and Settings share one row. Asserted as a
    // group because the point is that they are together: stacked over two rows
    // the last one fell below the fold on a phone.
    await tester.scrollUntilVisible(
      find.text('Play Online'),
      200,
      scrollable: find.byType(Scrollable).first,
    );
    expect(find.text('Play Online'), findsOneWidget);
    expect(find.byIcon(Icons.emoji_events), findsOneWidget);
    expect(find.byIcon(Icons.settings_outlined), findsOneWidget);
    // The removed local board must not come back.
    expect(find.text('On this device'), findsNothing);
    expect(find.text('Online — all players'), findsNothing);
  });

  testWidgets('tapping Ludo opens the setup screen', (tester) async {
    SharedPreferences.setMockInitialValues({});
    await tester.pumpWidget(const ProviderScope(child: GameClubApp()));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Ludo'));
    await tester.pumpAndSettle();

    expect(find.text('Ludo — New game'), findsOneWidget);
    expect(find.text('Start game'), findsOneWidget);
  });
}
