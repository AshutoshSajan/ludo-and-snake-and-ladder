/// The podium's width: a plain `Dialog` around flexing rows takes the
/// whole window when the window is wide (Material sizes unbounded dialogs
/// by content), so the win/loss banner ended up edge to edge on web while
/// every other popup capped itself to a card (playtest: "width of the
/// winner and looser popup banner ... should be as per the other game
/// ui"). The dialog now carries a width cap of its own.
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:game_club/ui/shared/victory_dialog.dart';

void main() {
  testWidgets('the podium dialog is a card, not the window', (tester) async {
    // A desktop-ish surface first: the contract only means something when
    // the window is much wider than a popup.
    tester.view.physicalSize = const Size(1400 * 3, 900 * 3);
    tester.view.devicePixelRatio = 3.0;
    addTearDown(tester.view.reset);

    BuildContext? bodyContext;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (ctx) {
              bodyContext = ctx;
              return const Center(
                child: FilledButton(
                  onPressed: null,
                  child: Text('end'),
                ),
              );
            },
          ),
        ),
      ),
    );
    showDialog<void>(
      context: bodyContext!,
      barrierDismissible: false,
      builder: (_) => VictoryDialog(
        title: 'You win Ludo!',
        rankedNames: const ['Bo', 'Ana'],
        onRematch: null,
        onHome: () => Navigator.pop(bodyContext!),
      ),
    );
    // Two beats settle the 400ms dialog entrance — the podium never
    // fully "settles" (the confetti controller repeats) so a timed pump.
    await tester.pump(const Duration(milliseconds: 350));
    await tester.pump(const Duration(milliseconds: 350));

    // An unbounded dialog would flex to the 1400px window; the cap holds
    // instead, and the title still reads.
    final dialog = tester.widget<Dialog>(find.byType(Dialog));
    expect(dialog.constraints?.maxWidth, 460.0,
        reason: 'a popup width, like the app\'s other dialogs');
    expect(find.text('You win Ludo!'), findsOneWidget);
  });
}
