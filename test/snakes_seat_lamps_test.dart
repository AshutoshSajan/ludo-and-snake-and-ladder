/// The online Snakes seat lamps: one compact chip per seat above the board,
/// carrying the same five-dot strike ledger Ludo's corner lamps use.
///
/// Playtest: Snakes named the seat on turn but never showed the turn-miss
/// count, so "why did that seat disappear" had no visible answer. These tests
/// build the widget directly with an unconnected [OnlineClient], the same
/// construction the turn-HUD tests use.
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:game_club/engine/snakes/snakes_engine.dart';
import 'package:game_club/services/online_client.dart';
import 'package:game_club/ui/shared/strike_dots.dart';
import 'package:game_club/ui/snakes/snakes_seat_lamps.dart';
import 'package:game_club/ui/theme.dart';

void main() {
  late OnlineClient client;

  setUp(() {
    client = OnlineClient('ws://test/ws', seatId: 'me', name: 'Me');
    client.started = true;
  });

  SnakesState stateWith({required String currentPlayerId}) {
    final s = createSnakesState([
      SnakesPlayer(id: 'p1', name: 'Ana', tokenIndex: 0),
      SnakesPlayer(id: 'me', name: 'Me', tokenIndex: 1),
    ]);
    s.currentPlayerIndex = s.players.indexWhere((p) => p.id == currentPlayerId);
    return s;
  }

  Future<void> pumpLamps(WidgetTester tester, SnakesState state) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Center(
            child: SizedBox(
              width: 390,
              child: SnakesSeatLamps(state: state, client: client),
            ),
          ),
        ),
      ),
    );
  }

  testWidgets('one lamp per seat, each with its own strike count', (
    tester,
  ) async {
    client.seatMisses['me'] = 2;
    await pumpLamps(tester, stateWith(currentPlayerId: 'me'));

    expect(
      find.byKey(const ValueKey('snakes-seat-lamp-p1')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('snakes-seat-lamp-me')),
      findsOneWidget,
    );
    expect(
      tester
          .widget<StrikeDotsRow>(
            find.byKey(const ValueKey('snakes-strike-dots-me')),
          )
          .misses,
      2,
    );
    expect(
      tester
          .widget<StrikeDotsRow>(
            find.byKey(const ValueKey('snakes-strike-dots-p1')),
          )
          .misses,
      0,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('the seat on turn wears the gold boundary', (tester) async {
    await pumpLamps(tester, stateWith(currentPlayerId: 'me'));

    Border borderOf(String seat) {
      final lamp = tester.widget<Container>(
        find.byKey(ValueKey('snakes-seat-lamp-$seat')),
      );
      return (lamp.decoration! as BoxDecoration).border! as Border;
    }

    expect(borderOf('me').top.color, AppColors.gold);
    expect(borderOf('me').top.width, 1.6);
    expect(
      borderOf('p1').top.color,
      isNot(AppColors.gold),
      reason: 'only the seat that owns the turn is lit',
    );
  });

  testWidgets('the lamps leave with the turns', (tester) async {
    final state = stateWith(currentPlayerId: 'me');

    client.started = false;
    await pumpLamps(tester, state);
    expect(find.byType(SnakesSeatLamps), findsOneWidget);
    expect(find.byKey(const ValueKey('snakes-seat-lamp-me')), findsNothing);

    client.started = true;
    state.phase = SnakesPhase.gameOver;
    await pumpLamps(tester, state);
    expect(find.byKey(const ValueKey('snakes-seat-lamp-me')), findsNothing);
  });
}
