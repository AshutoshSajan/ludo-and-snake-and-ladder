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
/// so `/admin/me` is asked on each build and the answer lands here.
/// A 401/403 (no cookie, expired, revoked) or an unreachable server leaves
/// the state null — the door is a shortcut, and a session that cannot be
/// proven is not shown. Nothing here grants access: the dashboard still
/// proves the cookie on its own first read, so the worst a wrong answer can
/// do is hide a door.
class AdminSession {
  const AdminSession({required this.email, required this.name});

  /// The account snapshot out of a `{ok, user: {...}}` answer, or null when
  /// the body does not carry a usable one.
  ///
  /// Both call sites that read this body — the cold-load restore and the
  /// `/admin` hand-off — must agree on what counts as signed in, so the
  /// rule lives here once instead of being re-guessed per screen.
  static AdminSession? fromUser(Object? user) {
    if (user is! Map) return null;
    final email = '${user['email'] ?? ''}';
    if (email.isEmpty) return null;
    return AdminSession(email: email, name: '${user['name'] ?? ''}');
  }

  final String email;
  final String name;

  @override
  bool operator ==(Object other) =>
      other is AdminSession && other.email == email && other.name == name;

  @override
  int get hashCode => Object.hash(email, name);
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
  /// The most a probe may cost the door. Without one, a black-holed network
  /// (captive portal, dropped packets) holds the request for the OS TCP
  /// timeout and the door stays undecided for minutes — the one case the
  /// "unreachable server shows no door" answer was supposed to cover.
  static const _probeTimeout = Duration(seconds: 5);

  @override
  AdminSession? build() {
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
      final me = await client.me().timeout(_probeTimeout);
      final session = AdminSession.fromUser(me['user']);
      // Asked of the *current* ref, never a flag captured in build: a
      // rebuild hands the notifier a fresh Ref and fires onDispose for the
      // old one, so a "disposed" flag set there would drop every probe
      // after the first. Only real disposal may silence a probe in flight.
      if (session == null || !ref.mounted) return;
      // A sign-in that landed while the answer was in flight is fresher
      // than this probe, so it wins.
      if (state != null) return;
      state = session;
    } on AdminException {
      // 401/403 is a dead cookie; anything else is an unreachable server.
      // Both answer the same: no door, no bounce.
    } catch (_) {
      // Unreachable server, a timed-out probe, or a body that no longer
      // matches the contract: a fire-and-forget probe may surface none of
      // them, and an escaping error would become an unhandled async failure
      // in the shell.
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
