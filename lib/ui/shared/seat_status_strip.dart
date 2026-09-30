import 'package:flutter/material.dart';

import '../../services/online_client.dart';
import 'auto_mode_badge.dart';
import '../theme.dart';

/// Who is actually at this table: which seat the room is playing for, and
/// which corner just went empty because someone walked out.
///
/// It stays invisible while everything is normal — a room where all four
/// people are present and playing has nothing to report, and the game gets
/// the space back. A permanent roster is the thing people scroll past without
/// reading, which is exactly how a seat that stopped playing came to look
/// like a frozen game.
///
/// Shared by the Ludo board and the Snakes board, because the question "is
/// nobody coming, or did they quit?" reads the same on either one. The lobby
/// asks it too, but there the answer sits inside each roster row instead of
/// in a strip above a board.
class SeatStatusStrip extends StatelessWidget {
  const SeatStatusStrip({required this.seats, this.mySeatId, super.key});

  final List<LobbySeat> seats;

  /// Our own seat id, so the strip can say "playing for *you*" rather than
  /// pointing at a name we already know.
  final String? mySeatId;

  @override
  Widget build(BuildContext context) {
    final notable = [
      for (final s in seats)
        if (s.status != SeatStatus.connected || !s.live) s,
    ];
    if (notable.isEmpty) return const SizedBox.shrink();
    return Material(
      color: Colors.black.withValues(alpha: 0.31),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 4, 12, 6),
        child: Wrap(
          spacing: 12,
          runSpacing: 2,
          children: [for (final s in notable) _chip(s)],
        ),
      ),
    );
  }

  Widget _chip(LobbySeat s) {
    final mine = mySeatId != null && s.seatId == mySeatId;
    final dot = Container(
      width: 8,
      height: 8,
      decoration: BoxDecoration(
        color: AppColors.ludo(s.color),
        shape: BoxShape.circle,
      ),
    );

    // Autoplay renders on its own: a name plus a spinning loop, explained on
    // the loop. It used to print "playing for them" beside every auto seat and
    // repeat the same words in the chip tooltip, which said the thing twice and
    // spent the name's width on it. The badge owns its tooltip, so this branch
    // must not wrap the row in another one — the outer tooltip would swallow
    // the badge's and the old wording would come straight back.
    if (s.status == SeatStatus.auto) {
      return Row(
        key: ValueKey('seat-${s.seatId}'),
        mainAxisSize: MainAxisSize.min,
        children: [
          dot,
          const SizedBox(width: 4),
          Text(
            mine ? 'You' : s.name,
            style: const TextStyle(fontSize: 12, color: AppColors.gold),
          ),
          const SizedBox(width: 4),
          AutoModeBadge(seatName: s.name, mine: mine),
        ],
      );
    }

    // Everything else keeps the name-plus-status shape and the chip tooltip.
    final (IconData icon, String theirs, String mineText, Color tint) =
        switch (s.status) {
      SeatStatus.left => (
          Icons.person_off_outlined,
          'left the game',
          'left the game',
          AppColors.danger,
        ),
      SeatStatus.auto => (Icons.sync, '', '', AppColors.gold),
      _ => s.live
          ? (Icons.circle, '', '', Colors.white70)
          : (
              Icons.wifi_off,
              'connection lost',
              'waiting on your connection',
              Colors.white70,
            ),
    };
    return Tooltip(
      message: mine
          ? switch (s.status) {
              SeatStatus.left => 'You left this game.',
              SeatStatus.connected when !s.live =>
                'Your own link to the table has dropped — the others are waiting it out.',
              _ => 'You',
            }
          : '${s.name} — $theirs',
      child: Row(
        key: ValueKey('seat-${s.seatId}'),
        mainAxisSize: MainAxisSize.min,
        children: [
          dot,
          const SizedBox(width: 4),
          Text(
            mine ? 'You · $mineText' : '${s.name} · $theirs',
            style: TextStyle(fontSize: 12, color: tint),
          ),
          const SizedBox(width: 3),
          Icon(icon, size: 13, color: tint),
        ],
      ),
    );
  }
}
