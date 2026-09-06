import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../engine/core/player_profiles.dart';
import '../services/sound_service.dart';
import '../services/storage_service.dart';

/// App-wide providers: profiles (local leaderboard source), sound, storage.

final storageProvider = Provider<StorageService>((ref) => StorageService());

final soundEnabledProvider =
    StateNotifierProvider<SoundToggle, bool>((ref) => SoundToggle(ref));

class SoundToggle extends StateNotifier<bool> {
  SoundToggle(this._ref) : super(true) {
    _ref.read(storageProvider).loadSoundEnabled().then((v) {
      state = v;
      _ref.read(soundServiceProvider).enabled = v;
    });
  }

  final Ref _ref;

  void toggle() {
    state = !state;
    _ref.read(soundServiceProvider).enabled = state;
    _ref.read(storageProvider).saveSoundEnabled(state);
  }
}

final hapticsEnabledProvider =
    StateNotifierProvider<HapticsToggle, bool>((ref) => HapticsToggle(ref));

class HapticsToggle extends StateNotifier<bool> {
  HapticsToggle(this._ref) : super(true) {
    _ref.read(storageProvider).loadHapticsEnabled().then((v) {
      state = v;
      Haptics.enabled = v;
    });
  }

  final Ref _ref;

  void toggle() {
    state = !state;
    Haptics.enabled = state;
    _ref.read(storageProvider).saveHapticsEnabled(state);
  }
}

/// Battery saver: off disables the continuous board effects (breathing turn
/// glow, spinning selection rings). One-shot feedback like the dice tumble
/// and token hops still play — they stop by themselves in under a second.
final animationsEnabledProvider =
    StateNotifierProvider<AnimationsToggle, bool>((ref) => AnimationsToggle(ref));

class AnimationsToggle extends StateNotifier<bool> {
  AnimationsToggle(this._ref) : super(true) {
    _ref.read(storageProvider).loadAnimationsEnabled().then((v) => state = v);
  }

  final Ref _ref;

  void toggle() {
    state = !state;
    _ref.read(storageProvider).saveAnimationsEnabled(state);
  }
}

final soundServiceProvider = Provider<SoundService>((ref) {
  final s = SoundService();
  ref.onDispose(s.dispose);
  return s;
});

final profilesProvider =
    StateNotifierProvider<ProfilesNotifier, List<PlayerProfile>>((ref) {
  final notifier = ProfilesNotifier(ref);
  notifier.load();
  return notifier;
});

class ProfilesNotifier extends StateNotifier<List<PlayerProfile>> {
  ProfilesNotifier(this._ref) : super(const []);

  final Ref _ref;
  late PlayerRegistry _registry = PlayerRegistry();

  Future<void> load() async {
    _registry = await _ref.read(storageProvider).loadProfiles();
    state = _registry.profiles.toList();
  }

  PlayerProfile create(String name) {
    final p = _registry.create(name);
    _persist();
    return p;
  }

  void remove(String id) {
    _registry.remove(id);
    _persist();
  }

  void rename(String id, String name) {
    _registry.rename(id, name);
    _persist();
  }

  PlayerProfile? byId(String? id) => _registry.byId(id);

  /// Record finished-game stats for local leaderboards.
  void recordResults(GameKind game, List<String> rankedProfileIds) {
    for (var i = 0; i < rankedProfileIds.length; i++) {
      final p = _registry.byId(rankedProfileIds[i]);
      if (p == null) continue;
      p.recordGame(game, i == 0);
    }
    _persist();
  }

  void _persist() {
    state = _registry.profiles.toList();
    _ref.read(storageProvider).saveProfiles(_registry).catchError((e) {
      if (kDebugMode) debugPrint('profile save failed: $e');
      return;
    });
  }
}
