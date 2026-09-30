/// Tests for how a Snakes & Ladders game starts and how fast it plays:
///
/// 1. Home area: every seat starts in ONE shared home area — a single panel
///    under the board marked with one house, holding a colour chip per pawn
///    that has not entered yet — not a separate "home" per player. The board
///    itself numbers 1..100, so a pawn at square 0 has no cell of its own and
///    used to be drawn outside the board, where it was clipped and invisible.
/// 2. The animated walk visibly leaves that area and then enters the board.
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
import 'package:game_club/ui/theme.dart';
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
    await tester.pumpWidget(
      ProviderScope(
        overrides: [soundServiceProvider.overrideWithValue(_SilentSound())],
        child: MaterialApp(
          home: SnakesGameView(
            seats: [for (var i = 0; i < seats; i++) SeatSetup(name: 'P$i')],
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.pump();
  }

  Finder board() => find.byWidgetPredicate(
    (w) => w is CustomPaint && w.painter is SnakesBoardPainter,
  );
  Finder homeArea() => find.byKey(const ValueKey('home-area'));
  Finder homePawn(int seat) => find.byKey(ValueKey('home-pawn-$seat'));
  Finder ghost() => find.byKey(const ValueKey('ghost'));
  double screenHeight(WidgetTester tester) =>
      tester.view.physicalSize.height / tester.view.devicePixelRatio;

  /// Colour of [seat]'s chip while its pawn waits at home.
  Color chipColor(WidgetTester tester, int seat) {
    final box =
        tester
                .widget<Container>(
                  find.descendant(
                    of: homePawn(seat),
                    matching: find.byType(Container),
                  ),
                )
                .decoration!
            as BoxDecoration;
    return (box.gradient! as RadialGradient).colors.last;
  }

  group('1. home area', () {
    testWidgets('all seats share ONE home area, each as a colour chip', (
      tester,
    ) async {
      await pumpGame(tester, 4);
      final b = tester.getRect(board());
      final area = tester.getRect(homeArea());

      // One area for the table — not a separate home per player.
      expect(homeArea(), findsOneWidget);
      expect(
        find.byKey(const ValueKey('garage-0')),
        findsNothing,
        reason: 'the per-seat garages are gone',
      );
      expect(
        find.descendant(
          of: homeArea(),
          matching: find.byIcon(Icons.home_rounded),
        ),
        findsOneWidget,
        reason: 'exactly one house marks the area',
      );
      expect(find.text('Home'), findsOneWidget);
      expect(find.text('4 of 4 waiting to enter'), findsOneWidget);

      // It hangs directly under the board and never leaves the screen.
      expect(
        area.top,
        greaterThanOrEqualTo(b.bottom - 1),
        reason: 'the area sits under the board, not on top of it',
      );
      expect(
        area.bottom,
        lessThan(screenHeight(tester)),
        reason: 'the area is never clipped off screen',
      );
      expect(area.width, closeTo(b.width, 0.5));

      // Every seat's pawn waits in that one area, in the seat's own colour.
      for (var i = 0; i < 4; i++) {
        expect(homePawn(i), findsOneWidget, reason: 'pawn of seat ${i + 1}');
        expect(chipColor(tester, i), AppColors.snakesColors[i]);
        final r = tester.getRect(homePawn(i));
        expect(
          area.contains(r.topLeft),
          isTrue,
          reason: 'chip ${i + 1} is inside the one home area',
        );
        expect(
          area.contains(r.bottomRight - const Offset(0.01, 0.01)),
          isTrue,
          reason: 'chip ${i + 1} is inside the one home area',
        );
      }
    });

    testWidgets('ten seats still share the one home area, in a single row', (
      tester,
    ) async {
      await pumpGame(tester, 10);
      expect(homeArea(), findsOneWidget);
      final b = tester.getRect(board());
      final tops = <double>{};
      for (var i = 0; i < 10; i++) {
        expect(homePawn(i), findsOneWidget, reason: 'pawn of seat ${i + 1}');
        final r = tester.getRect(homePawn(i));
        tops.add(r.top);
        expect(r.left, greaterThanOrEqualTo(b.left - 0.5));
        expect(r.right, lessThanOrEqualTo(b.right + 0.5));
        expect(r.bottom, lessThan(screenHeight(tester)));
      }
      expect(tops.length, 1, reason: 'ten seats never grow a second area/row');
      expect(find.text('10 of 10 waiting to enter'), findsOneWidget);
    });
  });

  group('2. the walk leaves home', () {
    testWidgets('the pawn starts on its chip and then enters the board', (
      tester,
    ) async {
      await pumpGame(tester, 2);
      final b = tester.getRect(board());
      final chip0 = tester.getRect(homePawn(0));
      expect(chipColor(tester, 0), AppColors.snakesColors[0]);
      expect(ghost(), findsNothing, reason: 'nothing animates before a roll');

      await tester.tap(find.widgetWithText(FilledButton, 'ROLL'));
      await tester.pump(); // animation is live, still on its first waypoint
      expect(ghost(), findsOneWidget);
      expect(
        (tester.getRect(ghost()).center - chip0.center).distance,
        lessThan(2),
        reason: 'the first hop rests on the chip it left, not off-screen',
      );
      expect(
        homePawn(0),
        findsNothing,
        reason: 'the moving pawn is drawn by the ghost, not twice',
      );

      await tester.pump(const Duration(milliseconds: 130)); // one hop later
      await tester.pump();
      expect(
        tester.getRect(ghost()).top,
        lessThan(b.bottom),
        reason: 'after the first hop the pawn is on the board',
      );

      await tester.pump(const Duration(seconds: 2)); // walk + settle tail done
      await tester.pump();
      expect(ghost(), findsNothing);
      expect(
        homePawn(0),
        findsNothing,
        reason: 'the pawn is gone from home once it has entered',
      );
      expect(find.text('1 of 2 waiting to enter'), findsOneWidget);
    });
  });

  group('3. autoplay', () {
    testWidgets('rolls without any tap and stops when switched off', (
      tester,
    ) async {
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
      expect(
        find.text('Your roll, P1!'),
        findsOneWidget,
        reason: 'with autoplay off the next human seat is waited for',
      );
    });

    testWidgets('switching it off mid-move still lands the pawn', (
      tester,
    ) async {
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
      // Asserted on the home pawn itself, not on the 'start' label in the
      // player strip: that strip is gone, and the pawn is the thing this test
      // actually means — one seat never left home.
      expect(find.byKey(const ValueKey('home-area')), findsOneWidget);
      expect(
        find.byKey(const ValueKey('home-pawn-1')),
        findsOneWidget,
        reason: 'only the seat that never moved is still parked at home',
      );
      expect(find.byKey(const ValueKey('home-pawn-0')), findsNothing);
      expect(find.text('Your roll, P1!'), findsOneWidget);
    });
  });

  group('4. pacing', () {
    SnakesAnim walk(int hops) =>
        SnakesAnim(tokenIndex: 0, waypoints: List.generate(hops, (i) => i + 1));

    test('a full walk is quick — one hop every 120 ms', () {
      expect(SnakesAnim.uiStepMs, 120);
      // The old beat was 240 ms per hop with a 900 ms settle tail.
      expect(walk(6).totalMs, lessThan(1000));
      expect(walk(12).totalMs, lessThan(2000));
      expect(walk(6).totalMs, lessThan(6 * 240 + 900));
    });

    test('the dice tumble always settles before the move it opens is over', () {
      // The view tumbles for diceRollMs of the same hop clock; the shortest
      // move there is (start + landing) has to outlast it, or the die would
      // still be spinning when the pawn already reached its square.
      expect(SnakesAnim.diceRollMs, lessThan(walk(2).totalMs));
    });
  });
}
