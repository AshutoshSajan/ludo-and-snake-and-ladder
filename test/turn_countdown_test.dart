/// The countdown chip the online tables hang beside their subtitle: derives
/// seconds from the client's `turnMs` between broadcasts, turns warning red
/// under ten, and disappears when no clock is running.
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:game_club/services/online_client.dart';
import 'package:game_club/ui/shared/turn_countdown.dart';
import 'package:game_club/ui/theme.dart';

void main() {
  testWidgets('shows the deadline as seconds, and hides with none',
      (tester) async {
    final client = OnlineClient(
      'ws://localhost:8080/ws',
      seatId: 'me',
      name: 'Me',
    );
    addTearDown(client.dispose);

    await tester.pumpWidget(
      MaterialApp(home: Scaffold(body: TurnCountdown(client: client))),
    );
    expect(find.text('30 s'), findsNothing,
        reason: 'no countdown until the server arms one');

    client.turnMs = 30000;
    await tester.pumpWidget(
      MaterialApp(home: Scaffold(body: TurnCountdown(client: client))),
    );
    expect(find.text('30 s'), findsOneWidget);
    // A standalone chip reads as a bare "30" without context, so screen
    // readers get the full sentence instead.
    expect(
      find.bySemanticsLabel('30 seconds left on this turn'),
      findsOneWidget,
    );
  });

  testWidgets('counts down between broadcasts, red when the time is short',
      (tester) async {
    final client = OnlineClient(
      'ws://localhost:8080/ws',
      seatId: 'me',
      name: 'Me',
    );
    addTearDown(client.dispose);

    client.turnMs = 12 * 1000;
    await tester.pumpWidget(
      MaterialApp(home: Scaffold(body: TurnCountdown(client: client))),
    );
    expect(find.text('12 s'), findsOneWidget);

    // One wall-clock second, locally ticked: no new broadcast needed.
    await tester.pump(const Duration(seconds: 3));
    expect(find.text('9 s'), findsOneWidget,
        reason: 'the chip ticks between broadcasts');
    // Under ten the chip is a warning, in the same tone the app reserves
    // for danger — sitting through it costs the turn.
    final text = tester.widget<Text>(find.text('9 s'));
    expect(text.style?.color, AppColors.danger);
  });
}
