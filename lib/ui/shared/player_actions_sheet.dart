import 'package:flutter/material.dart';

import '../../services/friend_client.dart';
import '../theme.dart';
import 'player_avatar.dart';

/// Actions for an online player met at a table — add as friend, block,
/// report — opened from the surfaces gameplay actually gives you: a
/// chat line's tap, or a lobby roster row's menu button.
///
/// The friends screen is where a full tray management lives; this sheet
/// carries exactly the three moves a player needs *on the spot*, worded
/// the same as the screen so nothing new is being taught. Addressing is
/// by seat id (the friends store's key) — display names collide and get
/// ambiguity tags, and the id survives reconnects.
///
/// The peer's profile is minted server-side from the roster name if they
/// have never opened the friends screen, so a tablemate is always
/// addable — nobody should have to visit a menu before being friended.
class PlayerActionsSheet extends StatefulWidget {
  const PlayerActionsSheet({
    required this.serverUrl,
    required this.mySeatId,
    required this.myName,
    required this.peerSeatId,
    required this.peerName,
    this.friendClientForTest,
    super.key,
  });

  /// Same-origin game server URL (ws(s)://host/ws form, as everywhere).
  final String serverUrl;
  final String mySeatId;
  final String myName;
  final String peerSeatId;

  /// The preview display name, from the roster row or the chat byline.
  final String peerName;

  /// Test seam: an injected [FriendClient] (with a mock http.Client) keeps
  /// the sheet off the wire. Production leaves it null and the sheet
  /// builds its own — and owns it, closing it on dispose.
  final FriendClient? friendClientForTest;

  /// Opens the sheet. Returns when it is dismissed.
  static Future<void> show(
    BuildContext context, {
    required String serverUrl,
    required String mySeatId,
    required String myName,
    required String peerSeatId,
    required String peerName,
  }) {
    return showModalBottomSheet<void>(
      context: context,
      backgroundColor: AppColors.feltLight,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(18)),
      ),
      builder: (_) => PlayerActionsSheet(
        serverUrl: serverUrl,
        mySeatId: mySeatId,
        myName: myName,
        peerSeatId: peerSeatId,
        peerName: peerName,
      ),
    );
  }

  @override
  State<PlayerActionsSheet> createState() => _PlayerActionsSheetState();
}

/// The drag handle above the sheet's head, same visual as the chat sheet's.
class _Handle extends StatelessWidget {
  const _Handle();

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 42,
      height: 4,
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.3),
        borderRadius: BorderRadius.circular(2),
      ),
    );
  }
}

class _PlayerActionsSheetState extends State<PlayerActionsSheet> {
  FriendClient? _client;
  late final bool _ownsClient = widget.friendClientForTest == null;
  FriendState? _state;
  String? _error;
  bool _working = false;

