import '../ui/page_app_bar.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../providers/app_providers.dart';

/// Settings: sound, haptics, animation (battery saver) toggles.
/// All preferences persist via SharedPreferences and apply instantly.
class SettingsScreen extends ConsumerWidget {
  const SettingsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final sound = ref.watch(soundEnabledProvider);
    final haptics = ref.watch(hapticsEnabledProvider);
    final anims = ref.watch(animationsEnabledProvider);

    return Scaffold(
      appBar: PageAppBar(title: 'Settings'),
      body: ContentColumn(
        child: ListView(
        children: [
          const SizedBox(height: 8),
          SwitchListTile(
            secondary: const Icon(Icons.volume_up),
            title: const Text('Sound effects'),
            subtitle: const Text('Dice, hops, captures and fanfares'),
            value: sound,
            onChanged: (_) => ref.read(soundEnabledProvider.notifier).toggle(),
          ),
          SwitchListTile(
            secondary: const Icon(Icons.vibration),
            title: const Text('Haptics'),
            subtitle: const Text('Vibrate on rolls and moves'),
            value: haptics,
            onChanged: (_) =>
                ref.read(hapticsEnabledProvider.notifier).toggle(),
          ),
          SwitchListTile(
            secondary: const Icon(Icons.animation),
            title: const Text('Board animations'),
            subtitle: const Text(
                'Breathing turn glow and spinning rings. '
                'Turn off to save battery — dice and hops still animate.'),
            value: anims,
            onChanged: (_) =>
                ref.read(animationsEnabledProvider.notifier).toggle(),
          ),
          const Divider(height: 32),
          const ListTile(
            leading: Icon(Icons.info_outline),
            title: Text('Game Club'),
            subtitle: Text('Ludo & Snakes and Ladders · local play, '
                'bots and pass-and-play. Progress and stats are stored '
                'on this device only.'),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Text(
              'Tip: use the lightbulb button in a game for a move hint, '
              'the undo arrow to take back a roll, and auto-mode to let '
              'the game play itself while you take a break.',
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ),
        ],
      ),
      ),
    );
  }
}
