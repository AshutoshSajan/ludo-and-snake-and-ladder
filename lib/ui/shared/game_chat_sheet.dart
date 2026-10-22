import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app_router.dart';
import '../../app_routes.dart';
import '../../screens/friends_screen.dart';
import '../../services/friend_client.dart';
import '../../services/note_recorder.dart';
import '../../services/online_client.dart';
import '../page_app_bar.dart';
import '../theme.dart';
import 'chat_line_view.dart';
import 'gif_picker_sheet.dart';
import 'keyboard_content.dart';
import 'note_composer.dart';
import 'player_actions_sheet.dart';

/// In-game chat, as a sheet over the board.
///
/// Chat used to exist only in the lobby — the one screen where you are not
/// mid-game — so a table could not talk to itself while playing. This opens
/// from a board's app bar instead, and shows recent history plus an input.
class GameChatSheet extends ConsumerStatefulWidget {
  const GameChatSheet({super.key, required this.client});

  final OnlineClient client;

  /// Opens the sheet. Returns when it is dismissed.
  ///
  /// The sheet is capped at a little over half the screen: it answers
  /// "what did the table say?" while the board still answers "whose turn is
  /// it?" — a full-height sheet left the reader blind to the game they were
  /// playing, and turns kept passing underneath a chat they could not see.
  /// The cap, instead of a fixed height, keeps a quiet table's sheet small
  /// and a busy one's scrollable without ever covering the board outright.
  ///
  /// The sheet is also capped to the app's reading width: on a desktop
  /// window a bottom sheet spans the whole width by default, and a chat
  /// stretched across a laptop is the same "not like every other screen"
  /// problem the page bodies were fixed for. Constrained, it reads as the
  /// same centered column the headers draw.
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
  ConsumerState<GameChatSheet> createState() => _GameChatSheetState();
}

class _GameChatSheetState extends ConsumerState<GameChatSheet> {
  final _input = TextEditingController();

  /// True while [NoteComposer] holds the row — the field, GIF and send
  /// make way for the recording bar.
  bool _recording = false;

  /// Pending friend requests, counted once when the sheet opens so the
  /// friends entry in the header can wear a badge. The sheet is a brief
  /// surface — one fetch, no poller.
  int _pendingRequests = 0;

  @override
  void initState() {
    super.initState();
    widget.client.addListener(_onClient);
    // Opening the sheet is the read act, so mark it as such immediately —
    // otherwise a message arriving while it is open would still count as
    // unread and the dot on the app bar icon would never clear.
    widget.client.setChatOpen(true);
    _countRequests();
  }

  @override
  void dispose() {
    widget.client.setChatOpen(false);
    widget.client.removeListener(_onClient);
    _input.dispose();
    super.dispose();
  }

  /// The friends HTTP identity mirrors the friends screen: the id and the
  /// name the client itself holds — both stored values, so no room
  /// context can retint the friend profile with a tagged display name.
  Future<void> _countRequests() async {
    try {
      final state = await FriendClient(serverUrl: widget.client.serverUrl)
          .state(seatId: widget.client.seatId, name: widget.client.name);
      if (!mounted) return;
      setState(() => _pendingRequests = state.incoming.length);
    } on FriendException {
      // A silent badge is a smaller failure than a sheet that nags; the
      // full friends screen reports its own errors once opened.
    }
  }

  /// One tap or long press on a line opens the author's menu.
  void _lineMenu(ChatLine line) {
    if (line.seatId.isEmpty) {
      _chatError('This message predates the friend options — reload the room');
      return;
    }
    if (line.seatId == widget.client.seatId) {
      _chatError('That is your own message');
      return;
    }
    unawaited(
      PlayerActionsSheet.show(
        context,
        serverUrl: widget.client.serverUrl,
        mySeatId: widget.client.seatId,
        myName: widget.client.name,
        peerSeatId: line.seatId,
        peerName: line.from,
      ),
    );
  }

  void _openFriends() {
    pushAppScreen<void>(
      context,
      name: AppRoutes.friends,
      builder: (_) => const FriendsScreen(),
    );
  }

  void _onClient() {
    if (mounted) setState(() {});
  }

  void _send() {
    final text = _input.text.trim();
    if (text.isEmpty) return;
    widget.client.sendChat(text);
    _input.clear();
  }

  Future<bool> _sendNote(NoteRecording recording) =>
      widget.client.sendVoiceNote(
        bytes: recording.bytes,
        mime: recording.mime,
        durMs: recording.durMs,
      );

  void _chatError(String message) {
    // The app's one spoken surface: the gold card on the root overlay, so
    // it works from inside a sheet as well as from the lobby screen.
    showSnackInColumn(context, message, icon: Icons.error_outline);
  }

