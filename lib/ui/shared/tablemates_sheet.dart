/// The table's own roster strip, opened from the board: every player
/// seated at THIS table, one tap from the friend lanes (add / block /
/// report / invite hand-off) through the same [PlayerActionsSheet] the
/// lobby's seat rows use.
///
/// It exists because the seat rows live in the lobby panel — once the
/// game starts, the board replaces them and there was nothing on screen
/// to add the person you are playing with (playtest: "add friend option
/// is not there on online gameplay"). The app bar's players action on
/// the board is now the same door, from the same seats.
library;

import 'package:flutter/material.dart';

import '../../services/friend_client.dart';
import '../../services/online_client.dart';
import '../theme.dart';
import 'player_actions_sheet.dart';

class TablematesSheet extends StatelessWidget {
  const TablematesSheet({
    super.key,
    required this.client,
    this.friendClientForTest,
  });

  final OnlineClient client;

  /// Test seam: the friend HTTP client the per-player actions sheet talks
  /// through. Production leaves it null and the actions sheet builds one.
  final FriendClient? friendClientForTest;

  static void show(
    BuildContext context, {
    required OnlineClient client,
    FriendClient? friendClientForTest,
  }) {
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: AppColors.feltLight,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(18)),
      ),
      builder: (_) =>
          TablematesSheet(client: client, friendClientForTest: friendClientForTest),
    );
  }

  @override
  Widget build(BuildContext context) {
    // Spectators are seats without a player to befriend; my own seat does
    // not open the actions sheet aimed at myself. Left seats stay listed:
    // the sheet is the one place still explainable about them ("left").
    final seats = client.lobbySeats.where((s) => s.name != '?').toList();
    final mine = client.seatId;
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Text(
              'Players at this table',
              style: TextStyle(
                fontWeight: FontWeight.w800,
                color: AppColors.ivory,
              ),
            ),
            const SizedBox(height: 10),
            if (seats.isEmpty)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 12),
                child: Text(
                  'Nobody is seated yet.',
                  style: TextStyle(color: AppColors.ivory),
                ),
              )
            else
              for (final s in seats) ...[
                const SizedBox(height: 4),
                _row(context, s, mine),
              ],
          ],
        ),
      ),
    );
  }

  Widget _row(BuildContext context, LobbySeat s, String mine) {
    final color = AppColors.ludo(s.color);
    return ListTile(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      leading: Container(
        width: 14,
        height: 14,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: color,
          border: Border.all(width: 1, color: Colors.white24),
        ),
      ),
      title: Text(
        s.name,
        style: const TextStyle(color: AppColors.ivory),
      ),
      subtitle: Text(
        switch (s.status) {
          SeatStatus.left => 'left this table',
          SeatStatus.auto => 'playing on autoplay',
          _ => s.live ? 'at the table' : 'connection lost',
        },
        style: const TextStyle(fontSize: 12, color: Colors.white70),
      ),
      trailing: const Icon(Icons.chevron_right, color: Colors.white54),
      onTap: s.seatId == mine && s.seatId.isNotEmpty
          ? null
          : () {
              Navigator.of(context).pop();
              PlayerActionsSheet.show(
                context,
                serverUrl: client.serverUrl,
                mySeatId: mine,
                myName: client.name,
                myCredential: client.credential,
                peerSeatId: s.seatId,
                peerName: s.name,
                friendClientForTest: friendClientForTest,
              );
            },
    );
  }
}
