import 'package:flutter_test/flutter_test.dart';
import 'package:game_club/services/sound_service.dart';

/// Sound playback itself needs platform channels, but the decisions that keep
/// it smooth — when a step tick is redundant and which player comes next — are
/// pure and pinned here.
void main() {
  group('step coalescing', () {
    test('folds ticks inside the 45 ms window into the first', () {
      final sound = SoundService();
      final start = DateTime(2026, 1, 1, 12);

      expect(sound.acceptStepAt(start), isTrue);
      expect(
        sound.acceptStepAt(start.add(const Duration(milliseconds: 20))),
        isFalse,
      );
      expect(
        sound.acceptStepAt(start.add(const Duration(milliseconds: 44))),
        isFalse,
      );
      expect(
        sound.acceptStepAt(start.add(const Duration(milliseconds: 45))),
        isTrue,
        reason: 'the window is exclusive at 45 ms',
      );
      expect(
        sound.acceptStepAt(start.add(const Duration(milliseconds: 60))),
        isFalse,
        reason: 'the window restarts from the last tick that played',
      );
      expect(
        sound.acceptStepAt(start.add(const Duration(milliseconds: 90))),
        isTrue,
      );
      sound.dispose();
    });
  });

  group('playback pool', () {
    test('round-robin hands each sound a different player', () {
      final sound = SoundService();

      expect(
        [for (var i = 0; i < 5; i++) sound.takeNextPlayerIndex()],
        [0, 1, 2, 3, 0],
      );
      expect(
        sound.playerCount,
        0,
        reason: 'choosing a slot must not construct platform players',
      );
      sound.dispose();
    });

    test('a disabled service never creates players', () async {
      final sound = SoundService()..enabled = false;

      await Future.wait([
        sound.tap(),
        sound.dice(),
        sound.move(),
        sound.step(),
        sound.message(),
      ]);

      expect(sound.playerCount, 0);
      sound.dispose();
    });
  });
}
