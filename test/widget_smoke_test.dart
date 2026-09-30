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
    // The local leaderboard is gone, so exactly one board remains and it is
    // simply "Leaderboard" — no qualifier needed to tell it apart from
    // anything. The trophy pins the icon too, since the label alone would not
    // catch a stray cloud or bar-chart glyph.
    expect(find.text('On this device'), findsNothing);
    expect(find.text('Online — all players'), findsNothing);
    // The home list is a ListView, so the board button sits below the fold at
    // the default 800x600 test viewport. scrollUntilVisible is how a user
    // reaches it; a bare find.text reports it missing and invites deleting a
    // button that works fine on a real screen.
    await tester.scrollUntilVisible(
      find.text('Leaderboard'),
      200,
      scrollable: find.byType(Scrollable).first,
    );
    expect(find.text('Leaderboard'), findsOneWidget);
    expect(find.byIcon(Icons.emoji_events), findsOneWidget);
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
