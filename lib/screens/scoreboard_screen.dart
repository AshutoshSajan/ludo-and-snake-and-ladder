import 'package:flutter/material.dart';

import '../services/online_client.dart';
import '../ui/theme.dart';
import '../ui/shared/player_avatar.dart';
import 'online_lobby_screen.dart';

/// The online scoreboard: career stats from the authoritative server's
/// SQLite store (GET /leaderboard).
class ScoreboardScreen extends StatefulWidget {
  const ScoreboardScreen({super.key, this.serverUrl, this.load});

  /// WebSocket base URL of the server; defaults to the usual local one.
  final String? serverUrl;

  /// Overridable for tests: the widget tests feed canned futures so each of
  /// the three "no scores" states can be shown without a live server.
  final Future<LeaderboardData> Function(String serverUrl)? load;

  @override
  State<ScoreboardScreen> createState() => _ScoreboardScreenState();
}

class _ScoreboardScreenState extends State<ScoreboardScreen> {
  late Future<LeaderboardData> _future;

  /// Which board is shown: 'ludo', 'snakes', or null for the combined one.
  /// The server records the game on every result, so each game gets its own
  /// career stats instead of one merged list.
  String? _game;

  String get _serverUrl =>
      widget.serverUrl ?? OnlineLobbyScreen.defaultServerUrl();

  Future<LeaderboardData> _fetch() {
    final load = widget.load;
    if (load != null) return load(_serverUrl);
    return OnlineClient.fetchLeaderboard(_serverUrl, game: _game);
  }

  @override
  void initState() {
    super.initState();
    _future = _fetch();
  }

  void _reload() => setState(() {
    _future = _fetch();
  });

