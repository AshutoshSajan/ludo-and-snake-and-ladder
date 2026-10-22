import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Plays the synthesized sound effects bundled in assets/sounds/.
///
/// Effects are short and often overlap (a step tick under a capture, the dice
/// under a chat chime), so playback runs through a small round-robin pool
/// instead of one player that would stop the previous effect mid-note.
/// Errors are swallowed silently: a missing sound must never break gameplay.
class SoundService {
  SoundService();

  /// Four players cover every overlap the game produces (a move's step ticks,
  /// the dice, an outcome tick and a chat chime) without a fifth sound cutting
  /// one of them off.
  static const int _poolSize = 4;

  /// One stable level for every effect: level jumps between overlapping sounds
  /// read as stutter, not as emphasis.
  static const double _volume = 0.75;

  /// Step ticks closer together than this are one movement, not several
  /// sounds; without the window a fast walk machine-guns into a buzz.
  static const Duration _stepGap = Duration(milliseconds: 45);

  /// Created lazily on first play — constructing [AudioPlayer] touches
  /// platform channels, which must not happen until a sound is needed
  /// (and makes SoundService subclasses safe to create in tests).
  final List<AudioPlayer> _players = [];
  final Set<AudioPlayer> _prepared = {};
  int _nextPlayer = 0;
  DateTime? _lastStep;
  bool _disposed = false;

  bool enabled = true;

  /// How many players the pool currently holds. Visible so tests can prove no
  /// platform players exist until a sound actually plays.
  @visibleForTesting
  int get playerCount => _players.length;

  /// Whether a step arriving at [now] should play. Leading-edge throttle: the
  /// first tick of a burst sounds and later ticks inside [_stepGap] fold into
  /// it. Only played ticks move the window, so a long walk keeps ticking.
  @visibleForTesting
  bool acceptStepAt(DateTime now) {
    final last = _lastStep;
    if (last != null && now.difference(last) < _stepGap) return false;
    _lastStep = now;
    return true;
  }

  /// The next pool slot. Round-robin, so a new effect never reuses the player
  /// that may still be playing the previous one.
  @visibleForTesting
  int takeNextPlayerIndex() {
    final index = _nextPlayer;
    _nextPlayer = (_nextPlayer + 1) % _poolSize;
    return index;
  }

  AudioPlayer _nextPlayerFor() {
    if (_players.isEmpty) {
      // Build off to the side: if construction throws, the service keeps an
      // empty list and the next play retries instead of indexing a short pool.
      final players = [for (var i = 0; i < _poolSize; i++) AudioPlayer()];
      _players.addAll(players);
    }
    return _players[takeNextPlayerIndex()];
  }

  /// Low latency is a hint, not a requirement: some backends reject or ignore
  /// it, and media-player mode still plays the sound. Preparation is once per
  /// player, and [_prepared] is updated synchronously so two simultaneous
  /// sounds cannot configure the same player twice.
  Future<void> _prepare(AudioPlayer player) async {
    if (!_prepared.add(player)) return;
    try {
      await player.setPlayerMode(PlayerMode.lowLatency);
    } catch (e) {
      if (kDebugMode) debugPrint('sound low-latency mode failed: $e');
    }
    try {
      // Keep the native player alive between effects instead of releasing it
      // after every completion; that release is what makes the next hit slow.
      await player.setReleaseMode(ReleaseMode.stop);
    } catch (e) {
      if (kDebugMode) debugPrint('sound release mode failed: $e');
    }
  }

  Future<void> _play(String name) async {
    if (!enabled || _disposed) return;
    try {
      final player = _nextPlayerFor();
      await _prepare(player);
      await player.play(AssetSource('sounds/$name.wav'), volume: _volume);
    } catch (e) {
      if (kDebugMode) debugPrint('sound $name failed: $e');
    }
  }

  Future<void> tap() => _play('tap');
  Future<void> dice() => _play('dice');
  Future<void> move() => _play('move');

  /// One tick per hop of a walk animation. Rapid ticks are coalesced here so
  /// a fast multi-step move reads as a smooth run rather than a buzz.
  Future<void> step() {
    if (!enabled || !acceptStepAt(DateTime.now())) {
      return Future<void>.value();
    }
    return _play('step');
  }

  Future<void> capture() => _play('capture');
  Future<void> ladder() => _play('ladder');
  Future<void> snake() => _play('snake');
  Future<void> home() => _play('home');
  Future<void> safe() => _play('safe');
  Future<void> win() => _play('win');
  Future<void> champion() => _play('champion');

  /// The chat notification: a rising two-note chime, deliberately unlike the
  /// single low blips the game sounds use, so a message is never mistaken for
  /// a dice roll or a capture.
  Future<void> message() => _play('message');

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    final players = List<AudioPlayer>.of(_players);
    _players.clear();
    _prepared.clear();
    for (final player in players) {
      player.dispose().catchError((Object e) {
        if (kDebugMode) debugPrint('sound dispose failed: $e');
      });
    }
  }
}

/// Centralized haptics; no-ops on platforms without a vibrator.
/// [enabled] is the user-facing toggle persisted in Settings.
/// Platform errors are swallowed: haptics must never break gameplay.
class Haptics {
  static bool enabled = true;

  static void light() {
    if (enabled) HapticFeedback.lightImpact().catchError((_) {});
  }

  static void medium() {
    if (enabled) HapticFeedback.mediumImpact().catchError((_) {});
  }

  static void heavy() {
    if (enabled) HapticFeedback.heavyImpact().catchError((_) {});
  }

  static void success() {
    if (enabled) HapticFeedback.vibrate().catchError((_) {});
  }
}
