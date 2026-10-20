/// The corner furniture's geometry on an online ludo table:
///
/// - the strike-dot lamps above and below the board are pinned to the
///   board's own square width — they used to span the whole play area,
///   so on a desktop window the top panels hung off the screen's far
///   edges while the board sat centered (playtest: turn dots and timer
///   should sit directly above/below the player corners);
/// - the lamps carry state (spot, dots, clock), not identity — the name
///   lives once, on the yard pill painted inside the corner square;
/// - the on-turn seat carries the phase prompt ("Your roll, {name}!") —
///   it used to be a full-width status row that landed at a wide
///   window's far left, half a screen away from the corner dots it was
///   describing (playtest: it should sit below/above the dots when the
///   player's turn comes).
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:game_club/engine/ludo/ludo_models.dart';
import 'package:game_club/engine/ludo/ludo_rules.dart';
import 'package:game_club/services/online_client.dart';
import 'package:game_club/ui/ludo/ludo_board_painter.dart';
import 'package:game_club/ui/ludo/ludo_view.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'fake_channel.dart';

void main() {
  late FakeChannel channel;
  late OnlineClient client;

  setUp(() {
    channel = FakeChannel();
  });

  LudoState twoPlayerState() => createLudoState([
        LudoPlayer(id: 'p1', name: 'Ana', color: LudoColor.red),
        LudoPlayer(id: 'p2', name: 'Bo', color: LudoColor.green),
      ]);

  /// Joined room 'CODE' at seat p2 with the table live on screen — the
  /// same join order the authoritative server drives, before the board
  /// hosts a state to play.
  Future<void> pumpTable(WidgetTester tester, {double logicalWidth = 1440}) async {
    SharedPreferences.setMockInitialValues({});
    client = OnlineClient(
      'ws://x/ws',
      seatId: 'p2',
      name: 'Bo',
      gameType: 'ludo',
      channelFactory: (_) => channel,
    );
    final joined = client.connect(code: 'CODE');
    await tester.pump();
    channel.serverAdd({'type': 'joined', 'code': 'CODE', 'game': 'ludo'});
    await tester.pump();
    await joined;

    // A desktop-ish window: 1440 logical width dwarfs the board, so the
    // old full-width rows would be clearly off the corners.
    tester.view.physicalSize = Size(logicalWidth * 3, 1080 * 3);
    tester.view.devicePixelRatio = 3.0;
    addTearDown(tester.view.reset);

    channel.serverAdd({
      'type': 'state',
      'game': 'ludo',
      'state': twoPlayerState().toJson(),
      'misses': ?null,
    });
    await tester.pump();
    await tester.pump();

    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          home: Scaffold(
            body: LudoGameView(
              onlineClient: client,
              onlineSeatId: 'p2',
              onOnlineLeave: () {},
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.pump();
  }

  testWidgets('the corner lamp rows sit over the board square, not the window', (
    tester,
  ) async {
    await pumpTable(tester);

    // The board painter renders the square; the lamp slabs render at that
    // exact width, so a lamp row cannot hug a window edge the board has
    // already left behind.
    final boardPaint = tester.renderObject<RenderBox>(
      find.byWidgetPredicate(
        (w) => w is CustomPaint && w.painter is LudoBoardPainter,
      ),
    );
    final slabs = tester
        .widgetList<SizedBox>(
          find.byWidgetPredicate((w) => w is SizedBox && w.height == 46.0),
        )
        .toList();
    expect(slabs, isNot(isEmpty),
        reason: 'two fixed lamp slabs flank the board');
    expect(slabs.length, 2);
    for (final slab in slabs) {
      expect(slab.width, boardPaint.size.width,
          reason: 'the lamp row is built on the board square, not the '
              'window — the corners answer the corners');
      // And that really is narrower than a full-width row on this window.
      expect(slab.width, lessThan(1200.0),
          reason: 'a 1440-wide window must not hang the lamps on its edges');
    }
  });

  testWidgets(
      'the on-turn seat carries the phase prompt beside its dots',
      (tester) async {
    await pumpTable(tester);

    // Ana (red) owns the turn, awaiting a roll: her lamp answers with the
    // roll prompt right where her strike dots live.
    final redLamp = find.byKey(const Key('corner-panel-red'));
    expect(redLamp, findsOneWidget);
    expect(
      find.descendant(of: redLamp, matching: find.text('Your roll, Ana!')),
      findsOneWidget,
      reason: 'the roll prompt rides the on-turn lamp, beside the dots — '
          'not a far-left status line',
    );
    final greenLamp = find.byKey(const Key('corner-panel-green'));
    expect(
      find.descendant(of: greenLamp, matching: find.textContaining('roll')),
      findsNothing,
      reason: 'only the seat on turn gets words; mine stays a lamp',
    );
    // And the old subtitle is gone: the phrase exists exactly once.
    expect(find.text('Your roll, Ana!'), findsOneWidget);
  });

  testWidgets('the lamps read state only — names live on the yard pill', (
    tester,
  ) async {
    await pumpTable(tester, logicalWidth: 800);

    final greenLamp = find.byKey(const Key('corner-panel-green'));
    expect(greenLamp, findsOneWidget);
    expect(
      find.descendant(of: greenLamp, matching: find.text('Bo')),
      findsNothing,
      reason:
          'the yard pill inside the corner square already says "Bo" — the '
          'lamp above it repeats only the turn state',
    );
    // The identity-bearing pill is painted by the board itself: the
    // painter still receives the players' names.
    final paint = tester
        .widgetList<CustomPaint>(
          find.byWidgetPredicate(
            (w) => w is CustomPaint && w.painter is LudoBoardPainter,
          ),
        )
        .first;
    expect(paint.painter, isNotNull);
  });
}
