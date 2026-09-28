/// Tests for how a Snakes & Ladders game starts and how fast it plays:
///
/// 1. Home area: every seat starts parked in its own numbered garage in the
///    strip directly under the board. The board itself numbers 1..100, so a
///    pawn at square 0 has no cell of its own and used to be drawn outside the
///    board, where it was clipped and invisible.
/// 2. The animated walk visibly leaves that garage and then enters the board.
/// 3. Autoplay rolls and moves on its own, and stops when switched off — and
///    switching it at any moment still lands the move that is in flight.
/// 4. Pacing: the timing constants shared by the session and the view keep a
///    full move short — walk, slide and dice tumble all overlap.
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:game_club/controllers/ludo_session.dart' show SeatSetup;
import 'package:game_club/controllers/snakes_session.dart';
import 'package:game_club/providers/app_providers.dart';
import 'package:game_club/services/sound_service.dart';
import 'package:game_club/ui/shared/dice_widget.dart';
import 'package:game_club/ui/snakes/snakes_board_painter.dart';
import 'package:game_club/ui/snakes/snakes_view.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Haptics fire real platform channels during a move; swallow them so no
/// MissingPluginException escapes from an unawaited call.
void _mockPlatformChannels() {
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(SystemChannels.platform, (call) async => null);
}

/// Sound stub: real playback would leave platform-channel work pending.
class _SilentSound extends SoundService {
  @override
  Future<void> dice() async {}
  @override
  Future<void> step() async {}
  @override
  Future<void> move() async {}
  @override
  Future<void> snake() async {}
  @override
  Future<void> ladder() async {}
  @override
  Future<void> home() async {}
  @override
  Future<void> win() async {}
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  _mockPlatformChannels();

  Future<void> pumpGame(WidgetTester tester, int seats) async {
    SharedPreferences.setMockInitialValues({});
    await tester.pumpWidget(ProviderScope(
      overrides: [soundServiceProvider.overrideWithValue(_SilentSound())],
      child: MaterialApp(
        home: SnakesGameView(
          seats: [for (var i = 0; i < seats; i++) SeatSetup(name: 'P$i')],
        ),
      ),
    ));
    await tester.pump();
    await tester.pump();
  }

  Finder board() => find.byWidgetPredicate(
      (w) => w is CustomPaint && w.painter is SnakesBoardPainter);
  Finder garage(int seat) => find.byKey(ValueKey('garage-$seat'));
  Finder ghost() => find.byKey(const ValueKey('ghost'));
  double screenHeight(WidgetTester tester) =>
      tester.view.physicalSize.height / tester.view.devicePixelRatio;

  /// The painted garage of [seat]: filled (gradient) while its pawn waits at
  /// home, only an empty ring once the pawn has left.
  BoxDecoration garageDecoration(WidgetTester tester, int seat) => tester
      .widget<Container>(
          find.descendant(of: garage(seat), matching: find.byType(Container)))
      .decoration! as BoxDecoration;

  group('1. home area', () {
    testWidgets('every seat starts parked in its own numbered garage',
        (tester) async {
      await pumpGame(tester, 4);
      expect(find.text('Home — waiting to enter'), findsOneWidget);

      final b = tester.getRect(board());
      for (var i = 0; i < 4; i++) {
        expect(garage(i), findsOneWidget, reason: 'garage of seat ${i + 1}');
        expect(garageDecoration(tester, i).gradient, isNotNull,
            reason: 'seat ${i + 1} still holds its pawn at home');
        final r = tester.getRect(garage(i));
        expect(r.top, greaterThanOrEqualTo(b.bottom - 1),
            reason: 'the strip hangs under the board, not on top of it');
        expect(r.bottom, lessThan(screenHeight(tester)),
            reason: 'garages are never clipped off screen');
      }
    });

    testWidgets('a ten seat game wraps the strip into a second row',
        (tester) async {
      await pumpGame(tester, 10);
      expect(garage(9), findsOneWidget);
      expect(tester.getRect(garage(9)).top,
          greaterThan(tester.getRect(garage(0)).top),
          reason: 'seats past the first row drop below it');
      expect(tester.getRect(garage(9)).bottom, lessThan(screenHeight(tester)));
      expect(tester.getRect(board()).width, greaterThan(0));
    });
  });

