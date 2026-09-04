import 'dart:math';

import 'package:flutter/services.dart';
import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/foundation.dart';

/// Plays the synthesized sound effects bundled in assets/sounds/.
/// Errors are swallowed silently: a missing sound must never break gameplay.
class SoundService {
  SoundService();

  /// Created lazily on first play — constructing [AudioPlayer] touches
  /// platform channels, which must not happen until a sound is needed
  /// (and makes SoundService subclasses safe to create in tests).
  AudioPlayer? _player;
  bool enabled = true;
  final _rng = Random();

  Future<void> _play(String name) async {
    if (!enabled) return;
    try {
      final player = _player ??= AudioPlayer();
      await player.stop();
      await player.play(AssetSource('sounds/$name.wav'),
            volume: 0.6 + _rng.nextDouble() * 0.15);
    } catch (e) {
      if (kDebugMode) debugPrint('sound $name failed: $e');
    }
  }

  Future<void> tap() => _play('tap');
  Future<void> dice() => _play('dice');
  Future<void> move() => _play('move');
  Future<void> step() => _play('step');
  Future<void> capture() => _play('capture');
  Future<void> ladder() => _play('ladder');
  Future<void> snake() => _play('snake');
  Future<void> home() => _play('home');
  Future<void> safe() => _play('safe');
  Future<void> win() => _play('win');
  Future<void> champion() => _play('champion');

  void dispose() => _player?.dispose();
}

/// Centralized haptics; no-ops on platforms without a vibrator.
class Haptics {
  static void light() => HapticFeedback.lightImpact();
  static void medium() => HapticFeedback.mediumImpact();
  static void heavy() => HapticFeedback.heavyImpact();
  static void success() => HapticFeedback.vibrate();
}
