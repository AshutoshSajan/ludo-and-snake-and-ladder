/// Widget tests for the online Snakes & Ladders game view: turn-gated
/// roll controls, the automatic move intent, and spectator read-only mode.
library;

import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:game_club/engine/snakes/snakes_engine.dart';
import 'package:game_club/screens/online_lobby_screen.dart';
import 'package:game_club/services/online_client.dart';
import 'package:game_club/ui/shared/dice_widget.dart';
import 'package:game_club/ui/snakes/online_snakes_view.dart';
import 'package:stream_channel/stream_channel.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

/// A scripted server side of one WebSocket connection (same pattern as the
/// reconnect tests).
class FakeChannel extends StreamChannelMixin<dynamic>
    implements WebSocketChannel {
  final sent = <Map<String, dynamic>>[];
  final toClient = StreamController<dynamic>.broadcast();

  @override
  int? get closeCode => null;
  @override
  String? get closeReason => null;
  @override
  String? get protocol => null;
  @override
  Future<void> get ready => Future.value();
  @override
  Stream<dynamic> get stream => toClient.stream;
  @override
  WebSocketSink get sink => _FakeSink(this);

  void serverAdd(Map<String, dynamic> msg) => toClient.add(jsonEncode(msg));
}

class _FakeSink implements WebSocketSink {
  _FakeSink(this.channel);
  final FakeChannel channel;

  @override
  Future<void> get done => Future.value();
  @override
  void add(dynamic data) =>
      channel.sent.add(jsonDecode(data as String) as Map<String, dynamic>);
  @override
  void addError(Object error, [StackTrace? stackTrace]) {}
  @override
  Future<void> addStream(Stream<dynamic> stream) async {}
  @override
  Future close([int? closeCode, String? closeReason]) async {}
}

/// The `rolling` flag the view currently hands the die.
bool _diceRolling(WidgetTester tester) =>
    tester.widget<DiceWidget>(find.byType(DiceWidget)).rolling;

