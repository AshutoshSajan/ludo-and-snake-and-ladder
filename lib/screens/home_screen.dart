import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../app_router.dart';
import '../app_routes.dart';
import '../engine/core/player_profiles.dart';
import '../providers/app_providers.dart';
import '../services/friend_signals.dart';
import '../ui/admin_badge.dart';
import '../ui/page_app_bar.dart';
import '../ui/ludo/ludo_board_painter.dart';
import '../ui/snakes/snakes_board_painter.dart';
import '../ui/shared/tutorial_walkthrough.dart';
import '../ui/theme.dart';
import 'home_widgets.dart';
import 'friends_screen.dart';
import 'online_lobby_screen.dart';
import 'scoreboard_screen.dart';
import 'settings_screen.dart';
import 'setup_screen.dart';

/// Home: the club entrance — pick a table.
class HomeScreen extends ConsumerStatefulWidget {
  const HomeScreen({super.key});

  @override
  ConsumerState<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends ConsumerState<HomeScreen> {
  @override
  void initState() {
    super.initState();
    // The first-run tutorial ask goes out once storage answers, after the
    // first frame (the navigator must be live to host the dialog).
    WidgetsBinding.instance.addPostFrameCallback((_) => _maybeAskForTutorial());
  }

  /// The one-time ask. No `tutorialAsked` flag yet? Offer the tour once,
  /// never nag twice: answering — either way — writes the flag before the
  /// tour even starts, so a crash mid-dialog or a quick reopen shows no
  /// second ask. Accepting launches the walkthrough immediately.
  Future<void> _maybeAskForTutorial() async {
    final asked = await ref.read(storageProvider).loadTutorialAsked();
    if (!mounted || asked) return;
    final tookTour = await showDialog<bool>(
      context: context,
      // Not dismissible: a stray outside tap is not an answer, it would
      // either nag again next time or leak a flag nobody answered.
      barrierDismissible: false,
      builder: (_) => const _TutorialAskDialog(),
    );
    if (!mounted) return;
    await ref.read(storageProvider).saveTutorialAsked(true);
    if (!mounted) return;
    if (tookTour ?? false) {
      // The dialog is gone; home's own context launches the tour — still
      // live after the save's async gap, as the mounted guard proves.
      TutorialWalkthrough.show(context, steps: TutorialWalkthrough.homeSteps);
    }
  }

  @override
  Widget build(BuildContext context) {
    final admin = ref.watch(adminSessionProvider);
    return Scaffold(
      body: Container(
        decoration: const BoxDecoration(
          gradient: RadialGradient(
            center: Alignment(0, -0.4),
            radius: 1.4,
            colors: [AppColors.feltLight, AppColors.felt],
          ),
        ),
        child: SafeArea(
          // Rule 11: the home cards sit in the same reading column the room
          // creation form uses, so the two screens read as one family instead
          // of a wide menu and a narrow form trading widths underneath you.
          // The gradient stays full-bleed: a page background wants the window.
          child: ContentColumn(
            child: ListView(
              padding: const EdgeInsets.all(24),
              shrinkWrap: true,
              children: [
                const SizedBox(height: 12),
                const ClubHeader(),
                // Signed-in admins get a visible identity chip (and a way
                // back to the dashboard). Nobody else sees anything: there
                // is deliberately no admin entry point for signed-out users.
                if (admin != null) ...[
                  const SizedBox(height: 12),
                  Center(child: AdminBadge(session: admin)),
                ],
                const SizedBox(height: 28),
                // The `tour-…` keys are the tutorial's targets: the
                // walkthrough finds these widgets by key and spots them.
                GameCard(
                  key: const ValueKey('tour-ludo'),
                  title: 'Ludo',
                  subtitle: 'Classic race home · 2–4 players · friends or bots',
                  preview: CustomPaint(
                    size: const Size(120, 120),
                    painter: LudoBoardPainter(),
                  ),
                  onTap: () => _openSetup(context, GameKind.ludo),
                ),
                const SizedBox(height: 16),
                GameCard(
                  key: const ValueKey('tour-snakes'),
                  title: 'Snakes & Ladders',
                  subtitle: 'Snakes, ladders & luck · 2–10 players',
                  preview: CustomPaint(
                    size: const Size(120, 120),
                    painter: SnakesBoardPainter(),
                  ),
                  onTap: () => _openSetup(context, GameKind.snakes),
                ),
                const SizedBox(height: 16),
                // Leaderboard, online play and settings on one line. They were
                // stacked over two rows, which pushed the last one below the
                // fold on a phone and made the home screen taller than the
                // two game cards it exists to launch. "Play Online" keeps the
                // width because it is the one people come for; the other two
                // are icon buttons with tooltips.
                Row(
                  children: [
                    Expanded(
                      child: OutlinedButton.icon(
                        key: const ValueKey('tour-online'),
                        icon: const Icon(Icons.wifi, size: 18),
                        label: const Text('Play Online'),
                        onPressed: () => pushAppScreen<void>(
                          context,
                          name: AppRoutes.online,
                          builder: (_) => const OnlineLobbyScreen(),
                        ),
                      ),
                    ),
                    const SizedBox(width: 10),
                    IconButton.outlined(
                      key: const ValueKey('tour-friends'),
                      onPressed: () => pushAppScreen<void>(
                        context,
                        name: AppRoutes.friends,
                        builder: (_) => const FriendsScreen(),
                      ),
                      // The app-level watcher owns this count, so the dot is
                      // already warm before the player opens the lobby or
                      // the friends tray.
                      icon: ValueListenableBuilder<int>(
                        valueListenable: friendSignals.incomingRequests,
                        builder: (context, pending, _) => Badge(
                          key: const ValueKey('home-friends-badge'),
                          isLabelVisible: pending > 0,
                          backgroundColor: AppColors.danger,
                          textColor: Colors.white,
                          label: Text('$pending'),
                          child: const Icon(Icons.group_outlined),
                        ),
                      ),
                      tooltip: 'Friends',
                    ),
                    const SizedBox(width: 10),
                    IconButton.outlined(
                      key: const ValueKey('tour-leaderboard'),
                      onPressed: () => pushAppScreen<void>(
                        context,
                        name: AppRoutes.leaderboard,
                        builder: (_) => const ScoreboardScreen(),
                      ),
                      icon: const Icon(Icons.emoji_events),
                      tooltip: 'Leaderboard',
                    ),
                    const SizedBox(width: 10),
                    IconButton.outlined(
                      key: const ValueKey('tour-settings'),
                      onPressed: () => pushAppScreen<void>(
                        context,
                        name: AppRoutes.settings,
                        builder: (_) => const SettingsScreen(),
                      ),
                      icon: const Icon(Icons.settings_outlined),
                      tooltip: 'Settings',
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  void _openSetup(BuildContext context, GameKind game) {
    pushAppScreen<void>(
      context,
      name: game == GameKind.ludo ? AppRoutes.playLudo : AppRoutes.playSnakes,
      builder: (_) => SetupScreen(game: game),
    );
  }
}

/// The first-run ask, styled like the win podium family: a felt card with a
/// gold school icon and title over the dimmed home screen.
class _TutorialAskDialog extends StatelessWidget {
  const _TutorialAskDialog();

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.school_outlined, size: 40, color: AppColors.gold),
          const SizedBox(height: 10),
          Text(
            'First time here?',
            style: Theme.of(context).textTheme.headlineSmall
                ?.copyWith(fontWeight: FontWeight.w800, color: AppColors.gold),
          ),
          const SizedBox(height: 10),
          const Text(
            'Take a short walk through the board, the online tables and your '
            'friends — about a minute.',
            textAlign: TextAlign.center,
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(false),
          child: const Text('Not now'),
        ),
        FilledButton(
          onPressed: () => Navigator.of(context).pop(true),
          child: const Text('Take the tour'),
        ),
      ],
    );
  }
}
