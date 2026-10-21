/// The lone-pawn case: when a roll leaves exactly one legal move, the board
/// must play it without waiting for a tap.
///
/// This is the playtest report — a player with three pawns home and the last
/// one on the home stretch rolled the exact number it needed and the pawn
/// "would not move". Offline had a 700 ms auto-play; online never did, because
/// the server owns the roll and the client only reacted to taps. These tests
/// pin both paths, including the last-pawn finish.
library;

import 'dart:async';
import 'dart:math';

import 'package:fake_async/fake_async.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:game_club/controllers/ludo_session.dart';
import 'package:game_club/engine/core/player_profiles.dart';
import 'package:game_club/engine/ludo/ludo_models.dart';
import 'package:game_club/engine/ludo/ludo_rules.dart';
import 'package:game_club/providers/app_providers.dart';
import 'package:game_club/services/online_client.dart';
import 'package:game_club/services/sound_service.dart';
import 'package:game_club/services/storage_service.dart';
import 'package:game_club/ui/ludo/ludo_view.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'fake_channel.dart';

/// Every roll is a four, the exact number the last pawn needs to finish.
class _FaceFourRandom implements Random {
  @override
  int nextInt(int max) => 3; // dieRoll adds one
  @override
  bool nextBool() => false;
  @override
  double nextDouble() => 0.4;
}

/// Never answers a load, so a test's hand-built profiles cannot be
/// overwritten by an asynchronous SharedPreferences read.
class _InertStorage extends StorageService {
  @override
  Future<PlayerRegistry> loadProfiles() => Completer<PlayerRegistry>().future;
  @override
  Future<void> saveProfiles(PlayerRegistry registry) async {}
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(SystemChannels.platform, (call) async => null);
  SharedPreferences.setMockInitialValues({});

  ProfilesNotifier makeProfiles() {
    final container = ProviderContainer(
      overrides: [storageProvider.overrideWithValue(_InertStorage())],
    );
    addTearDown(container.dispose);
    return container.read(profilesProvider.notifier);
  }

  test('offline: the last pawn auto-plays the only legal move and finishes',
      () {
    fakeAsync((async) {
      final sound = SoundService()..enabled = false;
      final finished = <LudoState>[];
      final session = LudoSession(
        seats: [
          SeatSetup(name: 'R', color: LudoColor.red),
          SeatSetup(name: 'Y', color: LudoColor.yellow),
        ],
        profiles: makeProfiles(),
        sound: sound,
        onGameOver: finished.add,
        rng: _FaceFourRandom(),
        skipSchedule: true,
      );

      final red = session.state.tokensOf(0);
      red[0].pos = 52; // two steps from the finish triangle
      red[1].pos = 56;
      red[2].pos = 56;
      red[3].pos = 56;
      session.state.phase = LudoPhase.awaitingRoll;

      session.roll();
      expect(session.state.phase, LudoPhase.awaitingMove);
      expect(session.state.lastRoll, 4);
      expect(
        legalMoves(session.state).map((m) => m.tokenIndex),
        [0],
        reason: 'only the last pawn has anywhere to go',
      );

      async.elapse(const Duration(milliseconds: 699));
      expect(
        red[0].pos,
        52,
        reason: 'the roll stays visible for a beat before the forced move',
      );

      async.elapse(const Duration(milliseconds: 1200));
      expect(red[0].pos, 56, reason: 'the only legal move played itself');
      expect(session.state.phase, LudoPhase.gameOver);
      expect(finished, hasLength(1), reason: 'the finish is announced once');

      session.dispose();
      sound.dispose();
      async.flushTimers();
    });
  });

