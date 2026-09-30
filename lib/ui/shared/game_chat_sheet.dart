import 'package:flutter/material.dart';

import '../../services/online_client.dart';
import '../theme.dart';

/// In-game chat, as a sheet over the board.
///
/// Chat used to exist only in the lobby — the one screen where you are not
/// mid-game — so a table could not talk to itself while playing. This opens
/// from a board's app bar instead, and shows recent history plus an input.
class GameChatSheet extends StatefulWidget {
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
  State<GameChatSheet> createState() => _GameChatSheetState();
}

class _GameChatSheetState extends State<GameChatSheet> {
  final _input = TextEditingController();

  @override
  void initState() {
    super.initState();
    widget.client.addListener(_onClient);
  }

  @override
  void dispose() {
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
            Container(
              width: 42,
              height: 4,
              decoration: BoxDecoration(
                color: Colors.white24,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            const Padding(
              padding: EdgeInsets.fromLTRB(16, 12, 16, 4),
              child: Row(
                children: [
                  Icon(Icons.forum, size: 18, color: AppColors.gold),
                  SizedBox(width: 8),
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
            Flexible(child: _history(lines)),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
              child: Row(
                children: [
                  Expanded(child: _inputField()),
                  const SizedBox(width: 10),
                  IconButton.filled(
                    icon: const Icon(Icons.send),
                    onPressed: _send,
                    tooltip: 'Send',
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _inputField() {
    return TextField(
      controller: _input,
      style: const TextStyle(color: AppColors.ivory),
      textInputAction: TextInputAction.send,
      onSubmitted: (_) => _send(),
      decoration: InputDecoration(
        hintText: 'Message the table',
        hintStyle: TextStyle(color: AppColors.ivory.withValues(alpha: 0.5)),
        filled: true,
        fillColor: AppColors.felt,
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide.none,
        ),
      ),
    );
  }

  Widget _history(List<({String from, String text})> lines) {
    if (lines.isEmpty) {
      return const Padding(
        padding: EdgeInsets.symmetric(vertical: 24),
        child: Text(
          'No messages yet.\nSay hello to the table.',
          textAlign: TextAlign.center,
          style: TextStyle(color: Colors.white54),
        ),
      );
    }
    // Reversed so the newest message is the one visible when it opens.
    return ListView.builder(
      reverse: true,
      shrinkWrap: true,
      padding: const EdgeInsets.symmetric(horizontal: 16),
      itemCount: lines.length,
      itemBuilder: (_, i) {
        final line = lines[lines.length - 1 - i];
        return Padding(
          padding: const EdgeInsets.symmetric(vertical: 3),
          child: RichText(
            text: TextSpan(
              style: const TextStyle(color: AppColors.ivory, fontSize: 14),
              children: [
                TextSpan(
                  text: '${line.from}: ',
                  style: const TextStyle(
                    fontWeight: FontWeight.w700,
                    color: AppColors.gold,
                  ),
                ),
                TextSpan(text: line.text),
              ],
            ),
          ),
        );
      },
    );
  }
}
