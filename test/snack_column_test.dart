/// The page snack: floating, and never wider than the reading column.
/// A copied room code used to stretch a full-bleed stripe across a wide
/// desktop window while the page it copied stayed inside
/// [kContentMaxWidth] — the toast was the only element ignoring the
/// header's width, and this pins it into the same column.
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

SnackBar? _shown(WidgetTester tester) {
  for (final s in tester.widgetList<SnackBar>(find.byType(SnackBar))) {
    if (s.content is! Text) continue;
    if ((s.content as Text).data == 'PRK7VW copied') return s;
  }
  return null;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('a wide window keeps the toast inside the reading column', (
    tester,
  ) async {
    await _pumpWide(tester, 1200);
    await tester.tap(find.text('Copy code'));
    await tester.pump(const Duration(milliseconds: 400));
    final snack = _shown(tester);
    expect(snack, isNotNull);
    expect(snack!.behavior, SnackBarBehavior.floating);
    // 1200px window: (1200 − 720) / 2 = 240px insets center the toast
    // under the header and body, instead of touching the edges.
    expect(
      (snack.margin as EdgeInsets).horizontal,
      480,
      reason: 'the toast, like the body, is never wider than the header',
    );
  });

  testWidgets('a phone window keeps the familiar narrow margins', (
    tester,
  ) async {
    await _pumpWide(tester, 420);
    await tester.tap(find.text('Copy code'));
    await tester.pump(const Duration(milliseconds: 400));
    final snack = _shown(tester);
    expect(snack, isNotNull);
    // Phone: the computed inset floors at 16px, so the toast reads
    // exactly as a floating bar always did.
    expect((snack!.margin as EdgeInsets).horizontal, 32);
  });
}
