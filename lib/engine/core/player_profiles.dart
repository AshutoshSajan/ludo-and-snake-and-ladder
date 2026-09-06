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
    List<bool>? recentLudo,
    List<bool>? recentSnakes,
  })  : recentLudo = recentLudo ?? [],
        recentSnakes = recentSnakes ?? [];

  final String id;
  String name;
  int ludoGames;
  int ludoWins;
  int snakesGames;
  int snakesWins;

  /// Recent results, newest last (capped at 20) — powers streak stats.
  final List<bool> recentLudo;
  final List<bool> recentSnakes;

  static const _formCap = 20;

  double ludoWinRate() => ludoGames == 0 ? 0 : ludoWins / ludoGames;
  double snakesWinRate() => snakesGames == 0 ? 0 : snakesWins / snakesGames;

  /// Current win streak (consecutive most-recent wins), 0 if last was a loss.
  int ludoStreak() => _trailingWins(recentLudo);
  int snakesStreak() => _trailingWins(recentSnakes);

  /// Longest all-win run in the recorded form.
  int ludoBestStreak() => _bestRun(recentLudo);
  int snakesBestStreak() => _bestRun(recentSnakes);

  static int _trailingWins(List<bool> form) {
    var n = 0;
    for (var i = form.length - 1; i >= 0 && form[i]; i--, n++) {}
    return n;
  }

  static int _bestRun(List<bool> form) {
    var best = 0, cur = 0;
    for (final w in form) {
      cur = w ? cur + 1 : 0;
      if (cur > best) best = cur;
    }
    return best;
  }

  void recordGame(GameKind game, bool won) {
    switch (game) {
      case GameKind.ludo:
        ludoGames += 1;
        if (won) ludoWins += 1;
        recentLudo.add(won);
        if (recentLudo.length > _formCap) recentLudo.removeAt(0);
      case GameKind.snakes:
        snakesGames += 1;
        if (won) snakesWins += 1;
        recentSnakes.add(won);
        if (recentSnakes.length > _formCap) recentSnakes.removeAt(0);
    }
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'ludoGames': ludoGames,
        'ludoWins': ludoWins,
        'snakesGames': snakesGames,
        'snakesWins': snakesWins,
        'recentLudo': recentLudo,
        'recentSnakes': recentSnakes,
      };

  factory PlayerProfile.fromJson(Map<String, dynamic> j) => PlayerProfile(
        id: j['id'] as String,
        name: j['name'] as String,
        ludoGames: (j['ludoGames'] as num?)?.toInt() ?? 0,
        ludoWins: (j['ludoWins'] as num?)?.toInt() ?? 0,
        snakesGames: (j['snakesGames'] as num?)?.toInt() ?? 0,
        snakesWins: (j['snakesWins'] as num?)?.toInt() ?? 0,
        recentLudo:
            (j['recentLudo'] as List?)?.map((e) => e as bool).toList(),
        recentSnakes:
            (j['recentSnakes'] as List?)?.map((e) => e as bool).toList(),
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
