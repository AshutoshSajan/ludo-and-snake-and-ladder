/// The seat strip's event-feed contract: it reports what HAPPENED around a
/// seat — a walk-out, a dropped link, a seat switched to autoplay — and
/// nothing else. Misses are deliberately absent: the same playtest round
/// that took the "missed 3 · 2 left" words off the board ("it's not
/// required") pointed at this strip too. The corner strike dots are the
/// one miss surface; a chip row repeating them above the board read as a
/// second clock nobody needed. So a connected, live seat renders no chip
/// at all, however badly it is drifting toward the timer's removal.
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:game_club/engine/ludo/ludo_models.dart';
import 'package:game_club/services/online_client.dart';
import 'package:game_club/ui/shared/seat_status_strip.dart';

void main() {
  LobbySeat seat(
    String id, {
    required int misses,
    bool live = true,
    SeatStatus status = SeatStatus.connected,
  }) => LobbySeat(
        name: id == 'p1' ? 'A' : 'B',
        color: id == 'p1' ? LudoColor.red : LudoColor.green,
        seatId: id,
        misses: misses,
        live: live,
        status: status,
      );

  Widget subject(List<LobbySeat> seats, {String? mySeatId}) => MaterialApp(
        home: Scaffold(
          body: SeatStatusStrip(seats: seats, mySeatId: mySeatId),
        ),
      );

  /// The strip is mounted but must carry nothing readable — the exact
  /// expectation the event-feed contract needs in every quiet case.
  void expectSilence(WidgetTester tester) {
    expect(
      find.descendant(
        of: find.byType(SeatStatusStrip),
        matching: find.byType(Text),
      ),
      findsNothing,
      reason: 'a quiet table renders no chips: the strip speaks only on '
          'events, never on steady state',
    );
  }

  testWidgets(
      'a seat drifting toward removal shows no chip — dots own the miss story',
      (tester) async {
    await tester.pumpWidget(
      subject(
        [
          seat('p1', misses: 3),
          seat('p2', misses: 2),
        ],
        mySeatId: 'p1',
      ),
    );
    expect(find.textContaining('missed'), findsNothing,
        reason: 'the playtest asked the miss line gone: the corner strike '
            'dots are the one miss surface, not a second clock above the '
            'board');
    expectSilence(tester);
  });

  testWidgets('my own drifting seat is silent too — no second-person rule',
      (tester) async {
    await tester.pumpWidget(
      subject([seat('p1', misses: 4), seat('p2', misses: 0)], mySeatId: 'p1'),
    );
    expect(find.textContaining('You'), findsNothing,
        reason: 'the chip used to repeat the eviction rule in second '
            'person; the dots and their tooltips tell that story now');
    expectSilence(tester);
  });

  testWidgets('a dropped link still speaks', (tester) async {
    await tester.pumpWidget(
      subject([
        seat('p1', misses: 0),
        seat('p2', misses: 0, live: false),
      ], mySeatId: 'p1'),
    );
    expect(find.textContaining('connection lost'), findsOneWidget,
        reason: 'an opponent dropping off is the table\'s event to know');
    // My own link chips only when IT drops: second person, patient copy.
    await tester.pumpWidget(
      subject([
        seat('p1', misses: 0, live: false),
        seat('p2', misses: 0),
      ], mySeatId: 'p1'),
    );
    expect(find.text('You · waiting on your connection'), findsOneWidget);
  });

  testWidgets('a walked-out seat still speaks, in second person when mine', (
    tester,
  ) async {
    await tester.pumpWidget(
      subject([
        seat('p1', misses: 0, status: SeatStatus.left),
        seat('p2', misses: 0),
      ], mySeatId: 'p1'),
    );
    expect(find.textContaining('left the game'), findsOneWidget);
  });

  testWidgets('a healthy table shows nothing — the strip is event-fed', (
    tester,
  ) async {
    await tester.pumpWidget(
      subject([seat('p1', misses: 0), seat('p2', misses: 0)], mySeatId: 'p1'),
    );
    expectSilence(tester);
  });
}
