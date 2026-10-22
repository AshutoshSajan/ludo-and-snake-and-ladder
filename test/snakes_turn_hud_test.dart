/// The online Snakes turn HUD: the strip above the board that answers
/// "whose turn" and "how long" on a 390px phone.
///
/// The online table used to put a white70 status line and a small countdown
/// at the very bottom, below the board and the dice: on a phone they were
/// the furthest widgets from the players, and the playtest reported the
/// turn/timer UI as missing. These tests build [SnakesTurnHud] directly, with
/// an unconnected [OnlineClient] (the same construction the corner-clock
/// test uses), so no socket or screen harness is needed.
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:game_club/engine/snakes/snakes_engine.dart';
import 'package:game_club/services/online_client.dart';
import 'package:game_club/ui/shared/turn_countdown.dart';
import 'package:game_club/ui/snakes/snakes_turn_hud.dart';
import 'package:game_club/ui/theme.dart';

void main() {
  late OnlineClient client;

  setUp(() {
    client = OnlineClient('ws://test/ws', seatId: 'me', name: 'Me');
    client.started = true;
  });

  SnakesState stateWith({
    required String currentPlayerId,
    String meName = 'Me',
    String otherName = 'Ana',
  }) {
    final s = createSnakesState([
      SnakesPlayer(id: 'p1', name: otherName, tokenIndex: 0),
      SnakesPlayer(id: 'me', name: meName, tokenIndex: 1),
    ]);
    s.currentPlayerIndex = s.players.indexWhere((p) => p.id == currentPlayerId);
    return s;
  }

  Future<void> pumpHud(
    WidgetTester tester, {
    required SnakesState state,
    required String status,
    Size size = const Size(390, 844),
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Center(
            child: SnakesTurnHud(client: client, state: state, status: status),
          ),
        ),
      ),
    );
    await tester.pump();
  }

  testWidgets('my turn: coloured dot, "Your turn" and the countdown plate', (
    tester,
  ) async {
    client.turnMs = 25000;
    await pumpHud(
      tester,
      state: stateWith(currentPlayerId: 'me'),
      status: 'Your roll!',
    );

    expect(find.text('Your turn'), findsOneWidget);
    expect(find.text('Your roll!'), findsOneWidget);
    expect(find.byType(TurnCountdown), findsOneWidget);
    expect(find.text('25 s'), findsOneWidget);

    final dot = tester.widget<Container>(
      find.byKey(const ValueKey('snakes-turn-dot')),
    );
    final decoration = dot.decoration! as BoxDecoration;
    expect(
      decoration.color,
      AppColors.snakesColors[1],
      reason: 'the dot wears the current player\'s own colour',
    );
    expect(tester.takeException(), isNull);

    // The countdown owns a periodic timer; dispose the tree to cancel it.
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('another seat: waiting line, status and no unarmed clock', (
    tester,
  ) async {
    client.turnMs = null;
    await pumpHud(
      tester,
      state: stateWith(currentPlayerId: 'p1'),
      status: 'Ana is rolling...',
    );

    expect(find.text('Waiting for Ana'), findsOneWidget);
    expect(find.text('Ana is rolling...'), findsOneWidget);
    expect(
      find.byType(TurnCountdown),
      findsNothing,
      reason: 'no server deadline means no plate',
    );
    expect(find.textContaining(' s'), findsNothing);
  });

  testWidgets('a long name stays on one line on a narrow phone', (
    tester,
  ) async {
    client.turnMs = 25000;
    await pumpHud(
      tester,
      state: stateWith(
        currentPlayerId: 'p1',
        otherName: 'Alexandria-Cassandra The Third of Wallachia',
      ),
      status: 'Alexandria-Cassandra The Third of Wallachia is rolling...',
      size: const Size(320, 640),
    );

    expect(tester.takeException(), isNull);
    final hud = tester.getRect(find.byKey(const ValueKey('snakes-turn-hud')));
    expect(hud.width, lessThanOrEqualTo(320));
    expect(find.textContaining('25'), findsOneWidget);

    await tester.pumpWidget(const SizedBox());
  });
}
