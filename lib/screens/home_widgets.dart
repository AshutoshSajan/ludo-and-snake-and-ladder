import 'package:flutter/material.dart';

import '../services/sound_service.dart';
import '../ui/theme.dart';

/// Big "Game Club" header.
class ClubHeader extends StatelessWidget {
  const ClubHeader({super.key});

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Text('🎲', style: Theme.of(context).textTheme.displayMedium),
        const SizedBox(height: 6),
        Text(
          'Game Club',
          style: Theme.of(context).textTheme.headlineLarge?.copyWith(
                fontWeight: FontWeight.w900,
                color: AppColors.gold,
                letterSpacing: 1.2,
              ),
        ),
        const Text(
          'Tabletop classics, local & cozy',
          style: TextStyle(color: Colors.white70),
        ),
      ],
    );
  }
}

/// Selectable game card with a painted board preview.
class GameCard extends StatelessWidget {
  const GameCard({
    super.key,
    required this.title,
    required this.subtitle,
    required this.preview,
    required this.onTap,
  });

  final String title;
  final String subtitle;
  final Widget preview;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Card(
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: () {
          Haptics.light();
          onTap();
        },
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Row(
            children: [
              Container(
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(12),
                  boxShadow: const [
                    BoxShadow(color: Colors.black38, blurRadius: 8),
                  ],
                ),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(12),
                  child: SizedBox(
                      width: 96, height: 96, child: FittedBox(child: preview)),
                ),
              ),
              const SizedBox(width: 16),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(title,
                        style: Theme.of(context)
                            .textTheme
                            .titleLarge
                            ?.copyWith(fontWeight: FontWeight.w800)),
                    const SizedBox(height: 4),
                    Text(subtitle,
                        style: const TextStyle(
                            color: Colors.white70, fontSize: 13)),
                    const SizedBox(height: 10),
                    Text('Play now →',
                        style: TextStyle(
                            color: AppColors.gold,
                            fontWeight: FontWeight.w700,
                            fontSize: 13)),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
