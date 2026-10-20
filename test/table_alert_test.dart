/// The table's one spoken surface: a gold-rimmed pill at the top right.
///
/// The playtest asked for this surface in one sentence: "too many unwanted
/// alert popups now … keep only necessary alert popups make their design
/// good, show them on top right of the screen". The necessary lines all
/// arrive on it now, so the properties the whole feature rests on are
/// pinned here: anchored top-right under the app bar, capped in width,
/// tapped or timed away after five seconds, and spoken one at a time —
/// a new message replaces the one showing, never stacks behind it.
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:game_club/ui/shared/table_alert.dart';

/// The pill's own handle for tests: found by key, not by private type.
const _alert = Key('table-alert');

/// The knock card's handle: the same family slot, invite-shaped.
const _knock = Key('invite-knock');

const _say = Key('say');

const _invite = Key('invite');

/// Pumps a plain app whose one button speaks its [lines] — one line per
/// tap, each tap pumping the deferred insert and the entrance frame — so
/// replacement (the two-line case) happens inside ONE app, the way two
/// table events really arrive.
Future<void> _pumpTable(WidgetTester tester, List<String> lines) async {
  tester.view.physicalSize = const Size(1440, 900);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);

  var next = 0;
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: Center(
          child: Builder(
            builder: (context) => FilledButton(
              key: _say,
              onPressed: () {
                if (next >= lines.length) return;
                showTableAlert(context, lines[next]);
                next++;
              },
              child: const Text('say it'),
            ),
          ),
        ),
      ),
    ),
  );
  for (var i = 0; i < lines.length; i++) {
    await tester.tap(find.byKey(_say));
    // The entry inserts one frame after the call (so mounted context
    // geometry is valid), then builds on the next.
    await tester.pump();
    await tester.pump();
  }
}

/// The answer future of the knock one tap raises, plus the builder
/// context the app handed it, for tests that also speak table lines.
class _KnockHandle {
  BuildContext? context;
  Future<bool?>? answer;
}

/// Pumps a plain app whose one button raises the invite knock card;
/// returns the handle whose [answer] fills the moment the tap happens.
Future<_KnockHandle> _pumpInvite(
  WidgetTester tester, {
  String body = 'Swift Otter invites you to Ludo',
}) async {
  tester.view.physicalSize = const Size(1440, 900);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final handle = _KnockHandle();
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: Center(
          child: Builder(
            builder: (context) {
              handle.context = context;
              return FilledButton(
                key: _invite,
                onPressed: () {
                  handle.answer ??= showInviteKnock(
                    Overlay.of(context, rootOverlay: true),
                    title: 'Play invite',
                    body: body,
                  );
                },
                child: const Text('invite me'),
              );
            },
          ),
        ),
      ),
    ),
  );
  return handle;
}

