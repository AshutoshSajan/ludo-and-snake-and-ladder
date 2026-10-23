import 'package:flutter/material.dart';

import '../services/online_client.dart';
import '../ui/club_widgets.dart';
import '../ui/page_app_bar.dart';
import '../ui/shared/player_avatar.dart';
import '../ui/theme.dart';
import 'online_lobby_screen.dart';

/// The online scoreboard: career stats from the authoritative server's
/// SQLite store (GET /leaderboard).
///
/// This is a club standings page, not a bare table: the champion gets a
/// winner's card, second and third get their own medal cards, and the rest of
/// the field sits in one compact, scannable table. The numbers are the same
/// ones the server always sent — wins, games, average rank — but the page now
/// answers "who is on top, and how far ahead?" at a glance.
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

  /// The combined finished-game count, cached from the unfiltered board.
  ///
  /// A filtered response reports its own `games` count (the Snakes board says
  /// "5 games"), so using that number on the "All" tab made the tab claim
  /// "All · 5 games" the moment Snakes was chosen — even though All still
  /// meant the twelve-game combined board. The detail also undercounts on a
  /// server with pre-migration rows, whose game is unknown; only the "all"
  /// response carries the true combined total, so it is captured once and
  /// kept while the user moves between tabs.
  int? _allGames;

  String get _serverUrl =>
      widget.serverUrl ?? OnlineLobbyScreen.defaultServerUrl();

  Future<LeaderboardData> _fetch() async {
    final load = widget.load;
    final data = load != null
        ? await load(_serverUrl)
        : await OnlineClient.fetchLeaderboard(_serverUrl, game: _game);
    if (_game == null) _allGames = data.games;
    return data;
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
      appBar: PageAppBar(
        title: 'Leaderboard',
        actions: [
          // Inside the content column, so the refresh button lines up with the
          // right edge of the rows it reloads rather than floating at the far
          // edge of a 1900px window with nothing under it.
          IconButton(
            icon: const Icon(Icons.refresh),
            tooltip: 'Refresh leaderboard',
            onPressed: _reload,
          ),
        ],
      ),
      body: ClubBackground(
        child: FutureBuilder<LeaderboardData>(
          future: _future,
          builder: (context, snap) {
            if (snap.connectionState != ConnectionState.done) {
              // A free-tier host sleeps, and the request now waits ~18s for it
              // to wake. That wait used to be a bare spinner with no
              // explanation, which is indistinguishable from a hang — and from
              // the error that follows if it does eventually give up. The
              // socket path already says "Starting the game server…"; this uses
              // the same words so one habit covers both.
              return _statePanel(
                icon: Icons.emoji_events_outlined,
                iconColor: AppColors.gold,
                spinner: true,
                lines: const [
                  'Starting the leaderboard server…',
                  'A free-tier host sleeps — the first load can take a moment.',
                ],
              );
            }
            if (snap.hasError) return _error(snap.error!);
            final data = snap.data!;
            return ContentColumn(
              child: Column(
                children: [
                  // The tabs sit outside the rows so switching games is
                  // instant to tap and the selection survives a reload. They
                  // are only worth showing once the server has said it can
                  // split the board; an older server would offer a Snakes tab
                  // that could only ever come back with the combined list.
                  if (data.hasPerGameCounts) _tabs(data),
                  const SizedBox(height: 12),
                  // The board's identity and its summary stay put while the
                  // podium scrolls. Scrolling them away left the title half
                  // clipped under the fixed tabs, which read as a broken
                  // header rather than as content moving.
                  _standingsHeader(data),
                  const SizedBox(height: 14),
                  Expanded(
                    child: data.rows.isEmpty
                        ? _empty(data.games)
                        : RefreshIndicator(
                            onRefresh: () async => _reload(),
                            color: AppColors.gold,
                            backgroundColor: AppColors.feltLight,
                            child: ListView(
                              padding: const EdgeInsets.fromLTRB(16, 2, 16, 28),
                              children: [
                                _champion(data.rows.first),
                                if (data.rows.length > 1) ...[
                                  const SizedBox(height: 12),
                                  _runnersUp(data.rows),
                                ],
                                if (data.rows.length > 3) ...[
                                  const SizedBox(height: 20),
                                  _restTable(data.rows.sublist(3)),
                                ],
                              ],
                            ),
                          ),
                  ),
                ],
              ),
            );
          },
        ),
      ),
    );
  }

  // --------------------------------------------------------------- the top

  /// The page's own title, under the app bar: a trophy in a gold halo, the
  /// standings line, and the one summary that names both quantities.
  ///
  /// A tab labelled with a game count invites the reader to compare it against
  /// the rows underneath — and the two are different quantities. "Ludo · 1
  /// game" above two players reads as a broken ranking unless the summary says
  /// plainly that one is games and the other is players.
  Widget _standingsHeader(LeaderboardData data) {
    final games = data.games;
    final players = data.rows.length;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Column(
        children: [
          Row(
            children: [
              const ClubSeal(
                icon: Icons.emoji_events,
                size: 46,
                onPaper: false,
              ),
              const SizedBox(width: 12),
              // Flexible: the title and its subtitle are non-flex children of
              // this Row otherwise, so a narrow phone (or a wide accessibility
              // font) overflows the page instead of wrapping the subtitle.
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Text(
                      'Club standings',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontFamily: AppFonts.display,
                        color: AppColors.paper,
                        fontSize: 25,
                        fontWeight: FontWeight.w600,
                        height: 1.05,
                        letterSpacing: -0.3,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      _game == null
                          ? 'Career results across both games'
                          : _game == 'ludo'
                          ? 'Career results at the Ludo table'
                          : 'Career results on the Snakes board',
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontFamily: AppFonts.body,
                        color: AppColors.paperDeep,
                        fontSize: 11.5,
                        height: 1.4,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 7),
            decoration: BoxDecoration(
              color: AppColors.paper.withValues(alpha: 0.06),
              borderRadius: BorderRadius.circular(999),
              border: Border.all(color: AppColors.brass.withValues(alpha: 0.4)),
            ),
            child: Text(
              '$games ${games == 1 ? 'game' : 'games'} · '
              '$players ${players == 1 ? 'player' : 'players'}',
              textAlign: TextAlign.center,
              style: const TextStyle(
                fontFamily: AppFonts.body,
                color: AppColors.paper,
                fontSize: 12,
                fontWeight: FontWeight.w600,
                letterSpacing: 0.2,
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// Ludo / Snakes & Ladders / All, labelled with each game's finished count
  /// so an empty tab is visibly empty rather than looking broken.
  ///
  /// Pills instead of a SegmentedButton: the count makes each label wider than
  /// three equal segments allow on a phone, and a scrollable row of pills keeps
  /// every label readable without clipping the last one.
  Widget _tabs(LeaderboardData data) {
    String label(String g, int n) => '$g · $n ${n == 1 ? 'game' : 'games'}';
    final tabs = <({String? value, String label})>[
      (value: 'ludo', label: label('Ludo', data.ludoGames)),
      (value: 'snakes', label: label('Snakes', data.snakesGames)),
      // The all-tab total is the combined board's, not the current filtered
      // response's `games`. The first load is always All, so it is cached
      // before any filter can hide it.
      (value: null, label: label('All', _allGames ?? data.games)),
    ];
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 2),
      // Wrap, not a horizontal scroll: three "Game · N games" pills are wider
      // than a phone, and a scroll view clipped the selected "All" pill at the
      // right edge — leaving the current tab half readable with no hint that
      // it could be scrolled. Wrapping keeps every label whole; on a wide
      // screen all three stay on one centered row.
      child: Wrap(
        alignment: WrapAlignment.center,
        spacing: 8,
        runSpacing: 8,
        children: [
          for (var i = 0; i < tabs.length; i++)
            _GameTab(
              label: tabs[i].label,
              selected: _game == tabs[i].value,
              onTap: () => _selectGame(tabs[i].value),
            ),
        ],
      ),
    );
  }

  // ------------------------------------------------------------ the podium

  /// First place: the one card that is allowed to feel like a trophy.
  Widget _champion(LeaderboardRow r) {
    return ClubCard(
      accent: true,
      radius: 20,
      padding: EdgeInsets.zero,
      child: Stack(
        children: [
          // A washed-out trophy behind the name, so the card reads as the
          // winner's card even before the text is read.
          Positioned(
            right: -14,
            top: -18,
            child: Icon(
              Icons.emoji_events,
              size: 132,
              color: AppColors.brass.withValues(alpha: 0.1),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 19, 16, 16),
            child: Column(
              children: [
                Row(
                  children: [
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 10,
                        vertical: 4,
                      ),
                      decoration: BoxDecoration(
                        color: AppColors.surfaceRaised,
                        borderRadius: BorderRadius.circular(999),
                        border: Border.all(
                          color: AppColors.gold.withValues(alpha: 0.45),
                        ),
                      ),
                      child: const Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(
                            Icons.workspace_premium,
                            size: 14,
                            color: AppColors.gold,
                          ),
                          SizedBox(width: 5),
                          Text(
                            'CHAMPION',
                            style: TextStyle(
                              fontFamily: AppFonts.body,
                              color: AppColors.gold,
                              fontSize: 10,
                              fontWeight: FontWeight.w800,
                              letterSpacing: 1.1,
                            ),
                          ),
                        ],
                      ),
                    ),
                    const Spacer(),
                    const Text(
                      '1st',
                      style: TextStyle(
                        fontFamily: AppFonts.display,
                        color: AppColors.gold,
                        fontSize: 16,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 14),
                Row(
                  children: [
                    Container(
                      padding: const EdgeInsets.all(3),
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        border: Border.all(color: AppColors.brass, width: 2),
                      ),
                      child: ClipOval(
                        child: PlayerAvatar(seed: r.seatId, size: 52),
                      ),
                    ),
                    const SizedBox(width: 14),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            r.name,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              fontFamily: AppFonts.display,
                              color: AppColors.textPrimary,
                              fontSize: 24,
                              fontWeight: FontWeight.w600,
                              height: 1.05,
                            ),
                          ),
                          const SizedBox(height: 4),
                          Text(
                            '${r.wins} ${r.wins == 1 ? 'win' : 'wins'} in '
                            '${r.games} ${r.games == 1 ? 'game' : 'games'}',
                            style: const TextStyle(
                              fontFamily: AppFonts.body,
                              color: AppColors.textSecondary,
                              fontSize: 12,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 14),
                Container(
                  padding: const EdgeInsets.symmetric(vertical: 10),
                  decoration: BoxDecoration(
                    color: AppColors.surfaceDeep,
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(color: AppColors.paperEdge),
                  ),
                  child: Row(
                    children: [
                      _StatCell(
                        value: '${r.wins}',
                        label: 'WINS',
                        color: AppColors.gold,
                      ),
                      _statDivider(),
                      _StatCell(value: '${r.games}', label: 'GAMES'),
                      _statDivider(),
                      _StatCell(
                        value: r.avgRank.toStringAsFixed(1),
                        label: 'AVG RANK',
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _statDivider() =>
      Container(width: 1, height: 30, color: AppColors.paperEdge);

  /// Second and third beside each other. With only two players the second card
  /// takes the full width, which reads fine because there is no third to
  /// compare it with.
  Widget _runnersUp(List<LeaderboardRow> rows) {
    // Darker silver and bronze than the felt versions: these now sit on warm
    // paper, where the usual pale medal tints would disappear.
    const silver = Color(0xFF6F7B88);
    const bronze = Color(0xFF9A5B2D);
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(child: _runnerCard(2, rows[1], silver)),
        if (rows.length > 2) ...[
          const SizedBox(width: 12),
          Expanded(child: _runnerCard(3, rows[2], bronze)),
        ],
      ],
    );
  }

  Widget _runnerCard(int place, LeaderboardRow r, Color accent) {
    return ClubCard(
      radius: 16,
      padding: const EdgeInsets.all(12),
      background: AppColors.surfaceRaised,
      borderColor: accent.withValues(alpha: 0.45),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 24,
                height: 24,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: accent.withValues(alpha: 0.12),
                  border: Border.all(color: accent.withValues(alpha: 0.5)),
                ),
                child: Text(
                  '$place',
                  style: TextStyle(
                    fontFamily: AppFonts.body,
                    color: accent,
                    fontSize: 12,
                    fontWeight: FontWeight.w800,
                  ),
                ),
              ),
              const Spacer(),
              Icon(
                Icons.emoji_events,
                size: 15,
                color: accent.withValues(alpha: 0.8),
              ),
            ],
          ),
          const SizedBox(height: 10),
          Row(
            children: [
              ClipOval(child: PlayerAvatar(seed: r.seatId, size: 30)),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  r.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontFamily: AppFonts.display,
                    color: AppColors.textPrimary,
                    fontSize: 17,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            '${r.wins}W · ${r.games}G · avg ${r.avgRank.toStringAsFixed(1)}',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(
              fontFamily: AppFonts.body,
              color: AppColors.textSecondary,
              fontSize: 10.5,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    );
  }

  // ------------------------------------------------------------- the field

  /// The rest of the table: one card, column labels once, a divider between
  /// players. This is the part that has to fit ten people on a phone, so it
  /// stays a table rather than becoming ten more cards.
  Widget _restTable(List<LeaderboardRow> rows) {
    return ClubCard(
      radius: 18,
      padding: EdgeInsets.zero,
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(14, 13, 14, 8),
            child: Row(
              children: [
                const Icon(
                  Icons.format_list_numbered,
                  size: 15,
                  color: AppColors.gold,
                ),
                const SizedBox(width: 8),
                const Expanded(
                  child: Text(
                    'THE REST OF THE TABLE',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontFamily: AppFonts.body,
                      color: AppColors.textSecondary,
                      fontSize: 10.5,
                      fontWeight: FontWeight.w800,
                      letterSpacing: 1.0,
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                Text(
                  '${rows.length} ${rows.length == 1 ? 'player' : 'players'}',
                  style: const TextStyle(
                    fontFamily: AppFonts.body,
                    color: AppColors.textMuted,
                    fontSize: 10.5,
                  ),
                ),
              ],
            ),
          ),
          _fieldLabels(),
          for (var i = 0; i < rows.length; i++) ...[
            if (i > 0)
              const Divider(
                height: 1,
                thickness: 1,
                color: AppColors.paperEdge,
                indent: 14,
                endIndent: 14,
              ),
            _fieldRow(i + 4, rows[i]),
          ],
        ],
      ),
    );
  }

  Widget _fieldLabels() => const Padding(
    padding: EdgeInsets.fromLTRB(14, 0, 14, 6),
    child: Row(
      children: [
        SizedBox(width: 26),
        SizedBox(width: 8),
        SizedBox(width: 30),
        SizedBox(width: 10),
        Expanded(
          child: Text(
            'PLAYER',
            style: TextStyle(
              fontFamily: AppFonts.body,
              color: AppColors.textMuted,
              fontSize: 9.5,
              fontWeight: FontWeight.w700,
              letterSpacing: 0.8,
            ),
          ),
        ),
        SizedBox(
          width: 38,
          child: Text(
            'W',
            textAlign: TextAlign.right,
            style: TextStyle(
              fontFamily: AppFonts.body,
              color: AppColors.textMuted,
              fontSize: 9.5,
              fontWeight: FontWeight.w700,
            ),
          ),
        ),
        SizedBox(
          width: 34,
          child: Text(
            'G',
            textAlign: TextAlign.right,
            style: TextStyle(
              fontFamily: AppFonts.body,
              color: AppColors.textMuted,
              fontSize: 9.5,
              fontWeight: FontWeight.w700,
            ),
          ),
        ),
        SizedBox(
          width: 54,
          child: Text(
            'AVG',
            textAlign: TextAlign.right,
            style: TextStyle(
              fontFamily: AppFonts.body,
              color: AppColors.textMuted,
              fontSize: 9.5,
              fontWeight: FontWeight.w700,
            ),
          ),
        ),
      ],
    ),
  );

  Widget _fieldRow(int place, LeaderboardRow r) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(14, 10, 14, 10),
      child: Row(
        children: [
          SizedBox(
            width: 26,
            child: Text(
              '$place',
              textAlign: TextAlign.center,
              style: const TextStyle(
                fontFamily: AppFonts.body,
                color: AppColors.textMuted,
                fontSize: 12.5,
              ),
            ),
          ),
          const SizedBox(width: 8),
          PlayerAvatar(seed: r.seatId, size: 30),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              r.name,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                fontFamily: AppFonts.body,
                color: AppColors.textPrimary,
                fontSize: 14,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
          SizedBox(
            width: 38,
            child: Text(
              '${r.wins}W',
              textAlign: TextAlign.right,
              style: const TextStyle(
                fontFamily: AppFonts.body,
                color: AppColors.gold,
                fontSize: 13,
                fontWeight: FontWeight.w800,
              ),
            ),
          ),
          SizedBox(
            width: 34,
            child: Text(
              '${r.games}G',
              textAlign: TextAlign.right,
              style: const TextStyle(
                fontFamily: AppFonts.body,
                color: AppColors.textSecondary,
                fontSize: 12,
              ),
            ),
          ),
          SizedBox(
            width: 54,
            child: Text(
              'avg ${r.avgRank.toStringAsFixed(1)}',
              textAlign: TextAlign.right,
              style: const TextStyle(
                fontFamily: AppFonts.body,
                color: AppColors.textMuted,
                fontSize: 11.5,
              ),
            ),
          ),
        ],
      ),
    );
  }

  // ------------------------------------------------------- empty / failure

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
    return _statePanel(
      icon: Icons.cloud_off,
      iconColor: AppColors.gold,
      lines: [detail],
      action: OutlinedButton.icon(
        icon: const Icon(Icons.refresh, size: 18),
        label: const Text('Retry'),
        onPressed: _reload,
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
    final board = game ?? 'combined';
    final count = '$games ${games == 1 ? 'game' : 'games'}';
    final message = games == 0
        ? game == null
              ? 'No games finished yet on this server.\nWin one — make history.'
              : 'No $game games finished on this server yet.\n'
                    'Win one — make history.'
        : 'The $board leaderboard is empty.\n'
              '$count finished, but nobody has been recorded in it.';
    return _statePanel(
      icon: Icons.emoji_events_outlined,
      iconColor: AppColors.gold,
      lines: [message],
    );
  }

  /// One card for loading, empty and failed states, so those three never look
  /// like a different app from the standings they stand in for.
  Widget _statePanel({
    required IconData icon,
    required Color iconColor,
    required List<String> lines,
    Widget? action,
    bool spinner = false,
  }) {
    return ContentColumn(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: ClubCard(
          accent: true,
          radius: 22,
          padding: const EdgeInsets.fromLTRB(24, 28, 24, 24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 64,
                height: 64,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: AppColors.surfaceRaised,
                  border: Border.all(
                    color: AppColors.gold.withValues(alpha: 0.45),
                  ),
                ),
                child: spinner
                    ? const Padding(
                        padding: EdgeInsets.all(20),
                        child: CircularProgressIndicator(
                          strokeWidth: 2.5,
                          color: AppColors.gold,
                        ),
                      )
                    : Icon(icon, color: iconColor, size: 30),
              ),
              const SizedBox(height: 16),
              for (var i = 0; i < lines.length; i++) ...[
                if (i > 0) const SizedBox(height: 6),
                Text(
                  lines[i],
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    fontFamily: AppFonts.body,
                    color: i == 0
                        ? AppColors.textPrimary
                        : AppColors.textSecondary,
                    fontSize: i == 0 ? 14 : 12,
                    height: 1.5,
                    fontWeight: i == 0 ? FontWeight.w600 : FontWeight.w400,
                  ),
                ),
              ],
              if (action != null) ...[const SizedBox(height: 18), action],
            ],
          ),
        ),
      ),
    );
  }
}

/// One game tab: a 44px pill, gold when chosen and felt when not.
class _GameTab extends StatelessWidget {
  const _GameTab({
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      selected: selected,
      child: Material(
        color: selected
            ? AppColors.gold
            : AppColors.feltLight.withValues(alpha: 0.8),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(999),
          side: BorderSide(
            color: selected
                ? AppColors.gold
                : AppColors.gold.withValues(alpha: 0.22),
          ),
        ),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTap,
          child: ConstrainedBox(
            constraints: const BoxConstraints(minHeight: 44),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
              child: Text(
                label,
                style: TextStyle(
                  fontFamily: AppFonts.body,
                  color: selected ? AppColors.darkInk : AppColors.ivoryDark,
                  fontSize: 12.5,
                  fontWeight: selected ? FontWeight.w800 : FontWeight.w600,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// One number over its label on the champion card.
class _StatCell extends StatelessWidget {
  const _StatCell({
    required this.value,
    required this.label,
    this.color = AppColors.textPrimary,
  });

  final String value;
  final String label;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Expanded(
      child: Column(
        children: [
          Text(
            value,
            style: TextStyle(
              fontFamily: AppFonts.display,
              color: color,
              fontSize: 19,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 2),
          Text(
            label,
            style: const TextStyle(
              fontFamily: AppFonts.body,
              color: AppColors.textMuted,
              fontSize: 9.5,
              fontWeight: FontWeight.w700,
              letterSpacing: 1.0,
            ),
          ),
        ],
      ),
    );
  }
}
