/// Widget tests for the online Snakes & Ladders game view: turn-gated
/// roll controls, the automatic move intent, and spectator read-only mode.
library;

import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:game_club/engine/snakes/snakes_engine.dart';
import 'package:game_club/screens/online_lobby_screen.dart';
import 'package:game_club/services/online_client.dart';
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
      MaterialApp(
        home: Scaffold(
          body: OnlineSnakesView(client: client, onLeave: () {}),
        ),
      ),
    );
    channel.serverAdd({
      'type': 'state',
      'game': 'snakes',
      'state': twoPlayerState(currentPlayerId: 'p2').toJson(),
    });
    await tester.pumpAndSettle();

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
      MaterialApp(
        home: Scaffold(
          body: OnlineSnakesView(client: client, onLeave: () {}),
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
    await tester.pumpAndSettle();
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
      MaterialApp(
        home: Scaffold(
          body: OnlineSnakesView(client: client, onLeave: () {}),
        ),
      ),
    );
    channel.serverAdd({
      'type': 'state',
      'game': 'snakes',
      'state': twoPlayerState(currentPlayerId: 'p1').toJson(),
    });
    await tester.pumpAndSettle();

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
      MaterialApp(
        home: Scaffold(
          body: OnlineSnakesView(client: client, onLeave: () {}),
        ),
      ),
    );
    channel.serverAdd({
      'type': 'state',
      'game': 'snakes',
      'state': twoPlayerState(currentPlayerId: 'p2').toJson(),
    });
    await tester.pumpAndSettle();

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
      await tester.pumpWidget(const MaterialApp(home: OnlineLobbyScreen()));
      await tester.pumpAndSettle();

      // Defaults to Ludo.
      expect(find.text('Play Ludo online against friends'), findsOneWidget);
      // The toggle offers both games...
      expect(find.text('Ludo'), findsOneWidget);
      expect(find.text('Snakes'), findsOneWidget);

      // ...and picking Snakes rewords the pitch, with no connection needed.
      await tester.tap(find.text('Snakes'));
      await tester.pumpAndSettle();
      expect(
        find.text('Play Snakes & Ladders online against friends'),
        findsOneWidget,
      );
      expect(find.text('Play Ludo online against friends'), findsNothing);

      // And back again, so the label is derived rather than one-way.
      await tester.tap(find.text('Ludo'));
      await tester.pumpAndSettle();
      expect(find.text('Play Ludo online against friends'), findsOneWidget);
    });

    testWidgets('nothing on the online path is labelled Ludo-only', (
      tester,
    ) async {
      await tester.pumpWidget(const MaterialApp(home: OnlineLobbyScreen()));
      await tester.pumpAndSettle();
      // The app bar names the mode, not one game.
      expect(find.text('Play Online'), findsOneWidget);
      expect(find.text('Online Ludo'), findsNothing);
    });
  });
}
