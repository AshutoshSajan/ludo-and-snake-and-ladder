import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../engine/core/player_profiles.dart';
import '../providers/app_providers.dart';
import '../ui/theme.dart';

/// Local leaderboards: wins, games and win-rate per profile and game.
///
/// These count games played *on this device*. The online board is a separate
/// screen with different numbers, because a local game is never reported to the
/// server — so this one cannot be a stale copy of that one, and vice versa.
class LeaderboardScreen extends ConsumerWidget {
  const LeaderboardScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final profiles = ref.watch(profilesProvider);
    final ludo = [...profiles]..sort((a, b) => b.ludoWins.compareTo(a.ludoWins));
    final snakes = [...profiles]
      ..sort((a, b) => b.snakesWins.compareTo(a.snakesWins));

    return Scaffold(
      appBar: AppBar(
        title: const Text('On this device'),
        // Without this the screen reads as the whole leaderboard, which is how
        // "Leaderboards" and "Online Leaderboard" ended up ambiguous on home.
        bottom: const PreferredSize(
          preferredSize: Size.fromHeight(20),
          child: Padding(
            padding: EdgeInsets.only(bottom: 8, left: 16, right: 16),
            child: Align(
              alignment: Alignment.centerLeft,
              child: Text(
                'Local games only — the online board is separate.',
                style: TextStyle(fontSize: 12, color: Colors.white54),
              ),
            ),
          ),
        ),
      ),
      body: profiles.isEmpty
          ? const Center(
              child: Text(
                'No players yet.\nCreate profiles when starting a game.',
                textAlign: TextAlign.center,
                style: TextStyle(color: Colors.white54),
              ),
            )
          : ListView(
              padding: const EdgeInsets.all(16),
              children: [
                _section(context, '🎲 Ludo', ludo, _LudoStats()),
                const SizedBox(height: 16),
                _section(context, '🐍 Snakes & Ladders', snakes, _SnakesStats()),
              ],
            ),
    );
  }

  Widget _section(BuildContext context, String title, List<PlayerProfile> list,
      _StatsAdapter adapter) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(title,
                style: const TextStyle(
                    fontSize: 18, fontWeight: FontWeight.w800)),
            const SizedBox(height: 8),
            for (var i = 0; i < list.length; i++)
              ListTile(
                dense: true,
                leading: i < 3
                    ? Text(['🥇', '🥈', '🥉'][i],
                        style: const TextStyle(fontSize: 20))
                    : Text('${i + 1}.',
                        style: const TextStyle(color: Colors.white54)),
                title: Text(list[i].name,
                    style: const TextStyle(fontWeight: FontWeight.w700)),
                trailing: adapter.trailing(list[i]),
              ),
          ],
        ),
      ),
    );
  }
}

abstract class _StatsAdapter {
  Widget trailing(PlayerProfile p);
}

class _LudoStats implements _StatsAdapter {
  @override
  Widget trailing(PlayerProfile p) =>
      _stat(p.ludoWins, p.ludoGames, p.ludoStreak(), p.ludoBestStreak());
}

class _SnakesStats implements _StatsAdapter {
  @override
  Widget trailing(PlayerProfile p) =>
      _stat(p.snakesWins, p.snakesGames, p.snakesStreak(), p.snakesBestStreak());
}

Widget _stat(int wins, int games, int streak, int best) {
  final rate = games == 0 ? 0 : (wins / games * 100).round();
  return Row(
    mainAxisSize: MainAxisSize.min,
    children: [
      Text('$wins wins',
          style: const TextStyle(fontWeight: FontWeight.w700)),
      const SizedBox(width: 10),
      Text('$games games · $rate%',
          style: const TextStyle(color: Colors.white54, fontSize: 12)),
      if (games > 0) ...[
        const SizedBox(width: 10),
        Tooltip(
          message: 'Current streak (longest: $best)',
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(streak >= 3 ? Icons.local_fire_department : Icons.stairs,
                  size: 14,
                  color: streak >= 3 ? AppColors.gold : Colors.white54),
              const SizedBox(width: 2),
              Text('$streak',
                  style: TextStyle(
                      fontSize: 12,
                      color:
                          streak >= 3 ? AppColors.gold : Colors.white54)),
            ],
          ),
        ),
      ],
    ],
  );
}
