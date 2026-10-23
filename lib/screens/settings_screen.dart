import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../app_router.dart';
import '../app_routes.dart';
import '../providers/app_providers.dart';
import '../services/server_url.dart';
import '../ui/club_widgets.dart';
import '../ui/page_app_bar.dart';
import '../ui/shared/bug_report_sheet.dart';
import '../ui/shared/tutorial_walkthrough.dart';
import '../ui/theme.dart';
import 'contact_screen.dart';
import 'friends_screen.dart';
import 'rules_screen.dart';

/// Settings: how the table feels, who to reach, and how to learn the games.
///
/// Every preference is local and applies instantly through
/// [soundEnabledProvider], [hapticsEnabledProvider] and
/// [animationsEnabledProvider]. The rows below the toggles push exactly the
/// routes this screen has always pushed — the redesign changes the surface,
/// not the behaviour.
class SettingsScreen extends ConsumerWidget {
  const SettingsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final sound = ref.watch(soundEnabledProvider);
    final haptics = ref.watch(hapticsEnabledProvider);
    final anims = ref.watch(animationsEnabledProvider);

    return Scaffold(
      appBar: PageAppBar(title: 'Settings'),
      body: ClubBackground(
        child: SafeArea(
          child: ContentColumn(
            child: ListView(
              // The same 16px inset the page bar uses, so the hero card and the
              // app bar title share one edge on every window size.
              padding: const EdgeInsets.fromLTRB(16, 18, 16, 32),
              children: [
                const _ClubHero(),
                const SizedBox(height: 24),
                const _SectionLabel('Table feel'),
                _SurfaceCard(
                  children: [
                    _ToggleRow(
                      key: const ValueKey('settings-row-sound'),
                      switchKey: const ValueKey('settings-switch-sound'),
                      icon: Icons.volume_up,
                      title: 'Sound effects',
                      description: 'Dice, hops, captures and fanfares',
                      value: sound,
                      onToggle: () =>
                          ref.read(soundEnabledProvider.notifier).toggle(),
                    ),
                    _ToggleRow(
                      key: const ValueKey('settings-row-haptics'),
                      switchKey: const ValueKey('settings-switch-haptics'),
                      icon: Icons.vibration,
                      title: 'Haptics',
                      description: 'A gentle buzz on rolls and moves',
                      value: haptics,
                      onToggle: () =>
                          ref.read(hapticsEnabledProvider.notifier).toggle(),
                    ),
                    _ToggleRow(
                      key: const ValueKey('settings-row-animations'),
                      switchKey: const ValueKey('settings-switch-animations'),
                      icon: Icons.animation,
                      title: 'Board animations',
                      description: 'Glow and rings. Off saves battery.',
                      value: anims,
                      onToggle: () =>
                          ref.read(animationsEnabledProvider.notifier).toggle(),
                    ),
                  ],
                ),
                const SizedBox(height: 22),
                const _SectionLabel('Friends & support'),
                _SurfaceCard(
                  children: [
                    _LinkRow(
                      key: const ValueKey('settings-row-friends'),
                      icon: Icons.group_outlined,
                      title: 'Friends',
                      description: 'Add friends, chat, and invite them over.',
                      onTap: () => pushAppScreen<void>(
                        context,
                        name: AppRoutes.friends,
                        builder: (_) => const FriendsScreen(),
                      ),
                    ),
                    _LinkRow(
                      key: const ValueKey('settings-row-report'),
                      icon: Icons.bug_report,
                      title: 'Report an issue',
                      description: 'Something broken, or an idea? Tell us.',
                      onTap: () => BugReportSheet.show(
                        context,
                        serverUrl: defaultServerUrl(),
                      ),
                    ),
                    _LinkRow(
                      key: const ValueKey('settings-row-contact'),
                      icon: Icons.mail_outline,
                      title: 'Contact us',
                      description: 'Questions or feedback? Leave an email.',
                      onTap: () => pushAppScreen<void>(
                        context,
                        name: AppRoutes.contact,
                        builder: (_) =>
                            ContactScreen(serverUrl: defaultServerUrl()),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 22),
                const _SectionLabel('Learn'),
                _SurfaceCard(
                  children: [
                    _LinkRow(
                      key: const ValueKey('settings-row-tutorial'),
                      icon: Icons.school_outlined,
                      title: 'Replay the tutorial',
                      description: 'A one-minute walk through everything',
                      onTap: () => TutorialWalkthrough.show(
                        context,
                        steps: TutorialWalkthrough.homeSteps,
                      ),
                    ),
                    _LinkRow(
                      key: const ValueKey('settings-row-rules'),
                      icon: Icons.help_outline,
                      title: 'How to play',
                      description: 'Rules for Ludo and Snakes & Ladders',
                      onTap: () => pushAppScreen<void>(
                        context,
                        name: AppRoutes.rules,
                        builder: (_) => const RulesScreen(),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 22),
                const _SectionLabel('About'),
                const _AboutCard(),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// The club mark, the club name and one warm line: this is a table, not a
/// system preferences pane.
class _ClubHero extends StatelessWidget {
  const _ClubHero();

  @override
  Widget build(BuildContext context) {
    return ClubCard(
      accent: true,
      padding: const EdgeInsets.fromLTRB(16, 17, 16, 16),
      child: Stack(
        children: [
          // A washed-out die in the corner, the same quiet watermark the
          // leaderboard uses behind its champion card.
          Positioned(
            right: -22,
            top: -30,
            child: Icon(
              Icons.casino_outlined,
              size: 132,
              color: AppColors.textPrimary.withValues(alpha: 0.045),
            ),
          ),
          Row(
            children: [
              Container(
                width: 58,
                height: 58,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  gradient: const RadialGradient(
                    colors: [AppColors.feltLight, AppColors.feltDeep],
                  ),
                  border: Border.all(color: AppColors.gold, width: 1.6),
                  boxShadow: [
                    BoxShadow(
                      color: AppColors.feltDeep.withValues(alpha: 0.28),
                      blurRadius: 10,
                      offset: const Offset(0, 4),
                    ),
                  ],
                ),
                child: const Icon(
                  Icons.casino,
                  color: AppColors.gold,
                  size: 28,
                ),
              ),
              const SizedBox(width: 15),
              const Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      'LOCAL TABLE SETTINGS',
                      style: TextStyle(
                        fontFamily: AppFonts.body,
                        color: AppColors.gold,
                        fontSize: 9.5,
                        fontWeight: FontWeight.w800,
                        letterSpacing: 1.7,
                      ),
                    ),
                    SizedBox(height: 4),
                    Text(
                      'Game Club',
                      style: TextStyle(
                        fontFamily: AppFonts.display,
                        color: AppColors.textPrimary,
                        fontSize: 26,
                        fontWeight: FontWeight.w600,
                        height: 1.05,
                      ),
                    ),
                    SizedBox(height: 5),
                    Text(
                      'Set the table to your taste — it all stays on this '
                      'device.',
                      style: TextStyle(
                        fontFamily: AppFonts.body,
                        color: AppColors.textSecondary,
                        fontSize: 12.5,
                        height: 1.4,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// An uppercase, letter-spaced section caption with a hairline gold rule —
/// the page's quiet table of contents.
class _SectionLabel extends StatelessWidget {
  const _SectionLabel(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(left: 4, bottom: 9),
      child: Row(
        children: [
          Text(
            text.toUpperCase(),
            style: const TextStyle(
              fontFamily: AppFonts.body,
              color: AppColors.gold,
              fontSize: 10,
              fontWeight: FontWeight.w800,
              letterSpacing: 1.7,
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Container(
              height: 1,
              color: AppColors.gold.withValues(alpha: 0.20),
            ),
          ),
        ],
      ),
    );
  }
}

/// A felt card that hosts a group of rows, with a hairline between them.
class _SurfaceCard extends StatelessWidget {
  const _SurfaceCard({required this.children});

  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    return ClubCard(
      padding: EdgeInsets.zero,
      radius: 18,
      child: Column(
        children: [
          for (var i = 0; i < children.length; i++) ...[
            if (i > 0)
              Divider(
                height: 1,
                thickness: 1,
                indent: 66,
                endIndent: 14,
                color: AppColors.textPrimary.withValues(alpha: 0.09),
              ),
            children[i],
          ],
        ],
      ),
    );
  }
}

/// One label, one supporting line, and a switch on the right.
///
/// The whole row is the target, not just the switch: the switch is painted
/// for state but its pointer is off, so a tap anywhere is handled once by the
/// row's [InkWell]. The two text lines form the merged semantics label and
/// the row carries the on/off state for screen readers.
class _ToggleRow extends StatelessWidget {
  const _ToggleRow({
    super.key,
    required this.switchKey,
    required this.icon,
    required this.title,
    required this.description,
    required this.value,
    required this.onToggle,
  });

  final Key switchKey;
  final IconData icon;
  final String title;
  final String description;
  final bool value;
  final VoidCallback onToggle;

  @override
  Widget build(BuildContext context) {
    return MergeSemantics(
      child: Semantics(
        toggled: value,
        child: InkWell(
          onTap: onToggle,
          child: ConstrainedBox(
            constraints: const BoxConstraints(minHeight: 64),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(14, 12, 10, 12),
              child: Row(
                children: [
                  _RowIcon(icon: icon, active: value),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          title,
                          style: const TextStyle(
                            fontFamily: AppFonts.body,
                            color: AppColors.textPrimary,
                            fontSize: 15,
                            fontWeight: FontWeight.w800,
                          ),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          description,
                          style: const TextStyle(
                            fontFamily: AppFonts.body,
                            color: AppColors.textSecondary,
                            fontSize: 12,
                            height: 1.35,
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 8),
                  ExcludeSemantics(
                    child: IgnorePointer(
                      child: Switch(
                        key: switchKey,
                        value: value,
                        onChanged: (_) => onToggle(),
                        activeThumbColor: AppColors.darkInk,
                        activeTrackColor: AppColors.gold.withValues(
                          alpha: 0.75,
                        ),
                        inactiveThumbColor: AppColors.paperLight,
                        inactiveTrackColor: AppColors.textPrimary.withValues(
                          alpha: 0.12,
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// One destination in a group: icon, title, supporting line, chevron.
class _LinkRow extends StatelessWidget {
  const _LinkRow({
    super.key,
    required this.icon,
    required this.title,
    required this.description,
    required this.onTap,
  });

  final IconData icon;
  final String title;
  final String description;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return MergeSemantics(
      child: Semantics(
        button: true,
        child: InkWell(
          onTap: onTap,
          child: ConstrainedBox(
            constraints: const BoxConstraints(minHeight: 64),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(14, 12, 10, 12),
              child: Row(
                children: [
                  _RowIcon(icon: icon, active: true),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          title,
                          style: const TextStyle(
                            fontFamily: AppFonts.body,
                            color: AppColors.textPrimary,
                            fontSize: 15,
                            fontWeight: FontWeight.w800,
                          ),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          description,
                          style: const TextStyle(
                            fontFamily: AppFonts.body,
                            color: AppColors.textSecondary,
                            fontSize: 12,
                            height: 1.35,
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 8),
                  Icon(
                    Icons.chevron_right,
                    size: 20,
                    color: AppColors.textPrimary.withValues(alpha: 0.30),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// A 40px tinted tile behind a row's icon. The gold wash is the "on" state
/// for toggles and the standing accent for destinations.
class _RowIcon extends StatelessWidget {
  const _RowIcon({required this.icon, required this.active});

  final IconData icon;
  final bool active;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 40,
      height: 40,
      decoration: BoxDecoration(
        color: active
            ? AppColors.gold.withValues(alpha: 0.20)
            : AppColors.textPrimary.withValues(alpha: 0.06),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: active
              ? AppColors.brass.withValues(alpha: 0.38)
              : AppColors.textPrimary.withValues(alpha: 0.08),
        ),
      ),
      child: Icon(
        icon,
        size: 20,
        color: active
            ? AppColors.gold
            : AppColors.textPrimary.withValues(alpha: 0.58),
      ),
    );
  }
}

/// The quiet colophon: what the club is, and the one tip worth keeping.
class _AboutCard extends StatelessWidget {
  const _AboutCard();

  @override
  Widget build(BuildContext context) {
    final body = TextStyle(
      fontFamily: AppFonts.body,
      color: AppColors.textSecondary,
      fontSize: 13,
      height: 1.45,
    );
    return _SurfaceCard(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 14),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  const Icon(
                    Icons.info_outline,
                    size: 18,
                    color: AppColors.gold,
                  ),
                  const SizedBox(width: 8),
                  Text(
                    'About the club',
                    style: const TextStyle(
                      fontFamily: AppFonts.body,
                      color: AppColors.textPrimary,
                      fontSize: 15,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              Text(
                'Ludo & Snakes and Ladders for the table — bots, '
                'pass-and-play, or a room online. Progress and stats stay on '
                'this device.',
                style: body,
              ),
              const SizedBox(height: 14),
              Container(
                height: 1,
                color: AppColors.textPrimary.withValues(alpha: 0.10),
              ),
              const SizedBox(height: 12),
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Icon(
                    Icons.lightbulb_outline,
                    size: 16,
                    color: AppColors.brass,
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      'Tip: the lightbulb in a game hints at a move, undo '
                      'takes back a roll, and auto-mode lets the table play '
                      'while you rest.',
                      style: body,
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ],
    );
  }
}
