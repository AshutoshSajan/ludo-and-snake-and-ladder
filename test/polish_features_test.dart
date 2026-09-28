/// Tests for the polish/hardening features: undo, hints, streak stats,
/// and persisted settings (sound / haptics / animations).
library;

import 'dart:async';
import 'dart:math';

import 'package:fake_async/fake_async.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:game_club/controllers/ludo_session.dart';
import 'package:game_club/engine/core/player_profiles.dart';
import 'package:game_club/engine/ludo/ludo_models.dart';
import 'package:game_club/engine/ludo/ludo_rules.dart';
import 'package:game_club/providers/app_providers.dart';
import 'package:game_club/services/sound_service.dart';
import 'package:game_club/services/storage_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Deterministic RNG: every roll is a six, so session tests never flake.
class _FixedRandom implements Random {
  @override
  int nextInt(int max) => max - 1;
  @override
  bool nextBool() => true;
  @override
  double nextDouble() => 0.999;
}

class _CountingSound extends SoundService {
  @override
  Future<void> dice() async {}
}

/// A storage that never answers. Reading `profilesProvider` makes its `build`
/// kick off a load, and a load that never completes can neither reach
/// SharedPreferences nor overwrite the profiles a test creates by hand.
class _InertStorage extends StorageService {
  @override
  Future<PlayerRegistry> loadProfiles() => Completer<PlayerRegistry>().future;
  @override
  Future<void> saveProfiles(PlayerRegistry registry) async {}
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(SystemChannels.platform, (call) async {
    return const JSONMethodCodec().encodeSuccessEnvelope(null);
  });
  SharedPreferences.setMockInitialValues({});

  /// Since Riverpod 3 a notifier owns the Ref it reads its dependencies
  /// through, so it can only come from a container. One throwaway container
  /// per session keeps each session's profiles as separate as they were when
  /// the notifier was built by hand.
  ProfilesNotifier makeProfiles() {
    final container = ProviderContainer(
      overrides: [storageProvider.overrideWithValue(_InertStorage())],
    );
    addTearDown(container.dispose);
    return container.read(profilesProvider.notifier);
  }

  LudoSession makeSession() => LudoSession(
        seats: [
          SeatSetup(name: 'R', color: LudoColor.red),
          SeatSetup(name: 'Y', color: LudoColor.yellow),
        ],
        profiles: makeProfiles(),
        sound: _CountingSound(),
        onGameOver: (_) {},
        rng: _FixedRandom(),
      );

  group('undo', () {
    test('restores the exact pre-roll state', () {
      fakeAsync((async) {
        final session = makeSession();
        expect(session.state.currentPlayerIndex, 0);

        session.roll();
        expect(session.canUndo, isTrue,
            reason: 'a fresh roll must be undoable');
        expect(session.state.phase, LudoPhase.awaitingMove);
        expect(session.state.lastRoll, isNotNull);

        session.undo();
        expect(session.state.phase, LudoPhase.awaitingRoll);
        expect(session.state.lastRoll, isNull);
        expect(session.state.currentPlayerIndex, 0);
        expect(session.state.tokens.every((t) => t.pos == -1), isTrue,
            reason: 'tokens back to their pre-roll spots');
        expect(session.canUndo, isFalse, reason: 'stack is empty again');
        session.dispose();
        async.flushTimers();
      });
    });

    test('disabled while autoplay runs', () {
      fakeAsync((async) {
        final session = makeSession();
        session.roll();
        session.toggleAutoPlay();
        expect(session.canUndo, isFalse,
            reason: 'no take-backs while the game plays itself');
        session.dispose();
        async.flushTimers();
      });
    });
  });

  group('hint', () {
    test('suggests a legal token during the move phase', () {
      final session = makeSession();
      session.state.phase = LudoPhase.awaitingMove;
      session.state.lastRoll = 6;
      expect(session.canHint, isTrue);
      final hint = session.hintTokenIndex();
      expect(hint, isNotNull);
      expect(hint, inInclusiveRange(0, 3));
      expect(legalMoves(session.state).any((m) => m.tokenIndex == hint),
          isTrue,
          reason: 'the hint must be an actually legal move');
      session.dispose();
    });

    test('unavailable outside the move phase', () {
      final session = makeSession();
      expect(session.canHint, isFalse);
      expect(session.hintTokenIndex(), isNull);
      session.dispose();
    });
  });

  group('streak stats', () {
    test('current streak counts trailing wins only', () {
      final p = PlayerProfile(id: 'p', name: 'P');
      for (var i = 0; i < 3; i++) {
        p.recordGame(GameKind.ludo, true);
      }
      expect(p.ludoStreak(), 3);
      expect(p.ludoBestStreak(), 3);
      p.recordGame(GameKind.ludo, false);
      expect(p.ludoStreak(), 0, reason: 'a loss resets the current streak');
      expect(p.ludoBestStreak(), 3, reason: 'best streak is remembered');
      p.recordGame(GameKind.ludo, true);
      expect(p.ludoStreak(), 1);
    });

    test('form is capped at 20 results, games counted separately', () {
      final p = PlayerProfile(id: 'p', name: 'P');
      for (var i = 0; i < 25; i++) {
        p.recordGame(GameKind.snakes, true);
      }
      expect(p.snakesGames, 25);
      expect(p.snakesWins, 25);
      expect(p.snakesBestStreak(), 20,
          reason: 'best run can only span the kept window');
    });

    test('survives JSON roundtrip', () {
      final p = PlayerProfile(id: 'p', name: 'P');
      p.recordGame(GameKind.ludo, true);
      p.recordGame(GameKind.ludo, true);
      p.recordGame(GameKind.ludo, false);
      final restored = PlayerProfile.fromJson(p.toJson());
      expect(restored.ludoStreak(), 0);
      expect(restored.ludoBestStreak(), 2);
    });
  });

  group('settings persistence', () {
    test('haptics and animations roundtrip through storage', () async {
      final storage = StorageService();
      expect(await storage.loadHapticsEnabled(), isTrue);
      expect(await storage.loadAnimationsEnabled(), isTrue);
      await storage.saveHapticsEnabled(false);
      await storage.saveAnimationsEnabled(false);
      expect(await storage.loadHapticsEnabled(), isFalse);
      expect(await storage.loadAnimationsEnabled(), isFalse);
    });

    test('toggles gate haptics and sound instantly', () async {
      Haptics.enabled = true;
      Haptics.light(); // must not throw when enabled
      Haptics.enabled = false;
      Haptics.heavy(); // no-op when disabled — still no throw
      final sound = SoundService();
      sound.enabled = false;
      sound.dice(); // no-op path, no crash
      sound.enabled = true;
      sound.dispose();
    });
  });
}
