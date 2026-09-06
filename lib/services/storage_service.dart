import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../engine/core/player_profiles.dart';

/// Persistent local storage: player profiles, settings, stats.
class StorageService {
  static const _kProfiles = 'gc.profiles';
  static const _kSound = 'gc.soundEnabled';
  static const _kHaptics = 'gc.hapticsEnabled';
  static const _kAnimations = 'gc.animationsEnabled';

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

  /// Convenience JSON helpers for future use (settings blobs, sessions).
  static String encodeJson(Object? o) => jsonEncode(o);
  static dynamic decodeJson(String s) => jsonDecode(s);
}