  group('2. the walk leaves home', () {
    testWidgets('the pawn starts on its garage and then enters the board',
        (tester) async {
      await pumpGame(tester, 2);
      final b = tester.getRect(board());
      final g0 = tester.getRect(garage(0));
      expect(ghost(), findsNothing, reason: 'nothing animates before a roll');

      await tester.tap(find.widgetWithText(FilledButton, 'ROLL'));
      await tester.pump(); // animation is live, still on its first waypoint
      expect(ghost(), findsOneWidget);
      expect(
        (tester.getRect(ghost()).center - g0.center).distance,
        lessThan(2),
        reason: 'the first hop rests on the home garage, not off-screen',
      );

      await tester.pump(const Duration(milliseconds: 130)); // one hop later
      await tester.pump();
      expect(tester.getRect(ghost()).top, lessThan(b.bottom),
          reason: 'after the first hop the pawn is on the board');

      await tester.pump(const Duration(seconds: 2)); // walk + settle tail done
      await tester.pump();
      expect(ghost(), findsNothing);
      expect(garageDecoration(tester, 0).gradient, isNull,
          reason: 'the garage empties once the pawn has left home');
    });
  });

  group('3. autoplay', () {
    testWidgets('rolls without any tap and stops when switched off',
        (tester) async {
      await pumpGame(tester, 2);
      expect(find.text('Your roll, P0!'), findsOneWidget);

      await tester.tap(find.byIcon(Icons.auto_mode_outlined));
      await tester.pump();
      expect(find.text('P0 rolls automatically…'), findsOneWidget);

      await tester.pump(const Duration(milliseconds: 1150)); // auto beat
      await tester.pump();
      expect(
        tester.widget<DiceWidget>(find.byType(DiceWidget)).value,
        inInclusiveRange(1, 6),
        reason: 'autoplay rolled by itself',
      );

      await tester.tap(find.byIcon(Icons.auto_mode)); // switch back off
      await tester.pump();
      await tester.pump(const Duration(seconds: 4)); // walk ends, turn passes
      await tester.pump();
      expect(find.text('Your roll, P1!'), findsOneWidget,
          reason: 'with autoplay off the next human seat is waited for');
    });

    testWidgets('switching it off mid-move still lands the pawn',
        (tester) async {
      await pumpGame(tester, 2);
      await tester.tap(find.byIcon(Icons.auto_mode_outlined));
      await tester.pump(const Duration(milliseconds: 1150)); // auto beat
      await tester.pump();
      expect(find.text('Moving…'), findsOneWidget);

      await tester.tap(find.byIcon(Icons.auto_mode)); // toggle mid-walk
      await tester.pump();
      await tester.pump(const Duration(seconds: 4));
      await tester.pump();

      expect(find.text('Moving…'), findsNothing);
      expect(find.text('start'), findsOneWidget,
          reason: 'only the seat that never moved is still parked at home');
      expect(find.text('Your roll, P1!'), findsOneWidget);
    });
  });

  group('4. pacing', () {
    SnakesAnim walk(int hops) => SnakesAnim(
        tokenIndex: 0, waypoints: List.generate(hops, (i) => i + 1));

    test('a full walk is quick — one hop every 120 ms', () {
      expect(SnakesAnim.uiStepMs, 120);
      // The old beat was 240 ms per hop with a 900 ms settle tail.
      expect(walk(6).totalMs, lessThan(1000));
      expect(walk(12).totalMs, lessThan(2000));
      expect(walk(6).totalMs, lessThan(6 * 240 + 900));
    });

    test('the dice tumble always settles before the move it opens is over',
        () {
      // The view tumbles for diceRollMs of the same hop clock; the shortest
      // move there is (start + landing) has to outlast it, or the die would
      // still be spinning when the pawn already reached its square.
      expect(SnakesAnim.diceRollMs, lessThan(walk(2).totalMs));
    });
  });
}

