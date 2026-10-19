/// The table notice is a pill, not a banner.
///
/// Every "something happened at the table" line (a spent roll, a missed
/// turn, a seat walking out) shares [showTableNotice]. It floated without a
/// width cap, so the message crossed the whole screen — a full-width slab
/// laid across the board reads like a system failure while a table line is
/// a whisper between turns.
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:game_club/ui/shared/table_notice.dart';

void main() {
  testWidgets('the notice is capped and floating, never full-width', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(600, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Center(
            child: Builder(
              builder: (context) => FilledButton(
                onPressed: () =>
                    showTableNotice(context, 'Bo missed a turn (2 of 5)'),
                child: const Text('notify'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('notify'));
    await tester.pump();
    await tester.pump();

    final box = tester.renderObject<RenderBox>(
      find
          .descendant(
            of: find.byType(SnackBar),
            matching: find.byWidgetPredicate(
              (w) => w is SizedBox && w.width != null && w.width! <= 360,
            ),
          )
          .first,
    );
    expect(box.size.width, lessThanOrEqualTo(360),
        reason: 'the cap keeps the line a whisper-wide pill');
    expect(box.size.width, lessThan(600),
        reason: 'not a banner: the board stays visible around the notice');
  });
}
