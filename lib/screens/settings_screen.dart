import '../ui/page_app_bar.dart';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../app_router.dart';
import '../app_routes.dart';
import '../providers/app_providers.dart';
import '../services/server_url.dart';
import '../ui/shared/bug_report_sheet.dart';
import '../ui/shared/tutorial_walkthrough.dart';
import 'contact_screen.dart';
import 'friends_screen.dart';
import 'rules_screen.dart';

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
              onChanged: (_) =>
                  ref.read(soundEnabledProvider.notifier).toggle(),
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
                'Turn off to save battery — dice and hops still animate.',
              ),
              value: anims,
              onChanged: (_) =>
                  ref.read(animationsEnabledProvider.notifier).toggle(),
            ),
            const Divider(height: 32),
            ListTile(
              leading: const Icon(Icons.group_outlined),
              title: const Text('Friends'),
              subtitle: const Text(
                'Add friends by code, chat, and invite '
                'them to a table.',
              ),
              onTap: () => pushAppScreen<void>(
                context,
                name: AppRoutes.friends,
                builder: (_) => const FriendsScreen(),
              ),
            ),
            ListTile(
              leading: const Icon(Icons.bug_report),
              title: const Text('Report an issue'),
              subtitle: const Text(
                'Something broken, or an idea? File it — it goes '
                'straight to the developers.',
              ),
              onTap: () =>
                  BugReportSheet.show(context, serverUrl: defaultServerUrl()),
            ),
            ListTile(
              leading: const Icon(Icons.mail_outline),
              title: const Text('Contact us'),
              subtitle: const Text(
                'Questions and feedback, with an email '
                'if you want a reply.',
              ),
              onTap: () => pushAppScreen<void>(
                context,
                name: AppRoutes.contact,
                builder: (_) =>
                    ContactScreen(serverUrl: defaultServerUrl()),
              ),
            ),
            // This tile keeps to its own section so parallel additions to
            // this same list merge cleanly.
            const Divider(height: 32),
            ListTile(
              leading: const Icon(Icons.school_outlined),
              title: const Text('Replay the tutorial'),
              subtitle: const Text('A one-minute walk through everything'),
              onTap: () => TutorialWalkthrough.show(
                context,
                steps: TutorialWalkthrough.homeSteps,
              ),
            ),
            const Divider(height: 32),
            ListTile(
              leading: const Icon(Icons.help_outline),
              title: const Text('How to play'),
              subtitle: const Text('Rules for Ludo and Snakes & Ladders'),
              onTap: () => pushAppScreen<void>(
                context,
                name: AppRoutes.rules,
                builder: (_) => const RulesScreen(),
              ),
            ),
            const ListTile(
              leading: Icon(Icons.info_outline),
              title: Text('Game Club'),
              subtitle: Text(
                'Ludo & Snakes and Ladders · local play, '
                'bots and pass-and-play. Progress and stats are stored '
                'on this device only.',
              ),
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
