import 'package:flutter/material.dart';

import '../theme.dart';

/// One row in the seat manager.
class SeatRowData {
  SeatRowData({
    required this.index,
    required this.name,
    required this.color,
    required this.isAI,
    required this.isCurrent,
    required this.canRemove,
    this.subtitle,
  });

  final int index;
  final String name;
  final Color color;
  final bool isAI;
  final bool isCurrent;
  final bool canRemove;
  final String? subtitle; // e.g. tokens home / square
}

/// Mid-game player management: swap human <-> AI, remove seats, add seats.
/// The host view supplies add/remove/swap callbacks and the add-seat flow.
Future<void> showSeatManager(
  BuildContext context, {
  required String title,
  required List<SeatRowData> seats,
  required void Function(int index) onSwapAI,
  required void Function(int index) onSwapHuman,
  required void Function(int index) onRemove,
  required VoidCallback onAdd,
  required bool canAdd,
  required VoidCallback onChanged,
}) {
  return showModalBottomSheet(
    context: context,
    isScrollControlled: true,
    backgroundColor: AppColors.feltLight,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
    ),
    builder: (context) => _SeatManager(
      title: title,
      seats: seats,
      onSwapAI: onSwapAI,
      onSwapHuman: onSwapHuman,
      onRemove: onRemove,
      onAdd: onAdd,
      canAdd: canAdd,
      onChanged: onChanged,
    ),
  );
}

class _SeatManager extends StatelessWidget {
  const _SeatManager({
    required this.title,
    required this.seats,
    required this.onSwapAI,
    required this.onSwapHuman,
    required this.onRemove,
    required this.onAdd,
    required this.canAdd,
    required this.onChanged,
  });

  final String title;
  final List<SeatRowData> seats;
  final void Function(int) onSwapAI;
  final void Function(int) onSwapHuman;
  final void Function(int) onRemove;
  final VoidCallback onAdd;
  final bool canAdd;
  final VoidCallback onChanged;

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 16, 20, 20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(title,
                style: Theme.of(context)
                    .textTheme
                    .titleLarge
                    ?.copyWith(fontWeight: FontWeight.w800)),
            const SizedBox(height: 4),
            const Text(
              'Swap any seat to a bot or back to a human at any time. '
              'Removed players leave the game immediately.',
              style: TextStyle(color: Colors.white70, fontSize: 12.5),
            ),
            const SizedBox(height: 12),
            Flexible(
              child: ListView.builder(
                shrinkWrap: true,
                itemCount: seats.length,
                itemBuilder: (context, i) =>
                    _row(context, seats[i]),
              ),
            ),
            const SizedBox(height: 10),
            FilledButton.icon(
              onPressed: canAdd ? onAdd : null,
              icon: const Icon(Icons.person_add_alt),
              label: const Text('Add player'),
            ),
          ],
        ),
      ),
    );
  }

  Widget _row(BuildContext context, SeatRowData s) {
    return Card(
      margin: const EdgeInsets.symmetric(vertical: 4),
      child: ListTile(
        leading: CircleAvatar(
            backgroundColor: s.color,
            child: s.isCurrent
                ? const Icon(Icons.play_arrow, color: Colors.white)
                : null),
        title: Text(s.name, style: const TextStyle(fontWeight: FontWeight.w700)),
        subtitle: s.subtitle == null
            ? null
            : Text(s.subtitle!, style: const TextStyle(fontSize: 12)),
        trailing: SizedBox(
          width: 190,
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              _pillButton(
                label: s.isAI ? 'Bot' : 'Human',
                icon: s.isAI ? Icons.smart_toy : Icons.person,
                onTap: () {
                  s.isAI ? onSwapHuman(s.index) : onSwapAI(s.index);
                  onChanged();
                },
              ),
              const SizedBox(width: 6),
              _pillButton(
                label: 'Remove',
                icon: Icons.person_remove,
                danger: true,
                onTap: s.canRemove
                    ? () {
                        onRemove(s.index);
                        Navigator.of(context).pop();
                      }
                    : null,
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _pillButton({
    required String label,
    required IconData icon,
    required VoidCallback? onTap,
    bool danger = false,
  }) {
    final c = danger ? AppColors.danger : AppColors.gold;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(20),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        decoration: BoxDecoration(
          border: Border.all(color: onTap == null ? Colors.white24 : c),
          borderRadius: BorderRadius.circular(20),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 15, color: onTap == null ? Colors.white24 : c),
            const SizedBox(width: 4),
            Text(label,
                style: TextStyle(
                    fontSize: 12,
                    color: onTap == null ? Colors.white24 : c,
                    fontWeight: FontWeight.w600)),
          ],
        ),
      ),
    );
  }
}
