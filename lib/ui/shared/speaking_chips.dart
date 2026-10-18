import 'package:flutter/material.dart';

import '../theme.dart';

/// The "somebody is talking" notice for every voice surface.
///
/// A row of one chip per speaking seat — name on the pill, live bars as
/// the icon, felt-gold palette so it reads as a property of the table —
/// and `SizedBox.shrink()` while nobody talks, so a quiet table shows
/// nothing rather than an empty plate. The speaker sees their own chip
/// too ("You"): hearing yourself described back is what makes mute-level
/// confusion (am I hot? am I muted?) answerable at a glance.
class SpeakingChips extends StatelessWidget {
  const SpeakingChips({super.key, required this.names});

  /// Display names, caller-resolved (own seat → "You", seat ids → the
  /// lobby roster's name), in no particular order.
  final List<String> names;

  @override
  Widget build(BuildContext context) {
    if (names.isEmpty) return const SizedBox.shrink();
    return Wrap(
      spacing: 8,
      runSpacing: 6,
      children: [for (final name in names) _chip(name)],
    );
  }

  Widget _chip(String name) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
    decoration: BoxDecoration(
      color: AppColors.gold.withAlpha(28),
      border: Border.all(color: AppColors.gold.withAlpha(120)),
      borderRadius: BorderRadius.circular(14),
    ),
    child: Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        const Icon(Icons.graphic_eq, size: 14, color: AppColors.gold),
        const SizedBox(width: 5),
        Text(name, style: const TextStyle(color: AppColors.gold, fontSize: 12)),
      ],
    ),
  );
}
