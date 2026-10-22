/// The Settings surface: a club-coloured hero, three live toggles, the
/// Friends/support and Learn rows, and the quiet about card.
///
/// These tests own the page's own shape — the rules and tutorial suites own
/// their destinations. Everything is pumped at a 390px phone width because
/// that is where the cards have the least room; the wide-window case asserts
/// the shared reading column instead of stretching the rows.
library;

import 'dart:ui' show Tristate;

import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:game_club/screens/rules_screen.dart';
import 'package:game_club/screens/settings_screen.dart';
import 'package:game_club/ui/page_app_bar.dart';

const _phone = Size(390, 844);

Future<void> _pumpSettings(WidgetTester tester, {Size size = _phone}) async {
  // No plugin channels and no HTTP: the toggles only read local prefs, and
  // every destination reached by these tests is either a local sheet or a
  // route with no network in its build.
  SharedPreferences.setMockInitialValues({});
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = size;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    const ProviderScope(child: MaterialApp(home: SettingsScreen())),
  );
  await tester.pumpAndSettle();
}

Finder _row(String name) => find.byKey(ValueKey('settings-row-$name'));

Future<void> _scrollTo(WidgetTester tester, Finder target) async {
  await tester.scrollUntilVisible(
    target,
    160,
    scrollable: find.byType(Scrollable).first,
  );
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('a 390px phone shows the whole club surface without overflow', (
    tester,
  ) async {
    await _pumpSettings(tester);

    // The hero is the page's own title, above the fold.
    expect(find.text('Game Club'), findsOneWidget);
    expect(find.text('LOCAL TABLE SETTINGS'), findsOneWidget);
    expect(find.text('TABLE FEEL'), findsOneWidget);

    // All three preferences keep their names and their switches.
    for (final title in ['Sound effects', 'Haptics', 'Board animations']) {
      expect(find.text(title), findsOneWidget);
    }
    expect(find.byType(Switch), findsNWidgets(3));

    // Walk the page in reading order: every group caption and every
    // destination is present, big enough to tap, and the list never
    // overflows on the way. A lazy list disposes what has scrolled away, so
    // each caption is checked as its group arrives.
    Future<void> expectRow(String name) async {
      final row = _row(name);
      await _scrollTo(tester, row);
      expect(row, findsOneWidget, reason: 'the $name row is on the page');
      expect(
        row.hitTestable(),
        findsOneWidget,
        reason: 'the whole $name row is a tap target',
      );
      expect(
        tester.getSize(row).height,
        greaterThanOrEqualTo(44),
        reason: 'the $name row keeps a comfortable touch target',
      );
      expect(tester.takeException(), isNull);
    }

    await expectRow('sound');
    await expectRow('haptics');
    await expectRow('animations');

    await _scrollTo(tester, find.text('FRIENDS & SUPPORT'));
    expect(find.text('FRIENDS & SUPPORT'), findsOneWidget);
    await expectRow('friends');
    await expectRow('report');
    await expectRow('contact');

    await _scrollTo(tester, find.text('LEARN'));
    expect(find.text('LEARN'), findsOneWidget);
    await expectRow('tutorial');
    await expectRow('rules');

    await _scrollTo(tester, find.text('ABOUT'));
    expect(find.text('ABOUT'), findsOneWidget);
    await _scrollTo(tester, find.text('About the club'));
    expect(find.text('About the club'), findsOneWidget);
    await _scrollTo(tester, find.textContaining('Tip:'));
    expect(find.textContaining('Tip:'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('each toggle flips from its row and from its switch, once', (
    tester,
  ) async {
    await _pumpSettings(tester);

    for (final (name, title) in [
      ('sound', 'Sound effects'),
      ('haptics', 'Haptics'),
      ('animations', 'Board animations'),
    ]) {
      final switchFinder = find.byKey(ValueKey('settings-switch-$name'));
      expect(
        tester.widget<Switch>(switchFinder).value,
        isTrue,
        reason: '$name starts on',
      );

      // The row is the target: tapping the title flips it.
      await tester.tap(find.text(title));
      await tester.pumpAndSettle();
      expect(
        tester.widget<Switch>(switchFinder).value,
        isFalse,
        reason: 'tapping the $name row turns it off',
      );

      // Tapping the painted switch must flip it exactly once: its pointer is
      // off, so the press falls through to the row and no second handler
      // underneath can fire.
      await tester.tap(switchFinder, warnIfMissed: false);
      await tester.pumpAndSettle();
      expect(
        tester.widget<Switch>(switchFinder).value,
        isTrue,
        reason: 'the $name switch toggles once, never twice',
      );

      await tester.tap(find.text(title));
      await tester.pumpAndSettle();
      expect(
        tester.widget<Switch>(switchFinder).value,
        isFalse,
        reason: '$name stays tied to its provider after both tap paths',
      );
    }
  });

  testWidgets('rows keep their labels and toggle state in semantics', (
    tester,
  ) async {
    final handle = tester.ensureSemantics();
    await _pumpSettings(tester);

    final toggle = tester.getSemantics(_row('sound'));
    expect(toggle.label, contains('Sound effects'));
    expect(toggle.label, contains('Dice, hops, captures and fanfares'));
    expect(toggle.flagsCollection.isToggled, Tristate.isTrue);
    expect(
      toggle.getSemanticsData().hasAction(SemanticsAction.tap),
      isTrue,
      reason: 'the whole row remains one tappable semantics node',
    );

    await _scrollTo(tester, _row('rules'));
    final link = tester.getSemantics(_row('rules'));
    expect(link.label, contains('How to play'));
    expect(link.label, contains('Rules for Ludo and Snakes & Ladders'));
    expect(link.flagsCollection.isButton, isTrue);
    expect(link.getSemanticsData().hasAction(SemanticsAction.tap), isTrue);

    handle.dispose();
  });

  testWidgets('Report an issue still opens the sheet', (tester) async {
    await _pumpSettings(tester);
    await _scrollTo(tester, _row('report'));

    await tester.tap(_row('report'));
    await tester.pumpAndSettle();

    expect(find.text('What happened? *'), findsOneWidget);
    expect(find.text('Send'), findsOneWidget);
  });

  testWidgets('How to play still pushes the rule book', (tester) async {
    await _pumpSettings(tester);
    await _scrollTo(tester, _row('rules'));

    await tester.tap(_row('rules'));
    await tester.pumpAndSettle();

    expect(find.byType(RulesScreen), findsOneWidget);
    expect(find.text('Ludo'), findsOneWidget);
  });

  testWidgets('a wide window keeps the rows in the reading column', (
    tester,
  ) async {
    await _pumpSettings(tester, size: const Size(1440, 900));

    final widths = tester
        .widgetList<ConstrainedBox>(
          find.descendant(
            of: find.byType(ContentColumn),
            matching: find.byType(ConstrainedBox),
          ),
        )
        .where((b) => b.constraints.hasBoundedWidth)
        .map((b) => b.constraints.maxWidth);
    expect(widths, contains(kContentMaxWidth));

    // Not only declared: the list itself is the centred 720px column.
    final list = tester.getRect(find.byType(ListView));
    expect(list.width, kContentMaxWidth);
    expect(list.left, (1440 - kContentMaxWidth) / 2);
    expect(tester.takeException(), isNull);
  });
}
