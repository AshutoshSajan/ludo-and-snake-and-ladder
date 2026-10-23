import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../app_router.dart';
import '../app_routes.dart';
import '../engine/core/player_profiles.dart';
import '../providers/app_providers.dart';
import '../services/friend_signals.dart';
import '../ui/admin_badge.dart';
import '../ui/club_widgets.dart';
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
  /// Whether the ask has already been handed to the frame scheduler. One
  /// ask per home visit, never a second one from a rebuild.
  bool _askScheduled = false;

  /// Schedules the first-run ask the first time home is the route on top.
  ///
  /// Home is built underneath every deep link (`/join/ABCD`, `/friends/…`)
  /// so back leaves the app only after the linked screen. Asking from
  /// `initState` meant the dialog opened over that linked screen — a fresh
  /// browser tab following an invite got the tour prompt instead of the
  /// invite. [ModalRoute.of] is a dependency, so when the linked screen pops
  /// back to home this build runs again and the ask is still owed then.
  void _scheduleTutorialAsk(BuildContext context) {
    if (_askScheduled) return;
    if (ModalRoute.of(context)?.isCurrent != true) return;
    _askScheduled = true;
    // After the first frame: the navigator must be live to host the dialog.
    WidgetsBinding.instance.addPostFrameCallback((_) => _maybeAskForTutorial());
  }

  /// The one-time ask. No `tutorialAsked` flag yet? Offer the tour once,
  /// never nag twice: answering — either way — writes the flag before the
  /// tour even starts, so a crash mid-dialog or a quick reopen shows no
  /// second ask. Accepting launches the walkthrough immediately.
  Future<void> _maybeAskForTutorial() async {
    final asked = await ref.read(storageProvider).loadTutorialAsked();
    if (!mounted || asked) return;
    // The player may have left home while storage answered (tapped Play
    // Online, say). Don't cover that screen; the ask returns when home does.
    if (ModalRoute.of(context)?.isCurrent != true) {
      _askScheduled = false;
      return;
    }
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
    _scheduleTutorialAsk(context);
    final admin = ref.watch(adminSessionProvider);
    return Scaffold(
      body: ClubBackground(
        child: SafeArea(
          // Rule 11: the home cards sit in the same reading column the room
          // creation form uses, so the two screens read as one family instead
          // of a wide menu and a narrow form trading widths underneath you.
          // The gradient stays full-bleed: a page background wants the window.
          child: ContentColumn(
            child: SingleChildScrollView(
              padding: const EdgeInsets.fromLTRB(20, 22, 20, 28),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  const ClubHeader(),
                  // Signed-in admins get a visible identity chip (and a way
                  // back to the dashboard). Nobody else sees anything: there
                  // is deliberately no admin entry point for signed-out users.
                  if (admin != null) ...[
                    const SizedBox(height: 14),
                    Center(child: AdminBadge(session: admin)),
                  ],
                  const SizedBox(height: 22),
                  // The `tour-…` keys are the tutorial's targets: the
                  // walkthrough finds these widgets by key and spots them.
                  GameCard(
                    key: const ValueKey('tour-ludo'),
                    eyebrow: 'The classic',
                    title: 'Ludo',
                    subtitle:
                        'Race four pieces home. Capture, block, and take the '
                        'long way only when you must.',
                    meta: const ['2–4 players', 'Friends or bots'],
                    preview: CustomPaint(
                      size: const Size(120, 120),
                      painter: LudoBoardPainter(),
                    ),
                    onTap: () => _openSetup(context, GameKind.ludo),
                  ),
                  const SizedBox(height: 14),
                  GameCard(
                    key: const ValueKey('tour-snakes'),
                    eyebrow: 'The family favourite',
                    title: 'Snakes & Ladders',
                    subtitle:
                        'Roll, climb and slide. A hundred squares, nine ladders '
                        'and ten snakes between you and the top.',
                    meta: const ['2–10 players', 'Hot-seat or bots'],
                    preview: CustomPaint(
                      size: const Size(120, 120),
                      painter: SnakesBoardPainter(),
                    ),
                    onTap: () => _openSetup(context, GameKind.snakes),
                  ),
                  const SizedBox(height: 20),
                  _OnlineDoor(
                    key: const ValueKey('tour-online'),
                    onTap: () => pushAppScreen<void>(
                      context,
                      name: AppRoutes.online,
                      builder: (_) => const OnlineLobbyScreen(),
                    ),
                  ),
                  const SizedBox(height: 14),
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Expanded(
                        child: ClubDoor(
                          key: const ValueKey('tour-friends'),
                          icon: Icons.group_outlined,
                          label: 'Friends',
                          detail: 'Your circle',
                          badge: ValueListenableBuilder<int>(
                            valueListenable: friendSignals.incomingRequests,
                            builder: (context, pending, _) => Badge(
                              key: const ValueKey('home-friends-badge'),
                              isLabelVisible: pending > 0,
                              backgroundColor: AppColors.danger,
                              textColor: Colors.white,
                              label: Text(
                                '$pending',
                                style: const TextStyle(
                                  fontSize: 10,
                                  fontWeight: FontWeight.w800,
                                ),
                              ),
                              child: const SizedBox(width: 22, height: 22),
                            ),
                          ),
                          onTap: () => pushAppScreen<void>(
                            context,
                            name: AppRoutes.friends,
                            builder: (_) => const FriendsScreen(),
                          ),
                        ),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: ClubDoor(
                          key: const ValueKey('tour-leaderboard'),
                          icon: Icons.emoji_events,
                          label: 'Leaderboard',
                          detail: 'Club standings',
                          onTap: () => pushAppScreen<void>(
                            context,
                            name: AppRoutes.leaderboard,
                            builder: (_) => const ScoreboardScreen(),
                          ),
                        ),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: ClubDoor(
                          key: const ValueKey('tour-settings'),
                          icon: Icons.settings_outlined,
                          label: 'Settings',
                          detail: 'Set the table',
                          onTap: () => pushAppScreen<void>(
                            context,
                            name: AppRoutes.settings,
                            builder: (_) => const SettingsScreen(),
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 22),
                  const _HomeFooter(),
                ],
              ),
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

/// Online is the one door that leads outside the room, so it gets a brass
/// ticket of its own rather than sharing the little side-door tiles.
class _OnlineDoor extends StatelessWidget {
  const _OnlineDoor({super.key, required this.onTap});

  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return ClubCard(
      background: AppColors.gold,
      borderColor: AppColors.brassDeep.withValues(alpha: 0.55),
      padding: const EdgeInsets.fromLTRB(16, 15, 14, 15),
      onTap: onTap,
      child: Row(
        children: [
          Container(
            width: 46,
            height: 46,
            decoration: const BoxDecoration(
              color: AppColors.ink,
              shape: BoxShape.circle,
            ),
            child: const Icon(Icons.wifi, color: AppColors.gold, size: 22),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Play Online',
                  style: Theme.of(context).textTheme.headlineSmall
                      ?.copyWith(color: AppColors.ink, fontSize: 23, height: 1),
                ),
                const SizedBox(height: 4),
                const Text(
                  'Rooms, table chat, voice and the club leaderboard.',
                  style: TextStyle(
                    fontFamily: AppFonts.body,
                    color: AppColors.inkSoft,
                    fontSize: 11.5,
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 8),
          Container(
            width: 34,
            height: 34,
            decoration: BoxDecoration(
              color: AppColors.ink.withValues(alpha: 0.10),
              shape: BoxShape.circle,
            ),
            child: const Icon(
              Icons.arrow_forward,
              size: 17,
              color: AppColors.ink,
            ),
          ),
        ],
      ),
    );
  }
}

class _HomeFooter extends StatelessWidget {
  const _HomeFooter();

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Container(
              width: 20,
              height: 1,
              color: AppColors.gold.withValues(alpha: 0.35),
            ),
            const SizedBox(width: 10),
            const Flexible(
              child: Text(
                'NO ACCOUNT · NO ADS · JUST THE TABLE',
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontFamily: AppFonts.body,
                  color: AppColors.paperDeep,
                  fontSize: 8.5,
                  fontWeight: FontWeight.w700,
                  letterSpacing: 1.5,
                ),
              ),
            ),
            const SizedBox(width: 10),
            Container(
              width: 20,
              height: 1,
              color: AppColors.gold.withValues(alpha: 0.35),
            ),
          ],
        ),
      ],
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
                ?.copyWith(color: AppColors.gold),
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