  FriendClient get _c => _client ??=
      widget.friendClientForTest ?? FriendClient(serverUrl: widget.serverUrl);

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    if (_ownsClient) _client?.close();
    super.dispose();
  }

  Future<void> _load() async {
    String? error;
    FriendState? state;
    try {
      state = await _c.state(seatId: widget.mySeatId, name: widget.myName);
    } on FriendException catch (e) {
      error = e.text;
    }
    if (!mounted) return;
    setState(() {
      _state = state;
      _error = error;
    });
  }

  void _showSnack(String text) {
    // The root ScaffoldMessenger sits above the navigator, so snackbars
    // work from inside a modal route (the sheet) as well as from screens.
    ScaffoldMessenger.maybeOf(context)
      ?..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(text)));
  }

  bool get _isMe => widget.peerSeatId == widget.mySeatId;

  /// Row taps are one flight at a time — a double tap is one action and
  /// the snack that states it, not two requests racing the server caps.
  bool get _locked => _working;

  Future<void> _addFriend() async {
    final go = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Add ${widget.peerName} as a friend?'),
        content: Text(
          'When they accept, you can message and invite each other '
          'between games.',
          style: const TextStyle(color: AppColors.ivory),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Not now'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Send request'),
          ),
        ],
      ),
    );
    if (go != true || !mounted) return;
    await _run(() async {
      final status = await _c.request(
        seatId: widget.mySeatId,
        name: widget.myName,
        target: widget.peerSeatId,
        // Room context: mint the tablemate's profile when they have
        // never opened the friends screen.
        targetName: widget.peerName,
      );
      if (!mounted) return;
      _showSnack(
        status == 'accepted'
            ? 'They added you back — you are friends!'
            : 'Request sent',
      );
      await _load();
    });
  }

  Future<void> _block() async {
    final sure = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Block ${widget.peerName}?'),
        content: Text(
          'Removes them from your friends if you are connected, drops every '
          'pending request or invite between you, and neither of you can '
          'message, invite, or re-add the other until one of you unblocks.',
          style: const TextStyle(color: AppColors.ivory),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Block'),
          ),
        ],
      ),
    );
    if (sure != true || !mounted) return;
    await _run(() async {
      await _c.block(
        seatId: widget.mySeatId,
        target: widget.peerSeatId,
        targetName: widget.peerName,
      );
      if (!mounted) return;
      _showSnack('${widget.peerName} blocked');
      await _load();
    });
  }

  Future<void> _unblock() async {
    await _run(() async {
      await _c.unblock(seatId: widget.mySeatId, target: widget.peerSeatId);
      if (!mounted) return;
      _showSnack('${widget.peerName} unblocked');
      await _load();
    });
  }

  Future<void> _report() async {
    final reason = await _prompt(
      title: 'Report ${widget.peerName}',
      hint: 'What happened? (goes to the moderators)',
      multiline: true,
    );
    if (reason == null || !mounted) return;
    await _run(() async {
      await _c.report(
        seatId: widget.mySeatId,
        target: widget.peerSeatId,
        reason: reason,
      );
      if (!mounted) return;
      _showSnack('Report sent — thank you');
    });
  }

  Future<void> _run(Future<void> Function() flight) async {
    setState(() => _working = true);
    try {
      await flight();
    } on FriendException catch (e) {
      if (mounted) _showSnack(e.text);
    } finally {
      if (mounted) setState(() => _working = false);
    }
  }

  Future<String?> _prompt({
    required String title,
    required String hint,
    bool multiline = false,
  }) {
    final ctrl = TextEditingController();
    return showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(title),
        content: TextField(
          controller: ctrl,
          autofocus: true,
          maxLines: multiline ? 3 : 1,
          decoration: InputDecoration(hintText: hint),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, ctrl.text.trim()),
            child: const Text('OK'),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final state = _state;
    return Padding(
      padding: EdgeInsets.only(
        bottom: MediaQuery.of(context).viewInsets.bottom,
      ),
      child: SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const SizedBox(height: 10),
            const _Handle(),
            _head(),
            const SizedBox(height: 4),
            if (state == null && _error != null)
              Padding(
                padding: const EdgeInsets.all(16),
                child: Text(
                  _error!,
                  style: TextStyle(
                    color: AppColors.ivory.withValues(alpha: 0.8),
                  ),
                ),
              )
            else if (state == null)
              const Padding(
                padding: EdgeInsets.all(18),
                child: SizedBox(
                  width: 22,
                  height: 22,
                  child: CircularProgressIndicator(
                    strokeWidth: 2.4,
                    color: AppColors.gold,
                  ),
                ),
              )
            else ...[
              _rows(state),
              const SizedBox(height: 8),
            ],
          ],
        ),
      ),
    );
  }

  Widget _head() {
    final state = _state;
    final subtitle = switch ((state == null, _error)) {
      (true, final String e) => e,
      _ => 'Table player',
    };
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 6, 16, 2),
      child: Row(
        children: [
          PlayerAvatar(seed: widget.peerSeatId, size: 40, circular: true),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  widget.peerName,
                  style: const TextStyle(
                    color: AppColors.ivory,
                    fontSize: 15,
                    fontWeight: FontWeight.w800,
                  ),
                ),
                Text(
                  subtitle,
                  style: TextStyle(
                    color: AppColors.ivory.withValues(alpha: 0.55),
                    fontSize: 12,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _rows(FriendState state) {
    if (_isMe) {
      return _item(Icons.person, 'This is you', onPressed: null);
    }
    final friend = state.friends.any((f) => f.seatId == widget.peerSeatId);
    final pending = state.outgoing.any((r) => r.seatId == widget.peerSeatId);
    final blocked = state.blocked.any((b) => b.seatId == widget.peerSeatId);
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (friend)
          _item(Icons.handshake_outlined, 'Already friends', onPressed: null)
        else if (blocked)
          _item(
            Icons.block,
            'Unblock ${widget.peerName}',
            onPressed: _locked ? null : _unblock,
          )
        else if (pending)
          _item(Icons.hourglass_top, 'Request pending', onPressed: null)
        else
          _item(
            Icons.person_add_alt_1,
            'Add ${widget.peerName} as a friend',
            onPressed: _locked ? null : _addFriend,
          ),
        if (!blocked)
          _item(
            Icons.block,
            'Block ${widget.peerName}',
            onPressed: _locked ? null : _block,
          ),
        _item(
          Icons.flag_outlined,
          'Report ${widget.peerName}',
          onPressed: _locked ? null : _report,
        ),
      ],
    );
  }

  Widget _item(
    IconData icon,
    String label, {
    required VoidCallback? onPressed,
  }) {
    final inactive = onPressed == null;
    return ListTile(
      leading: Icon(
        icon,
        color: inactive
            ? AppColors.ivory.withValues(alpha: 0.45)
            : AppColors.gold,
      ),
      title: Text(
        label,
        style: TextStyle(
          color: inactive
              ? AppColors.ivory.withValues(alpha: 0.45)
              : AppColors.ivory,
          fontSize: 14.5,
        ),
      ),
      onTap: onPressed,
    );
  }
}
