/// Shared player profiles + local leaderboard stats.
///
/// A [PlayerProfile] is a named local user. Stats are tracked per game so
/// the leaderboard screens can show wins / games / win-rate.
library;

import 'dart:convert';

class PlayerProfile {
  PlayerProfile({
    required this.id,
    required this.name,
    this.ludoGames = 0,
    this.ludoWins = 0,
    this.snakesGames = 0,
    this.snakesWins = 0,
  });

  final String id;
  String name;
  int ludoGames;
  int ludoWins;
  int snakesGames;
  int snakesWins;

  double ludoWinRate() => ludoGames == 0 ? 0 : ludoWins / ludoGames;
  double snakesWinRate() => snakesGames == 0 ? 0 : snakesWins / snakesGames;

  void recordGame(GameKind game, bool won) {
    switch (game) {
      case GameKind.ludo:
        ludoGames += 1;
        if (won) ludoWins += 1;
      case GameKind.snakes:
        snakesGames += 1;
        if (won) snakesWins += 1;
    }
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'ludoGames': ludoGames,
        'ludoWins': ludoWins,
        'snakesGames': snakesGames,
        'snakesWins': snakesWins,
      };

  factory PlayerProfile.fromJson(Map<String, dynamic> j) => PlayerProfile(
        id: j['id'] as String,
        name: j['name'] as String,
        ludoGames: (j['ludoGames'] as num?)?.toInt() ?? 0,
        ludoWins: (j['ludoWins'] as num?)?.toInt() ?? 0,
        snakesGames: (j['snakesGames'] as num?)?.toInt() ?? 0,
        snakesWins: (j['snakesWins'] as num?)?.toInt() ?? 0,
      );
}

enum GameKind { ludo, snakes }

extension GameKindX on GameKind {
  String get label => switch (this) {
        GameKind.ludo => 'Ludo',
        GameKind.snakes => 'Snakes & Ladders',
      };
}

/// In-memory profile registry; persistence is injected as JSON strings so
/// the engine stays platform-independent.
class PlayerRegistry {
  PlayerRegistry({List<PlayerProfile>? profiles}) : _profiles = profiles ?? [];

  final List<PlayerProfile> _profiles;

  List<PlayerProfile> get profiles => List.unmodifiable(_profiles);

  PlayerProfile create(String name) {
    final p = PlayerProfile(
      id: 'p${DateTime.now().microsecondsSinceEpoch}',
      name: name,
    );
    _profiles.add(p);
    return p;
  }

  void remove(String id) => _profiles.removeWhere((p) => p.id == id);

  void rename(String id, String name) =>
      _profiles.firstWhere((p) => p.id == id).name = name;

  PlayerProfile? byId(String? id) =>
      id == null ? null : _profiles.where((p) => p.id == id).firstOrNull;

  /// Serialize / restore (used by the storage service).
  String encode() => jsonEncode(_profiles.map((p) => p.toJson()).toList());

  factory PlayerRegistry.decode(String raw) => PlayerRegistry(
        profiles: (jsonDecode(raw) as List)
            .map((e) => PlayerProfile.fromJson(e as Map<String, dynamic>))
            .toList(),
      );
}
