import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../engine/core/player_profiles.dart';
import '../services/admin_session_store.dart';
import '../services/sound_service.dart';
import '../services/storage_service.dart';

/// App-wide providers: profiles (local leaderboard source), sound, storage.

final storageProvider = Provider<StorageService>((ref) => StorageService());

/// The admin session, when signed in at /admin.
///
/// The token is what [AdminClient] rides as its Bearer header and what the
/// /admin surfaces use to re-open the dashboard. It survives a page refresh:
/// [AdminSessionNotifier] reads a persisted record at build time and writes
/// through on sign-in/out, so a reload at /admin/dashboard restores the same
/// operator rather than bouncing to the login form. Watched by the home
/// screen to keep the admin door beside Settings for signed-in admins.
///
/// [expiresAt] is milliseconds-since-epoch, the server's session expiry
/// reported at login. The server is the source of truth — the field lets the
/// store drop a dead record without showing a dashboard whose first request
/// would 401, and any 401 [AdminClient] returns ends the session here too.
class AdminSession {
  const AdminSession({
    required this.token,
    required this.email,
    required this.name,
    required this.expiresAt,
  });

  final String token;
  final String email;
  final String name;
  final int expiresAt;
}

final adminSessionProvider =
    NotifierProvider<AdminSessionNotifier, AdminSession?>(
  AdminSessionNotifier.new,
);

class AdminSessionNotifier extends Notifier<AdminSession?> {
  @override
  AdminSession? build() {
    // A fresh load restores the persisted session (web: localStorage; the
    // platform stub reads as signed out). An expired or corrupt record is
    // dropped inside the store, so null here means "no usable session".
    final record = restoreAdminSession();
    if (record == null) return null;
    return AdminSession(
      token: record.token,
      email: record.email,
      name: record.name,
      expiresAt: record.expiresAt,
    );
  }

  void signIn(AdminSession session) {
    state = session;
    persistAdminSession(
      AdminAuthRecord(
        token: session.token,
        email: session.email,
        name: session.name,
        expiresAt: session.expiresAt,
      ),
    );
  }

  void signOut() {
    state = null;
    forgetAdminSession();
  }
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
