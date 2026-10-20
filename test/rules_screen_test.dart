/// The rules pages (playtest ask: "add rules page for ludo and snake game in
/// the settings page so users can read that how all the features
/// functionalities, gameplay works").
///
/// The copy is pinned to code-verified mechanics — a six to come out in Ludo,
/// a 1 to enter in Snakes, exact-landing finishes, the thirty-second turn
/// clock and the five-miss removal — so the rule book cannot quietly drift
/// away from what the engines actually do.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:game_club/screens/rules_screen.dart';
import 'package:game_club/screens/settings_screen.dart';
import 'package:game_club/ui/page_app_bar.dart';

Future<void> _pumpRules(WidgetTester tester, {required Size size}) async {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = size;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    const ProviderScope(child: MaterialApp(home: RulesScreen())),
  );
  await tester.pumpAndSettle();
}

Future<void> _pumpSettings(WidgetTester tester) async {
  SharedPreferences.setMockInitialValues({});
  tester.view.devicePixelRatio = 1;
  // Tall on purpose: the pushed rules page is a reading page, and with a
  // phone-sized test surface its lower sections would be scrolled out and
  // unfindable. A tall window keeps the whole document built.
  tester.view.physicalSize = const Size(800, 4000);
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    const ProviderScope(child: MaterialApp(home: SettingsScreen())),
  );
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('the settings screen links out to the rules page', (
    tester,
  ) async {
    await _pumpSettings(tester);

    expect(find.byIcon(Icons.help_outline), findsOneWidget);
    expect(find.text('How to play'), findsOneWidget);
    expect(find.text('Rules for Ludo and Snakes & Ladders'), findsOneWidget);

    await tester.tap(find.text('How to play'));
    await tester.pumpAndSettle();

    // The app bar joins the pushed route; the settings screen stays
    // mounted but offstage behind it.
    expect(find.byType(RulesScreen), findsOneWidget);
    // And the rule book itself is on screen, on the Ludo tab by default.
    expect(find.textContaining('to leave its yard'), findsOneWidget);
  });

  testWidgets('the ludo tab states the engine-verified rules', (tester) async {
    await _pumpRules(tester, size: const Size(800, 4000));

    // A 6 brings a pawn out (ludo_rules.dart: `roll == 6` opens the base).
    expect(find.textContaining('to leave its yard'), findsOneWidget);
    // Town-and-comes-home extras kind of turn (applyMove: extra roll on 6,
    // capture, or home) ...
    expect(find.textContaining('roll again'), findsOneWidget);
    // ... capped by three sixes (rollDice: consecutiveSixes >= 3 forfeits).
    expect(find.textContaining('Three 6s in a row'), findsOneWidget);
    // No captures on the safe cells (applyMove: `!isSafe` guard).
    expect(find.textContaining('never be captured'), findsOneWidget);
    // A 2-token block cannot be passed or landed on (_pathClear).
    expect(find.textContaining('walk past it'), findsOneWidget);
    // Exact home entry: `target > homePos` is not even a legal move.
    expect(
      find.textContaining('must land on home with the precise count'),
      findsOneWidget,
    );
    // The online turn clock (game_server: thirty seconds, misses, removal).
    expect(find.textContaining('thirty seconds'), findsOneWidget);
    expect(find.textContaining('misses in a row'), findsOneWidget);
  });

  testWidgets('the snakes tab states the engine-verified rules', (
    tester,
  ) async {
    await _pumpRules(tester, size: const Size(800, 4000));

    await tester.tap(find.text('Snakes'));
    await tester.pumpAndSettle();

    // A pawn off the board needs a 1 to enter (snakes_engine rollDice).
    expect(find.textContaining('needs a 1 to enter'), findsOneWidget);
    // Jump map: ladders up, snakes down, automatic (kSnakesLaddersJumps).
    expect(find.textContaining('Ladders carry you up'), findsOneWidget);
    expect(find.textContaining('slide you down'), findsOneWidget);
    // Exact landing on 100, overshoot bounces back (pendingMove).
    expect(find.textContaining('bounces'), findsOneWidget);
    // First to 100 ends it; others ranked by square (applyMove).
    expect(
      find.textContaining('ranked by how far up the board'),
      findsOneWidget,
    );
    // The shared online clock copy is there too.
    expect(find.textContaining('thirty seconds'), findsOneWidget);
  });

  testWidgets('switching games swaps the content', (tester) async {
    await _pumpRules(tester, size: const Size(800, 4000));

    expect(find.textContaining('to leave its yard'), findsOneWidget);

    await tester.tap(find.text('Snakes'));
    await tester.pumpAndSettle();

    expect(find.textContaining('to leave its yard'), findsNothing);
    expect(find.textContaining('needs a 1 to enter'), findsOneWidget);

    await tester.tap(find.text('Ludo'));
    await tester.pumpAndSettle();

    expect(find.textContaining('needs a 1 to enter'), findsNothing);
    expect(find.textContaining('to leave its yard'), findsOneWidget);
  });

  testWidgets('a wide window keeps the reading column at kContentMaxWidth', (
    tester,
  ) async {
    // Rule 11 for the new page: at a desktop-sized window the rule book must
    // be a centered reading column, not rows stretched across the screen.
    await _pumpRules(tester, size: const Size(1440, 900));

    // The layout law itself: the column constraint is in the tree.
    final columns = tester
        .widgetList<ConstrainedBox>(
          find.descendant(
            of: find.byType(ContentColumn),
            matching: find.byType(ConstrainedBox),
          ),
        )
        .where((b) => b.constraints.hasBoundedWidth)
        .map((b) => b.constraints.maxWidth)
        .toList();
    expect(columns, contains(kContentMaxWidth));

    // And it holds in practice: a paragraph's width can never pass the
    // reading column even though the window is 1440 wide. The deep clock
    // section is scrolled for, kept inside the built range of the list.
    final target = find.textContaining('thirty seconds');
    await tester.scrollUntilVisible(
      target,
      200,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.pumpAndSettle();
    expect(target, findsOneWidget);
    final box = tester.renderObject<RenderBox>(target);
    expect(box.size.width, lessThanOrEqualTo(kContentMaxWidth));
    expect(
      box.size.width,
      greaterThan(300),
      reason: 'the rules text must still be reading-wide, not collapsed',
    );
  });
}
