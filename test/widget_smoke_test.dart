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
    // Both leaderboards are reachable and must be distinguishable: the local
    // one counts games played on this device, the online one counts games
    // played by anyone. Asserting both labels is what stops them drifting back
    // into two buttons that both read like "the leaderboard".
    expect(find.text('On this device'), findsOneWidget);
    // The home list is a ListView, so the online button sits below the fold at
    // the default 800x600 test viewport. scrollUntilVisible is how a user would
    // reach it; find.text alone would report it missing and tempt someone into
    // deleting a button that works fine on a real screen.
    await tester.scrollUntilVisible(
      find.text('Online — all players'),
      200,
      scrollable: find.byType(Scrollable).first,
    );
    expect(find.text('Online — all players'), findsOneWidget);
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
