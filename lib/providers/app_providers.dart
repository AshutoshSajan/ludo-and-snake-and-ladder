import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../engine/core/player_profiles.dart';
import '../services/sound_service.dart';
import '../services/storage_service.dart';

/// App-wide providers: profiles (local leaderboard source), sound, storage.

final storageProvider = Provider<StorageService>((ref) => StorageService());

/// The admin session, when signed in at /admin.
///
/// The session's credential is the browser's HttpOnly cookie and never
/// lives here — this provider holds only the account snapshot the login
/// response carried. Watched by the home screen to keep the admin door
/// beside Settings for signed-in admins, and by the dashboard to end the
/// session when the server stops accepting the cookie (any 401 evades to
/// the login screen through [AdminSessionNotifier.signOut]).
///
/// There is no persistent restore: a page refresh re-enters the dashboard
/// with the cookie it kept, and the dashboard's first authenticated read
/// (its death watch on `/admin/me`) both proves the cookie and names the
/// operator. A momentary `null` state is therefore signed-nobody, and not
/// a signal to bounce anybody — the screens that care about identity read
/// it off the /admin/me response.
class AdminSession {
  const AdminSession({required this.email, required this.name});

  final String email;
  final String name;
}

final adminSessionProvider =
    NotifierProvider<AdminSessionNotifier, AdminSession?>(
  AdminSessionNotifier.new,
);

class AdminSessionNotifier extends Notifier<AdminSession?> {
  @override
  AdminSession? build() {
    // No restore stage: the cookie the browser kept IS the restored
    // session, and the dashboard proves it on its first read. This build
    // answers null every fresh process — the only consumers that persist
    // a session are its screens via the server's Set-Cookie.
    return null;
  }

  void signIn(AdminSession session) => state = session;

  void signOut() => state = null;
}

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
