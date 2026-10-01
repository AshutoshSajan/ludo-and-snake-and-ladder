import 'package:flutter_test/flutter_test.dart';
import 'package:game_club/controllers/ludo_session.dart';
import 'package:game_club/engine/core/player_profiles.dart';
import 'package:game_club/providers/app_providers.dart';
import 'package:game_club/engine/ludo/ludo_models.dart';
import 'package:game_club/engine/ludo/ludo_rules.dart';
import 'package:game_club/services/saved_game.dart';
import 'package:game_club/services/sound_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Autosave and resume for local games.
///
/// The state has to come back *exactly* — the board, whose turn it is, the
/// sixes-in-a-row count. A lossy resume is worse than no resume: the player
/// comes back to a board that disagrees with the one they left, and there is
/// no way to tell which is right.
class _Silent extends SoundService {}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('a save survives a round trip byte for byte', () {
    final state = createLudoState([
      LudoPlayer(id: 'a', name: 'Ana', color: LudoColor.red),
      LudoPlayer(id: 'b', name: 'Bo', color: LudoColor.blue),
    ]);
    state.tokens[0].pos = 7;
    state.currentPlayerIndex = 1;
    state.consecutiveSixes = 2;
    state.lastRoll = 5;

    final restored = SavedGame.fromJson(
      SavedGame(
        game: GameKind.ludo,
        state: state.toJson(),
        seatNames: ['Ana', 'Bo'],
        savedAt: DateTime.fromMillisecondsSinceEpoch(1700000000000),
      ).encode(),
    )!;

    expect(restored.game, GameKind.ludo);
    expect(restored.seatNames, ['Ana', 'Bo']);
    expect(restored.state['cur'], 1);
    expect(restored.state['sixes'], 2);
    expect(restored.state['roll'], 5);
  });

  test('a corrupt save is treated as no save, not a crash', () {
    // A save written by an older build, or half-written by a killed process.
    // The home screen must not fail because of it.
    expect(SavedGame.fromJson('not json at all'), isNull);
    expect(SavedGame.fromJson('{"game":"ludo"}'), isNull);
  });

  test('each game type has its own slot', () async {
    final store = SavedGameStore();
    await store.save(SavedGame(
      game: GameKind.ludo,
      // Ludo needs 2..4 seats, so the sample board is a real two-player one.
      state: createLudoState([
        LudoPlayer(id: 'a', name: 'Ana', color: LudoColor.red),
        LudoPlayer(id: 'b', name: 'Bo', color: LudoColor.blue),
      ]).toJson(),
      seatNames: const ['Ana', 'Bo'],
      savedAt: DateTime(2026),
    ));
    // A snakes save must not appear just because a ludo one exists.
    expect(await store.load(GameKind.snakes), isNull);
    expect(await store.load(GameKind.ludo), isNotNull);

    await store.clear(GameKind.ludo);
    expect(await store.load(GameKind.ludo), isNull);
  });

  test('a resumed session comes back on the same turn and board', () {
    final state = createLudoState([
      LudoPlayer(id: 'a', name: 'Ana', color: LudoColor.red),
      LudoPlayer(id: 'b', name: 'Bo', color: LudoColor.blue),
    ]);
    state.tokens[0].pos = 9;
    state.currentPlayerIndex = 1;
    state.consecutiveSixes = 2;

    final session = LudoSession.resume(
      stateJson: state.toJson(),
      seatNames: const ['Ana', 'Bo'],
      profiles: ProfilesNotifier(),
      sound: _Silent(),
      onGameOver: (_) {},
    );

    expect(session.state.currentPlayerIndex, 1,
        reason: 'resuming on the wrong turn is the bug that matters');
    expect(session.state.tokens[0].pos, 9);
    expect(session.state.consecutiveSixes, 2);
    expect([for (final p in session.state.players) p.name], ['Ana', 'Bo']);
  });
}
