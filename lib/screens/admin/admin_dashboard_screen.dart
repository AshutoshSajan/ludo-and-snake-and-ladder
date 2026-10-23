import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app_router.dart';
import '../../app_routes.dart';
import '../../providers/app_providers.dart';
import '../../services/admin_client.dart';
import '../../ui/club_widgets.dart';
import '../../ui/shared/player_avatar.dart';
import '../../ui/shared/table_alert.dart';
import '../../ui/theme.dart';
import 'admin_login_screen.dart';

/// Admin dashboard: overview stats, live + recent rooms, players with
/// ban/rename, and the moderation audit log. All data comes from the
/// same SQLite DB the server writes (rooms included).
class AdminDashboardScreen extends ConsumerStatefulWidget {
  const AdminDashboardScreen({super.key, required this.client});

  final AdminClient client;

  @override
  ConsumerState<AdminDashboardScreen> createState() =>
      _AdminDashboardScreenState();
}

/// Shape the Data tab passes around: the served table spec plus its
/// capabilities (the API returns exactly these fields).
typedef _TableSpec = ({
  String pk,
  List<String> columns,
  Set<String> editable,
  bool insertable,
  bool deletable,
});

const _adminTabLabels = [
  'Stats',
  'Rooms',
  'Players',
  'Users',
  'Audit',
  'Reports',
  'Data',
];

const _adminTabIcons = <IconData>[
  Icons.dashboard_outlined,
  Icons.meeting_room_outlined,
  Icons.people_outline,
  Icons.manage_accounts_outlined,
  Icons.history,
  Icons.bug_report_outlined,
  Icons.table_chart_outlined,
];

class _AdminDashboardScreenState extends ConsumerState<AdminDashboardScreen> {
  int _tab = 0;
  Future<Map<String, dynamic>>? _overview;
  Future<Map<String, dynamic>>? _rooms;
  Future<Map<String, dynamic>>? _players;
  Future<Map<String, dynamic>>? _audit;
  Future<Map<String, dynamic>>? _me;
  Future<Map<String, dynamic>>? _users;
  Future<Map<String, dynamic>>? _reports;
  Future<Map<String, dynamic>>? _tableRows;

  // Reports tab filters — the queue sorts actionable-first by default;
  // these narrow it down.
  String _repStatus = '';
  String _repCategory = '';
  String _repSort = 'priority';

  // Data tab selection.
  String _dataTableName = 'feedback';
  String _dataQuery = '';

  static const _dataTables = [
    'feedback',
    'results',
    'players',
    'admin_players',
    'admin_bans',
    'admin_rooms',
    'admin_audit',
    'auth_users',
    'auth_sessions',
  ];

  @override
  void initState() {
    super.initState();
    _reloadAll();
  }

  void _reloadAll() {
    setState(() {
      _overview = widget.client.overview();
      _me = widget.client.me();
      // Other tabs fetch lazily on first visit (_ensureTab): firing them
      // all here leaves futures nobody listens to when their tab never
      // opens — unhandled async errors, not just wasted requests.
      _rooms = null;
      _players = null;
      _audit = null;
      _users = null;
      _reports = null;
      _tableRows = null;
    });
    _ensureTab(_tab);
  }

  void _ensureTab(int i) {
    switch (i) {
      case 1:
        _rooms ??= widget.client.rooms();
      case 2:
        _players ??= widget.client.players();
      case 3:
        _users ??= widget.client.users();
      case 4:
        _audit ??= widget.client.audit();
      case 5:
        _reports ??= widget.client.feedback(
          status: _repStatus.isEmpty ? null : _repStatus,
          category: _repCategory.isEmpty ? null : _repCategory,
          sort: _repSort,
        );
      case 6:
        _tableRows ??= widget.client.table(_dataTableName, q: _dataQuery);
    }
  }

  void _selectTab(int i) {
    setState(() {
      _tab = i;
      _ensureTab(i);
    });
  }

  /// Re-fetches the reports queue with the current filters; called after
  /// every triage action and whenever a filter changes.
  void _reloadReports() {
    setState(() {
      _reports = widget.client.feedback(
        status: _repStatus.isEmpty ? null : _repStatus,
        category: _repCategory.isEmpty ? null : _repCategory,
        sort: _repSort,
      );
    });
  }

  void _reloadTable() {
    setState(() {
      _tableRows = widget.client.table(_dataTableName, q: _dataQuery);
    });
  }

  Future<void> _ban(String seatId) async {
    await widget.client.ban(seatId);
    _reloadAll();
  }

  Future<void> _unban(String seatId) async {
    await widget.client.unban(seatId);
    _reloadAll();
  }

