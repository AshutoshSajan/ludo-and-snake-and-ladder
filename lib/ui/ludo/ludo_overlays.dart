import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../controllers/ludo_session.dart';
import '../../engine/ludo/ludo_models.dart';
import '../../providers/app_providers.dart';
import '../shared/seat_manager.dart';
import '../theme.dart';

/// Pause menu + mid-game player management for the Ludo view.
void showLudoPauseMenu(
    BuildContext context, WidgetRef ref, LudoSession session) {
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
              showLudoSeatManager(context, ref, session);
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

void showLudoSeatManager(
    BuildContext context, WidgetRef ref, LudoSession session) {
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
          color: AppColors.ludo(s.players[i].color),
          isAI: s.players[i].isAI,
          isCurrent: i == s.currentPlayerIndex,
          canRemove: session.canRemovePlayer,
          subtitle: 'Home: ${s.tokensOf(i).where((t) => t.isHome).length}/4',
        ),
    ],
    onSwapAI: session.swapToAI,
    onSwapHuman: session.swapToHuman,
    onRemove: session.removePlayer,
    onAdd: () => _showAddPlayerDialog(context, ref, session),
  );
}

Future<void> _showAddPlayerDialog(
    BuildContext context, WidgetRef ref, LudoSession session) async {
  final profiles = ref.read(profilesProvider);
  final freeColors = session.freeColors();
  if (freeColors.isEmpty) return;
  LudoColor? color = freeColors.first;
  String? profileId;
  final nameCtrl = TextEditingController();
  var asBot = false;
  var difficulty = AIDifficulty.medium;

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
              Wrap(
                spacing: 8,
                children: [
                  for (final c in freeColors)
                    ChoiceChip(
                      label: Text(c.label),
                      selected: color == c,
                      selectedColor: AppColors.ludo(c),
                      onSelected: (_) => setLocal(() => color = c),
                    ),
                ],
              ),
              const SizedBox(height: 12),
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
              if (asBot)
                DropdownButtonFormField<AIDifficulty>(
                  initialValue: difficulty,
                  decoration: const InputDecoration(labelText: 'Difficulty'),
                  items: const [
                    DropdownMenuItem(
                        value: AIDifficulty.easy, child: Text('Easy')),
                    DropdownMenuItem(
                        value: AIDifficulty.medium, child: Text('Medium')),
                    DropdownMenuItem(
                        value: AIDifficulty.hard, child: Text('Hard')),
                  ],
                  onChanged: (v) =>
                      setLocal(() => difficulty = v ?? AIDifficulty.medium),
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
              if (name.isEmpty || color == null) return;
              session.addPlayer(
                profileId: asBot ? null : profileId,
                name: name,
                color: color!,
              );
              Navigator.of(context).pop();
            },
            child: const Text('Add'),
          ),
        ],
      ),
    ),
  );
}
