import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../controllers/snakes_session.dart';
import '../../providers/app_providers.dart';
import '../shared/seat_manager.dart';
import '../theme.dart';

/// Pause menu + mid-game player management for the Snakes & Ladders view.
void showSnakesPauseMenu(
    BuildContext context, WidgetRef ref, SnakesSession session) {
  showModalBottomSheet(
    context: context,
    backgroundColor: AppColors.feltLight,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
    ),
    builder: (context) => SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const SizedBox(height: 16),
          ListTile(
            leading: const Icon(Icons.group),
            title: const Text('Manage players'),
            onTap: () {
              Navigator.of(context).pop();
              showSnakesSeatManager(context, ref, session);
            },
          ),
          Consumer(builder: (context, ref, _) {
            final on = ref.watch(soundEnabledProvider);
            return ListTile(
              leading: Icon(on ? Icons.volume_up : Icons.volume_off),
              title: Text(on ? 'Sound: on' : 'Sound: off'),
              onTap: () => ref.read(soundEnabledProvider.notifier).toggle(),
            );
          }),
          ListTile(
            leading: const Icon(Icons.home_outlined),
            title: const Text('Quit to home'),
            onTap: () {
              Navigator.of(context).pop();
              Navigator.of(context).popUntil((r) => r.isFirst);
            },
          ),
          const SizedBox(height: 12),
        ],
      ),
    ),
  );
}

void showSnakesSeatManager(
    BuildContext context, WidgetRef ref, SnakesSession session) {
  final s = session.state;
  showSeatManager(
    context,
    title: 'Players',
    canAdd: session.canAddPlayer,
    onChanged: () {},
    seats: [
      for (var i = 0; i < s.players.length; i++)
        SeatRowData(
          index: i,
          name: s.players[i].name,
          color: AppColors.snakesColors[
              s.players[i].tokenIndex % AppColors.snakesColors.length],
          isAI: s.players[i].isAI,
          isCurrent: i == s.currentPlayerIndex,
          canRemove: session.canRemovePlayer,
          subtitle: 'Square: ${s.players[i].square == 0 ? 'start' : s.players[i].square}',
        ),
    ],
    onSwapAI: session.swapToAI,
    onSwapHuman: session.swapToHuman,
    onRemove: session.removePlayer,
    onAdd: () => _showAddPlayerDialog(context, ref, session),
  );
}

Future<void> _showAddPlayerDialog(
    BuildContext context, WidgetRef ref, SnakesSession session) async {
  final profiles = ref.read(profilesProvider);
  String? profileId;
  final nameCtrl = TextEditingController();
  var asBot = false;

  await showDialog<void>(
    context: context,
    builder: (context) => StatefulBuilder(
      builder: (context, setLocal) => AlertDialog(
        title: const Text('Add player'),
        content: SizedBox(
          width: 320,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              DropdownButtonFormField<String?>(
                initialValue: profileId,
                decoration: const InputDecoration(labelText: 'Profile'),
                items: [
                  const DropdownMenuItem(value: null, child: Text('— none —')),
                  ...profiles.map((p) =>
                      DropdownMenuItem(value: p.id, child: Text(p.name))),
                ],
                onChanged: (v) => setLocal(() {
                  profileId = v;
                  nameCtrl.text = v == null
                      ? nameCtrl.text
                      : profiles.firstWhere((p) => p.id == v).name;
                }),
              ),
              TextField(
                controller: nameCtrl,
                decoration: const InputDecoration(labelText: 'Name'),
              ),
              SwitchListTile(
                title: const Text('Bot'),
                value: asBot,
                onChanged: (v) => setLocal(() => asBot = v),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('Cancel')),
          FilledButton(
            onPressed: () {
              final name = nameCtrl.text.trim();
              if (name.isEmpty) return;
              session.addPlayer(profileId: asBot ? null : profileId, name: name);
              Navigator.of(context).pop();
            },
            child: const Text('Add'),
          ),
        ],
      ),
    ),
  );
}