  testWidgets('online: the only legal move is sent exactly once', (
    tester,
  ) async {
    final channel = FakeChannel();
    final client = OnlineClient(
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

    final state = createLudoState([
      LudoPlayer(id: 'p1', name: 'Ana', color: LudoColor.red),
      LudoPlayer(id: 'p2', name: 'Bo', color: LudoColor.green),
    ]);
    state.currentPlayerIndex = 1;
    state.phase = LudoPhase.awaitingMove;
    state.lastRoll = 4;
    state.rollSeq = 1;
    state.lastRolledValue = 4;
    state.lastRolledBy = 1;
    final green = state.tokensOf(1);
    green[0].pos = 52;
    green[1].pos = 56;
    green[2].pos = 56;
    green[3].pos = 56;

    channel.serverAdd({
      'type': 'state',
      'game': 'ludo',
      'state': state.toJson(),
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
    await tester.pump(const Duration(milliseconds: 300));
    expect(
      channel.sent.where((m) => m['type'] == 'move'),
      isEmpty,
      reason: 'the roll stays visible before the forced move',
    );

    // Presence/chat/reconnect can repeat the same authoritative snapshot
    // during the beat. It must not cancel the pending auto-move.
    channel.serverAdd({
      'type': 'state',
      'game': 'ludo',
      'state': state.toJson(),
    });
    await tester.pump(const Duration(milliseconds: 100));

    await tester.pump(const Duration(milliseconds: 800));
    final moves = channel.sent.where((m) => m['type'] == 'move').toList();
    expect(moves, hasLength(1));
    expect(moves.single['token'], 0);

    // A repeated snapshot or a second pump must not duplicate the intent.
    channel.serverAdd({
      'type': 'state',
      'game': 'ludo',
      'state': state.toJson(),
    });
    await tester.pump(const Duration(milliseconds: 1500));
    expect(channel.sent.where((m) => m['type'] == 'move'), hasLength(1));

    await tester.pumpWidget(const SizedBox());
    client.dispose();
  });

  testWidgets('online: a manual tap wins the race and is sent once', (
    tester,
  ) async {
    final channel = FakeChannel();
    final client = OnlineClient(
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

    final state = createLudoState([
      LudoPlayer(id: 'p1', name: 'Ana', color: LudoColor.red),
      LudoPlayer(id: 'p2', name: 'Bo', color: LudoColor.green),
    ]);
    state.currentPlayerIndex = 1;
    state.phase = LudoPhase.awaitingMove;
    state.lastRoll = 4;
    state.rollSeq = 1;
    state.lastRolledValue = 4;
    state.lastRolledBy = 1;
    final green = state.tokensOf(1);
    green[0].pos = 52;
    green[1].pos = 56;
    green[2].pos = 56;
    green[3].pos = 56;
    channel.serverAdd({
      'type': 'state',
      'game': 'ludo',
      'state': state.toJson(),
    });
    await tester.pump();
    await tester.pump();

    final sound = SoundService()..enabled = false;
    final session = LudoSession.online(
      client: client,
      seatId: 'p2',
      profiles: makeProfiles(),
      sound: sound,
      onGameOver: (_) {},
    );
    session.tapToken(0);
    await tester.pump(const Duration(milliseconds: 1500));

    expect(channel.sent.where((m) => m['type'] == 'move'), hasLength(1));
    expect(
      channel.sent.where((m) => m['type'] == 'move').single['token'],
      0,
    );

    session.dispose();
    sound.dispose();
    client.dispose();
  });

  testWidgets('online: a late tap after the forced send does not duplicate', (
    tester,
  ) async {
    final channel = FakeChannel();
    final client = OnlineClient(
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

    final state = createLudoState([
      LudoPlayer(id: 'p1', name: 'Ana', color: LudoColor.red),
      LudoPlayer(id: 'p2', name: 'Bo', color: LudoColor.green),
    ]);
    state.currentPlayerIndex = 1;
    state.phase = LudoPhase.awaitingMove;
    state.lastRoll = 4;
    state.rollSeq = 1;
    state.lastRolledValue = 4;
    state.lastRolledBy = 1;
    final green = state.tokensOf(1);
    green[0].pos = 52;
    green[1].pos = 56;
    green[2].pos = 56;
    green[3].pos = 56;
    channel.serverAdd({
      'type': 'state',
      'game': 'ludo',
      'state': state.toJson(),
    });
    await tester.pump();
    await tester.pump();

    final sound = SoundService()..enabled = false;
    final session = LudoSession.online(
      client: client,
      seatId: 'p2',
      profiles: makeProfiles(),
      sound: sound,
      onGameOver: (_) {},
    );
    await tester.pump(const Duration(milliseconds: 800));
    expect(channel.sent.where((m) => m['type'] == 'move'), hasLength(1));

    // The authoritative snapshot has not come back yet. A tap now is the
    // same intent, already in flight — ignore it.
    session.tapToken(0);
    await tester.pump(const Duration(milliseconds: 100));
    expect(channel.sent.where((m) => m['type'] == 'move'), hasLength(1));

    session.dispose();
    sound.dispose();
    client.dispose();
  });
}