  Future<void> _rename(String seatId) async {
    final ctrl = TextEditingController();
    final name = await showDialog<String>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('Rename player'),
        content: TextField(
          controller: ctrl,
          decoration: const InputDecoration(labelText: 'New name'),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(c),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(c, ctrl.text.trim()),
            child: const Text('Save'),
          ),
        ],
      ),
    );
    if (name != null && name.isNotEmpty) {
      await widget.client.rename(seatId, name);
      _reloadAll();
    }
  }

  Future<void> _closeRoom(String code) async {
    await widget.client.closeRoom(code);
    _reloadAll();
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final wide = constraints.maxWidth >= 1020;
        final extendedRail = constraints.maxWidth >= 1260;
        return Scaffold(
          backgroundColor: AppColors.felt,
          appBar: AppBar(
            title: FutureBuilder<Map<String, dynamic>>(
              future: _me,
              builder: (c, s) {
                final email = (s.data?['user'] as Map?)?['email'];
                return Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Text(
                      'Admin dashboard',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    if (email != null)
                      Text(
                        'Signed in as $email',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontFamily: AppFonts.body,
                          fontSize: 11.5,
                          fontWeight: FontWeight.normal,
                          color: AppColors.textSecondary,
                        ),
                      ),
                  ],
                );
              },
            ),
            actions: [
              IconButton(
                icon: const Icon(Icons.refresh),
                tooltip: 'Refresh data',
                onPressed: _reloadAll,
              ),
              IconButton(
                icon: const Icon(Icons.logout),
                tooltip: 'Sign out',
                onPressed: () async {
                  await widget.client.logout();
                  if (!context.mounted) return;
                  ref.read(adminSessionProvider.notifier).signOut();
                  resetAppScreen<void>(
                    context,
                    name: AppRoutes.admin,
                    builder: (_) => const AdminLoginScreen(),
                  );
                },
              ),
            ],
            bottom: wide
                ? null
                : PreferredSize(
                    preferredSize: const Size.fromHeight(62),
                    child: _AdminTabStrip(
                      selectedIndex: _tab,
                      onSelected: _selectTab,
                    ),
                  ),
          ),
          body: ClubBackground(
            child: SafeArea(
              top: false,
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  if (wide) ...[
                    NavigationRail(
                      selectedIndex: _tab,
                      onDestinationSelected: _selectTab,
                      extended: extendedRail,
                      labelType: extendedRail
                          ? null
                          : NavigationRailLabelType.all,
                      backgroundColor: AppColors.feltDeep,
                      groupAlignment: -0.9,
                      destinations: [
                        for (var i = 0; i < _adminTabLabels.length; i++)
                          NavigationRailDestination(
                            icon: Icon(_adminTabIcons[i]),
                            selectedIcon: Icon(_adminTabIcons[i]),
                            label: Text(_adminTabLabels[i]),
                          ),
                      ],
                    ),
                    VerticalDivider(
                      width: 1,
                      color: AppColors.gold.withValues(alpha: 0.18),
                    ),
                  ],
                  Expanded(child: _tabBody()),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _tabBody() => switch (_tab) {
    0 => _statsTab(),
    1 => _roomsTab(),
    2 => _playersTab(),
    3 => _usersTab(),
    4 => _auditTab(),
    5 => _reportsTab(),
    _ => _dataTab(),
  };

  Widget _header({
    required String title,
    required String subtitle,
    required IconData icon,
    Widget? trailing,
  }) {
    return ClubPageHeader(
      eyebrow: 'Back office',
      title: title,
      subtitle: subtitle,
      icon: icon,
      trailing: trailing,
    );
  }

  Widget _loading(String label) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 46),
      child: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const SizedBox(
              width: 26,
              height: 26,
              child: CircularProgressIndicator(
                strokeWidth: 2.6,
                color: AppColors.gold,
              ),
            ),
            const SizedBox(height: 14),
            Text(
              'Loading $label…',
              style: const TextStyle(
                fontFamily: AppFonts.body,
                color: AppColors.textSecondary,
                fontSize: 13,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _errorPanel(Object error, VoidCallback retry) {
    return ClubCard(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(
                Icons.cloud_off_outlined,
                color: AppColors.danger,
                size: 22,
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  'Could not reach the admin API',
                  style: Theme.of(context).textTheme.titleSmall
                      ?.copyWith(color: AppColors.ivory),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            '$error',
            style: const TextStyle(
              fontFamily: AppFonts.body,
              color: AppColors.textSecondary,
              fontSize: 12.5,
              height: 1.45,
            ),
          ),
          const SizedBox(height: 14),
          OutlinedButton.icon(
            onPressed: retry,
            icon: const Icon(Icons.refresh, size: 18),
            label: const Text('Try again'),
          ),
        ],
      ),
    );
  }

  Widget _empty({
    required IconData icon,
    required String title,
    required String message,
  }) {
    return ClubCard(
      padding: const EdgeInsets.fromLTRB(18, 20, 18, 20),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          ClubSeal(icon: icon, size: 44, onPaper: false),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: const TextStyle(
                    fontFamily: AppFonts.body,
                    color: AppColors.ivory,
                    fontSize: 14,
                    fontWeight: FontWeight.w800,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  message,
                  style: const TextStyle(
                    fontFamily: AppFonts.body,
                    color: AppColors.textSecondary,
                    fontSize: 12.5,
                    height: 1.5,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  String _dateLabel(num? millis) {
    if (millis == null || millis <= 0) return '—';
    final d = DateTime.fromMillisecondsSinceEpoch(millis.toInt()).toLocal();
    String two(int n) => n.toString().padLeft(2, '0');
    return '${d.year}-${two(d.month)}-${two(d.day)} '
        '${two(d.hour)}:${two(d.minute)}';
  }

  Widget _statsTab() => FutureBuilder<Map<String, dynamic>>(
    future: _overview,
    builder: (c, s) {
      final header = _header(
        title: 'Overview',
        subtitle: 'Live room health and the club ledger at a glance.',
        icon: Icons.dashboard_outlined,
      );
      if (!s.hasData) {
        return _AdminPage(
          children: [
            header,
            const SizedBox(height: 18),
            s.hasError
                ? _errorPanel(s.error!, _reloadAll)
                : _loading('the overview'),
          ],
        );
      }
      final d = s.data!;
      final live = d['live'] as Map? ?? {};
      final stored = d['stored'] as Map? ?? {};
      final liveTiles = [
        _AdminStatCard(
          icon: Icons.meeting_room_outlined,
          label: 'Live rooms',
          value: '${live['rooms'] ?? 0}',
        ),
        _AdminStatCard(
          icon: Icons.cable_outlined,
          label: 'Connections',
          value: '${live['connections'] ?? 0}',
        ),
        _AdminStatCard(
          icon: Icons.visibility_outlined,
          label: 'Spectators',
          value: '${live['spectators'] ?? 0}',
        ),
      ];
      final storedTiles = [
        _AdminStatCard(
          icon: Icons.table_rows_outlined,
          label: 'Total rooms',
          value: '${stored['totalRooms'] ?? 0}',
          accent: AppColors.ivory,
        ),
        _AdminStatCard(
          icon: Icons.groups_outlined,
          label: 'Total players',
          value: '${stored['totalPlayers'] ?? 0}',
          accent: AppColors.ivory,
        ),
        _AdminStatCard(
          icon: Icons.flag_outlined,
          label: 'Finished games',
          value: '${stored['finishedGames'] ?? 0}',
          accent: AppColors.ivory,
        ),
        _AdminStatCard(
          icon: Icons.block_outlined,
          label: 'Banned players',
          value: '${stored['bannedPlayers'] ?? 0}',
          accent: AppColors.danger,
        ),
      ];
      return _AdminPage(
        children: [
          header,
          const SizedBox(height: 20),
          const ClubSectionLabel('Live now'),
          _statGrid(liveTiles),
          const SizedBox(height: 20),
          const ClubSectionLabel('Stored in the club ledger'),
          _statGrid(storedTiles),
        ],
      );
    },
  );

  Widget _statGrid(List<Widget> tiles) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final columns = constraints.maxWidth >= 900
            ? 4
            : constraints.maxWidth >= 620
            ? 3
            : 2;
        const gap = 10.0;
        final width = (constraints.maxWidth - gap * (columns - 1)) / columns;
        return Wrap(
          spacing: gap,
          runSpacing: gap,
          children: [
            for (final tile in tiles) SizedBox(width: width, child: tile),
          ],
        );
      },
    );
  }

  Widget _roomsTab() => FutureBuilder<Map<String, dynamic>>(
    future: _rooms ??= widget.client.rooms(),
    builder: (c, s) {
      final header = _header(
        title: 'Rooms',
        subtitle: 'Tables in play right now, and the history behind them.',
        icon: Icons.meeting_room_outlined,
      );
      if (!s.hasData) {
        return _AdminPage(
          children: [
            header,
            const SizedBox(height: 18),
            s.hasError
                ? _errorPanel(s.error!, _reloadAll)
                : _loading('the rooms'),
          ],
        );
      }
      final live = (s.data!['live'] as List? ?? []).cast<Map>();
      final recent = (s.data!['recent'] as List? ?? []).cast<Map>();
      return _AdminPage(
        children: [
          header,
          const SizedBox(height: 20),
          ClubSectionLabel(
            'Live rooms',
            trailing: _AdminCountPill('${live.length} open'),
          ),
          if (live.isEmpty)
            _empty(
              icon: Icons.meeting_room_outlined,
              title: 'No tables are open',
              message:
                  'Live rooms appear here as soon as a host opens one. '
                  'The club is quiet.',
            )
          else
            for (final r in live)
              Padding(
                padding: const EdgeInsets.only(bottom: 10),
                child: _liveRoomCard(r),
              ),
          const SizedBox(height: 18),
          ClubSectionLabel(
            'Recent history',
            trailing: _AdminCountPill('${recent.length} stored'),
          ),
          if (recent.isEmpty)
            _empty(
              icon: Icons.history,
              title: 'No room history yet',
              message: 'Finished and closed rooms will collect here.',
            )
          else
            for (final r in recent)
              Padding(
                padding: const EdgeInsets.only(bottom: 10),
                child: _recentRoomCard(r),
              ),
        ],
      );
    },
  );

  Widget _liveRoomCard(Map r) {
    final code = '${r['code'] ?? '----'}';
    final started = r['started'] == true;
    return ClubCard(
      radius: 16,
      padding: const EdgeInsets.fromLTRB(14, 12, 8, 12),
      child: Row(
        children: [
          Container(
            width: 10,
            height: 10,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: started ? AppColors.sage : AppColors.gold,
              boxShadow: [
                BoxShadow(
                  color: (started ? AppColors.sage : AppColors.gold).withValues(
                    alpha: 0.45,
                  ),
                  blurRadius: 8,
                  spreadRadius: 1,
                ),
              ],
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  code,
                  style: const TextStyle(
                    fontFamily: AppFonts.display,
                    color: AppColors.ivory,
                    fontSize: 22,
                    fontWeight: FontWeight.w600,
                    letterSpacing: 2.4,
                    height: 1.05,
                  ),
                ),
                const SizedBox(height: 3),
                Text(
                  '${r['game'] ?? 'game'} · ${r['members'] ?? 0} at the table · '
                  '${started ? 'in play' : 'waiting to start'}',
                  style: const TextStyle(
                    fontFamily: AppFonts.body,
                    color: AppColors.textSecondary,
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
            ),
          ),
          TextButton(
            onPressed: () => _closeRoom(code),
            child: const Text('Close'),
          ),
        ],
      ),
    );
  }

  Widget _recentRoomCard(Map r) {
    final status = '${r['status'] ?? 'unknown'}';
    return ClubCard(
      radius: 16,
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
      child: Row(
        children: [
          const Icon(Icons.history, size: 18, color: AppColors.gold),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '${r['code'] ?? '----'} · ${r['game'] ?? 'game'}',
                  style: const TextStyle(
                    fontFamily: AppFonts.body,
                    color: AppColors.ivory,
                    fontSize: 13.5,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  'created ${_dateLabel(r['createdAt'] as num?)}',
                  style: const TextStyle(
                    fontFamily: AppFonts.body,
                    color: AppColors.textMuted,
                    fontSize: 11.5,
                  ),
                ),
              ],
            ),
          ),
          _AdminTag(label: status.toUpperCase()),
        ],
      ),
    );
  }

  Widget _playersTab() => FutureBuilder<Map<String, dynamic>>(
    future: _players ??= widget.client.players(),
    builder: (c, s) {
      final header = _header(
        title: 'Players',
        subtitle: 'Rename a player or close their seat at the table.',
        icon: Icons.people_outline,
      );
      if (!s.hasData) {
        return _AdminPage(
          children: [
            header,
            const SizedBox(height: 18),
            s.hasError
                ? _errorPanel(s.error!, _reloadAll)
                : _loading('the players'),
          ],
        );
      }
      final players = (s.data!['players'] as List? ?? []).cast<Map>();
      return _AdminPage(
        children: [
          header,
          const SizedBox(height: 20),
          ClubSectionLabel(
            'Player ledger',
            trailing: _AdminCountPill(
              '${players.length} ${players.length == 1 ? 'player' : 'players'}',
            ),
          ),
          if (players.isEmpty)
            _empty(
              icon: Icons.people_outline,
              title: 'No players yet',
              message:
                  'Players are recorded the first time they sit at a table.',
            )
          else
            for (final p in players)
              Padding(
                padding: const EdgeInsets.only(bottom: 10),
                child: _playerCard(p),
              ),
        ],
      );
    },
  );

  Widget _playerCard(Map p) {
    final seatId = '${p['seatId'] ?? ''}';
    final banned = p['banned'] as bool? ?? false;
    final name = '${p['name'] ?? ''}'.trim();
    return ClubCard(
      radius: 16,
      padding: const EdgeInsets.fromLTRB(12, 10, 6, 10),
      child: Row(
        children: [
          PlayerAvatar(seed: seatId, size: 42, circular: true),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Flexible(
                      child: Text(
                        name.isEmpty ? 'Unnamed player' : name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontFamily: AppFonts.body,
                          color: AppColors.ivory,
                          fontSize: 14,
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                    ),
                    if (banned) ...[
                      const SizedBox(width: 8),
                      const _AdminTag(label: 'BANNED', danger: true),
                    ],
                  ],
                ),
                const SizedBox(height: 3),
                Text(
                  banned
                      ? '$seatId · blocked from play'
                      : '$seatId · last seen ${_dateLabel(p['lastSeen'] as num?)}',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontFamily: AppFonts.body,
                    color: AppColors.textMuted,
                    fontSize: 11.5,
                  ),
                ),
              ],
            ),
          ),
          IconButton(
            icon: const Icon(Icons.edit_outlined, size: 20),
            tooltip: 'Rename',
            onPressed: () => _rename(seatId),
          ),
          IconButton(
            icon: Icon(
              banned ? Icons.check_circle_outline : Icons.block,
              size: 20,
            ),
            tooltip: banned ? 'Unban' : 'Ban',
            onPressed: () => banned ? _unban(seatId) : _ban(seatId),
          ),
        ],
      ),
    );
  }

  Future<void> _createUser() async {
    final emailCtrl = TextEditingController();
    final nameCtrl = TextEditingController();
    final passCtrl = TextEditingController();
    var role = 'moderator';
    final result = await showDialog<Map<String, String>>(
      context: context,
      builder: (c) => StatefulBuilder(
        builder: (c, setDialog) => AlertDialog(
          title: const Text('New user'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: emailCtrl,
                keyboardType: TextInputType.emailAddress,
                decoration: const InputDecoration(labelText: 'Email'),
              ),
              TextField(
                controller: nameCtrl,
                decoration: const InputDecoration(labelText: 'Name'),
              ),
              TextField(
                controller: passCtrl,
                obscureText: true,
                decoration: const InputDecoration(
                  labelText: 'Password (min 8 chars)',
                ),
              ),
              DropdownButtonFormField<String>(
                initialValue: role,
                items: const [
                  DropdownMenuItem(value: 'admin', child: Text('admin')),
                  DropdownMenuItem(
                    value: 'moderator',
                    child: Text('moderator'),
                  ),
                  DropdownMenuItem(value: 'user', child: Text('user')),
                ],
                onChanged: (v) => setDialog(() => role = v ?? 'moderator'),
                decoration: const InputDecoration(labelText: 'Role'),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(c),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(c, {
                'email': emailCtrl.text.trim(),
                'name': nameCtrl.text.trim(),
                'password': passCtrl.text,
                'role': role,
              }),
              child: const Text('Create'),
            ),
          ],
        ),
      ),
    );
    if (result != null) {
      try {
        await widget.client.createUser(
          email: result['email']!,
          password: result['password']!,
          name: result['name']!,
          role: result['role']!,
        );
      } on AdminException catch (e) {
        if (!mounted) return;
        showTableAlert(
          context,
          'Create failed: ${e.body}',
          icon: Icons.error_outline,
        );
        return;
      }
      _reloadAll();
    }
  }

  Widget _usersTab() => FutureBuilder<Map<String, dynamic>>(
    future: _users ??= widget.client.users(),
    builder: (c, s) {
      final header = _header(
        title: 'Users',
        subtitle: 'The people allowed through the back door.',
        icon: Icons.manage_accounts_outlined,
      );
      if (!s.hasData) {
        return _AdminPage(
          children: [
            header,
            const SizedBox(height: 18),
            s.hasError
                ? _errorPanel(s.error!, _reloadAll)
                : _loading('the users'),
          ],
        );
      }
      final users = (s.data!['users'] as List? ?? []).cast<Map>();
      return _AdminPage(
        children: [
          header,
          const SizedBox(height: 20),
          ClubSectionLabel(
            'Admin accounts',
            trailing: _AdminCountPill('${users.length} total'),
          ),
          Align(
            alignment: Alignment.centerRight,
            child: FilledButton.icon(
              onPressed: _createUser,
              icon: const Icon(Icons.person_add, size: 18),
              label: const Text('New user'),
            ),
          ),
          const SizedBox(height: 12),
          if (users.isEmpty)
            _empty(
              icon: Icons.manage_accounts_outlined,
              title: 'No users yet',
              message: 'Create the first admin or moderator account.',
            )
          else
            for (final u in users)
              Padding(
                padding: const EdgeInsets.only(bottom: 10),
                child: _userCard(u),
              ),
        ],
      );
    },
  );

  Widget _userCard(Map u) {
    final role = '${u['role'] ?? 'user'}';
    final isAdmin = role == 'admin';
    final name = '${u['name'] ?? ''}'.trim();
    return ClubCard(
      radius: 16,
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
      child: Row(
        children: [
          Container(
            width: 40,
            height: 40,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: AppColors.gold.withValues(alpha: 0.12),
              border: Border.all(color: AppColors.gold.withValues(alpha: 0.45)),
            ),
            child: Icon(
              isAdmin ? Icons.verified_user_outlined : Icons.person_outline,
              size: 20,
              color: AppColors.gold,
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  name.isEmpty ? 'Unnamed user' : name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontFamily: AppFonts.body,
                    color: AppColors.ivory,
                    fontSize: 14,
                    fontWeight: FontWeight.w800,
                  ),
                ),
                const SizedBox(height: 3),
                Text(
                  '${u['email'] ?? '—'}',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontFamily: AppFonts.body,
                    color: AppColors.textMuted,
                    fontSize: 11.5,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 8),
          _AdminTag(label: role.toUpperCase()),
        ],
      ),
    );
  }

  Widget _auditTab() => FutureBuilder<Map<String, dynamic>>(
    future: _audit ??= widget.client.audit(),
    builder: (c, s) {
      final header = _header(
        title: 'Audit log',
        subtitle: 'Every moderation action, newest first.',
        icon: Icons.history,
      );
      if (!s.hasData) {
        return _AdminPage(
          children: [
            header,
            const SizedBox(height: 18),
            s.hasError
                ? _errorPanel(s.error!, _reloadAll)
                : _loading('the audit log'),
          ],
        );
      }
      final items = (s.data!['audit'] as List? ?? []).cast<Map>();
      return _AdminPage(
        children: [
          header,
          const SizedBox(height: 20),
          ClubSectionLabel(
            'Recent actions',
            trailing: _AdminCountPill('${items.length} entries'),
          ),
          if (items.isEmpty)
            _empty(
              icon: Icons.history,
              title: 'Nothing to audit yet',
              message: 'Bans, renames and room closures will be recorded here.',
            )
          else
            for (final e in items)
              Padding(
                padding: const EdgeInsets.only(bottom: 10),
                child: _auditCard(e),
              ),
        ],
      );
    },
  );

  Widget _auditCard(Map e) {
    final action = '${e['action'] ?? 'event'}';
    final detail = '${e['detail'] ?? ''}'.trim();
    return ClubCard(
      radius: 16,
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 36,
            height: 36,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: AppColors.gold.withValues(alpha: 0.10),
            ),
            child: const Icon(Icons.history, size: 18, color: AppColors.gold),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '$action · ${e['seatId'] ?? '—'}',
                  style: const TextStyle(
                    fontFamily: AppFonts.body,
                    color: AppColors.ivory,
                    fontSize: 13,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 3),
                Text(
                  'by ${e['by'] ?? 'system'} · '
                  '${_dateLabel(e['at'] as num?)}',
                  style: const TextStyle(
                    fontFamily: AppFonts.body,
                    color: AppColors.textMuted,
                    fontSize: 11.5,
                  ),
                ),
                if (detail.isNotEmpty) ...[
                  const SizedBox(height: 5),
                  Text(
                    detail,
                    style: const TextStyle(
                      fontFamily: AppFonts.body,
                      color: AppColors.textSecondary,
                      fontSize: 12,
                      height: 1.45,
                    ),
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }

  // ------------------------------------------------------------- reports

  /// Feedback triage queue: priority-ranked by the server (open first,
  /// critical-first, newest tiebreak), filterable by status/category,
  /// with quick status/priority changes and delete.
  Widget _reportsTab() => FutureBuilder<Map<String, dynamic>>(
    future: _reports,
    builder: (c, s) {
      final header = _header(
        title: 'Reports',
        subtitle: 'Player feedback, ranked by what needs attention first.',
        icon: Icons.bug_report_outlined,
      );
      if (!s.hasData) {
        return _AdminPage(
          children: [
            header,
            const SizedBox(height: 18),
            s.hasError
                ? _errorPanel(s.error!, _reloadReports)
                : _loading('the reports'),
          ],
        );
      }
      final entries = (s.data!['feedback'] as List? ?? []).cast<Map>();
      final open = (s.data!['openCount'] as num?)?.toInt() ?? 0;
      return _AdminPage(
        children: [
          header,
          const SizedBox(height: 20),
          ClubSectionLabel(
            'Filters',
            trailing: _AdminCountPill('$open open · ${entries.length} shown'),
          ),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              _filterChip(
                label: _repStatus.isEmpty
                    ? 'Status: all'
                    : 'Status: $_repStatus',
                selected: _repStatus.isNotEmpty,
                options: const [
                  '',
                  'open',
                  'in_progress',
                  'resolved',
                  'closed',
                ],
                onPick: (v) {
                  setState(() => _repStatus = v);
                  _reloadReports();
                },
              ),
              _filterChip(
                label: _repCategory.isEmpty
                    ? 'Category: all'
                    : 'Category: $_repCategory',
                selected: _repCategory.isNotEmpty,
                options: const [
                  '',
                  'bug',
                  'feature',
                  'question',
                  'other',
                  'player',
                ],
                onPick: (v) {
                  setState(() => _repCategory = v);
                  _reloadReports();
                },
              ),
              _filterChip(
                label: _repSort == 'priority'
                    ? 'Sort: priority'
                    : 'Sort: newest',
                selected: true,
                options: const ['priority', 'newest'],
                onPick: (v) {
                  setState(() => _repSort = v);
                  _reloadReports();
                },
              ),
            ],
          ),
          const SizedBox(height: 16),
          if (entries.isEmpty)
            _empty(
              icon: Icons.inbox_outlined,
              title: 'No reports match',
              message: 'Try clearing a filter to see the rest of the queue.',
            )
          else
            for (final e in entries)
              Padding(
                padding: const EdgeInsets.only(bottom: 10),
                child: _reportCard(e),
              ),
        ],
      );
    },
  );

  Widget _filterChip({
    required String label,
    required bool selected,
    required List<String> options,
    required void Function(String) onPick,
  }) {
    final labels = {for (final o in options) o: o.isEmpty ? 'all' : o};
    return PopupMenuButton<String>(
      initialValue: null,
      onSelected: onPick,
      itemBuilder: (_) => [
        for (final o in options)
          PopupMenuItem(value: o, child: Text(labels[o] ?? o)),
      ],
      child: FilterChip(
        selected: selected,
        label: Text(label),
        onSelected: (_) {},
        showCheckmark: false,
        selectedColor: AppColors.gold,
        backgroundColor: AppColors.surfaceRaised,
        side: BorderSide(
          color: selected
              ? AppColors.gold
              : AppColors.gold.withValues(alpha: 0.28),
        ),
        labelStyle: TextStyle(
          fontFamily: AppFonts.body,
          fontSize: 12,
          fontWeight: FontWeight.w700,
          color: selected ? AppColors.darkInk : AppColors.ivory,
        ),
        visualDensity: VisualDensity.compact,
      ),
    );
  }

  static const _statusLabels = {
    'open': 'Open',
    'in_progress': 'In progress',
    'resolved': 'Resolved',
    'closed': 'Closed',
  };

  Widget _reportCard(Map e) {
    final id = (e['id'] as num).toInt();
    final title = '${e['title'] ?? ''}'.trim();
    final message = '${e['message'] ?? ''}'.trim();
    final contact = '${e['contact'] ?? ''}'.trim();
    final seatId = '${e['seatId'] ?? ''}'.trim();
    final gameId = '${e['gameId'] ?? ''}'.trim();
    final notes = '${e['adminNotes'] ?? ''}'.trim();

    Widget meta(IconData icon, String text) => Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 12, color: AppColors.textMuted),
        const SizedBox(width: 4),
        Text(
          text,
          style: const TextStyle(
            fontFamily: AppFonts.body,
            color: AppColors.textMuted,
            fontSize: 11,
          ),
        ),
      ],
    );

    return ClubCard(
      radius: 16,
      padding: const EdgeInsets.fromLTRB(14, 12, 6, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Wrap(
                  spacing: 6,
                  runSpacing: 6,
                  children: _reportChips(e),
                ),
              ),
              PopupMenuButton<String>(
                tooltip: 'Report actions',
                iconColor: AppColors.textSecondary,
                onSelected: (a) => _reportAction(a, id, e),
                itemBuilder: (_) => [
                  for (final st in _statusLabels.keys)
                    PopupMenuItem(
                      value: 'status:$st',
                      child: Text('Status: ${_statusLabels[st]}'),
                    ),
                  const PopupMenuDivider(),
                  for (final p in const ['low', 'medium', 'high', 'critical'])
                    PopupMenuItem(
                      value: 'priority:$p',
                      child: Text('Priority: $p'),
                    ),
                  const PopupMenuDivider(),
                  const PopupMenuItem(
                    value: 'notes',
                    child: Text('Edit admin notes'),
                  ),
                  const PopupMenuItem(value: 'edit', child: Text('Edit row')),
                  const PopupMenuDivider(),
                  const PopupMenuItem(
                    value: 'delete',
                    child: Text('Delete report'),
                  ),
                ],
              ),
            ],
          ),
          const SizedBox(height: 8),
          if (title.isNotEmpty)
            Text(
              '(#$id) $title',
              style: const TextStyle(
                fontFamily: AppFonts.body,
                color: AppColors.ivory,
                fontSize: 14,
                fontWeight: FontWeight.w800,
              ),
            ),
          if (message.isNotEmpty) ...[
            const SizedBox(height: 4),
            Text(
              message,
              style: const TextStyle(
                fontFamily: AppFonts.body,
                color: AppColors.textSecondary,
                fontSize: 12.5,
                height: 1.5,
              ),
            ),
          ],
          const SizedBox(height: 8),
          Wrap(
            spacing: 12,
            runSpacing: 6,
            children: [
              meta(Icons.schedule, _dateLabel(e['createdAt'] as num?)),
              if (contact.isNotEmpty) meta(Icons.mail_outline, contact),
              if (seatId.isNotEmpty) meta(Icons.person_outline, 'seat $seatId'),
              if (gameId.isNotEmpty) meta(Icons.videogame_asset, gameId),
              if (notes.isNotEmpty) meta(Icons.notes, 'notes: $notes'),
            ],
          ),
        ],
      ),
    );
  }

  List<Widget> _reportChips(Map e) {
    final priority = '${e['priority'] ?? 'low'}';
    final status = '${e['status'] ?? ''}';
    final category = '${e['category'] ?? 'other'}';
    return [
      _AdminTag(label: category),
      _AdminTag(
        label: priority,
        accent: priority == 'low' ? AppColors.textSecondary : AppColors.gold,
      ),
      _AdminTag(
        label: _statusLabels[status] ?? status,
        danger: status == 'open',
        accent: status == 'in_progress'
            ? AppColors.gold
            : status == 'resolved'
            ? AppColors.sage
            : AppColors.textSecondary,
      ),
    ];
  }

  Future<void> _reportAction(String action, int id, Map e) async {
    if (action.startsWith('status:') || action.startsWith('priority:')) {
      final key = action.split(':')[0];
      final value = action.split(':')[1];
      await widget.client.updateFeedback(id, {key: value});
      _reloadReports();
      return;
    }
    switch (action) {
      case 'notes':
        final notes = await _promptText(
          title: 'Admin notes — report #$id',
          initial: '${e['adminNotes'] ?? ''}',
        );
        if (notes == null) return;
        await widget.client.updateFeedback(id, {'adminNotes': notes});
        _reloadReports();
      case 'edit':
        await _editFeedbackRow(e);
        _reloadReports();
      case 'delete':
        final sure = await showDialog<bool>(
          context: context,
          builder: (c) => AlertDialog(
            title: const Text('Delete report?'),
            content: const Text('This removes it permanently.'),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(c),
                child: const Text('Cancel'),
              ),
              FilledButton(
                onPressed: () => Navigator.pop(c, true),
                child: const Text('Delete'),
              ),
            ],
          ),
        );
        if (sure == true) {
          await widget.client.deleteFeedback(id);
          _reloadReports();
        }
    }
  }

  Future<void> _editFeedbackRow(Map e) async {
    final id = (e['id'] as num).toInt();
    final titleCtrl = TextEditingController(text: '${e['title'] ?? ''}');
    final messageCtrl = TextEditingController(text: '${e['message'] ?? ''}');
    final contactCtrl = TextEditingController(text: '${e['contact'] ?? ''}');
    String category = '${e['category']}';
    String status = '${e['status']}';
    String priority = '${e['priority']}';
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => StatefulBuilder(
        builder: (c, setD) => AlertDialog(
          title: Text('Edit report #$id'),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                DropdownButtonFormField<String>(
                  initialValue: category,
                  decoration: const InputDecoration(labelText: 'Category'),
                  items: [
                    for (final v in const [
                      'bug',
                      'feature',
                      'question',
                      'other',
                      'player',
                    ])
                      DropdownMenuItem(value: v, child: Text(v)),
                  ],
                  onChanged: (v) => setD(() => category = v ?? category),
                ),
                DropdownButtonFormField<String>(
                  initialValue: status,
                  decoration: const InputDecoration(labelText: 'Status'),
                  items: [
                    for (final s2 in _statusLabels.keys)
                      DropdownMenuItem(
                        value: s2,
                        child: Text(_statusLabels[s2]!),
                      ),
                  ],
                  onChanged: (v) => setD(() => status = v ?? status),
                ),
                DropdownButtonFormField<String>(
                  initialValue: priority,
                  decoration: const InputDecoration(labelText: 'Priority'),
                  items: [
                    for (final v in const ['low', 'medium', 'high', 'critical'])
                      DropdownMenuItem(value: v, child: Text(v)),
                  ],
                  onChanged: (v) => setD(() => priority = v ?? priority),
                ),
                TextField(
                  controller: titleCtrl,
                  decoration: const InputDecoration(labelText: 'Title'),
                ),
                TextField(
                  controller: messageCtrl,
                  maxLines: 4,
                  decoration: const InputDecoration(labelText: 'Message'),
                ),
                TextField(
                  controller: contactCtrl,
                  decoration: const InputDecoration(labelText: 'Contact'),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(c),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(c, true),
              child: const Text('Save'),
            ),
          ],
        ),
      ),
    );
    if (ok != true) return;
    await widget.client.updateFeedback(id, {
      'category': category,
      'status': status,
      'priority': priority,
      'title': titleCtrl.text.trim(),
      'message': messageCtrl.text.trim(),
      'contact': contactCtrl.text.trim(),
    });
  }

  // ---------------------------------------------------------------- data

  /// Raw table CRUD over the whitelisted registry — the power tool for
  /// "all the tables": list, search, insert, edit, delete. Read-only
  /// tables (the audit log) show no write affordances.
  Widget _dataTab() => FutureBuilder<Map<String, dynamic>>(
    future: _tableRows,
    builder: (c, s) {
      final header = _header(
        title: 'Data',
        subtitle: 'Read and repair the club’s SQLite tables directly.',
        icon: Icons.table_chart_outlined,
      );
      if (!s.hasData) {
        return _AdminPage(
          children: [
            header,
            const SizedBox(height: 18),
            s.hasError
                ? _errorPanel(s.error!, _reloadTable)
                : _loading('the table'),
          ],
        );
      }
      final d = s.data!;
      final spec = (
        pk: d['pk'] as String,
        columns: (d['columns'] as List).cast<String>(),
        editable: ((d['editable'] as List?) ?? const []).cast<String>().toSet(),
        insertable: d['insertable'] as bool? ?? false,
        deletable: d['deletable'] as bool? ?? false,
      );
      final rows = (d['rows'] as List? ?? []).cast<Map>();

      final tableField = DropdownButtonFormField<String>(
        initialValue: _dataTableName,
        decoration: const InputDecoration(labelText: 'Table'),
        items: [
          for (final t in _dataTables)
            DropdownMenuItem(value: t, child: Text(t)),
        ],
        onChanged: (t) {
          if (t == null || t == _dataTableName) return;
          setState(() {
            _dataTableName = t;
            _dataQuery = '';
          });
          _reloadTable();
        },
      );
      final searchField = TextField(
        // A fresh key clears the visible query when the table changes.
        key: ValueKey('data-search-$_dataTableName'),
        decoration: const InputDecoration(
          labelText: 'Search',
          prefixIcon: Icon(Icons.search, size: 20),
        ),
        textInputAction: TextInputAction.search,
        onSubmitted: (q) {
          setState(() => _dataQuery = q);
          _reloadTable();
        },
      );

      return _AdminPage(
        children: [
          header,
          const SizedBox(height: 20),
          ClubCard(
            padding: const EdgeInsets.all(14),
            child: LayoutBuilder(
              builder: (context, c) {
                if (c.maxWidth < 560) {
                  return Column(
                    children: [
                      tableField,
                      const SizedBox(height: 10),
                      searchField,
                    ],
                  );
                }
                return Row(
                  children: [
                    Expanded(child: tableField),
                    const SizedBox(width: 10),
                    Expanded(child: searchField),
                  ],
                );
              },
            ),
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              Text(
                '${rows.length} of ${d['total']} rows',
                style: const TextStyle(
                  fontFamily: AppFonts.body,
                  color: AppColors.textSecondary,
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const Spacer(),
              if (spec.insertable)
                OutlinedButton.icon(
                  icon: const Icon(Icons.add, size: 18),
                  label: const Text('Add row'),
                  onPressed: () => _insertTableRow(spec),
                ),
            ],
          ),
          const SizedBox(height: 10),
          if (rows.isEmpty)
            _empty(
              icon: Icons.table_chart_outlined,
              title: 'No rows match',
              message: 'Try a different table or clear the search.',
            )
          else
            for (final r in rows)
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: _dataRowCard(r, spec),
              ),
        ],
      );
    },
  );

  Widget _dataRowCard(Map r, _TableSpec spec) {
    final pkValue = '${r[spec.pk]}';
    final summary = [
      for (final c in spec.columns.take(4))
        if (r[c] != null && '${r[c]}'.isNotEmpty) '${r[c]}',
    ].join(' · ');
    return ClubCard(
      radius: 16,
      padding: EdgeInsets.zero,
      child: ListTile(
        contentPadding: const EdgeInsets.fromLTRB(14, 2, 4, 2),
        title: Text(
          summary.isEmpty ? '(empty row)' : summary,
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(
            fontFamily: AppFonts.body,
            color: AppColors.ivory,
            fontSize: 12.5,
            fontWeight: FontWeight.w600,
          ),
        ),
        subtitle: Text(
          '${spec.pk}: $pkValue',
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(
            fontFamily: AppFonts.body,
            color: AppColors.textMuted,
            fontSize: 10.5,
          ),
        ),
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (spec.editable.isNotEmpty)
              IconButton(
                icon: const Icon(Icons.edit_outlined, size: 18),
                tooltip: 'Edit row',
                onPressed: () async {
                  await _editTableRow(r, spec);
                  _reloadTable();
                },
              ),
            if (spec.deletable)
              IconButton(
                icon: const Icon(Icons.delete_outline, size: 18),
                tooltip: 'Delete row',
                onPressed: () async {
                  final sure = await showDialog<bool>(
                    context: context,
                    builder: (c) => AlertDialog(
                      title: const Text('Delete row?'),
                      content: Text(
                        'Delete the row with ${spec.pk} = $pkValue? '
                        'This cannot be undone.',
                      ),
                      actions: [
                        TextButton(
                          onPressed: () => Navigator.pop(c),
                          child: const Text('Cancel'),
                        ),
                        FilledButton(
                          onPressed: () => Navigator.pop(c, true),
                          child: const Text('Delete'),
                        ),
                      ],
                    ),
                  );
                  if (sure == true) {
                    await widget.client.deleteTableRow(_dataTableName, pkValue);
                    _reloadTable();
                  }
                },
              ),
          ],
        ),
        onTap: spec.editable.isEmpty
            ? null
            : () async {
                await _editTableRow(r, spec);
                _reloadTable();
              },
      ),
    );
  }

  /// JSON scalar coercion for the Data tab forms: numeric-looking strings
  /// become numbers so integer columns stay integers after an edit.
  dynamic _coerce(String raw) {
    final v = raw.trim();
    if (v.isEmpty) return '';
    final i = int.tryParse(v);
    if (i != null) return i;
    final d = double.tryParse(v);
    if (d != null) return d;
    return v;
  }

  Future<void> _editTableRow(Map r, _TableSpec spec) async {
    final ctrlFor = {
      for (final c in spec.editable)
        c: TextEditingController(text: '${r[c] ?? ''}'),
    };
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: Text('Edit $_dataTableName row (${spec.pk} = ${r[spec.pk]})'),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              for (final c in spec.editable)
                TextField(
                  controller: ctrlFor[c],
                  decoration: InputDecoration(
                    labelText: c,
                    border: const OutlineInputBorder(),
                    isDense: true,
                  ),
                ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(c),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(c, true),
            child: const Text('Save'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    final values = {
      for (final e in ctrlFor.entries)
        if (_coerce(e.value.text) != (r[e.key] ?? ''))
          e.key: _coerce(e.value.text),
    };
    if (values.isEmpty) return;
    await widget.client.updateTableRow(_dataTableName, '${r[spec.pk]}', values);
  }

  Future<void> _insertTableRow(_TableSpec spec) async {
    final ctrlFor = {for (final c in spec.editable) c: TextEditingController()};
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: Text('Insert into $_dataTableName'),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              for (final c in spec.editable)
                TextField(
                  controller: ctrlFor[c],
                  decoration: InputDecoration(
                    labelText: c,
                    border: const OutlineInputBorder(),
                    isDense: true,
                  ),
                ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(c),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(c, true),
            child: const Text('Insert'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    final values = {
      for (final e in ctrlFor.entries)
        if (e.value.text.trim().isNotEmpty) e.key: _coerce(e.value.text),
    };
    try {
      await widget.client.insertTableRow(_dataTableName, values);
      _reloadTable();
    } on AdminException catch (e) {
      if (!mounted) return;
      showTableAlert(context, e.body, icon: Icons.error_outline);
    }
  }

  Future<String?> _promptText({required String title, String initial = ''}) {
    final ctrl = TextEditingController(text: initial);
    return showDialog<String>(
      context: context,
      builder: (c) => AlertDialog(
        title: Text(title),
        content: TextField(
          controller: ctrl,
          autofocus: true,
          maxLines: 3,
          decoration: const InputDecoration(border: OutlineInputBorder()),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(c),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(c, ctrl.text.trim()),
            child: const Text('Save'),
          ),
        ],
      ),
    );
  }
}

/// A padded, reading-width page inside the admin shell.
class _AdminPage extends StatelessWidget {
  const _AdminPage({required this.children});

  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(16, 20, 16, 32),
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 1120),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: children,
          ),
        ),
      ),
    );
  }
}

