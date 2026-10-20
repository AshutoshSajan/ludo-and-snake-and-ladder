/// The first-run tutorial: the one-time ask on home, the guided walkthrough
/// (dimmed screen, one spotlight hole per step, Next/Back/Skip/Done) and the
/// "Replay the tutorial" tile on Settings.
///
/// Storage is seeded through [StorageService]'s real keys — the ask must
/// never nag a player who already answered, and the walkthrough must round
/// trip into the same store the Settings replay reads.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:game_club/screens/home_screen.dart';
import 'package:game_club/screens/settings_screen.dart';
import 'package:game_club/services/storage_service.dart';
import 'package:game_club/ui/shared/tutorial_walkthrough.dart';
import 'package:shared_preferences/shared_preferences.dart';

final _screen1440x900 = Rect.fromLTWH(0, 0, 1440, 900);

Finder _dimmer() => find.byWidgetPredicate(
  (w) => w is CustomPaint && w.painter is TutorialSpotlightPainter,
);

/// Step titles scoped to the walkthrough card: the underlying screen keeps
/// showing its own text ("Snakes & Ladders" is a card there too), so an
/// unscaled find.text counts them both.
Finder _cardText(String text) => find.descendant(
  of: find.byKey(const ValueKey('tutorial-card')),
  matching: find.text(text),
);

Rect? _spotlightHole(WidgetTester tester) =>
    (tester.widget<CustomPaint>(_dimmer()).painter as TutorialSpotlightPainter)
        .hole;

Future<void> pumpHome(
  WidgetTester tester, {
  Map<String, Object> storage = const {},
}) async {
  SharedPreferences.setMockInitialValues(storage);
  await tester.pumpWidget(
    const ProviderScope(child: MaterialApp(home: HomeScreen())),
  );
  await tester.pumpAndSettle();
}

/// Home with the tour running. Calls that would settle never stop — the
/// spotlight [Pulse] repeats forever while the walkthrough is mounted, so
/// everything below lands on plain pumps, sized past the pop/push fades and
/// the post-frame spotlight measure.
Future<void> pumpHomeTour(WidgetTester tester) async {
  await pumpHome(tester);
  await tester.tap(find.text('Take the tour'));
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 300));
}

/// One Next press: rebuilds and finishes the post-frame re-measure for the
/// new step before the caller inspects the screen.
Future<void> nextStep(WidgetTester tester) async {
  await tester.tap(find.text('Next'));
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 120));
}

