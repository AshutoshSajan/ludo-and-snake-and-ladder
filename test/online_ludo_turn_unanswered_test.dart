/// The turn-anxiety surfaces on an online ludo table, as real client
/// behaviour against scripted server frames (the same frame order the
/// authority sends):
///
/// - the removal is the end screen for the seat that was walked out — a
///   banner that says what happened plus one way out, on the board they
///   were removed from, not a toast above a frozen game (the server removes
///   the seat from the roster before the gameOver snapshot ships, so that
///   client never receives a final state to show);
/// - other seats hear the removal as a notice and keep playing;
/// - the strike dots live on each player's own name pill, driven by the
///   client's seat-miss counts (five strikes is the turn tracker's rule);
/// - a missed-turn toast speaks TO the seat that missed it, not at the
///   whole table;
/// - a game the client finally sees end addresses the winner as "you".
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:game_club/engine/ludo/ludo_models.dart';
import 'package:game_club/engine/ludo/ludo_rules.dart';
import 'package:game_club/services/online_client.dart';
import 'package:game_club/ui/ludo/ludo_corner_panel.dart';
import 'package:game_club/ui/ludo/ludo_view.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'fake_channel.dart';

void main() {
  late FakeChannel channel;
  late OnlineClient client;
  var exits = <String>[];

  LudoState twoPlayerState() => createLudoState([
        LudoPlayer(id: 'p1', name: 'Ana', color: LudoColor.red),
        LudoPlayer(id: 'p2', name: 'Bo', color: LudoColor.green),
      ]);

  void sendState(LudoState s, {Map<String, int>? misses}) =>
      channel.serverAdd({
        'type': 'state',
        'game': 'ludo',
        'state': s.toJson(),
        'misses': ?misses,
      });

  /// Joined room 'CODE' at seat p2, with the table view live on screen. The
  /// initial state ships before the table view pumps: the lobby only hosts
  /// the board once an authoritative snapshot exists, which `initState`
  /// (LudoSession.online) requires.
  Future<void> pumpTable(
    WidgetTester tester, {
    LudoState? state,
    Map<String, int>? misses,
  }) async {
    SharedPreferences.setMockInitialValues({});
    client = OnlineClient(
      'ws://x/ws',
      seatId: 'p2',
      name: 'Bo',
      gameType: 'ludo',
      channelFactory: (_) => channel,
    );
    final joined = client.connect(code: 'CODE');
    // testWidgets runs in a FakeAsync zone — zero-duration futures only
    // complete when the tester's clock advances.
    await tester.pump();
    channel.serverAdd({'type': 'joined', 'code': 'CODE', 'game': 'ludo'});
    await tester.pump();
    await joined;

    sendState(state ?? twoPlayerState(), misses: misses);
    await tester.pump();
    await tester.pump();

    exits = [];
    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          home: Scaffold(
            body: LudoGameView(
              onlineClient: client,
              onlineSeatId: 'p2',
              onOnlineLeave: () => exits.add('left'),
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.pump();
  }

  setUp(() {
    channel = FakeChannel();
  });

  testWidgets("a timeout removal is the evicted seat's end screen", (
    tester,
  ) async {
    await pumpTable(tester);

    channel.serverAdd({
      'type': 'left',
      'seatId': 'p2',
      'name': 'Bo',
      'color': 'green',
      'reason': 'timeout',
    });
    await tester.pump();
    await tester.pump();

    expect(find.text('You were removed'), findsOneWidget,
        reason: 'the removal is this seat\'s game over: the final state '
            'never reaches a removed seat again — the banner plus the exit '
            'IS the answer, on the board, not a toast that scrolls away');
    expect(find.textContaining('Five turns in a row'), findsOneWidget,
        reason: 'the card says why');

    await tester.tap(find.widgetWithText(FilledButton, 'Back to lobby'));
    await tester.pump();
    expect(exits, ['left'],
        reason: 'Back to lobby hands the screen\'s exit to the lobby screen');
    expect(find.text('You were removed'), findsNothing);
  });

  testWidgets('other seats only hear the removal, they keep the table', (
    tester,
  ) async {
    await pumpTable(tester);

    channel.serverAdd({
      'type': 'left',
      'seatId': 'p1',
      'name': 'Ana',
      'color': 'red',
      'reason': 'timeout',
    });
    await tester.pump();
    await tester.pump();

    expect(find.text('You were removed'), findsNothing,
        reason: 'this seat was not removed — there is no end card for it');
    expect(find.textContaining('was removed — five turns missed'),
        findsOneWidget,
        reason: 'the table announcement still travels, as a notice');
  });

  testWidgets('a game the client sees end addresses its own winner as you', (
    tester,
  ) async {
    await pumpTable(tester);
    final s = twoPlayerState();
    s.phase = LudoPhase.gameOver;
    s.rankings.addAll(['p2', 'p1']);
    sendState(s);
    await tester.pump();
    await tester.pump();

    expect(find.text('You win Ludo!'), findsOneWidget,
        reason: 'the trophy dialog speaks to the seat that holds it — p2 '
            'ranked first is this client');
  });

  testWidgets(
    'a client that (re)joins an already-finished table still gets the end '
    'screen', (tester) async {
      // The state frame lands BEFORE the view mounts — a rejoin, not a live
      // transition. The session assigns a preloaded snapshot directly
      // (through the factory, never through _adoptState), so nothing opens
      // the end screen by itself; this seat would sit on a frozen board in
      // the UI of a live table — the playtest round's "no popup" report.
      // This client rejoins as the LOSER: p1 (Ana) ranked first.
      final s = twoPlayerState()
        ..phase = LudoPhase.gameOver
        ..lastRoll = null;
      s.rankings.addAll(['p1', 'p2']);
      await pumpTable(tester, state: s);
      await tester.pump();
      await tester.pump();

      expect(find.text('Ana wins Ludo!'), findsOneWidget,
          reason: 'the rejoining loser reads the result on an end screen, '
              'not on a table that pretends to still be going');
      expect(find.text('Home'), findsOneWidget);

      await tester.tap(find.text('Home'));
      await tester.pump();
      await tester.pump();
      expect(find.text('Ana wins Ludo!'), findsNothing,
          reason: 'Home leaves through the dialog');
    },
  );

  testWidgets('the reconnect budget exhausted is a way back in, not a freeze', (
    tester,
  ) async {
    await pumpTable(tester);

    // Drop the socket: the client reconnects with backoff and, after the
    // budget, settles into error — previously a silent dead table.
    channel.dropConnection();
    for (var i = 0; i < 6; i++) {
      await tester.pump(const Duration(seconds: 3));
    }
    expect(find.text('Connection lost — could not reach the server.'),
        findsOneWidget,
        reason: 'the spent table says so instead of going silent forever');
    expect(find.text('Retry'), findsOneWidget,
        reason: 'the spent table offers the way back in');
    expect(find.text('Leave'), findsOneWidget,
        reason: 'and the way out, so nobody sits frozen in silence');
  });

  testWidgets('strike dots live outside the board, at each player corner', (
    tester,
  ) async {
    await pumpTable(tester, misses: {'p1': 2, 'p2': 4});
    await tester.pump();

    // The board painter no longer carries the dots — each corner square is
    // covered by that corner's floating dice, so the strikes moved into
    // the panels that stand outside the board, one per player corner.
    final red = tester.widget<StrikeDotsRow>(
      find.byKey(const Key('strike-dots-red')),
    );
    expect(
      red.misses,
      2,
      reason: 'p1 is red; two spent strikes at their own corner',
    );
    final green = tester.widget<StrikeDotsRow>(
      find.byKey(const Key('strike-dots-green')),
    );
    expect(
      green.misses,
      4,
      reason: 'p2 is green; four of five strikes spent at their corner',
    );
    expect(
      ludoStrikeDots,
      maxTurnMisses,
      reason:
          'one strike per allowed miss: the dot count mirrors the '
          'turn tracker\'s rule exactly',
    );

    // And the panels themselves exist per seated player — the corner the
    // dice stand on no longer owns the only copy of someone's strikes.
    expect(find.byKey(const Key('corner-panel-red')), findsOneWidget);
    expect(find.byKey(const Key('corner-panel-green')), findsOneWidget);
  });

  testWidgets('the fifth strike reaches the corner dots with no state frame', (
    tester,
  ) async {
    await pumpTable(tester, misses: {'p1': 2, 'p2': 4});
    await tester.pump();

    // The evicting miss rides a seats frame — the state frame it would
    // normally be followed by never ships to the removed seat, which is
    // off the roster before the next broadcast. The dots read the seats
    // feed too, or the corner shows one strike fewer than the strip's
    // miss chip (the playtest board frozen at "missed 5" with four dots).
    channel.serverAdd({
      'type': 'seats',
      'seats': [
        {
          'seatId': 'p1', 'name': 'Ana', 'color': 'red',
          'connected': true, 'auto': false, 'misses': 2,
        },
        {
          'seatId': 'p2', 'name': 'Bo', 'color': 'green',
          'connected': true, 'auto': false, 'misses': 5,
        },
      ],
    });
    await tester.pump();

    expect(client.seatMisses['p2'], 5,
        reason: 'the strip and the corner dots read the same count');
    final green = tester.widget<StrikeDotsRow>(
      find.byKey(const Key('strike-dots-green')),
    );
    expect(green.misses, 5,
        reason: 'five silent turns is five spent strikes on the corner');
  });

  testWidgets("another seat's missed turn never interrupts this player", (
    tester,
  ) async {
    await pumpTable(tester);

    var notices = 0;
    client.onLeft = (_) => notices++;
    channel.serverAdd({
      'type': 'turnMissed',
      'seatId': 'p1',
      'name': 'Ana',
      'count': 1,
    });
    await tester.pump();

    expect(notices, isZero,
        reason: 'Ana\'s slow beat is Ana\'s problem: her pill glows red and '
            'the table does not toast at everyone else');
  });

  testWidgets('my missed turn tells me the stakes before the next one', (
    tester,
  ) async {
    await pumpTable(tester);

    channel.serverAdd({
      'type': 'turnMissed',
      'seatId': 'p2',
      'name': 'Bo',
      'count': 2,
    });
    await tester.pump();
    await tester.pump();

    expect(find.textContaining('You missed a turn (2 of 5)'), findsOneWidget,
        reason: 'the hearer wakes up knowing the count and the cap');
  });

  testWidgets('a server without seat ids still announces the miss by name', (
    tester,
  ) async {
    await pumpTable(tester);

    channel.serverAdd({'type': 'turnMissed', 'name': 'Ana', 'count': 1});
    await tester.pump();
    await tester.pump();
    expect(find.textContaining('Ana missed a turn (1 of 5)'), findsOneWidget,
        reason: 'pre-seat-id servers keep their old wording for everyone');
  });
}
