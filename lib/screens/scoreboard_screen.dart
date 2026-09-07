import 'package:flutter/material.dart';

import '../services/online_client.dart';
import '../ui/theme.dart';
import 'online_lobby_screen.dart';

/// The online scoreboard: career stats from the authoritative server's
/// SQLite store (GET /leaderboard).
class ScoreboardScreen extends StatefulWidget {
  const ScoreboardScreen({super.key, this.serverUrl});

  /// WebSocket base URL of the server; defaults to the usual local one.
  final String? serverUrl;

  @override
  State<ScoreboardScreen> createState() => _ScoreboardScreenState();
}

class _ScoreboardScreenState extends State<ScoreboardScreen> {
  late Future<LeaderboardData> _future;

  String get _serverUrl =>
      widget.serverUrl ?? OnlineLobbyScreen.defaultServerUrl();

  @override
  void initState() {
    super.initState();
    _future = OnlineClient.fetchLeaderboard(_serverUrl);
  }

  void _reload() => setState(() {
        _future = OnlineClient.fetchLeaderboard(_serverUrl);
      });

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.felt,
      appBar: AppBar(
        backgroundColor: AppColors.feltLight,
        foregroundColor: AppColors.ivory,
        title: const Text('Leaderboard'),
        actions: [
          IconButton(icon: const Icon(Icons.refresh), onPressed: _reload),
        ],
      ),
      body: FutureBuilder<LeaderboardData>(
        future: _future,
        builder: (context, snap) {
          if (snap.connectionState != ConnectionState.done) {
            return const Center(child: CircularProgressIndicator());
          }
          if (snap.hasError) return _error();
          final data = snap.data!;
          if (data.rows.isEmpty) return _empty(data.games);
          return RefreshIndicator(
            onRefresh: () async => _reload(),
            child: ListView(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
              children: [
                Text(
                  '${data.games} '
                  '${data.games == 1 ? 'game' : 'games'} recorded here',
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                      color: AppColors.ivoryDark, fontSize: 13),
                ),
                const SizedBox(height: 16),
                ..._podium(data.rows),
                for (var i = 3; i < data.rows.length; i++)
                  _row(i + 1, data.rows[i]),
              ],
            ),
          );
        },
      ),
    );
  }

  Widget _error() {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.cloud_off, size: 40, color: AppColors.ivoryDark),
            const SizedBox(height: 12),
            Text(
              'Could not reach the server at $_serverUrl.\n'
              'Is `dart run bin/server.dart` running?',
              textAlign: TextAlign.center,
              style: const TextStyle(
                  color: AppColors.ivory, fontSize: 14, height: 1.5),
            ),
            const SizedBox(height: 16),
            OutlinedButton.icon(
              icon: const Icon(Icons.refresh, size: 18),
              label: const Text('Retry'),
              onPressed: _reload,
            ),
          ],
        ),
      ),
    );
  }

  Widget _empty(int games) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Text(
          games == 0
              ? 'No games finished yet on this server.\nWin one — make history.'
              : 'The leaderboard is empty.',
          textAlign: TextAlign.center,
          style:
              const TextStyle(color: AppColors.ivory, fontSize: 15, height: 1.5),
        ),
      ),
    );
  }

  /// The top three as highlighted cards; absent ranks are skipped.
  List<Widget> _podium(List<LeaderboardRow> rows) {
    const medalColors = [
      Color(0xFFD9A441), // gold
      Color(0xFF9FA8B0), // silver
      Color(0xFFA5682A), // bronze
    ];
    const medals = ['1st', '2nd', '3rd'];
    return [
      for (var i = 0; i < rows.length && i < 3; i++)
        Padding(
          padding: const EdgeInsets.only(bottom: 8),
          child: Card(
            color: AppColors.feltLight,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(12),
              side: BorderSide(color: medalColors[i], width: 1.5),
            ),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
              child: Row(
                children: [
                  Icon(Icons.emoji_events, color: medalColors[i], size: 28),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(rows[i].name,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                                color: AppColors.ivory,
                                fontSize: 16,
                                fontWeight: FontWeight.bold)),
                        Text(
                          '${rows[i].wins} wins · ${rows[i].games} games · '
                          'avg ${rows[i].avgRank.toStringAsFixed(1)}',
                          style: const TextStyle(
                              color: AppColors.ivoryDark, fontSize: 12),
                        ),
                      ],
                    ),
                  ),
                  Text(medals[i],
                      style: TextStyle(
                          color: medalColors[i],
                          fontSize: 15,
                          fontWeight: FontWeight.bold)),
                ],
              ),
            ),
          ),
        ),
    ];
  }

  Widget _row(int place, LeaderboardRow r) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        children: [
          SizedBox(
            width: 30,
            child: Text('$place',
                style:
                    const TextStyle(color: AppColors.ivoryDark, fontSize: 14)),
          ),
          Expanded(
            child: Text(r.name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(color: AppColors.ivory, fontSize: 15)),
          ),
          Text('${r.wins}W',
              style: const TextStyle(
                  color: AppColors.gold,
                  fontSize: 13,
                  fontWeight: FontWeight.bold)),
          const SizedBox(width: 12),
          Text('${r.games}G',
              style:
                  const TextStyle(color: AppColors.ivoryDark, fontSize: 13)),
          const SizedBox(width: 12),
          Text('avg ${r.avgRank.toStringAsFixed(1)}',
              style:
                  const TextStyle(color: AppColors.ivoryDark, fontSize: 13)),
        ],
      ),
    );
  }
}