void main() {
  testWidgets('the first visit asks once, and never again', (tester) async {
    await pumpHome(tester);
    expect(find.text('First time here?'), findsOneWidget);
    expect(find.text('Take the tour'), findsOneWidget);
    expect(find.text('Not now'), findsOneWidget);

    // Answering — either way — is what sets the asked flag.
    await tester.tap(find.text('Not now'));
    await tester.pumpAndSettle();
    final sp = await SharedPreferences.getInstance();
    expect(
      sp.getBool(StorageService.kTutorialAskedKey),
      isTrue,
      reason: '"Not now" counts as answered: the ask must never nag twice',
    );

    // A later visit (fresh home, flags in storage) shows nothing.
    await pumpHome(tester, storage: {StorageService.kTutorialAskedKey: true});
    expect(find.text('First time here?'), findsNothing);
  });

  testWidgets('"Not now" answers the ask and starts no walkthrough', (
    tester,
  ) async {
    await pumpHome(tester);
    await tester.tap(find.text('Not now'));
    await tester.pumpAndSettle();

    // The screen is back to its own content only.
    expect(_dimmer(), findsNothing);
    expect(find.text('Skip'), findsNothing);
    expect(find.text('Next'), findsNothing);
  });

  testWidgets('"Take the tour" starts the walkthrough at step one', (
    tester,
  ) async {
    await pumpHome(tester);
    await tester.tap(find.text('Take the tour'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    // The dimmed screen carries the spotlight, and the card matches step 1.
    expect(_dimmer(), findsOneWidget);
    expect(find.text('Next'), findsOneWidget);
    expect(
      _cardText(TutorialWalkthrough.homeSteps.first.title),
      findsOneWidget,
    );

    final back = tester.widget<TextButton>(
      find.widgetWithText(TextButton, 'Back'),
    );
    expect(back.onPressed, isNull, reason: 'Back is disabled on step one');

    // The ask is answered the moment the tour starts.
    final sp = await SharedPreferences.getInstance();
    expect(sp.getBool(StorageService.kTutorialAskedKey), isTrue);
  });

  testWidgets('Next advances, and the last step Done closes and persists', (
    tester,
  ) async {
    await pumpHomeTour(tester);

    await nextStep(tester);
    expect(
      _cardText(TutorialWalkthrough.homeSteps.first.title),
      findsNothing,
      reason: 'the card moved on to step 2',
    );
    expect(_cardText(TutorialWalkthrough.homeSteps[1].title), findsOneWidget);

    // Walk to the end: every middle step offers Next; the final one offers
    // Done and only Done.
    var presses = 1;
    for (var i = 2; i < TutorialWalkthrough.homeSteps.length; i++) {
      await nextStep(tester);
      presses++;
      expect(
        _cardText(TutorialWalkthrough.homeSteps[i].title),
        findsOneWidget,
        reason: 'on step ${i + 1} after $presses presses',
      );
    }
    expect(find.text('Done'), findsOneWidget);
    expect(find.text('Next'), findsNothing);

    await tester.tap(find.text('Done'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(_dimmer(), findsNothing, reason: 'Done popped the walkthrough');
    final sp = await SharedPreferences.getInstance();
    expect(sp.getBool(StorageService.kTutorialDoneKey), isTrue);
    // A completed tour never re-asks either.
    await pumpHome(
      tester,
      storage: {
        StorageService.kTutorialAskedKey: true,
        StorageService.kTutorialDoneKey: true,
      },
    );
    expect(find.text('First time here?'), findsNothing);
  });

  testWidgets('Settings replays the walkthrough without the ask', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({
      StorageService.kTutorialAskedKey: true,
    });
    await tester.pumpWidget(
      const ProviderScope(child: MaterialApp(home: SettingsScreen())),
    );
    await tester.pumpAndSettle();

    expect(
      find.text('First time here?'),
      findsNothing,
      reason: 'the ask lives on home only',
    );
    // The tile sits below the fold at the default test window.
    await tester.scrollUntilVisible(
      find.text('Replay the tutorial'),
      120,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.tap(find.text('Replay the tutorial'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    expect(_dimmer(), findsOneWidget);
    expect(find.text('Skip'), findsOneWidget);
    expect(
      _cardText(TutorialWalkthrough.homeSteps.first.title),
      findsOneWidget,
    );
  });

  testWidgets('the spotlight stays on screen and away from its card', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = _screen1440x900.size;
    addTearDown(tester.view.reset);

    await pumpHomeTour(tester);

    final screenRect = _screen1440x900;
    for (var i = 0; i < TutorialWalkthrough.homeSteps.length; i++) {
      final step = TutorialWalkthrough.homeSteps[i];
      final card = tester.getRect(find.byKey(const ValueKey('tutorial-card')));
      expect(
        screenRect.contains(card.topLeft) &&
            screenRect.contains(card.bottomRight),
        isTrue,
        reason: 'step ${i + 1} keeps its card on screen',
      );

      if (step.key != null) {
        final hole = _spotlightHole(tester)!;
        final target = tester.getRect(find.byKey(step.key!));
        expect(
          hole == target.inflate(6),
          isTrue,
          reason:
              'step ${i + 1} spots ${step.title} '
              '(hole $hole, target $target)',
        );
        expect(
          screenRect.contains(hole.topLeft) &&
              screenRect.contains(hole.bottomRight),
          isTrue,
          reason: 'step ${i + 1} spotlight lies within the 1440x900 window',
        );
        expect(
          card.overlaps(hole),
          isFalse,
          reason: 'step ${i + 1}: the card must not cover its spotlight',
        );
      } else {
        // The finisher points at nothing: full dim, the card is the guest.
        expect(
          _spotlightHole(tester),
          isNull,
          reason: 'the finisher has no hole, only the dim',
        );
      }

      if (i < TutorialWalkthrough.homeSteps.length - 1) {
        await nextStep(tester);
      }
    }
  });
}
