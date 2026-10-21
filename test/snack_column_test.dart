/// The page toast is the table's own card, in the top-right corner.
///
/// The playtest called the old shape out plainly: "room code copy is showing
/// plain white alert at the bottom, i wanted the good popup ui on the top
/// right of the screen — find all such plain white banners". This pins the
/// one surface every page message now uses: gold rim, top-right, no snackbar.
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:game_club/ui/page_app_bar.dart';

Future<void> _pumpWide(WidgetTester tester, double width) async {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = Size(width, 600);
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: Builder(
          builder: (context) => Center(
            child: TextButton(
              onPressed: () => showSnackInColumn(context, 'PRK7VW copied'),
              child: const Text('Copy code'),
            ),
          ),
        ),
      ),
    ),
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('a page message lands in the top-right table card', (
    tester,
  ) async {
    await _pumpWide(tester, 1200);
    await tester.tap(find.text('Copy code'));
    // The overlay insert waits one frame; then the card slides in over
    // 220ms. Settle the slide so the position assertion sees its resting
    // place, not a frame mid-flight.
    await tester.pumpAndSettle();

    final card = find.byKey(const Key('table-alert'));
    expect(card, findsOneWidget);
    expect(find.text('PRK7VW copied'), findsOneWidget);
    expect(find.byType(SnackBar), findsNothing,
        reason: 'the plain bottom banner must not exist any more');

    final rect = tester.getRect(card);
    expect(rect.top, closeTo(64, 1),
        reason: 'under the 56px app bar, with an 8px breath');
    expect(rect.right, closeTo(1188, 1),
        reason: '12px from the right edge — the corner, not a centred bar');
    expect(rect.left, greaterThan(600),
        reason: 'on a wide window the message belongs on the far right');
  });

  testWidgets('a phone keeps the same top-right corner', (tester) async {
    await _pumpWide(tester, 420);
    await tester.tap(find.text('Copy code'));
    await tester.pumpAndSettle();

    final card = find.byKey(const Key('table-alert'));
    expect(card, findsOneWidget);
    expect(find.text('PRK7VW copied'), findsOneWidget);
    final rect = tester.getRect(card);
    expect(rect.right, closeTo(408, 1));
    expect(rect.top, closeTo(64, 1));
    expect(rect.width, lessThanOrEqualTo(460),
        reason: 'the card never grows past its family width');
  });
}