/// A single score-sheet number: the value in Fraunces over a small caption.
class _AdminStatCard extends StatelessWidget {
  const _AdminStatCard({
    required this.icon,
    required this.label,
    required this.value,
    this.accent = AppColors.gold,
  });

  final IconData icon;
  final String label;
  final String value;
  final Color accent;

  @override
  Widget build(BuildContext context) {
    return ClubCard(
      radius: 16,
      padding: const EdgeInsets.fromLTRB(13, 11, 13, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(icon, size: 16, color: AppColors.gold),
              const Spacer(),
              Text(
                value,
                style: TextStyle(
                  fontFamily: AppFonts.display,
                  color: accent,
                  fontSize: 26,
                  fontWeight: FontWeight.w600,
                  height: 1,
                ),
              ),
            ],
          ),
          const SizedBox(height: 7),
          Text(
            label.toUpperCase(),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(
              fontFamily: AppFonts.body,
              color: AppColors.textMuted,
              fontSize: 9,
              fontWeight: FontWeight.w800,
              letterSpacing: 1.0,
            ),
          ),
        ],
      ),
    );
  }
}

/// A small brass or danger tag for a role, status or priority.
class _AdminTag extends StatelessWidget {
  const _AdminTag({
    required this.label,
    this.accent = AppColors.gold,
    this.danger = false,
  });

