import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../engine/core/player_profiles.dart';
import '../services/sound_service.dart';
import '../services/storage_service.dart';

/// App-wide providers: profiles (local leaderboard source), sound, storage.

final storageProvider = Provider<StorageService>((ref) => StorageService());

final soundEnabledProvider =
    NotifierProvider<SoundToggle, bool>(SoundToggle.new);

class SoundToggle extends Notifier<bool> {
  @override
  bool build() {
    // Resolved up front: the load can outlive this provider, and a disposed
    // Ref refuses to answer `read` from 3.0 on.
    final storage = ref.read(storageProvider);
    final sound = ref.read(soundServiceProvider);
    storage.loadSoundEnabled().then((v) {
      if (!ref.mounted) return;
      state = v;
      sound.enabled = v;
    });
    return true;
  }

  void toggle() {
    state = !state;
    ref.read(soundServiceProvider).enabled = state;
    ref.read(storageProvider).saveSoundEnabled(state);
  }
}

final hapticsEnabledProvider =
    NotifierProvider<HapticsToggle, bool>(HapticsToggle.new);

class HapticsToggle extends Notifier<bool> {
  @override
  bool build() {
    final storage = ref.read(storageProvider);
    storage.loadHapticsEnabled().then((v) {
      if (!ref.mounted) return;
      state = v;
      Haptics.enabled = v;
    });
    return true;
  }

  void toggle() {
    state = !state;
    Haptics.enabled = state;
    ref.read(storageProvider).saveHapticsEnabled(state);
  }
}

/// Battery saver: off disables the continuous board effects (breathing turn
/// glow, spinning selection rings). One-shot feedback like the dice tumble
/// and token hops still play — they stop by themselves in under a second.
final animationsEnabledProvider =
    NotifierProvider<AnimationsToggle, bool>(AnimationsToggle.new);

class AnimationsToggle extends Notifier<bool> {
  @override
  bool build() {
    final storage = ref.read(storageProvider);
    storage.loadAnimationsEnabled().then((v) {
      if (!ref.mounted) return;
      state = v;
    });
    return true;
  }

  void toggle() {
    state = !state;
    ref.read(storageProvider).saveAnimationsEnabled(state);
  }
}

final soundServiceProvider = Provider<SoundService>((ref) {
  final s = SoundService();
  ref.onDispose(s.dispose);
  return s;
});

final profilesProvider =
    NotifierProvider<ProfilesNotifier, List<PlayerProfile>>(
        ProfilesNotifier.new);

class ProfilesNotifier extends Notifier<List<PlayerProfile>> {
  PlayerRegistry _registry = PlayerRegistry();

  /// The first frame shows no profiles: `build` has to hand back a value
  /// synchronously, so the list fills in when storage answers. That is the
  /// same behaviour as before, when `load()` ran right after construction.
  @override
  List<PlayerProfile> build() {
    _registry = PlayerRegistry();
    final storage = ref.read(storageProvider);
    storage.loadProfiles().then((registry) {
      if (!ref.mounted) return;
      _registry = registry;
      state = registry.profiles.toList();
    });
    return const [];
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
    ref.read(storageProvider).saveProfiles(_registry).catchError((e) {
      if (kDebugMode) debugPrint('profile save failed: $e');
      return;
    });
  }
}
