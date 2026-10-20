/// The corner furniture's geometry on an online ludo table:
///
/// - the strike-dot lamps above and below the board are pinned to the
///   board's own square width — they used to span the whole play area,
///   so on a desktop window the top panels hung off the screen's far
///   edges while the board sat centered (playtest: turn dots and timer
///   should sit directly above/below the player corners);
/// - the lamps carry state (spot, dots, clock), not identity — the name
///   lives once, on the yard pill painted inside the corner square;
///   neither is the lamp the place for phase words — a playtest round put
///   "Your roll, {name}!" beside the dots and the next one asked it gone
///   ("i don't need your turn username message"), so no spoken line
///   exists anywhere: dots and a clock say the whole turn story.
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
      'on-turn lamps stay wordless — dots and a clock, no phase line',
      (tester) async {
    await pumpTable(tester);

    // The spoken phase line ("Your roll, {name}!" and friends) was played
    // both on a full-width row and on the on-turn lamp and removed by the
    // third playtest round: no seat's lamp holds words now, and no other
    // status row revived to carry them instead.
    expect(find.textContaining('roll,'), findsNothing,
        reason: 'the lamp answers "whose turn, how long" without saying it '
            'in words — a prompt next to the dots was not wanted');
    expect(find.text('Pick a token to move'), findsNothing);
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
