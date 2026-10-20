import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:game_club/engine/ludo/ludo_models.dart';
import 'package:game_club/services/online_client.dart';
import 'package:game_club/ui/ludo/ludo_corner_panel.dart';
import 'package:game_club/ui/shared/turn_countdown.dart';

/// The corner's turn clock must survive its slab.
///
/// The playtest round caught the plate starving inside the board's panel
/// rows: the 46px slabs spent 14px on the dice gap and the panel spent its
/// chrome (padding + border) on top, leaving the [TurnCountdown] less than
/// five pixels of height — the count text clipped to two mid-glyph
/// slashes ("the timer is not visible at all") and the half-size watch
/// icon painted past the plate's rim ("watch icon is also off").
///
/// This builds the same slab column the Ludo view does — fixed 46-slab,
/// 14px dice gap, Expanded board between — and asserts the plate comes out
/// at its true height with the icon and the text un-squashed.
void main() {
  testWidgets('the corner clock plate keeps its height in the slab row', (
    tester,
  ) async {
    final client = OnlineClient(
      'wss://probe.invalid/ws',
      seatId: 'probe-seat',
      name: 'Probe',
    );
    client.turnMs = 28000;

    await tester.pumpWidget(
      Directionality(
        textDirection: TextDirection.ltr,
        child: SizedBox(
          width: 1000,
          height: 640, // a phone-landscape play area
          child: Column(
            children: [
              SizedBox(
                height: ludoPanelSlab,
                width: 528, // boardSide = min(1000, 640 - 2 * ludoPanelSlab)
                child: Padding(
                  padding: const EdgeInsets.only(bottom: 14),
                  child: Row(
                    children: cornerPanels(
                      top: true,
                      seats: [
                        (
                          color: LudoColor.green,
                          misses: 0,
                          onTurn: false,
                          clock: null,
                        ),
                        (
                          color: LudoColor.yellow,
                          misses: 0,
                          onTurn: true,
                          clock: TurnCountdown(
                            key: const Key('clock-top'),
                            client: client,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
              const Expanded(child: SizedBox(width: 548)),
              SizedBox(
                height: ludoPanelSlab,
                width: 528,
                child: Padding(
                  padding: const EdgeInsets.only(top: 14),
                  child: Row(
                    children: cornerPanels(
                      top: false,
                      seats: [
                        (
                          color: LudoColor.red,
                          misses: 0,
                          onTurn: true,
                          clock: TurnCountdown(
                            key: const Key('clock-red'),
                            client: client,
                          ),
                        ),
                        (
                          color: LudoColor.blue,
                          misses: 0,
                          onTurn: false,
                          clock: null,
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    // The plate at its natural height: border + padding + a 16px row of
    // icon and text. Anything under ~24 means the glyph row is squashed.
    final plate = tester.getSize(find.byKey(const Key('clock-red')));
    expect(plate.height, greaterThanOrEqualTo(24),
        reason: 'the clock plate is height-starved in the slab row');

    // The watch icon holds its full 16px box — a squashed icon still paints
    // at full glyph size, ending up half outside the plate's rim.
    final icon = find.descendant(
      of: find.byKey(const Key('clock-red')),
      matching: find.byIcon(Icons.timer_outlined),
    );
    expect(tester.getSize(icon).height, 16.0,
        reason: 'the watch glyph must sit unsquashed inside its plate');

    // The count text keeps its full line height — clipped to a slash it is
    // unreadable.
    final text = find.descendant(
      of: find.byKey(const Key('clock-red')),
      matching: find.byType(Text),
    );
    expect(tester.getSize(text).height, lessThanOrEqualTo(plate.height),
        reason: 'the count must fit inside the plate');
    expect(tester.getSize(text).height, greaterThanOrEqualTo(14.0),
        reason: 'the count line must keep its full size');
  });
}