  final String label;
  final Color accent;
  final bool danger;

  @override
  Widget build(BuildContext context) {
    final color = danger ? AppColors.danger : accent;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: color.withValues(alpha: 0.40)),
      ),
      child: Text(
        label,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(
          fontFamily: AppFonts.body,
          color: danger ? AppColors.ivory : color,
          fontSize: 10,
          fontWeight: FontWeight.w800,
          letterSpacing: 0.3,
        ),
      ),
    );
  }
}

/// A compact count in a brass pill, used beside a section label.
class _AdminCountPill extends StatelessWidget {
  const _AdminCountPill(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: AppColors.surfaceDeep,
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: AppColors.gold.withValues(alpha: 0.24)),
      ),
      child: Text(
        text,
        style: const TextStyle(
          fontFamily: AppFonts.body,
          color: AppColors.gold,
          fontSize: 10,
          fontWeight: FontWeight.w800,
        ),
      ),
    );
  }
}

/// The phone/tablet tab bar: one scrollable row of 44px brass pills.
class _AdminTabStrip extends StatelessWidget {
  const _AdminTabStrip({required this.selectedIndex, required this.onSelected});

  final int selectedIndex;
  final ValueChanged<int> onSelected;

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 62,
      decoration: BoxDecoration(
        color: AppColors.feltDeep,
        border: Border(
          top: BorderSide(color: AppColors.gold.withValues(alpha: 0.14)),
          bottom: BorderSide(color: AppColors.gold.withValues(alpha: 0.22)),
        ),
      ),
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
        itemCount: _adminTabLabels.length,
        separatorBuilder: (_, _) => const SizedBox(width: 8),
        itemBuilder: (context, i) {
          final selected = i == selectedIndex;
          return Semantics(
            button: true,
            selected: selected,
            child: Material(
              color: selected
                  ? AppColors.gold
                  : AppColors.surfaceRaised.withValues(alpha: 0.45),
              shape: StadiumBorder(
                side: BorderSide(
                  color: selected
                      ? AppColors.gold
                      : AppColors.gold.withValues(alpha: 0.28),
                ),
              ),
              clipBehavior: Clip.antiAlias,
              child: InkWell(
                onTap: () => onSelected(i),
                child: ConstrainedBox(
                  constraints: const BoxConstraints(minHeight: 44),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 12),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(
                          _adminTabIcons[i],
                          size: 18,
                          color: selected
                              ? AppColors.darkInk
                              : AppColors.textSecondary,
                        ),
                        const SizedBox(width: 6),
                        Text(
                          _adminTabLabels[i],
                          style: TextStyle(
                            fontFamily: AppFonts.body,
                            color: selected
                                ? AppColors.darkInk
                                : AppColors.ivory,
                            fontSize: 12,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          );
        },
      ),
    );
  }
}