  @override
  Widget build(BuildContext context) {
    final lines = widget.client.chat;
    return Padding(
      // Lifts the sheet above the keyboard, so the input stays reachable while
      // the board is still visible behind it.
      padding: EdgeInsets.only(
        bottom: MediaQuery.of(context).viewInsets.bottom,
      ),
      child: SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const SizedBox(height: 10),
            _Header(pending: _pendingRequests, onFriends: _openFriends),
            Flexible(child: _history(lines)),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
              child: Row(
                children: [
                  if (!_recording) ...[
                    IconButton(
                      icon: const Icon(Icons.gif_box, color: AppColors.gold),
                      tooltip: 'Send a GIF',
                      onPressed: () => GifPickerSheet.show(
                        context,
                        serverUrl: widget.client.serverUrl,
                        onPick: (url) => widget.client.sendGif(url),
                      ),
                    ),
                    Expanded(child: _inputField()),
                    const SizedBox(width: 10),
                    _sendButton(),
                  ],
                  // The composer is the one child that must survive the swap —
                  // see [NoteComposer]; rebuilding it would kill the mic
                  // session mid-recording.
                  // Flex follows the state (see the lobby row): idle, the
                  // composer is one mic chip at intrinsic width and the
                  // field owns the row; recording, the bar takes over.
                  // The Flexible type never changes, so the mic session
                  // survives the rebuild.
                  Flexible(
                    flex: _recording ? 1 : 0,
                    child: NoteComposer(
                      send: _sendNote,
                      onError: _chatError,
                      onRecordingChanged: (r) {
                        if (mounted) setState(() => _recording = r);
                      },
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _sendButton() {
    final enabled = _input.text.trim().isNotEmpty;
    return IconButton.filled(
      icon: const Icon(Icons.send),
      onPressed: enabled ? _send : null,
      tooltip: 'Send',
      style: IconButton.styleFrom(
        backgroundColor: enabled
            ? AppColors.gold
            : Colors.white.withValues(alpha: 0.1),
        foregroundColor: enabled
            ? AppColors.ink
            : AppColors.ivory.withValues(alpha: 0.4),
      ),
    );
  }

  Widget _inputField() {
    // The keyboard GIF key (Gboard, Samsung Keyboard) commits the media
    // straight into this field; it becomes the same chat line the GIF
    // sheet sends, so no one learns a second pathway to a GIF they
    // already hold in their keyboard.
    return TextField(
      controller: _input,
      onChanged: (_) => setState(() {}),
      style: const TextStyle(color: AppColors.ivory),
      textInputAction: TextInputAction.send,
      onSubmitted: (_) => _send(),
      contentInsertionConfiguration: keyboardGifInsertion(
        send: ({required bytes, required mime}) =>
            widget.client.sendKeyboardGif(bytes: bytes, mime: mime),
        sendLink: widget.client.sendGif,
        onError: _chatError,
      ),
      decoration: InputDecoration(
        hintText: 'Message the table',
        hintStyle: TextStyle(color: AppColors.ivory.withValues(alpha: 0.5)),
        filled: true,
        fillColor: Colors.white.withValues(alpha: 0.07),
        contentPadding: const EdgeInsets.symmetric(
          horizontal: 16,
          vertical: 10,
        ),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(22),
          borderSide: BorderSide(color: Colors.white.withValues(alpha: 0.14)),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(22),
          borderSide: BorderSide(color: Colors.white.withValues(alpha: 0.14)),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(22),
          borderSide: const BorderSide(color: AppColors.gold),
        ),
      ),
    );
  }

  Widget _history(List<ChatLine> lines) {
    if (lines.isEmpty) {
      return const Padding(
        padding: EdgeInsets.symmetric(vertical: 28),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.chat_bubble_outline, size: 30, color: Colors.white24),
            SizedBox(height: 10),
            Text(
              'No messages yet.\nSay hello to the table.',
              textAlign: TextAlign.center,
              style: TextStyle(
                color: Colors.white54,
                fontSize: 13,
                height: 1.5,
              ),
            ),
          ],
        ),
      );
    }
    // Reversed so the newest message is the one visible when it opens.
    return ListView.builder(
      reverse: true,
      shrinkWrap: true,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      itemCount: lines.length,
      itemBuilder: (_, i) {
        final line = lines[lines.length - 1 - i];
        return Padding(
          padding: const EdgeInsets.symmetric(vertical: 5),
          child: ChatLineView(
            line: line,
            myName: widget.client.name,
            onOpenMenu: () => _lineMenu(line),
          ),
        );
      },
    );
  }
}

/// The sheet's title bar: drag handle, a gold chat chip and the title —
/// unchanged in meaning from when it was a bare icon row, only set-like.
/// The trailing friends icon is the "receive" half of table friendship:
/// incoming requests wear a badge and open the friends screen, where
/// accept/decline lives.
class _Header extends StatelessWidget {
  const _Header({required this.pending, required this.onFriends});

  final int pending;
  final VoidCallback onFriends;

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 42,
          height: 4,
          decoration: BoxDecoration(
            color: Colors.white.withValues(alpha: 0.3),
            borderRadius: BorderRadius.circular(2),
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 10, 8, 2),
          child: Row(
            children: [
              const _ChipIcon(icon: Icons.forum),
              const SizedBox(width: 9),
              const Expanded(
                child: Text(
                  'Table chat',
                  style: TextStyle(
                    fontWeight: FontWeight.w800,
                    fontSize: 16,
                    color: AppColors.ivory,
                  ),
                ),
              ),
              // The friends doorway: every line's tap opens the actions
              // sheet, and this icon is where incoming requests are
              // accepted. The badge answers "did anyone want to be my
              // friend?" without opening anything.
              IconButton(
                icon: Badge(
                  isLabelVisible: pending > 0,
                  backgroundColor: AppColors.gold,
                  label: Text(
                    '$pending',
                    style: const TextStyle(
                      color: AppColors.ink,
                      fontSize: 9,
                      fontWeight: FontWeight.w900,
                    ),
                  ),
                  child: const Icon(Icons.group_outlined),
                ),
                tooltip: pending > 0
                    ? 'Friends ($pending request${pending == 1 ? '' : 's'} waiting)'
                    : 'Friends',
                onPressed: onFriends,
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _ChipIcon extends StatelessWidget {
  const _ChipIcon({required this.icon});

  final IconData icon;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 30,
      height: 30,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: AppColors.gold.withValues(alpha: 0.18),
        borderRadius: BorderRadius.circular(9),
      ),
      child: Icon(icon, size: 17, color: AppColors.gold),
    );
  }
}
