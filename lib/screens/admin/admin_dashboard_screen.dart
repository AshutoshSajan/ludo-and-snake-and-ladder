import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../providers/app_providers.dart';
import '../../services/admin_client.dart';
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

class _AdminDashboardScreenState extends ConsumerState<AdminDashboardScreen> {
  int _tab = 0;
  Future<Map<String, dynamic>>? _overview;
  Future<Map<String, dynamic>>? _rooms;
  Future<Map<String, dynamic>>? _players;
  Future<Map<String, dynamic>>? _audit;
  Future<Map<String, dynamic>>? _me;
  Future<Map<String, dynamic>>? _users;

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
    }
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
              final navigator = Navigator.of(context);
              await widget.client.logout();
              ref.read(adminSessionProvider.notifier).signOut();
              navigator.pushAndRemoveUntil(
                MaterialPageRoute(builder: (_) => const AdminLoginScreen()),
                (_) => false,
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
        ],
      ),
      body: switch (_tab) {
        0 => _statsTab(),
        1 => _roomsTab(),
        2 => _playersTab(),
        3 => _usersTab(),
        _ => _auditTab(),
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
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('Create failed: ${e.body}')));
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
}
