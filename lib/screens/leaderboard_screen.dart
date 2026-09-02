import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../engine/core/player_profiles.dart';
import '../providers/app_providers.dart';

/// Local leaderboards: wins, games and win-rate per profile and game.
class LeaderboardScreen extends ConsumerWidget {
  const LeaderboardScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final profiles = ref.watch(profilesProvider);
    final ludo = [...profiles]..sort((a, b) => b.ludoWins.compareTo(a.ludoWins));
    final snakes = [...profiles]
      ..sort((a, b) => b.snakesWins.compareTo(a.snakesWins));

    return Scaffold(
      appBar: AppBar(title: const Text('Leaderboards')),
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
  Widget trailing(PlayerProfile p) => _stat(p.ludoWins, p.ludoGames);
}

class _SnakesStats implements _StatsAdapter {
  @override
  Widget trailing(PlayerProfile p) => _stat(p.snakesWins, p.snakesGames);
}

Widget _stat(int wins, int games) {
  final rate = games == 0 ? 0 : (wins / games * 100).round();
  return Row(
    mainAxisSize: MainAxisSize.min,
    children: [
      Text('$wins wins',
          style: const TextStyle(fontWeight: FontWeight.w700)),
      const SizedBox(width: 10),
      Text('$games games · $rate%',
          style: const TextStyle(color: Colors.white54, fontSize: 12)),
    ],
  );
}
