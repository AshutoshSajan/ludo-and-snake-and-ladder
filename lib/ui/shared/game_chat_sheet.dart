import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../services/note_recorder.dart';
import '../../services/online_client.dart';
import '../theme.dart';
import 'chat_line_view.dart';
import 'gif_picker_sheet.dart';
import 'keyboard_content.dart';
import 'note_composer.dart';

/// In-game chat, as a sheet over the board.
///
/// Chat used to exist only in the lobby — the one screen where you are not
/// mid-game — so a table could not talk to itself while playing. This opens
/// from a board's app bar instead, and shows recent history plus an input.
class GameChatSheet extends ConsumerStatefulWidget {
  const GameChatSheet({super.key, required this.client});

  final OnlineClient client;

  /// Opens the sheet. Returns when it is dismissed.
  static Future<void> show(BuildContext context, OnlineClient client) {
    return showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
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

  @override
  void initState() {
    super.initState();
    widget.client.addListener(_onClient);
    // Opening the sheet is the read act, so mark it as such immediately —
    // otherwise a message arriving while it is open would still count as
    // unread and the dot on the app bar icon would never clear.
    widget.client.setChatOpen(true);
  }

  @override
  void dispose() {
    widget.client.setChatOpen(false);
    widget.client.removeListener(_onClient);
    _input.dispose();
    super.dispose();
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

  Future<bool> _sendNote(NoteRecording recording) => widget.client
      .sendVoiceNote(bytes: recording.bytes, mime: recording.mime, durMs: recording.durMs);

  void _chatError(String message) {
    // The root ScaffoldMessenger sits above the navigator, so snackbars
    // work from inside a modal route as well as from the lobby screen.
    ScaffoldMessenger.maybeOf(context)
      ?..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
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
            const _Header(),
            Flexible(child: _history(lines)),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
              child: Row(
                children: [
                  if (!_recording) ...[
                    IconButton(
                      icon: const Icon(
                        Icons.gif_box,
                        color: AppColors.gold,
                      ),
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
                  Flexible(
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
        foregroundColor: enabled ? AppColors.ink : AppColors.ivory.withValues(alpha: 0.4),
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
        send: ({required bytes, required mime}) => widget.client
            .sendKeyboardGif(bytes: bytes, mime: mime),
        sendLink: widget.client.sendGif,
        onError: _chatError,
      ),
      decoration: InputDecoration(
        hintText: 'Message the table',
        hintStyle: TextStyle(color: AppColors.ivory.withValues(alpha: 0.5)),
        filled: true,
        fillColor: Colors.white.withValues(alpha: 0.07),
        contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
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
              style: TextStyle(color: Colors.white54, fontSize: 13, height: 1.5),
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
      itemBuilder: (_, i) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 5),
        child: ChatLineView(
          line: lines[lines.length - 1 - i],
          myName: widget.client.name,
        ),
      ),
    );
  }
}

/// The sheet's title bar: drag handle, a gold chat chip and the title —
/// unchanged in meaning from when it was a bare icon row, only set-like.
class _Header extends StatelessWidget {
  const _Header();

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
        const Padding(
          padding: EdgeInsets.fromLTRB(16, 10, 16, 2),
          child: Row(
            children: [
              _ChipIcon(icon: Icons.forum),
              SizedBox(width: 9),
              Text(
                'Table chat',
                style: TextStyle(
                  fontWeight: FontWeight.w800,
                  fontSize: 16,
                  color: AppColors.ivory,
                ),
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

