import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:game_club/engine/ludo/ludo_models.dart' show LudoColor;
import 'package:game_club/providers/app_providers.dart';
import 'package:game_club/services/online_client.dart';
import 'package:game_club/ui/shared/auto_mode_badge.dart';
import 'package:game_club/ui/shared/seat_status_strip.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// The automatic-mode marker: a spinning loop beside the name, explained on
/// hover, with no "playing for them" text competing for the name's width.
void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  LobbySeat seat(String id, String name, SeatStatus status) => LobbySeat(
        seatId: id,
        name: name,
        color: LudoColor.red,
        status: status,
        live: true,
      );

  /// The real provider loads the preference from storage asynchronously, so a
  /// test that pumps once always sees the default. Overriding is the only way
  /// to assert the off case deterministically.
  Future<void> show(
    WidgetTester tester,
    List<LobbySeat> seats, {
    String? mySeatId,
    bool animations = true,
  }) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          animationsEnabledProvider.overrideWith(() => _FixedAnimations(animations)),
        ],
        child: MaterialApp(
          home: Scaffold(
            body: SeatStatusStrip(seats: seats, mySeatId: mySeatId),
          ),
        ),
      ),
    );
    await tester.pump();
  }

  double rotation(WidgetTester tester) => tester
      .widget<RotationTransition>(
        find.descendant(
          of: find.byType(AutoModeBadge),
          matching: find.byType(RotationTransition),
        ),
      )
      .turns
      .value;

  testWidgets('an auto seat shows the name and a loop, not the old text',
      (tester) async {
    await show(tester, [seat('s1', 'Ana', SeatStatus.auto)]);
    expect(find.text('Ana'), findsOneWidget);
    expect(find.byType(AutoModeBadge), findsOneWidget);
    expect(find.textContaining('playing for them'), findsNothing);
    expect(find.textContaining('playing for you'), findsNothing);
  });

  testWidgets('our own auto seat reads "You", not our name', (tester) async {
    await show(tester, [seat('s1', 'Ana', SeatStatus.auto)], mySeatId: 's1');
    expect(find.text('You'), findsOneWidget);
    expect(find.text('Ana'), findsNothing);
  });

  testWidgets('hovering the loop explains automatic mode', (tester) async {
    await show(tester, [seat('s1', 'Ana', SeatStatus.auto)]);
    // AutoModeBadge is the stateful wrapper; the Tooltip is inside it.
    final tip = tester.widget<Tooltip>(
      find.descendant(
        of: find.byType(AutoModeBadge),
        matching: find.byType(Tooltip),
      ),
    );
    expect(tip.message, contains('automatic mode'));
    expect(tip.message, contains('Ana'));
  });

  testWidgets('the loop is explained to us in the first person', (tester) async {
    await show(tester, [seat('s1', 'Ana', SeatStatus.auto)], mySeatId: 's1');
    // AutoModeBadge is the stateful wrapper; the Tooltip is inside it.
    final tip = tester.widget<Tooltip>(
      find.descendant(
        of: find.byType(AutoModeBadge),
        matching: find.byType(Tooltip),
      ),
    );
    expect(tip.message, contains('You are in automatic mode'));
  });

  testWidgets('a non-auto seat is untouched by the badge', (tester) async {
    await show(tester, [seat('s1', 'Ana', SeatStatus.left)]);
    expect(find.byType(AutoModeBadge), findsNothing);
    expect(find.textContaining('left the game'), findsOneWidget);
  });

  testWidgets('the loop does not spin when animations are off', (tester) async {
    // A permanently rotating glyph is the classic vestibular trigger, and it
    // would otherwise be the one animation ignoring the setting meant to stop
    // exactly that.
    await show(tester, [seat('s1', 'Ana', SeatStatus.auto)],
        animations: false);
    await tester.pump(const Duration(milliseconds: 300));
    expect(rotation(tester), 0.0,
        reason: 'animations are off, so the loop must not be turning');
  });

  testWidgets('the loop spins when animations are on', (tester) async {
    await show(tester, [seat('s1', 'Ana', SeatStatus.auto)]);
    await tester.pump(const Duration(milliseconds: 400));
    expect(rotation(tester), greaterThan(0.0),
        reason: 'a static loop reads as an ordinary status glyph, not motion');
  });

  testWidgets('reduced-motion stops it even with animations on', (tester) async {
    // The platform asking for less motion outranks our own setting.
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          animationsEnabledProvider.overrideWith(() => _FixedAnimations(true)),
        ],
        child: MediaQuery(
          data: const MediaQueryData(disableAnimations: true),
          child: MaterialApp(
            home: Scaffold(
              body: SeatStatusStrip(
                seats: [seat('s1', 'Ana', SeatStatus.auto)],
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 300));
    expect(rotation(tester), 0.0);
  });
}

class _FixedAnimations extends AnimationsToggle {
  _FixedAnimations(this.value);

  final bool value;

  @override
  bool build() => value;
}
