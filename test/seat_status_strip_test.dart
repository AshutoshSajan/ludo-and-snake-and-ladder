/// The seat strip's turn-timer copy: "how many turns did that seat skip,
/// and how many are left before the table removes them" — both halves on
/// one chip, red from three, with the tooltip carrying the full rule for
/// the seat's own case.
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:game_club/engine/ludo/ludo_models.dart';
import 'package:game_club/services/online_client.dart';
import 'package:game_club/ui/shared/seat_status_strip.dart';
import 'package:game_club/ui/theme.dart';

void main() {
  LobbySeat seat(String id, {required int misses}) => LobbySeat(
        name: id == 'p1' ? 'A' : 'B',
        color: id == 'p1' ? LudoColor.red : LudoColor.green,
        seatId: id,
        misses: misses,
      );

  Widget subject(List<LobbySeat> seats, {String? mySeatId}) =>
      MaterialApp(
        home: Scaffold(
          body: SeatStatusStrip(seats: seats, mySeatId: mySeatId),
        ),
      );

  testWidgets('the chips answer skipped and remaining in one line', (tester) async {
    await tester.pumpWidget(
      subject([seat('p1', misses: 2), seat('p2', misses: 0)], mySeatId: 'p1'),
    );
    final chip = find.textContaining('missed 2');
    expect(chip, findsOneWidget);
    final text = tester.widget<Text>(chip).data!;
    expect(
      text,
      contains('3 left'),
      reason: 'the removal budget is the other half of the question — a '
          'count of skipped turns alone leaves "am I close to the drop?" '
          'unknowable',
    );
  });

  testWidgets('the note turns warning red from the third miss', (tester) async {
    await tester.pumpWidget(
      subject([seat('p1', misses: 3), seat('p2', misses: 0)], mySeatId: 'p1'),
    );
    expect(
      find.textContaining('missed 3'),
      findsOneWidget,
    );
    final chip = find.textContaining('missed 3');
    expect(
      tester.widget<Text>(chip).style?.color,
      AppColors.danger,
      reason: 'two quiet turns from the drop is a state, not a statement — '
          'red is the seat staring at it',
    );
  });

  testWidgets('my own chip speaks in second person with the full rule', (
    tester,
  ) async {
    await tester.pumpWidget(
      subject([seat('p1', misses: 2), seat('p2', misses: 0)], mySeatId: 'p1'),
    );
    expect(find.textContaining('You · missed 2'), findsOneWidget);
    final tooltips = tester
        .widgetList<Tooltip>(find.byType(Tooltip))
        .map((t) => t.message)
        .toList();
    expect(
      tooltips.where((m) => m!.contains('You have missed')),
      hasLength(1),
    );
    expect(
      tooltips.singleWhere((m) => m!.contains('You have missed'))!
          .contains('before the table removes you'),
      isTrue,
      reason: 'the eviction rule rides the tooltip, the chip stays short',
    );
  });

  testWidgets('a healthy table shows nothing — the strip is event-fed', (
    tester,
  ) async {
    await tester.pumpWidget(
      subject([seat('p1', misses: 0), seat('p2', misses: 0)], mySeatId: 'p1'),
    );
    // The strip widget is mounted but renders an empty box; what must not
    // exist is anything readable.
    expect(
      find.descendant(of: find.byType(SeatStatusStrip), matching: find.byType(Text)),
      findsNothing,
      reason: 'the strip must not turn into a permanent roster nobody '
          'reads; a clean table has nothing to report',
    );
  });
}
