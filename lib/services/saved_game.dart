import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../engine/core/player_profiles.dart';

/// A local game that can be picked up where it was left.
///
/// Only local games. An online game is owned by the server — it survives the
/// tab closing on its own, and a local copy of it would be a second, competing
/// source of truth about who is where.
class SavedGame {
  const SavedGame({
    required this.game,
    required this.state,
    required this.seatNames,
    required this.savedAt,
  });

  final GameKind game;

  /// The engine's own `toJson()` output, so this class never has to know the
  /// shape of a board.
  final Map<String, dynamic> state;

  /// Names, kept alongside the state. The engine stores ids, and a profile can
  /// be deleted between saving and resuming; the name is what still renders.
  final List<String> seatNames;

  final DateTime savedAt;

  Map<String, dynamic> toJson() => {
        'game': game.name,
        'state': state,
        'seats': seatNames,
        'at': savedAt.millisecondsSinceEpoch,
      };

  static SavedGame? fromJson(String raw) {
    try {
      final j = jsonDecode(raw) as Map<String, dynamic>;
      return SavedGame(
        game: GameKind.values.firstWhere(
          (g) => g.name == j['game'],
          orElse: () => GameKind.ludo,
        ),
        state: Map<String, dynamic>.from(j['state'] as Map),
        seatNames: [for (final s in (j['seats'] as List? ?? [])) '$s'],
        savedAt: DateTime.fromMillisecondsSinceEpoch(j['at'] as int? ?? 0),
      );
    } catch (_) {
      // A save written by an older build, or half-written. Treated as "no
      // save" rather than a crash on the home screen.
      return null;
    }
  }

  String encode() => jsonEncode(toJson());
}

/// Persistence for [SavedGame], one slot per game type.
///
/// One slot each, not a list: the thing worth resuming is the game you were
/// last in, and keeping a history of stale boards would offer a menu of them
/// and no sensible way to choose.
class SavedGameStore {
  static const _prefix = 'savedGame.';

  static String _key(GameKind g) => '$_prefix${g.name}';

  Future<SavedGame?> load(GameKind game) async {
    final sp = await SharedPreferences.getInstance();
    final raw = sp.getString(_key(game));
    return raw == null ? null : SavedGame.fromJson(raw);
  }

  Future<void> save(SavedGame game) async {
    final sp = await SharedPreferences.getInstance();
    await sp.setString(_key(game.game), game.encode());
  }

  Future<void> clear(GameKind game) async {
    final sp = await SharedPreferences.getInstance();
    await sp.remove(_key(game));
  }
}
