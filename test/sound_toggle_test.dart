import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:game_club/controllers/ludo_session.dart' show SeatSetup;
import 'package:game_club/providers/app_providers.dart';
import 'package:game_club/ui/shared/pulse.dart';
import 'package:game_club/ui/shared/sound_toggle_button.dart';
import 'package:game_club/ui/snakes/snakes_view.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// The board-level mute control. Sound used to be reachable only from Settings,
/// which is a menu away from the board — so muting it meant leaving the game
/// mid-roll, and the one moment you want to mute is a loud roll.
void main() {
  Finder button() => find.byType(SoundToggleButton);

  testWidgets('reflects the shared preference and flips it when tapped', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    late WidgetRef captured;
    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          home: Consumer(
            builder: (context, ref, _) {
              captured = ref;
              return const Scaffold(body: SoundToggleButton());
            },
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    // Starts from the same source of truth Settings writes, not a local flag.
    expect(captured.read(soundEnabledProvider), isTrue);
    expect(find.byIcon(Icons.volume_up), findsOneWidget);

    await tester.tap(button());
    await tester.pumpAndSettle();

    expect(
      captured.read(soundEnabledProvider),
      isFalse,
      reason: 'the board button must write the same provider Settings uses',
    );
    expect(find.byIcon(Icons.volume_off), findsOneWidget);

    // And back again.
    await tester.tap(button());
    await tester.pumpAndSettle();
    expect(captured.read(soundEnabledProvider), isTrue);
    expect(find.byIcon(Icons.volume_up), findsOneWidget);
  });

  testWidgets('is on the snakes board, not only in Settings', (tester) async {
    SharedPreferences.setMockInitialValues({});
    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          home: SnakesGameView(
            seats: [
              SeatSetup(name: 'P0'),
              SeatSetup(name: 'P1'),
            ],
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.pump();
    expect(button(), findsOneWidget);
  });

  testWidgets('autoplay sits in the top bar beside sound and pause', (
    tester,
  ) async {
    // Autoplay used to live in the row under the board, packed in with the
    // die and ROLL. That row is what overflows on a narrow layout, so the
    // control was pushed off-screen and read as "autoplay is missing" — the
    // top bar has room, and matches where Ludo already keeps it.
    SharedPreferences.setMockInitialValues({});
    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          home: SnakesGameView(
            seats: [
              SeatSetup(name: 'P0'),
              SeatSetup(name: 'P1'),
            ],
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.pump();

    // All three controls are in the app bar, in that order, and in that order
    // only — one autoplay control, not one up top and one down below.
    final appBar = find.byType(AppBar);
    expect(
      find.descendant(of: appBar, matching: find.byType(SoundToggleButton)),
      findsOneWidget,
      reason: 'sound belongs in the top bar',
    );
    final auto = find.descendant(
      of: appBar,
      matching: find.byIcon(Icons.auto_mode_outlined),
    );
    expect(auto, findsOneWidget, reason: 'autoplay belongs in the top bar');
    expect(
      find.descendant(of: appBar, matching: find.byIcon(Icons.pause)),
      findsOneWidget,
      reason: 'pause stays in the top bar',
    );
    // Nowhere else: the old bottom-row control must be gone, not duplicated.
    expect(
      find.byIcon(Icons.auto_mode_outlined),
      findsOneWidget,
      reason: 'exactly one autoplay control, not two',
    );

    // And it still works from up there.
    await tester.tap(auto);
    await tester.pump();
    await tester.pump();
    expect(find.byIcon(Icons.auto_mode), findsOneWidget);
  });

  testWidgets('the on-turn pawn pulses and the player chips are gone', (
    tester,
  ) async {
    // Whose turn it is used to be shown by a row of player chips above the
    // board, duplicating what the pawns already show. Removed: the piece on
    // turn now pulses instead, so the signal sits where the eye already is.
    SharedPreferences.setMockInitialValues({});
    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          home: SnakesGameView(
            seats: [
              SeatSetup(name: 'P0'),
              SeatSetup(name: 'P1'),
            ],
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.pump();

    // No player chips: no names, no person/toy icons, no square readouts.
    expect(find.text('P0'), findsNothing);
    expect(find.text('P1'), findsNothing);
    expect(find.byIcon(Icons.person), findsNothing);
    expect(find.byIcon(Icons.smart_toy), findsNothing);

    // Seat 0 is on turn at the start, so exactly one pawn breathes.
    final pulsing = find.byWidgetPredicate((w) => w is Pulse && w.active);
    expect(
      pulsing,
      findsOneWidget,
      reason: 'only the seat on turn should pulse',
    );

    // And it actually animates. Read the scale on the *active* pulse's own
    // ScaleTransition: a transform changes what is painted, not what is
    // laid out, so measuring the pawn's box would never move.
    final active = find.byWidgetPredicate((w) => w is Pulse && w.active);
    double breathe() => tester
        .widget<ScaleTransition>(
          find.descendant(of: active, matching: find.byType(ScaleTransition)),
        )
        .scale
        .value;
    final atRest = breathe();
    await tester.pump(const Duration(milliseconds: 430));
    final midBreath = breathe();
    expect(
      midBreath,
      isNot(closeTo(atRest, 0.001)),
      reason: 'the on-turn pawn must visibly pulse',
    );
    expect(midBreath, greaterThan(1.0), reason: 'and grow, not shrink');
  });
}
