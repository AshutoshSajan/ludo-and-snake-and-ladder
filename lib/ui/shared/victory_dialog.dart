import 'package:flutter/material.dart';

import '../theme.dart';

/// Podium shown when a game ends.
class VictoryDialog extends StatelessWidget {
  const VictoryDialog({
    super.key,
    required this.title,
    required this.rankedNames,
    required this.onRematch,
    required this.onHome,
  });

  final String title;
  final List<String> rankedNames; // winner first
  final VoidCallback onRematch;
  final VoidCallback onHome;

  static const _medals = ['🏆', '🥈', '🥉'];

  @override
  Widget build(BuildContext context) {
    return Dialog(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text('🏆', style: TextStyle(fontSize: 56)),
            const SizedBox(height: 8),
            Text(
              title,
              style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                    fontWeight: FontWeight.w800,
                    color: AppColors.gold,
                  ),
            ),
            const SizedBox(height: 16),
            for (var i = 0; i < rankedNames.length; i++)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 4),
                child: Row(
                  children: [
                    SizedBox(
                      width: 36,
                      child: Text(
                        i < 3 ? _medals[i] : '${i + 1}.',
                        style: const TextStyle(fontSize: 18),
                      ),
                    ),
                    Expanded(
                      child: Text(
                        rankedNames[i],
                        style: TextStyle(
                          fontSize: i == 0 ? 18 : 15,
                          fontWeight: i == 0 ? FontWeight.w800 : FontWeight.w400,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            const SizedBox(height: 20),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceEvenly,
              children: [
                OutlinedButton(onPressed: onHome, child: const Text('Home')),
                FilledButton(onPressed: onRematch, child: const Text('Rematch')),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