void main() {
  late FakeChannel channel;
  late OnlineClient client;

  SnakesState twoPlayerState({
    required String currentPlayerId,
    SnakesPhase phase = SnakesPhase.awaitingRoll,
    int? roll,
  }) {
    final s = createSnakesState([
      SnakesPlayer(id: 'p1', name: 'Ana', tokenIndex: 0),
      SnakesPlayer(id: 'p2', name: 'Bo', tokenIndex: 1),
    ]);
    s.currentPlayerIndex = s.players.indexWhere((p) => p.id == currentPlayerId);
    s.phase = phase;
    s.lastRoll = roll;
    return s;
  }

  /// A finished game, as the server broadcasts it: phase gameOver with the
  /// winner ranked first. Drives the game-over dialog.
  SnakesState finishedState() {
    final s = createSnakesState([
      SnakesPlayer(id: 'p1', name: 'Ana', tokenIndex: 0),
      SnakesPlayer(id: 'p2', name: 'Bo', tokenIndex: 1),
    ]);
    s.players[0].square = 100;
    s.players[0].finished = true;
    s.rankings.addAll(['p1', 'p2']);
    s.phase = SnakesPhase.gameOver;
    s.lastRoll = null;
    return s;
  }

  Future<void> connectAndEnterGame(WidgetTester tester) async {
    client = OnlineClient(
      'ws://x/ws',
      seatId: 'p2',
      name: 'Bo',
      gameType: 'snakes',
      channelFactory: (_) => channel,
    );
    final joined = client.connect(code: 'CODE');
    // testWidgets runs in a FakeAsync zone — zero-duration futures only
    // complete when the tester's clock advances.
    await tester.pump();
    channel.serverAdd({'type': 'joined', 'code': 'CODE', 'game': 'snakes'});
    await tester.pump();
    await joined;
  }

  setUp(() {
    channel = FakeChannel();
  });

  testWidgets('my turn: roll is enabled and intent is sent', (tester) async {
    await connectAndEnterGame(tester);
    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          home: Scaffold(
            body: OnlineSnakesView(client: client, onLeave: () {}),
          ),
        ),
      ),
    );
    channel.serverAdd({
      'type': 'state',
      'game': 'snakes',
      'state': twoPlayerState(currentPlayerId: 'p2').toJson(),
    });
    await tester.pump(const Duration(milliseconds: 300));

    final rollBtn = tester.widget<FilledButton>(
      find.widgetWithText(FilledButton, 'ROLL'),
    );
    expect(rollBtn.onPressed, isNotNull);

    await tester.tap(find.widgetWithText(FilledButton, 'ROLL'));
    await tester.pump();
    expect(
      channel.sent.any((m) => m['type'] == 'roll'),
      isTrue,
      reason: 'tapping ROLL must send the roll intent',
    );
  });

  testWidgets('roll snapshot triggers the automatic move intent', (
    tester,
  ) async {
    await connectAndEnterGame(tester);
    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          home: Scaffold(
            body: OnlineSnakesView(client: client, onLeave: () {}),
          ),
        ),
      ),
    );
    // Roll received -> awaitingMove for me.
    channel.serverAdd({
      'type': 'state',
      'game': 'snakes',
      'state': twoPlayerState(
        currentPlayerId: 'p2',
        phase: SnakesPhase.awaitingMove,
        roll: 4,
      ).toJson(),
    });
    await tester.pump(const Duration(milliseconds: 300));
    expect(
      channel.sent.any((m) => m['type'] == 'move'),
      isFalse,
      reason: 'the move waits a beat so the roll stays visible',
    );

    await tester.pump(const Duration(milliseconds: 800));
    expect(
      channel.sent.any((m) => m['type'] == 'move'),
      isTrue,
      reason: 'after the beat the single forced move is sent automatically',
    );
    // Exactly once — further pumps must not duplicate the intent.
    await tester.pump(const Duration(milliseconds: 800));
    expect(channel.sent.where((m) => m['type'] == 'move').length, 1);
  });

  testWidgets('not my turn: roll disabled, other turn snapshots still render', (
    tester,
  ) async {
    await connectAndEnterGame(tester);
    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          home: Scaffold(
            body: OnlineSnakesView(client: client, onLeave: () {}),
          ),
        ),
      ),
    );
    channel.serverAdd({
      'type': 'state',
      'game': 'snakes',
      'state': twoPlayerState(currentPlayerId: 'p1').toJson(),
    });
    await tester.pump(const Duration(milliseconds: 300));

    // Disabled: the roll button sits in its idle state and shows '…'.
    final rollBtn = tester.widget<FilledButton>(find.byType(FilledButton));
    expect(rollBtn.onPressed, isNull);
    expect(find.text('Ana is rolling...'), findsOneWidget);
  });

  testWidgets('spectators see the board but can never roll', (tester) async {
    client = OnlineClient(
      'ws://x/ws',
      seatId: 'p9',
      name: 'Watcher',
      gameType: 'snakes',
      channelFactory: (_) => channel,
    );
    final joined = client.connect(code: 'CODE', spectate: true);
    await tester.pump();
    channel.serverAdd({
      'type': 'joined',
      'code': 'CODE',
      'game': 'snakes',
      'spectator': true,
    });
    await tester.pump();
    await joined;

    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          home: Scaffold(
            body: OnlineSnakesView(client: client, onLeave: () {}),
          ),
        ),
      ),
    );
    channel.serverAdd({
      'type': 'state',
      'game': 'snakes',
      'state': twoPlayerState(currentPlayerId: 'p2').toJson(),
    });
    await tester.pump(const Duration(milliseconds: 300));

    final rollBtn = tester.widget<FilledButton>(find.byType(FilledButton));
    expect(rollBtn.onPressed, isNull);
    expect(find.text('Spectating'), findsOneWidget);
    expect(
      channel.sent.any((m) => m['type'] == 'roll' || m['type'] == 'move'),
      isFalse,
    );
  });

  group('the lobby offers both games', () {
    // Online Snakes & Ladders is fully playable, but the home screen's button
    // and the lobby's app bar both said "Online Ludo" and the tagline said
    // "Play Ludo online against friends" no matter which game the toggle had
    // selected. Someone looking for online Snakes had no way to know the
    // screen served them, which is exactly how a working feature reads as a
    // missing one.
    testWidgets('the tagline follows the selected game', (tester) async {
      await tester.pumpWidget(
        const ProviderScope(child: MaterialApp(home: OnlineLobbyScreen())),
      );
      await tester.pump(const Duration(milliseconds: 300));

      // Defaults to Ludo.
      expect(find.text('Play Ludo online against friends'), findsOneWidget);
      // The toggle offers both games...
      expect(find.text('Ludo'), findsOneWidget);
      expect(find.text('Snakes'), findsOneWidget);

      // ...and picking Snakes rewords the pitch, with no connection needed.
      await tester.tap(find.text('Snakes'));
      await tester.pump(const Duration(milliseconds: 300));
      expect(
        find.text('Play Snakes & Ladders online against friends'),
        findsOneWidget,
      );
      expect(find.text('Play Ludo online against friends'), findsNothing);

      // And back again, so the label is derived rather than one-way.
      await tester.tap(find.text('Ludo'));
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.text('Play Ludo online against friends'), findsOneWidget);
    });

    testWidgets('nothing on the online path is labelled Ludo-only', (
      tester,
    ) async {
      await tester.pumpWidget(
        const ProviderScope(child: MaterialApp(home: OnlineLobbyScreen())),
      );
      await tester.pump(const Duration(milliseconds: 300));
      // The app bar names the mode, not one game.
      expect(find.text('Play Online'), findsOneWidget);
      expect(find.text('Online Ludo'), findsNothing);
    });
  });

  group('leaving and feedback', () {
    testWidgets('the game-over dialog closes when Back to lobby is tapped', (
      tester,
    ) async {
      // The dialog is not barrier-dismissible and its button used to call
      // onLeave without popping itself, so the route underneath was torn down
      // while the dialog stayed on screen: stuck on "Back to lobby" forever.
      var left = false;
      await connectAndEnterGame(tester);
      await tester.pumpWidget(
        ProviderScope(
          child: MaterialApp(
            home: Scaffold(
              body: OnlineSnakesView(
                client: client,
                onLeave: () => left = true,
              ),
            ),
          ),
        ),
      );
      channel.serverAdd({
        'type': 'state',
        'game': 'snakes',
        'state': finishedState().toJson(),
      });
      await tester.pump(const Duration(milliseconds: 300));

      expect(find.text('Back to lobby'), findsOneWidget);
      await tester.tap(find.text('Back to lobby'));
      await tester.pump(const Duration(milliseconds: 300));

      expect(left, isTrue, reason: 'leaving must actually be requested');
      expect(
        find.text('Back to lobby'),
        findsNothing,
        reason: 'the dialog must dismiss itself, not sit on a dead route',
      );
    });

    testWidgets('a roll makes the dice sound', (tester) async {
      // Online Snakes was the only view that never made a sound: nothing was
      // wired to the client's roll callback, so a whole game played silent.
      await connectAndEnterGame(tester);
      await tester.pumpWidget(
        ProviderScope(
          child: MaterialApp(
            home: Scaffold(
              body: OnlineSnakesView(client: client, onLeave: () {}),
            ),
          ),
        ),
      );
      expect(
        client.onRoll,
        isNotNull,
        reason: 'the view must subscribe to rolls',
      );

      // The callback is what the client invokes on a roll -> move transition.
      // A plain pump, not pumpAndSettle: the sound plays through a platform
      // channel that never settles under the fake async zone.
      client.onRoll!();
      await tester.pump();

      // Disposing must not leave a dead callback on a client that outlives it.
      await tester.pumpWidget(const MaterialApp(home: SizedBox()));
      expect(client.onRoll, isNull);
    });
  });

  testWidgets('the die tumbles on a roll, matching the offline view', (
    tester,
  ) async {
    // The online die had `rolling: false` hardcoded, so it never tumbled and
    // just snapped to the new face while the offline one rolled. The roll is
    // timed here because there is no session to read an animation off.
    await connectAndEnterGame(tester);
    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          home: Scaffold(
            body: OnlineSnakesView(client: client, onLeave: () {}),
          ),
        ),
      ),
    );
    channel.serverAdd({
      'type': 'state',
      'game': 'snakes',
      'state': twoPlayerState(currentPlayerId: 'p2').toJson(),
    });
    // A plain pump, not pumpAndSettle: settling would advance past the 700ms
    // auto-move timer and the turn would resolve before the roll under test.
    await tester.pump();
    expect(_diceRolling(tester), isFalse);

    // The server accepts the roll: awaitingRoll -> awaitingMove publishes it.
    channel.serverAdd({
      'type': 'state',
      'game': 'snakes',
      'state': twoPlayerState(
        currentPlayerId: 'p2',
        phase: SnakesPhase.awaitingMove,
        roll: 4,
      ).toJson(),
    });
    await tester.pump();
    expect(
      _diceRolling(tester),
      isTrue,
      reason: 'the die must tumble on a roll, not snap to its face',
    );

    // ...and settles once the tumble is over.
    await tester.pump(const Duration(milliseconds: 700));
    await tester.pump();
    expect(_diceRolling(tester), isFalse);
  });

  testWidgets('a new turn does not leave the die mid-tumble', (tester) async {
    await connectAndEnterGame(tester);
    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          home: Scaffold(
            body: OnlineSnakesView(client: client, onLeave: () {}),
          ),
        ),
      ),
    );
    channel.serverAdd({
      'type': 'state',
      'game': 'snakes',
      'state': twoPlayerState(currentPlayerId: 'p2').toJson(),
    });
    await tester.pump();
    channel.serverAdd({
      'type': 'state',
      'game': 'snakes',
      'state': twoPlayerState(
        currentPlayerId: 'p2',
        phase: SnakesPhase.awaitingMove,
        roll: 5,
      ).toJson(),
    });
    await tester.pump();
    expect(_diceRolling(tester), isTrue);

    // The move resolves and the turn passes before the tumble finishes.
    channel.serverAdd({
      'type': 'state',
      'game': 'snakes',
      'state': twoPlayerState(currentPlayerId: 'p1').toJson(),
    });
    await tester.pump();
    expect(
      _diceRolling(tester),
      isFalse,
      reason: 'a finished turn must not freeze the die tumbling',
    );

    // Let the view's own 700ms auto-move timer expire so the tree tears down
    // with nothing pending.
    await tester.pump(const Duration(milliseconds: 800));
  });

  group('home area', () {
    // The online view had no home area at all while the offline one had a
    // whole panel for it. The board numbers 1..100, so square 0 has no cell
    // and squareCenter(0) fell onto square 10's cell: every waiting pawn was
    // drawn on top of a numbered square, which read as a missing home area.
    testWidgets('shows a home strip holding the pawns that have not entered', (
      tester,
    ) async {
      await connectAndEnterGame(tester);
      await tester.pumpWidget(
        ProviderScope(
          child: MaterialApp(
            home: Scaffold(
              body: OnlineSnakesView(client: client, onLeave: () {}),
            ),
          ),
        ),
      );
      // Fresh board: both pawns are still off-board at square 0.
      channel.serverAdd({
        'type': 'state',
        'game': 'snakes',
        'state': twoPlayerState(currentPlayerId: 'p2').toJson(),
      });
      await tester.pump();
      await tester.pump();

      expect(find.byKey(const ValueKey('home-area')), findsOneWidget);
      expect(find.byKey(const ValueKey('home-pawn-0')), findsOneWidget);
      expect(find.byKey(const ValueKey('home-pawn-1')), findsOneWidget);
      expect(find.textContaining('waiting to enter'), findsOneWidget);
    });

    testWidgets('a pawn that has left home is gone from the strip', (
      tester,
    ) async {
      await connectAndEnterGame(tester);
      await tester.pumpWidget(
        ProviderScope(
          child: MaterialApp(
            home: Scaffold(
              body: OnlineSnakesView(client: client, onLeave: () {}),
            ),
          ),
        ),
      );
      channel.serverAdd({
        'type': 'state',
        'game': 'snakes',
        'state': twoPlayerState(currentPlayerId: 'p2').toJson(),
      });
      await tester.pump();
      await tester.pump();
      expect(find.byKey(const ValueKey('home-pawn-1')), findsOneWidget);

      final moved = twoPlayerState(currentPlayerId: 'p2', roll: 3);
      moved.players[0].square = 14; // pawn 0 has entered the board
      channel.serverAdd({
        'type': 'state',
        'game': 'snakes',
        'state': moved.toJson(),
      });
      await tester.pump();
      await tester.pump();

      expect(
        find.byKey(const ValueKey('home-area')),
        findsOneWidget,
        reason: 'the panel stays; it just empties out',
      );
      expect(find.byKey(const ValueKey('home-pawn-0')), findsNothing);
      expect(find.byKey(const ValueKey('home-pawn-1')), findsOneWidget);
      expect(find.text('every pawn is out'), findsNothing);
    });

    testWidgets('a home pawn is not also drawn on the board', (tester) async {
      // The bug in one assertion: the pawn was in the home strip AND on the
      // board, landing on square 10.
      await connectAndEnterGame(tester);
      await tester.pumpWidget(
        ProviderScope(
          child: MaterialApp(
            home: Scaffold(
              body: OnlineSnakesView(client: client, onLeave: () {}),
            ),
          ),
        ),
      );
      channel.serverAdd({
        'type': 'state',
        'game': 'snakes',
        'state': twoPlayerState(currentPlayerId: 'p2').toJson(),
      });
      await tester.pump();
      await tester.pump();

      // Both players sit at square 0, so neither may also be placed on a
      // board cell. This is the assertion that catches the original bug: the
      // home-strip widgets exist either way, so asserting only those would
      // pass while every pawn was still also being drawn over square 10.
      expect(find.byKey(const ValueKey('pawn-p1')), findsNothing);
      expect(find.byKey(const ValueKey('pawn-p2')), findsNothing);

      final homePanel = tester.getRect(find.byKey(const ValueKey('home-area')));
      for (final i in [0, 1]) {
        final pawn = tester.getRect(find.byKey(ValueKey('home-pawn-$i')));
        expect(
          pawn.top,
          greaterThanOrEqualTo(homePanel.top),
          reason: 'pawn $i must be inside the home panel',
        );
      }

      // Once a pawn has entered, it appears on the board and leaves the strip.
      final moved = twoPlayerState(currentPlayerId: 'p2');
      moved.players[1].square = 20;
      channel.serverAdd({
        'type': 'state',
        'game': 'snakes',
        'state': moved.toJson(),
      });
      await tester.pump();
      await tester.pump();
      expect(find.byKey(const ValueKey('pawn-p2')), findsOneWidget);
      expect(find.byKey(const ValueKey('home-pawn-1')), findsNothing);
    });
  });
}
