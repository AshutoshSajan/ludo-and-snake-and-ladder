/// Rule 11, home-screen edition: the menu's cards sit in the same reading
/// column (`kContentMaxWidth`) the room creation form and every other page
/// body use. The home column used to be a bespoke 520 wide, so walking from
/// the lobby to the home screen traded card widths underneath the player —
/// the exact unevenness the rule exists to prevent.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:game_club/screens/home_screen.dart';
import 'package:game_club/ui/page_app_bar.dart';
import 'package:shared_preferences/shared_preferences.dart';

Future<void> _pumpHome(WidgetTester tester, double width) async {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = Size(width, 800);
  addTearDown(tester.view.reset);
  // The tutorial ask is home's story to own (test/tutorial_test.dart); these
  // tests are about the column, so the ask is answered away in storage.
  SharedPreferences.setMockInitialValues({'gc.tutorialAsked': true});
  await tester.pumpWidget(
    const ProviderScope(child: MaterialApp(home: HomeScreen())),
  );
  await tester.pumpAndSettle();
}

List<double> _columnWidths(WidgetTester tester) => tester
    .widgetList<ConstrainedBox>(find.byType(ConstrainedBox))
    .where((b) => b.constraints.hasBoundedWidth)
    .map((b) => b.constraints.maxWidth)
    .toList();

void main() {
  testWidgets('the home body sits in the kContentMaxWidth column', (
    tester,
  ) async {
    await _pumpHome(tester, 1200);
    expect(
      _columnWidths(tester),
      contains(kContentMaxWidth),
      reason: 'the home column must be the reading column every screen uses',
    );
  });

  testWidgets('the bespoke 520 column is gone', (tester) async {
    await _pumpHome(tester, 1200);
    expect(
      _columnWidths(tester),
      isNot(contains(520.0)),
      reason: '520 was the width mismatch against the room creation form',
    );
  });

  testWidgets('on a phone the 720 column is a no-op and nothing changes', (
    tester,
  ) async {
    // Below kContentMaxWidth the box lets the viewport through, so the phone
    // layout must be exactly what it was before the column moved.
    await _pumpHome(tester, 420);
    expect(find.text('Ludo'), findsOneWidget);
    expect(find.text('Snakes & Ladders'), findsOneWidget);
    expect(find.text('Play Online'), findsOneWidget);
  });
}
