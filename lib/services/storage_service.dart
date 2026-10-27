import 'dart:convert';
import 'dart:math';

import 'package:shared_preferences/shared_preferences.dart';

import '../engine/core/player_profiles.dart';

/// Persistent local storage: player profiles, settings, stats.
class StorageService {
  static const _kProfiles = 'gc.profiles';
  static const _kSound = 'gc.soundEnabled';
  static const _kHaptics = 'gc.hapticsEnabled';
  static const _kAnimations = 'gc.animationsEnabled';
  static const _kOnlineId = 'gc.onlinePlayerId';
  static const _kOnlineName = 'gc.onlineName';
  static const _kTutorialAsked = 'gc.tutorialAsked';
  static const _kTutorialDone = 'gc.tutorialDone';

  /// Public aliases for the tutorial keys so tests can seed the real store
  /// (mock initial values) instead of guessing key strings twice.
  static const kTutorialAskedKey = _kTutorialAsked;
  static const kTutorialDoneKey = _kTutorialDone;

  Future<PlayerRegistry> loadProfiles() async {
    final sp = await SharedPreferences.getInstance();
    final raw = sp.getString(_kProfiles);
    if (raw == null || raw.isEmpty) return PlayerRegistry();
    try {
      return PlayerRegistry.decode(raw);
    } catch (_) {
      return PlayerRegistry();
    }
  }

  Future<void> saveProfiles(PlayerRegistry registry) async {
    final sp = await SharedPreferences.getInstance();
    await sp.setString(_kProfiles, registry.encode());
  }

  Future<bool> loadSoundEnabled() async {
    final sp = await SharedPreferences.getInstance();
    return sp.getBool(_kSound) ?? true;
  }

  Future<void> saveSoundEnabled(bool value) async {
    final sp = await SharedPreferences.getInstance();
    await sp.setBool(_kSound, value);
  }

  Future<bool> loadHapticsEnabled() async {
    final sp = await SharedPreferences.getInstance();
    return sp.getBool(_kHaptics) ?? true;
  }

  Future<void> saveHapticsEnabled(bool value) async {
    final sp = await SharedPreferences.getInstance();
    await sp.setBool(_kHaptics, value);
  }

  Future<bool> loadAnimationsEnabled() async {
    final sp = await SharedPreferences.getInstance();
    return sp.getBool(_kAnimations) ?? true;
  }

  Future<void> saveAnimationsEnabled(bool value) async {
    final sp = await SharedPreferences.getInstance();
    await sp.setBool(_kAnimations, value);
  }

  /// The online player id, generated once and then reused.
  ///
  /// The server keys every recorded result by seat id, so a fresh id per
  /// session meant every session was a different player: no career carried
  /// across games, and a new row on the leaderboard each time. Persisting it
  /// makes the same person the same player.
  Future<String> loadOnlinePlayerId() async {
    final sp = await SharedPreferences.getInstance();
    final existing = sp.getString(_kOnlineId);
    if (existing != null && existing.isNotEmpty) return existing;
    final generated =
        'p${DateTime.now().microsecondsSinceEpoch.toRadixString(36)}'
        '${Random().nextInt(1 << 16).toRadixString(36)}';
    await sp.setString(_kOnlineId, generated);
    return generated;
  }

  static const _kOnlineCredential = 'gc.onlineCredential';
  static const _kSeatCredential = 'gc.seatCredential';

  /// The friends credential: the device's private identity half.
  ///
  /// The seat id is public (it appears in rosters, chats and the
  /// leaderboard) and carries no authority; the friends server binds this
  /// device-held secret — SHA-256 hashed, never echoed — to that seat on
  /// first registration, and every friends call presents it as
  /// `Authorization: Bearer`. Generated beside the id it belongs to, with
  /// secure random and enough bits that the public id leaking elsewhere
  /// can never stand in for it.
  Future<String> loadOnlineCredential() async {
    final sp = await SharedPreferences.getInstance();
    final existing = sp.getString(_kOnlineCredential);
    if (existing != null && existing.isNotEmpty) return existing;
    // 32 bytes = 256 bits, base64url — the same shape the server's admin
    // session tokens mint, so neither side ever compares tokens shorter
    // than guesswork.
    final data = List<int>.generate(32, (_) => Random.secure().nextInt(256));
    final generated = base64Url.encode(data).replaceAll('=', '');
    await sp.setString(_kOnlineCredential, generated);
    return generated;
  }

  /// The display name last used online, so the connect form can offer it
  /// instead of asking for the same name every time.
  Future<String> loadOnlineName() async {
    final sp = await SharedPreferences.getInstance();
    return sp.getString(_kOnlineName) ?? '';
  }

  Future<void> saveOnlineName(String name) async {
    final sp = await SharedPreferences.getInstance();
    await sp.setString(_kOnlineName, name);
  }

  /// The game server's private seat-reclaim credential, as granted inside
  /// the [joined] response of the room authority. Persisted beside the id
  /// and name with the same lifetime — one device profile — because the
  /// server refuses a seat rewrite without it and a restart mid-game must
  /// still be able to present it (CWE-287). Distinct from the friends
  /// credential's `gc.onlineCredential`: that one the device generates for
  /// the friends server; this one the game server grants per room, so the
  /// key differs to keep neither secret from clobbering the other.
  Future<String> loadSeatCredential() async {
    final sp = await SharedPreferences.getInstance();
    return sp.getString(_kSeatCredential) ?? '';
  }

  Future<void> saveSeatCredential(String credential) async {
    final sp = await SharedPreferences.getInstance();
    await sp.setString(_kSeatCredential, credential);
  }

  /// Whether the home screen already offered the guided walkthrough.
  ///
  /// The ask is one per player: it is written the moment the player answers —
  /// either way — so a decline puts the dialog to rest permanently.
  Future<bool> loadTutorialAsked() async {
    final sp = await SharedPreferences.getInstance();
    return sp.getBool(_kTutorialAsked) ?? false;
  }

  Future<void> saveTutorialAsked(bool value) async {
    final sp = await SharedPreferences.getInstance();
    await sp.setBool(_kTutorialAsked, value);
  }

  /// Whether the walkthrough was ever completed ("Done"), so other screens
  /// can steer a replay without re-asking anything.
  Future<bool> loadTutorialDone() async {
    final sp = await SharedPreferences.getInstance();
    return sp.getBool(_kTutorialDone) ?? false;
  }

  Future<void> saveTutorialDone(bool value) async {
    final sp = await SharedPreferences.getInstance();
    await sp.setBool(_kTutorialDone, value);
  }

  /// Convenience JSON helpers for future use (settings blobs, sessions).
  static String encodeJson(Object? o) => jsonEncode(o);
  static dynamic decodeJson(String s) => jsonDecode(s);
}
