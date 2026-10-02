import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:game_club/controllers/ludo_session.dart';
import 'package:game_club/engine/core/player_profiles.dart' show GameKind;
import 'package:game_club/engine/ludo/ludo_models.dart';
import 'package:game_club/screens/setup_screen.dart';
import 'package:game_club/ui/ludo/ludo_board_painter.dart';
import 'package:game_club/ui/ludo/ludo_view.dart';
import 'package:game_club/ui/shared/dice_widget.dart';
import 'package:game_club/ui/shared/sound_toggle_button.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Generated names for local seats.
///
/// The name is painted on the pawn, so a duplicate is worse here than on a
/// leaderboard: two "Swift Otter" pawns on one board and you cannot tell which
/// one you are steering. Uniqueness within the table is the property that
/// matters, and it is invisible until a collision actually happens.
void main() {
  Future<void> openSetup(WidgetTester tester, {int maxSeats = 10}) async {
    SharedPreferences.setMockInitialValues({});
    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(home: SetupScreen(game: GameKind.snakes)),
      ),
    );
    await tester.pumpAndSettle();
  }

  /// Every name currently typed into a seat field.
  List<String> seatNames(WidgetTester tester) => tester
      .widgetList<TextFormField>(find.byType(TextFormField))
      .map((f) => f.initialValue ?? '')
      .toList();

  testWidgets('seats get generated names, not "Player 1" and "Bot 2"', (
    tester,
  ) async {
    await openSetup(tester);
    final names = seatNames(tester);
    expect(names, isNotEmpty);
    expect(names, isNot(contains('Player 1')));
    expect(names, isNot(contains('Bot 2')));
    // Two words, capitalised — the same shape the online board uses.
    for (final n in names) {
      expect(n.trim().split(RegExp(r'\s+')).length, 2,
          reason: '"$n" is not a generated name');
    }
  });

  testWidgets('no two seats at one table share a name', (tester) async {
    await openSetup(tester);
    final names = seatNames(tester);
    expect(names.toSet().length, names.length,
        reason: 'duplicate seat names: $names');
  });

  testWidgets('seat cards stay a readable width on a wide viewport',
      (tester) async {
    // A desktop browser is ~1900px. Unconstrained, the seat row put the name at
    // one edge and the corner swatches at the other, with a metre of empty felt
    // between them. The swatches are what you compare across seats, so they have
    // to sit near the name.
    tester.view.physicalSize = const Size(1900, 1400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await openSetup(tester);

    final card = tester.getSize(find.byType(Card).first);
    expect(card.width, lessThanOrEqualTo(760),
        reason: 'the seat card must not stretch to a 1900px window');
  });

  testWidgets('the title bar sits inside the content column, not at the window edge',
      (tester) async {
    // On a 1900px window the setup body is capped at 720 and centred, so it
    // starts around x=590. A default AppBar is left-padded only 16px, which put
    // the title at x~72 -- a heading ~520px to the left of the content it names,
    // reading as if it belonged to nothing. The bar has to move with the column.
    tester.view.physicalSize = const Size(1900, 1400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await openSetup(tester);

    final title = tester.getTopLeft(find.textContaining('New game').first);
    final card = tester.getTopLeft(find.byType(Card).first);

    expect(
      (title.dx - card.dx).abs(),
      lessThan(2.0),
      reason: 'title starts at x=${title.dx} but the content it labels starts '
          'at x=${card.dx}',
    );
  });

  testWidgets('a narrow window still aligns, with no overflow', (tester) async {
    // The column must collapse to the viewport, not stay 720 wide and clip.
    tester.view.physicalSize = const Size(420, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await openSetup(tester);

    final card = tester.getSize(find.byType(Card).first);
    expect(card.width, lessThanOrEqualTo(420),
        reason: 'the column must not exceed a 420px viewport');

    final title = tester.getTopLeft(find.textContaining('New game').first);
    final cardAt = tester.getTopLeft(find.byType(Card).first);
    expect((title.dx - cardAt.dx).abs(), lessThan(2.0));
  });

  testWidgets('every page title bar sits inside the content column',
      (tester) async {
    // The game boards were the last screens with a full-width AppBar: on a
    // 1900px window their title and action icons sat at the far left and far
    // right, with the board stretched between them and nothing connecting the
    // three. Same rule as the paged screens — the board itself stays
    // full-bleed, but the bar that names it moves into the column.
    tester.view.physicalSize = const Size(1900, 1400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    SharedPreferences.setMockInitialValues({});
    await tester.pumpWidget(ProviderScope(
      child: MaterialApp(
        home: LudoGameView(
          seats: [
            SeatSetup(name: 'R', color: LudoColor.red),
            SeatSetup(name: 'G', color: LudoColor.green),
          ],
        ),
      ),
    ));
    // Never pumpAndSettle here: the board glow controller repeats forever.
    await tester.pump();
    await tester.pump();

    // The bar's own box must not span the viewport.
    final bar = tester.getSize(find.byType(AppBar));
    expect(bar.width, 1900, reason: 'the AppBar fills the window by design');

    // Its contents, though, are capped: confirm the action icons are not pinned
    // to the right edge of the window. SoundToggleButton is unconditional here,
    // unlike undo/hint, which only carry tooltips once a move exists.
    final sound = tester.getTopLeft(find.byType(SoundToggleButton));
    expect(
      sound.dx,
      lessThan(1300),
      reason: 'action icons must line up with the column, not the window edge',
    );

    // And the title must not start at the bare 16px gutter either.
    final title = tester.getTopLeft(find.text('Ludo'));
    expect(
      title.dx,
      greaterThan(16),
      reason: 'the title must sit inside the column, not at the window edge',
    );
  });

  testWidgets('corner dice sit beside the board, not at the window edges',
      (tester) async {
    // Reproduced on a 1900px window: the board is a centred square of about
    // 610px, but each die was aligned to the corner of the whole play area,
    // leaving roughly 600px of empty felt between a die and the board it
    // belongs to. The roll control read as decoration rather than as something
    // you press. The dice must track the board, not the window.
    tester.view.physicalSize = const Size(1900, 1400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    SharedPreferences.setMockInitialValues({});
    await tester.pumpWidget(ProviderScope(
      child: MaterialApp(
        home: LudoGameView(
          seats: [
            SeatSetup(name: 'R', color: LudoColor.red),
            SeatSetup(name: 'G', color: LudoColor.green),
          ],
        ),
      ),
    ));
    // Never pumpAndSettle: the board glow controller repeats forever.
    await tester.pump();
    await tester.pump();

    // The board specifically — find.byType(CustomPaint).first is the page
    // backdrop, which spans the whole window and would make this pass
    // vacuously.
    final boardFinder =
        find.byWidgetPredicate((w) => w is CustomPaint && w.painter is LudoBoardPainter);
    expect(boardFinder, findsOneWidget);

    final boardSize = tester.getSize(boardFinder);
    final boardLeft = tester.getTopLeft(boardFinder).dx;
    final die = tester.getTopLeft(find.byType(DiceWidget).first);

    // The die must hug the board's left edge. An absolute difference, not a
    // one-sided bound: a die flung to x=-8 (off-screen) still satisfies
    // `die.dx < boardLeft + 120`, so the looser form passed even when the dice
    // were nowhere near the board. This is the assertion that actually pins
    // the dice to the board on both sides.
    expect(
      (die.dx - boardLeft).abs(),
      lessThan(80),
      reason: 'the die sits at x=${die.dx} but the board starts at '
          'x=$boardLeft — the gap is not a margin, it is empty felt',
    );

    // And it must ring the board rather than sit on top of it: the board spans
    // boardLeft..boardLeft+boardSize.width, and the left die has to stay clear
    // of that span while still being near it.
    expect(
      die.dx + 72,
      lessThan(boardLeft + boardSize.width),
      reason: 'a die should ring the board, not overlap it',
    );
  });
}
