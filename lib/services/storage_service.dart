import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../engine/core/player_profiles.dart';

/// Persistent local storage: player profiles, settings, stats.
class StorageService {
  static const _kProfiles = 'gc.profiles';
  static const _kSound = 'gc.soundEnabled';

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

  /// Convenience JSON helpers for future use (settings blobs, sessions).
  static String encodeJson(Object? o) => jsonEncode(o);
  static dynamic decodeJson(String s) => jsonDecode(s);
}
