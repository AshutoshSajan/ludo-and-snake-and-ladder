import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../engine/core/player_profiles.dart';
import '../services/admin_client.dart';
import '../services/server_url.dart';
import '../services/sound_service.dart';
import '../services/storage_service.dart';

/// App-wide providers: profiles (local leaderboard source), sound, storage.

final storageProvider = Provider<StorageService>((ref) => StorageService());

/// The admin session, when signed in at /admin.
///
/// The session's credential is the browser's HttpOnly cookie and never
/// lives here — this provider holds only the account snapshot that names
/// the operator. Watched by the home screen to keep the admin door beside
/// Settings for signed-in admins, and by the dashboard to end the session
/// when the server stops accepting the cookie (any 401 evades to the login
/// screen through [AdminSessionNotifier.signOut]).
///
/// A cold load starts null and asks the cookie, because the snapshot is
/// memory-only and a refresh would otherwise hide the admin door from the
/// very operator the cookie still admits: the browser kept the credential,
/// so `/admin/me` is asked once on first read and the answer lands here.
/// A 401/403 (no cookie, expired, revoked) or an unreachable server leaves
/// the state null — the door is a shortcut, and a session that cannot be
/// proven is not shown. Nothing here grants access: the dashboard still
/// proves the cookie on its own first read, so the worst a wrong answer can
/// do is hide a door.
class AdminSession {
  const AdminSession({required this.email, required this.name});

  final String email;
  final String name;
}

/// Builds the client the cold-load restore asks `/admin/me` with.
///
/// Null where there is no cookie lane: the credential is the browser's, and
/// native builds hold the session token in memory only, so a native restart
/// is signed out by definition. Also the test seam — overriding this keeps
/// the probe off the real socket.
final adminRestoreClientProvider = Provider<AdminClient Function()?>(
  (ref) => kIsWeb ? () => AdminClient(serverUrl: defaultServerUrl()) : null,
);

final adminSessionProvider =
    NotifierProvider<AdminSessionNotifier, AdminSession?>(
      AdminSessionNotifier.new,
    );

class AdminSessionNotifier extends Notifier<AdminSession?> {
  /// Set once this notifier is torn down, so a probe still in flight cannot
  /// write to a disposed state.
  bool _disposed = false;

  @override
  AdminSession? build() {
    ref.onDispose(() => _disposed = true);
    // Deliberately unawaited: build must answer synchronously, and a cold
    // load is legitimately signed-nobody until the server says otherwise.
    // Home rebuilds when the answer lands.
    unawaited(_restoreFromCookie());
    return null;
  }

  /// Asks the one question a page without a readable credential can ask.
  ///
  /// Silent by design: a signed-out browser is the ordinary case, not an
  /// error worth surfacing, and the screens that need identity read it off
  /// their own `/admin/me` response.
  Future<void> _restoreFromCookie() async {
    final buildClient = ref.read(adminRestoreClientProvider);
    if (buildClient == null) return;
    final client = buildClient();
    try {
      final me = await client.me();
      final user = me['user'];
      if (_disposed || state != null || user is! Map) return;
      final email = '${user['email'] ?? ''}';
      if (email.isEmpty) return;
      state = AdminSession(email: email, name: '${user['name'] ?? ''}');
    } on AdminException {
      // 401/403 is a dead cookie; anything else is an unreachable server.
      // Both answer the same: no door, no bounce.
    } catch (_) {
      // Transport failures are the same story as an unreachable server.
    } finally {
      client.close();
    }
  }

  void signIn(AdminSession session) => state = session;

  void signOut() => state = null;
}

final soundEnabledProvider = NotifierProvider<SoundToggle, bool>(
  SoundToggle.new,
);

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

final hapticsEnabledProvider = NotifierProvider<HapticsToggle, bool>(
  HapticsToggle.new,
);

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
final animationsEnabledProvider = NotifierProvider<AnimationsToggle, bool>(
  AnimationsToggle.new,
);

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
      ProfilesNotifier.new,
    );

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
