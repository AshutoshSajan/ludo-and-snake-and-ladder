/// The home Friends action is the app-level doorway: it must wear the same
/// request count the watcher publishes, not wait for the player to open the
/// lobby or the friends tray first.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:game_club/screens/home_screen.dart';
import 'package:game_club/services/friend_signals.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('the home Friends action wears the shared request count', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({'gc.tutorialAsked': true});
    friendSignals.incomingRequests.value = 2;
    addTearDown(friendSignals.reset);

    await tester.pumpWidget(
      const ProviderScope(child: MaterialApp(home: HomeScreen())),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 60));

    final badge = tester.widget<Badge>(
      find.byKey(const ValueKey('home-friends-badge')),
    );
    expect(badge.isLabelVisible, isTrue);
    expect(
      find.descendant(
        of: find.byKey(const ValueKey('home-friends-badge')),
        matching: find.text('2'),
      ),
      findsOneWidget,
    );

    friendSignals.incomingRequests.value = 0;
    await tester.pump();
    final cleared = tester.widget<Badge>(
      find.byKey(const ValueKey('home-friends-badge')),
    );
    expect(cleared.isLabelVisible, isFalse);
  });
}
