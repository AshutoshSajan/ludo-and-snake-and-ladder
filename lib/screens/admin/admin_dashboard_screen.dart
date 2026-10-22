import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app_router.dart';
import '../../app_routes.dart';
import '../../providers/app_providers.dart';
import '../../services/admin_client.dart';
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
        content: TextField(controller: ctrl, decoration: const InputDecoration(labelText: 'New name')),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(c, ctrl.text.trim()), child: const Text('Save')),
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
                const Text('Admin dashboard'),
                if (email != null)
                  Text(
                    'Signed in as $email',
                    style: const TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.normal,
                      color: AppColors.ivoryDark,
                    ),
                  ),
              ],
            );
          },
        ),
        backgroundColor: AppColors.feltLight,
        actions: [
          IconButton(icon: const Icon(Icons.refresh), onPressed: _reloadAll),
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
      ),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _tab,
        onDestinationSelected: (i) => setState(() {
          _tab = i;
          _ensureTab(i);
        }),
        destinations: const [
          NavigationDestination(icon: Icon(Icons.dashboard), label: 'Stats'),
          NavigationDestination(icon: Icon(Icons.meeting_room), label: 'Rooms'),
          NavigationDestination(icon: Icon(Icons.people), label: 'Players'),
          NavigationDestination(
            icon: Icon(Icons.manage_accounts),
            label: 'Users',
          ),
          NavigationDestination(icon: Icon(Icons.history), label: 'Audit'),
          NavigationDestination(
            icon: Icon(Icons.bug_report),
            label: 'Reports',
          ),
          NavigationDestination(icon: Icon(Icons.table_chart), label: 'Data'),
        ],
      ),
      body: switch (_tab) {
        0 => _statsTab(),
        1 => _roomsTab(),
        2 => _playersTab(),
        3 => _usersTab(),
        4 => _auditTab(),
        5 => _reportsTab(),
        _ => _dataTab(),
      },
    );
  }

  Widget _statsTab() => FutureBuilder<Map<String, dynamic>>(
    future: _overview,
    builder: (c, s) {
      if (!s.hasData) {
        if (s.hasError) return Center(child: Text('${s.error}'));
        return const Center(child: CircularProgressIndicator());
      }
      final d = s.data!;
      final live = d['live'] as Map? ?? {};
      final stored = d['stored'] as Map? ?? {};
      final cards = <String, Object?>{
        'Live rooms': live['rooms'],
        'Connections': live['connections'],
        'Spectators': live['spectators'],
        'Total rooms (DB)': stored['totalRooms'],
        'Total players (DB)': stored['totalPlayers'],
        'Finished games': stored['finishedGames'],
        'Banned': stored['bannedPlayers'],
      };
      return ListView(
        padding: const EdgeInsets.all(16),
        children: [
          for (final e in cards.entries)
            Card(child: ListTile(title: Text(e.key), trailing: Text('${e.value ?? 0}', style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold)))),
        ],
      );
    },
  );

  Widget _roomsTab() => FutureBuilder<Map<String, dynamic>>(
    future: _rooms ??= widget.client.rooms(),
    builder: (c, s) {
      if (!s.hasData) {
        if (s.hasError) return Center(child: Text('${s.error}'));
        return const Center(child: CircularProgressIndicator());
      }
      final live = (s.data!['live'] as List? ?? []).cast<Map>();
      final recent = (s.data!['recent'] as List? ?? []).cast<Map>();
      return ListView(
        padding: const EdgeInsets.all(16),
        children: [
          const Text('Live', style: TextStyle(fontWeight: FontWeight.bold)),
          for (final r in live)
            Card(
              child: ListTile(
                title: Text('${r['code']} · ${r['game']}'),
                subtitle: Text('members ${r['members']} · started: ${r['started']}'),
                trailing: TextButton(onPressed: () => _closeRoom('${r['code']}'), child: const Text('Close')),
              ),
            ),
          const SizedBox(height: 12),
          const Text('Recent (DB history)', style: TextStyle(fontWeight: FontWeight.bold)),
          for (final r in recent)
            Card(
              child: ListTile(
                title: Text('${r['code']} · ${r['game']} · ${r['status']}'),
                subtitle: Text('created ${DateTime.fromMillisecondsSinceEpoch((r['createdAt'] as num).toInt())}'),
              ),
            ),
        ],
      );
    },
  );

  Widget _playersTab() => FutureBuilder<Map<String, dynamic>>(
    future: _players ??= widget.client.players(),
    builder: (c, s) {
      if (!s.hasData) {
        if (s.hasError) return Center(child: Text('${s.error}'));
        return const Center(child: CircularProgressIndicator());
      }
      final players = (s.data!['players'] as List? ?? []).cast<Map>();
      return ListView(
        padding: const EdgeInsets.all(16),
        children: [
          for (final p in players)
            Card(
              child: ListTile(
                title: Text('${p['name']} (${p['seatId']})'),
                subtitle: Text((p['banned'] as bool? ?? false) ? 'BANNED' : 'last seen ${DateTime.fromMillisecondsSinceEpoch((p['lastSeen'] as num).toInt())}'),
                trailing: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    IconButton(icon: const Icon(Icons.edit), tooltip: 'Rename', onPressed: () => _rename('${p['seatId']}')),
                    IconButton(
                      icon: Icon((p['banned'] as bool? ?? false) ? Icons.check : Icons.block),
                      tooltip: (p['banned'] as bool? ?? false) ? 'Unban' : 'Ban',
                      onPressed: () => (p['banned'] as bool? ?? false) ? _unban('${p['seatId']}') : _ban('${p['seatId']}'),
                    ),
                  ],
                ),
              ),
            ),
        ],
      );
    },
  );

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
                onChanged: (v) =>
                    setDialog(() => role = v ?? 'moderator'),
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
      if (!s.hasData) {
        if (s.hasError) return Center(child: Text('${s.error}'));
        return const Center(child: CircularProgressIndicator());
      }
      final users = (s.data!['users'] as List? ?? []).cast<Map>();
      return Scaffold(
        backgroundColor: Colors.transparent,
        floatingActionButton: FloatingActionButton(
          tooltip: 'New user',
          onPressed: _createUser,
          child: const Icon(Icons.person_add),
        ),
        body: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            for (final u in users)
              Card(
                child: ListTile(
                  leading: Icon(
                    u['role'] == 'admin'
                        ? Icons.verified_user
                        : Icons.person,
                  ),
                  title: Text('${u['name']}'),
                  subtitle: Text('${u['email']} · ${u['role']}'),
                ),
              ),
          ],
        ),
      );
    },
  );

  Widget _auditTab() => FutureBuilder<Map<String, dynamic>>(
    future: _audit ??= widget.client.audit(),
    builder: (c, s) {
      if (!s.hasData) {
        if (s.hasError) return Center(child: Text('${s.error}'));
        return const Center(child: CircularProgressIndicator());
      }
      final items = (s.data!['audit'] as List? ?? []).cast<Map>();
      return ListView(
        padding: const EdgeInsets.all(16),
        children: [
          for (final e in items)
            Card(
              child: ListTile(
                title: Text('${e['action']} · ${e['seatId']}'),
                subtitle: Text('by ${e['by']} · ${DateTime.fromMillisecondsSinceEpoch((e['at'] as num).toInt())}${e['detail'] != null ? ' · ${e['detail']}' : ''}'),
              ),
            ),
        ],
      );
    },
  );

  // ------------------------------------------------------------- reports

  /// Feedback triage queue: priority-ranked by the server (open first,
  /// critical-first, newest tiebreak), filterable by status/category,
  /// with quick status/priority changes and delete.
  Widget _reportsTab() => FutureBuilder<Map<String, dynamic>>(
    future: _reports,
    builder: (c, s) {
      if (!s.hasData) {
        if (s.hasError) return Center(child: Text('${s.error}'));
        return const Center(child: CircularProgressIndicator());
      }
      final entries = (s.data!['feedback'] as List? ?? []).cast<Map>();
      final open = (s.data!['openCount'] as num?)?.toInt() ?? 0;
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
            child: Text(
              '$open open · ${entries.length} shown',
              style: const TextStyle(fontSize: 12, color: AppColors.ivoryDark),
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
            child: Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                _filterChip(
                  label: _repStatus.isEmpty ? 'Status: all' : 'Status: $_repStatus',
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
                  options: const ['', 'bug', 'feature', 'question', 'other', 'player'],
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
          ),
          Expanded(
            child: entries.isEmpty
                ? const Center(child: Text('No reports match'))
                : ListView(
                    padding: const EdgeInsets.all(12),
                    children: [
                      for (final e in entries)
                        _reportCard(e),
                    ],
                  ),
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
          PopupMenuItem(
            value: o,
            child: Text(labels[o] ?? o),
          ),
      ],
      child: FilterChip(
        selected: selected,
        label: Text(label),
        onSelected: (_) {},
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
    return Card(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 8, 4, 4),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                for (final chip in _reportChips(e)) ...[
                  chip,
                  const SizedBox(width: 6),
                ],
                const Spacer(),
                PopupMenuButton<String>(
                  onSelected: (a) => _reportAction(a, id, e),
                  itemBuilder: (_) => [
                    for (final st in _statusLabels.keys)
                      PopupMenuItem(
                        value: 'status:$st',
                        child: Text('Status: ${_statusLabels[st]}'),
                      ),
                    const PopupMenuDivider(),
                    for (final p in const [
                      'low',
                      'medium',
                      'high',
                      'critical',
                    ])
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
            const SizedBox(height: 4),
            if ((e['title'] as String? ?? '').isNotEmpty)
              Text(
                '(#${e['id']}) ${e['title']}',
                style: const TextStyle(fontWeight: FontWeight.bold),
              ),
            Text('${e['message']}', style: const TextStyle(fontSize: 13)),
            const SizedBox(height: 6),
            DefaultTextStyle(
              style: const TextStyle(fontSize: 11, color: AppColors.ivoryDark),
              child: Wrap(
                spacing: 12,
                children: [
                  Text('${DateTime.fromMillisecondsSinceEpoch((e['createdAt'] as num).toInt())}'),
                  if ((e['contact'] as String? ?? '').isNotEmpty)
                    const Icon(
                      Icons.mail_outline,
                      size: 12,
                      color: AppColors.ivoryDark,
                    ),
                  if ((e['contact'] as String? ?? '').isNotEmpty)
                    Text('${e['contact']}'),
                  if ((e['seatId'] as String? ?? '').isNotEmpty)
                    Text('seat ${e['seatId']}'),
                  if ((e['gameId'] as String? ?? '').isNotEmpty)
                    Text('game ${e['gameId']}'),
                  if ((e['adminNotes'] as String? ?? '').isNotEmpty)
                    Text('notes: ${e['adminNotes']}'),
                ],
              ),
            ),
            const SizedBox(height: 4),
          ],
        ),
      ),
    );
  }

  List<Widget> _reportChips(Map e) => [
    Chip(
      label: Text('${e['category']}', style: const TextStyle(fontSize: 11)),
      visualDensity: VisualDensity.compact,
      backgroundColor: AppColors.felt,
    ),
    FilterChip(
      label: Text('${e['priority']}', style: const TextStyle(fontSize: 11)),
      selected: e['priority'] != 'low',
      visualDensity: VisualDensity.compact,
      onSelected: (_) {},
    ),
    Chip(
      label: Text(
        _statusLabels[e['status']] ?? '${e['status']}',
        style: const TextStyle(fontSize: 11),
      ),
      visualDensity: VisualDensity.compact,
      backgroundColor: e['status'] == 'open'
          ? AppColors.danger
          : AppColors.felt,
    ),
  ];

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
        await widget.client
            .updateFeedback(id, {'adminNotes': notes});
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
              TextButton(onPressed: () => Navigator.pop(c), child: const Text('Cancel')),
              FilledButton(onPressed: () => Navigator.pop(c, true), child: const Text('Delete')),
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
                    for (final v in const ['bug', 'feature', 'question', 'other', 'player'])
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
            TextButton(onPressed: () => Navigator.pop(c), child: const Text('Cancel')),
            FilledButton(onPressed: () => Navigator.pop(c, true), child: const Text('Save')),
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
      if (!s.hasData) {
        if (s.hasError) return Center(child: Text('${s.error}'));
        return const Center(child: CircularProgressIndicator());
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
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
            child: Row(
              children: [
                Expanded(
                  child: DropdownButtonFormField<String>(
                    initialValue: _dataTableName,
                    decoration: const InputDecoration(
                      labelText: 'Table',
                      border: OutlineInputBorder(),
                      isDense: true,
                    ),
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
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: TextField(
                    decoration: const InputDecoration(
                      labelText: 'Search',
                      border: OutlineInputBorder(),
                      isDense: true,
                    ),
                    onSubmitted: (q) {
                      setState(() => _dataQuery = q);
                      _reloadTable();
                    },
                  ),
                ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: Row(
              children: [
                Text(
                  '${rows.length} of ${d['total']} rows',
                  style: const TextStyle(
                    fontSize: 12,
                    color: AppColors.ivoryDark,
                  ),
                ),
                const Spacer(),
                if (spec.insertable)
                  TextButton.icon(
                    icon: const Icon(Icons.add, size: 18),
                    label: const Text('Add row'),
                    onPressed: () => _insertTableRow(spec),
                  ),
              ],
            ),
          ),
          Expanded(
            child: rows.isEmpty
                ? const Center(child: Text('No rows match'))
                : ListView(
                    padding: const EdgeInsets.all(12),
                    children: [
                      for (final r in rows) _dataRowCard(r, spec),
                    ],
                  ),
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
    return Card(
      child: ListTile(
        title: Text(summary, style: const TextStyle(fontSize: 13)),
        isThreeLine: false,
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (spec.editable.isNotEmpty)
              IconButton(
                icon: const Icon(Icons.edit, size: 18),
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
                        TextButton(onPressed: () => Navigator.pop(c), child: const Text('Cancel')),
                        FilledButton(onPressed: () => Navigator.pop(c, true), child: const Text('Delete')),
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
        onTap: spec.editable.isEmpty ? null : () async {
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
      for (final c in spec.editable) c: TextEditingController(text: '${r[c] ?? ''}'),
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
                  decoration: InputDecoration(labelText: c, border: const OutlineInputBorder(), isDense: true),
                ),
            ],
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(c, true), child: const Text('Save')),
        ],
      ),
    );
    if (ok != true) return;
    final values = {
      for (final e in ctrlFor.entries)
        if (_coerce(e.value.text) != (r[e.key] ?? '')) e.key: _coerce(e.value.text),
    };
    if (values.isEmpty) return;
    await widget.client.updateTableRow(
      _dataTableName,
      '${r[spec.pk]}',
      values,
    );
  }

  Future<void> _insertTableRow(_TableSpec spec) async {

    final ctrlFor = {
      for (final c in spec.editable) c: TextEditingController(),
    };
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
                  decoration: InputDecoration(labelText: c, border: const OutlineInputBorder(), isDense: true),
                ),
            ],
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(c, true), child: const Text('Insert')),
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
          TextButton(onPressed: () => Navigator.pop(c), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(c, ctrl.text.trim()), child: const Text('Save')),
        ],
      ),
    );
  }
}
