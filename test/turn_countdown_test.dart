/// The turn clock's mechanics: it counts down locally between server
/// broadcasts, re-baselines when the server re-arms the deadline, and
/// disappears entirely when no deadline stands. The plate used to sit
/// beside the subtitle; it lives on the on-turn seat's corner panel now —
/// but the countdown behavior below is the whole widget's job and stays
/// pinned regardless of where a screen hosts it.
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:game_club/services/online_client.dart';
import 'package:game_club/ui/shared/turn_countdown.dart';

void main() {
  testWidgets('the countdown drains one second per second between frames', (
    tester,
  ) async {
    final client = OnlineClient('ws://x/ws', seatId: 'p1', name: 'Ana')
      ..turnMs = 30_000;
    await tester.pumpWidget(
      MaterialApp(home: Scaffold(body: TurnCountdown(client: client))),
    );
    expect(find.text('30 s'), findsOneWidget);

    await tester.pump(const Duration(seconds: 3));
    expect(find.text('27 s'), findsOneWidget,
        reason: 'the local ticker burns real seconds while no broadcast '
            're-baselines the deadline');
  });

  testWidgets('a re-armed deadline re-baselines the burn', (tester) async {
    final client = OnlineClient('ws://x/ws', seatId: 'p1', name: 'Ana');
    await tester.pumpWidget(
      MaterialApp(home: Scaffold(body: TurnCountdown(client: client))),
    );
    // No deadline — the plate is absent entirely.
    expect(find.text('30 s'), findsNothing);

    client.turnMs = 30_000;
    // The client's turnMs changed without a widget rebuild on purpose:
    // drive a parent pass so didUpdateWidget re-remembers the clock.
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: TurnCountdown(
            key: ValueKey(client.turnMs),
            client: client,
          ),
        ),
      ),
    );
    expect(find.text('30 s'), findsOneWidget);

    await tester.pump(const Duration(seconds: 12));
    expect(find.text('18 s'), findsOneWidget);
  });

  testWidgets('the danger tint takes over in the last ten seconds', (
    tester,
  ) async {
    final client = OnlineClient('ws://x/ws', seatId: 'p1', name: 'Ana')
      ..turnMs = 9_000;
    await tester.pumpWidget(
      MaterialApp(home: Scaffold(body: TurnCountdown(client: client))),
    );
    expect(find.text('9 s'), findsOneWidget);
    // Danger state carries a timer glyph, not a plain outline.
    expect(find.byIcon(Icons.timer_sharp), findsOneWidget);
  });
}
