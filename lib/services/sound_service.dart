import 'dart:math';

import 'package:flutter/services.dart';
import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/foundation.dart';

/// Plays the synthesized sound effects bundled in assets/sounds/.
/// Errors are swallowed silently: a missing sound must never break gameplay.
class SoundService {
  SoundService();

  final AudioPlayer _player = AudioPlayer();
  bool enabled = true;
  final _rng = Random();

  Future<void> _play(String name) async {
    if (!enabled) return;
    try {
      await _player.stop();
      await _player.play(AssetSource('sounds/$name.wav'),
          volume: 0.6 + _rng.nextDouble() * 0.15);
    } catch (e) {
      if (kDebugMode) debugPrint('sound $name failed: $e');
    }
  }

  Future<void> tap() => _play('tap');
  Future<void> dice() => _play('dice');
  Future<void> move() => _play('move');
  Future<void> capture() => _play('capture');
  Future<void> ladder() => _play('ladder');
  Future<void> snake() => _play('snake');
  Future<void> home() => _play('home');
  Future<void> win() => _play('win');

  void dispose() => _player.dispose();
}

/// Centralized haptics; no-ops on platforms without a vibrator.
class Haptics {
  static void light() => HapticFeedback.lightImpact();
  static void medium() => HapticFeedback.mediumImpact();
  static void heavy() => HapticFeedback.heavyImpact();
  static void success() => HapticFeedback.vibrate();
}