void main() {
  testWidgets('the alert sits top right: right edge kisses the screen '
      'edge, top above the middle', (tester) async {
    await _pumpTable(tester, ['Ana left the game']);
    // Measure the SETTLED pill: the entrance slides it in through a paint
    // transform, and at t=0 the translate still carries it 28px right of
    // where its layout box lives.
    await tester.pump(const Duration(milliseconds: 250));

    final box = tester.renderObject<RenderBox>(find.byKey(_alert));
    final origin = box.localToGlobal(Offset.zero);
    final rightGap = 1440 - (origin.dx + box.size.width);
    expect(
      rightGap,
      inInclusiveRange(0, 16),
      reason: 'right inset 12 — anchored to the top-right corner',
    );
    expect(
      origin.dy,
      inInclusiveRange(kToolbarHeight + 1, 450),
      reason:
          '64 top inset puts it under the app bar and above the '
          'board\'s midline — not a bottom-anchored snackbar',
    );
  });

  testWidgets('a long message caps the pill at 460 wide', (tester) async {
    await _pumpTable(tester, [
      'go go go ' * 80 + 'the witness line that refuses to stop',
    ]);

    final box = tester.renderObject<RenderBox>(find.byKey(_alert));
    expect(
      box.size.width,
      lessThanOrEqualTo(460),
      reason:
          'the 460 cap keeps it the same family as the removal '
          'dialog and win podium',
    );
  });

  testWidgets('a tap dismisses the alert', (tester) async {
    await _pumpTable(tester, ['Ana left the game']);
    expect(find.byKey(_alert), findsOneWidget);

    await tester.tap(find.byKey(_alert));
    await tester.pump();
    expect(
      find.byKey(_alert),
      findsNothing,
      reason: 'the reader is done with the line the moment they tap it',
    );
  });

  testWidgets('the alert leaves by itself after five seconds', (tester) async {
    await _pumpTable(tester, ['Ana left the game']);

    await tester.pump(const Duration(seconds: 4, milliseconds: 999));
    expect(
      find.byKey(_alert),
      findsOneWidget,
      reason: 'five seconds is the table\'s patience, not four and a bit',
    );

    await tester.pump(const Duration(milliseconds: 200));
    expect(
      find.byKey(_alert),
      findsNothing,
      reason: 'the TTL clears the line without asking anyone',
    );
  });

  testWidgets('a second message replaces the one showing — never two', (
    tester,
  ) async {
    await _pumpTable(tester, [
      'Ana left the game',
      'Bo was removed — five turns missed',
    ]);

    expect(
      find.text('Bo was removed — five turns missed'),
      findsOneWidget,
      reason: 'the newest table event is what the pill says',
    );
    expect(
      find.byKey(_alert),
      findsOneWidget,
      reason:
          'exactly one pill: table messages are spoken one at a time, '
          'never stacked',
    );
    expect(find.text('Ana left the game'), findsNothing);
  });

  group('the invite knock card', () {
    testWidgets('sits top right under the app bar and carries its answers',
        (tester) async {
      final handle = await _pumpInvite(tester);
      await tester.tap(find.byKey(_invite));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 250)); // settled slide

      final box = tester.renderObject<RenderBox>(find.byKey(_knock));
      final origin = box.localToGlobal(Offset.zero);
      final rightGap = 1440 - (origin.dx + box.size.width);
      expect(rightGap, inInclusiveRange(0, 16),
          reason: 'the knock lives at the top-right corner like its family');
      expect(origin.dy, lessThan(450),
          reason: 'under the app bar, above the board midline');
      expect(find.text('Play invite'), findsOneWidget);
      expect(find.textContaining('Swift Otter invites you to Ludo'),
          findsOneWidget);
      expect(find.text('Join game'), findsOneWidget);
      expect(find.text('Not now'), findsOneWidget);
      await tester.tap(find.text('Not now'));
      await handle.answer;
    });

    testWidgets(
        'Join answers true and leaves; Not now answers false, both 44-tall',
        (tester) async {
      final handle = await _pumpInvite(tester);
      await tester.tap(find.byKey(_invite));
      await tester.pump();
      await tester.pump();

      final joinBox = tester.renderObject<RenderBox>(
        find.ancestor(
          of: find.text('Join game'),
          matching: find.byType(FilledButton),
        ),
      );
      expect(joinBox.size.height, greaterThanOrEqualTo(44.0),
          reason: 'the invite answer is a real decision, not a label');

      await tester.tap(find.text('Join game'));
      final joined = await handle.answer;
      await tester.pump();
      expect(joined, isTrue);
      await tester.pump();
      expect(find.byKey(_knock), findsNothing,
          reason: 'answered cards leave the corner');
    });

    testWidgets('a table line yields while the knock is up', (tester) async {
      final handle = await _pumpInvite(tester);
      await tester.tap(find.byKey(_invite));
      await tester.pump();
      await tester.pump();

      showTableAlert(handle.context!, 'Ana left the game');
      await tester.pump();
      await tester.pump();
      expect(find.text('Ana left the game'), findsNothing,
          reason: 'a knock is the table\'s loudest event; five-second '
              'lines wait until it is answered');
      expect(find.byKey(_knock), findsOneWidget,
          reason: 'the unanswered knock stays put');
      await tester.tap(find.text('Not now'));
      await handle.answer;
    });

    testWidgets(
        'a second knock replaces the first without stranding its asker',
        (tester) async {
      final handle = await _pumpInvite(tester, body: 'first knock');
      await tester.tap(find.byKey(_invite));
      await tester.pump();
      await tester.pump();
      final first = handle.answer;

      final secondHandle = await _pumpInvite(tester, body: 'second knock');
      await tester.tap(find.byKey(_invite));
      await tester.pump();
      await tester.pump();
      expect(find.textContaining('second knock'), findsOneWidget);
      await tester.tap(find.text('Join game'));
      final second = await secondHandle.answer;
      await tester.pump();
      expect(second, isTrue);

      expect(await first, isFalse,
          reason: 'a displaced knock answers not-joined, never hangs');
      expect(find.byKey(_knock), findsNothing);
    });
  });

  testWidgets('a long knock body caps at the family width', (tester) async {
    final handle = await _pumpInvite(
      tester,
      body: 'go go go ' * 60 + 'Swift Otter wants you at the table now',
    );
    await tester.tap(find.byKey(_invite));
    await tester.pump();
    await tester.pump();
    final box = tester.renderObject<RenderBox>(find.byKey(_knock));
    expect(box.size.width, lessThanOrEqualTo(460));
    await tester.tap(find.text('Not now'));
    await handle.answer;
  });
}
