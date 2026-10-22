import 'package:flutter/material.dart';

import '../../services/online_client.dart';
import '../page_app_bar.dart';
import '../theme.dart';
import 'responsive_chat_dock.dart';

/// The bottom-sheet presentation of the shared table-chat panel.
///
/// The live table surfaces now use [ResponsiveChatDock] (docked on wide
/// windows, an overlay on phones). This wrapper stays as the compact
/// alternative the existing sheet tests exercise, and keeps the panel in
/// one place: the same header, transcript, composer, GIF, voice-note and
/// author-menu code as the dock — not a second chat implementation.
class GameChatSheet extends StatefulWidget {
  const GameChatSheet({super.key, required this.client});

  final OnlineClient client;

  /// Opens the sheet. Returns when it is dismissed.
  ///
  /// The sheet is capped at a little over half the screen: it answers
  /// "what did the table say?" while the board still answers "whose turn is
  /// it?" — a full-height sheet left the reader blind to the game they were
  /// playing. The cap, instead of a fixed height, keeps a quiet table's sheet
  /// small and a busy one's scrollable without ever covering the board
  /// outright. It is also capped to the app's reading width, so a desktop
  /// window does not stretch chat across the whole screen.
  static Future<void> show(BuildContext context, OnlineClient client) {
    final screen = MediaQuery.sizeOf(context).height;
    return showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      constraints: BoxConstraints(
        maxHeight: screen * 0.55,
        maxWidth: kContentMaxWidth,
      ),
      backgroundColor: AppColors.feltLight,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(18)),
      ),
      builder: (_) => GameChatSheet(client: client),
    );
  }

  @override
  State<GameChatSheet> createState() => _GameChatSheetState();
}

class _GameChatSheetState extends State<GameChatSheet> {
  @override
  void initState() {
    super.initState();
    // Opening the sheet is the read act, so mark it as such immediately —
    // otherwise a message arriving while it is open would still count as
    // unread and the dot would never clear.
    widget.client.setChatOpen(true);
  }

  @override
  void dispose() {
    widget.client.setChatOpen(false);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return TableChatPanel(
      client: widget.client,
      sheet: true,
      showDragHandle: true,
    );
  }
}
