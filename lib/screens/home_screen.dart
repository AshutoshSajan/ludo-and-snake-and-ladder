import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../engine/core/player_profiles.dart';
import '../ui/ludo/ludo_board_painter.dart';
import '../ui/snakes/snakes_board_painter.dart';
import '../ui/theme.dart';
import 'home_widgets.dart';
import 'online_lobby_screen.dart';
import 'scoreboard_screen.dart';
import 'settings_screen.dart';
import 'setup_screen.dart';

/// Home: the club entrance — pick a table.
class HomeScreen extends ConsumerWidget {
  const HomeScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
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
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 520),
              child: ListView(
                padding: const EdgeInsets.all(24),
                shrinkWrap: true,
                children: [
                  const SizedBox(height: 12),
                  const ClubHeader(),
                  const SizedBox(height: 28),
                  GameCard(
                    title: 'Ludo',
                    subtitle:
                        'Classic race home · 2–4 players · friends or bots',
                    preview: CustomPaint(
                      size: const Size(120, 120),
                      painter: LudoBoardPainter(),
                    ),
                    onTap: () => _openSetup(context, GameKind.ludo),
                  ),
                  const SizedBox(height: 16),
                  GameCard(
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
                          icon: const Icon(Icons.wifi, size: 18),
                          label: const Text('Play Online'),
                          onPressed: () => Navigator.of(context).push(
                            MaterialPageRoute(
                              builder: (_) => const OnlineLobbyScreen(),
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(width: 10),
                      IconButton.outlined(
                        onPressed: () => Navigator.of(context).push(
                          MaterialPageRoute(
                            builder: (_) => const ScoreboardScreen(),
                          ),
                        ),
                        icon: const Icon(Icons.emoji_events),
                        tooltip: 'Leaderboard',
                      ),
                      const SizedBox(width: 10),
                      IconButton.outlined(
                        onPressed: () => Navigator.of(context).push(
                          MaterialPageRoute(
                            builder: (_) => const SettingsScreen(),
                          ),
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
      ),
    );
  }

  void _openSetup(BuildContext context, GameKind game) {
    Navigator.of(context)
        .push(MaterialPageRoute(builder: (_) => SetupScreen(game: game)));
  }
}