  void _selectGame(String? game) {
    if (_game == game) return;
    setState(() {
      _game = game;
      _future = _fetch();
    });
  }

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
          if (snap.hasError) return _error(snap.error!);
          final data = snap.data!;
          return Column(
            children: [
              // The tabs sit outside the FutureBuilder so switching games is
              // instant to tap and the selection survives a reload. They are
              // only worth showing once the server has said it can split the
              // board; an older server would offer a Snakes tab that could
              // only ever come back with the combined list.
              if (data.hasPerGameCounts) _tabs(data),
              Expanded(
                child: data.rows.isEmpty
                    ? _empty(data.games)
                    : RefreshIndicator(
                        onRefresh: () async => _reload(),
                        child: ListView(
                          padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
                          children: [
                            Text(
                              // Both numbers, because a tab labelled with a
                              // count invites the reader to compare it against
                              // the rows underneath — and the two are different
                              // quantities. "Ludo · 1 game" above two players
                              // reads as a broken ranking unless the header
                              // says plainly that one is games and the other is
                              // players.
                              '${data.games} '
                              '${data.games == 1 ? 'game' : 'games'} · '
                              '${data.rows.length} '
                              '${data.rows.length == 1 ? 'player' : 'players'}',
                              textAlign: TextAlign.center,
                              style: const TextStyle(
                                color: AppColors.ivoryDark,
                                fontSize: 13,
                              ),
                            ),
                            const SizedBox(height: 16),
                            ..._podium(data.rows),
                            for (var i = 3; i < data.rows.length; i++)
                              _row(i + 1, data.rows[i]),
                          ],
                        ),
                      ),
              ),
            ],
          );
        },
      ),
    );
  }

  /// Ludo / Snakes & Ladders / All, labelled with each game's finished count
  /// so an empty tab is visibly empty rather than looking broken.
  ///
  /// Iconless and scrollable on purpose. Three labelled segments with icons
  /// do not fit a phone's width, and a SegmentedButton that overflows clips
  /// its last segment — which made the Snakes tab simply absent rather than
  /// squashed. Losing the icons buys the room, and the horizontal scroll means
  /// a longer name or a bigger count can never hide a tab again.
  Widget _tabs(LeaderboardData data) {
    // The count is labelled "games" because it counts finished games, not the
    // players listed underneath. A bare number beside a game name reads as a
    // row count, and the two genuinely differ — 12 games can belong to 9
    // players — so "All 12" above 9 rows looked like broken ranking rather than
    // a label that never claimed to be a row count. The header above the list
    // spells out both quantities so the comparison resolves instead of
    // looking like a mismatch.
    String label(String g, int n) => '$g · $n ${n == 1 ? 'game' : 'games'}';
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 12, 12, 0),
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: SegmentedButton<String?>(
          segments: [
            ButtonSegment<String?>(
              value: 'ludo',
              label: Text(label('Ludo', data.ludoGames)),
            ),
            ButtonSegment<String?>(
              value: 'snakes',
              label: Text(label('Snakes', data.snakesGames)),
            ),
            ButtonSegment<String?>(
              value: null,
              label: Text(label('All', data.games)),
            ),
          ],
          selected: {_game},
          onSelectionChanged: (sel) => _selectGame(sel.first),
        ),
      ),
    );
  }

  /// The three "no scores" states say different things, and conflating them
  /// sends the player hunting for the wrong culprit: a server that answered
  /// 500 is running fine and needs its own log read, while a server that
  /// never answered is the one `dart run bin/server.dart` can fix.
  Widget _error(Object failure) {
    final detail = failure is LeaderboardServerException
        ? 'The server at $_serverUrl answered but could not load the scores '
              '(HTTP ${failure.statusCode}).\nIt is running — the problem is '
              'inside it, so read the server log.'
        // Do not tell someone on a hosted app to start a local server. This is
        // overwhelmingly a free-tier box still waking, which is a wait we have
        // already spent ~18s on; saying so is the difference between "this is
        // broken" and "try again in a moment".
        : 'Could not reach the server at $_serverUrl.\n'
              'It may be a free-tier host waking up — that takes up to half a '
              'minute. Tap refresh to try again.';
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.cloud_off, size: 40, color: AppColors.ivoryDark),
            const SizedBox(height: 12),
            Text(
              detail,
              textAlign: TextAlign.center,
              style: const TextStyle(
                color: AppColors.ivory,
                fontSize: 14,
                height: 1.5,
              ),
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
    // Naming the game matters: an empty Snakes tab on a server full of Ludo
    // games should say so, not read as a broken leaderboard.
    final game = switch (_game) {
      'ludo' => 'Ludo',
      'snakes' => 'Snakes & Ladders',
      _ => null,
    };
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Text(
          games == 0
              ? game == null
                    ? 'No games finished yet on this server.\nWin one — make history.'
                    : 'No $game games finished on this server yet.\n'
                          'Win one — make history.'
              : 'The $game leaderboard is empty.'
                    '${games == 1 ? 'game' : 'games'} finished, but nobody '
                    'has been recorded in it.',
          textAlign: TextAlign.center,
          style: const TextStyle(
            color: AppColors.ivory,
            fontSize: 15,
            height: 1.5,
          ),
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
                        Row(
                          children: [
                            // Derived from the seat id the leaderboard groups
                            // by, so the face always belongs to this player.
                            PlayerAvatar(seed: rows[i].seatId, size: 22),
                            const SizedBox(width: 8),
                            Expanded(
                              child: Text(
                                rows[i].name,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(
                                  color: AppColors.ivory,
                                  fontSize: 16,
                                  fontWeight: FontWeight.bold,
                                ),
                              ),
                            ),
                          ],
                        ),
                        Text(
                          '${rows[i].wins} wins · ${rows[i].games} games · '
                          'avg ${rows[i].avgRank.toStringAsFixed(1)}',
                          style: const TextStyle(
                            color: AppColors.ivoryDark,
                            fontSize: 12,
                          ),
                        ),
                      ],
                    ),
                  ),
                  Text(
                    medals[i],
                    style: TextStyle(
                      color: medalColors[i],
                      fontSize: 15,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
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
            child: Text(
              '$place',
              style: const TextStyle(color: AppColors.ivoryDark, fontSize: 14),
            ),
          ),
          PlayerAvatar(seed: r.seatId, size: 22),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              r.name,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(color: AppColors.ivory, fontSize: 15),
            ),
          ),
          Text(
            '${r.wins}W',
            style: const TextStyle(
              color: AppColors.gold,
              fontSize: 13,
              fontWeight: FontWeight.bold,
            ),
          ),
          const SizedBox(width: 12),
          Text(
            '${r.games}G',
            style: const TextStyle(color: AppColors.ivoryDark, fontSize: 13),
          ),
          const SizedBox(width: 12),
          Text(
            'avg ${r.avgRank.toStringAsFixed(1)}',
            style: const TextStyle(color: AppColors.ivoryDark, fontSize: 13),
          ),
        ],
      ),
    );
  }
}
