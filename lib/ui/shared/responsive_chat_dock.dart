import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

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

/// Width at which the table chat docks beside the play area.
///
/// Below this the board (or the lobby column) keeps the whole window and the
/// chat becomes an overlay opened from a launcher — a phone should never lose
/// a third of its width to a panel it did not ask for.
const double kChatDockBreakpoint = 960;

/// The docked panel's width. The play area gives up exactly this much plus
/// [kChatDockGutter], so the panel never sits on top of the board.
const double kChatDockWidth = 360;

/// Breathing room between the play area and the docked panel.
const double kChatDockGutter = 16;

/// The widest the overlay may get on a phone/tablet; the remaining strip of
/// scrim keeps the "dismiss by tapping outside" gesture discoverable.
const double kChatOverlayMaxWidth = 380;

/// Short enough to feel immediate, long enough to read as motion.
const Duration kChatDockMotion = Duration(milliseconds: 220);

/// The reusable table-chat panel: header, transcript and pinned composer.
///
/// One widget backs every surface — the docked desktop panel, the mobile
/// overlay, and the legacy bottom sheet in [GameChatSheet]. The transcript
/// comes from [OnlineClient.chat] (the single source of truth), so switching
/// layouts can never duplicate a connection or lose a line.
class TableChatPanel extends StatefulWidget {
  const TableChatPanel({
    super.key,
    required this.client,
    this.onClose,
    this.onCollapse,
    this.sheet = false,
    this.showDragHandle = false,
    this.showFriends = true,
  });

  final OnlineClient client;

  /// The mobile overlay's close control. Null on the docked panel, where the
  /// chat is a permanent part of the layout and has nothing to close.
  final VoidCallback? onClose;

  /// The wide dock's collapse control: folds the panel back to the launcher
  /// without destroying the composer or the transcript. Null on the overlay
  /// and the bottom sheet, which already have their own dismissal.
  final VoidCallback? onCollapse;

  /// Sheet mode sizes to its content (the bottom sheet's cap) instead of
  /// filling the dock. The transcript still scrolls inside the cap.
  final bool sheet;

  /// Draw the bottom-sheet grab handle. Dock and overlay have their own
  /// affordances and leave it off.
  final bool showDragHandle;

  /// The friends doorway in the header. The sheet always had it; the dock
  /// keeps it too, so open/closed or narrow/wide never removes a feature.
  final bool showFriends;

  @override
  State<TableChatPanel> createState() => _TableChatPanelState();
}

class _TableChatPanelState extends State<TableChatPanel> {
  final _input = TextEditingController();

  /// True while [NoteComposer] holds the row — the field, GIF and send make
  /// way for the recording bar.
  bool _recording = false;

  /// Pending friend requests, counted once when the panel mounts. A chat
  /// panel is a brief surface, not a poller; the friends screen refreshes
  /// itself when opened.
  int _pendingRequests = 0;

  @override
  void initState() {
    super.initState();
    widget.client.addListener(_onClient);
    if (widget.showFriends) _countRequests();
  }

  @override
  void didUpdateWidget(TableChatPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.client != widget.client) {
      oldWidget.client.removeListener(_onClient);
      widget.client.addListener(_onClient);
      _pendingRequests = 0;
      if (widget.showFriends) _countRequests();
    } else if (!oldWidget.showFriends && widget.showFriends) {
      _countRequests();
    }
  }

  @override
  void dispose() {
    widget.client.removeListener(_onClient);
    _input.dispose();
    super.dispose();
  }

  /// The friends HTTP identity mirrors the friends screen: the id and the
  /// name the client itself holds — both stored values, so no room context
  /// can retint the friend profile with a tagged display name.
  Future<void> _countRequests() async {
    try {
      final state = await FriendClient(serverUrl: widget.client.serverUrl)
          .state(seatId: widget.client.seatId, name: widget.client.name);
      if (!mounted) return;
      setState(() => _pendingRequests = state.incoming.length);
    } on FriendException {
      // A silent badge is a smaller failure than a panel that nags; the
      // full friends screen reports its own errors once opened.
    }
  }

  void _onClient() {
    if (mounted) setState(() {});
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

  void _send() {
    final text = _input.text.trim();
    if (text.isEmpty || widget.client.status == OnlineStatus.error) return;
    widget.client.sendChat(text);
    _input.clear();
    setState(() {});
  }

  Future<bool> _sendNote(NoteRecording recording) =>
      widget.client.sendVoiceNote(
        bytes: recording.bytes,
        mime: recording.mime,
        durMs: recording.durMs,
      );

  void _chatError(String message) {
    // The app's one spoken surface: the gold card on the root overlay, so it
    // works from inside a panel or an overlay as well as from the lobby.
    showSnackInColumn(context, message, icon: Icons.error_outline);
  }

  @override
  Widget build(BuildContext context) {
    final lines = widget.client.chat;
    final panel = Column(
      mainAxisSize: widget.sheet ? MainAxisSize.min : MainAxisSize.max,
      children: [
        if (widget.showDragHandle) _dragHandle(),
        _Header(
          pending: _pendingRequests,
          onFriends: widget.showFriends ? _openFriends : null,
          onClose: widget.onClose,
          onCollapse: widget.onCollapse,
        ),
        _connectionNotice(widget.client),
        if (widget.sheet)
          Flexible(child: _history(lines, shrinkWrap: true))
        else
          Expanded(child: _history(lines, shrinkWrap: false)),
        _composer(),
      ],
    );

    return Padding(
      // The bottom sheet is lifted above the keyboard; the dock sits in a
      // Scaffold body that already shrinks when the keyboard opens, so an
      // extra inset there would double-count it.
      padding: EdgeInsets.only(
        bottom: widget.sheet ? MediaQuery.viewInsetsOf(context).bottom : 0,
      ),
      child: SafeArea(top: false, child: panel),
    );
  }

  Widget _dragHandle() => Padding(
    padding: const EdgeInsets.only(top: 10),
    child: Container(
      width: 42,
      height: 4,
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.3),
        borderRadius: BorderRadius.circular(2),
      ),
    ),
  );

  /// One line, only while the transport is actually unhappy. It answers
  /// "why did nothing send?" without turning the panel into an error page,
  /// and the chat keeps its place in the layout.
  Widget _connectionNotice(OnlineClient client) {
    final (icon, text, color) = switch (client.status) {
      OnlineStatus.reconnecting => (
        Icons.sync,
        'Reconnecting… messages may be delayed.',
        AppColors.gold,
      ),
      OnlineStatus.error => (
        Icons.cloud_off,
        'Chat is offline — messages will send after the table reconnects.',
        AppColors.danger,
      ),
      _ => (null, null, null),
    };
    if (icon == null) return const SizedBox.shrink();
    return Container(
      margin: const EdgeInsets.fromLTRB(12, 4, 12, 2),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
      decoration: BoxDecoration(
        color: color!.withValues(alpha: 0.14),
        border: Border.all(color: color.withValues(alpha: 0.4)),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Row(
        children: [
          Icon(icon, size: 15, color: color),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              text!,
              style: TextStyle(
                color: AppColors.ivory.withValues(alpha: 0.82),
                fontSize: 11.5,
                height: 1.3,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _composer() {
    final offline = widget.client.status == OnlineStatus.error;
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 6, 12, 10),
      child: Row(
        children: [
          if (!_recording) ...[
            IconButton(
              icon: const Icon(Icons.gif_box, color: AppColors.gold),
              tooltip: 'Send a GIF',
              visualDensity: VisualDensity.compact,
              onPressed: offline
                  ? null
                  : () => GifPickerSheet.show(
                      context,
                      serverUrl: widget.client.serverUrl,
                      onPick: (url) => widget.client.sendGif(url),
                    ),
            ),
            Expanded(child: _inputField(offline)),
            const SizedBox(width: 6),
            _sendButton(offline),
          ],
          // The composer is the one child that must survive the swap — see
          // [NoteComposer]; rebuilding it would kill the mic session
          // mid-recording. Flex follows the state (see the lobby row): idle,
          // the composer is one mic chip at intrinsic width and the field
          // owns the row; recording, the bar takes over. The Flexible type
          // never changes, so the mic session survives the rebuild.
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
    );
  }

  Widget _sendButton(bool offline) {
    final enabled = _input.text.trim().isNotEmpty && !offline;
    return IconButton.filled(
      key: const Key('table-chat-send'),
      icon: const Icon(Icons.send, size: 20),
      onPressed: enabled ? _send : null,
      tooltip: offline
          ? 'Chat is offline — reconnect to send'
          : enabled
          ? 'Send message'
          : 'Type a message first',
      constraints: const BoxConstraints(minWidth: 44, minHeight: 44),
      style: IconButton.styleFrom(
        backgroundColor: enabled
            ? AppColors.gold
            : Colors.white.withValues(alpha: 0.1),
        foregroundColor: enabled
            ? AppColors.textPrimary
            : AppColors.ivory.withValues(alpha: 0.4),
      ),
    );
  }

  Widget _inputField(bool offline) {
    // The keyboard GIF key (Gboard, Samsung Keyboard) commits the media
    // straight into this field; it becomes the same chat line the GIF
    // sheet sends, so no one learns a second pathway to a GIF they
    // already hold in their keyboard.
    return TextField(
      key: const Key('table-chat-composer'),
      controller: _input,
      onChanged: (_) => setState(() {}),
      style: const TextStyle(color: AppColors.ivory),
      textInputAction: TextInputAction.send,
      onSubmitted: (_) => _send(),
      enabled: !offline,
      contentInsertionConfiguration: keyboardGifInsertion(
        send: ({required bytes, required mime}) =>
            widget.client.sendKeyboardGif(bytes: bytes, mime: mime),
        sendLink: widget.client.sendGif,
        onError: _chatError,
      ),
      decoration: InputDecoration(
        hintText: offline ? 'Reconnect to type' : 'Message the table',
        hintStyle: TextStyle(color: AppColors.ivory.withValues(alpha: 0.5)),
        filled: true,
        fillColor: Colors.white.withValues(alpha: 0.07),
        contentPadding: const EdgeInsets.symmetric(
          horizontal: 14,
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
        disabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(22),
          borderSide: BorderSide(color: Colors.white.withValues(alpha: 0.08)),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(22),
          borderSide: const BorderSide(color: AppColors.gold),
        ),
      ),
    );
  }

  Widget _history(List<ChatLine> lines, {required bool shrinkWrap}) {
    if (lines.isEmpty) {
      return Padding(
        padding: EdgeInsets.symmetric(vertical: shrinkWrap ? 24 : 28),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.chat_bubble_outline, size: 30, color: Colors.white24),
            const SizedBox(height: 10),
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
      shrinkWrap: shrinkWrap,
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

/// The panel's title bar: a gold chat chip, the title, and the two doors
/// that matter — friends (with the incoming-request badge) and, on the
/// mobile overlay, a labelled close control.
class _Header extends StatelessWidget {
  const _Header({
    required this.pending,
    required this.onFriends,
    required this.onClose,
    required this.onCollapse,
  });

  final int pending;
  final VoidCallback? onFriends;
  final VoidCallback? onClose;
  final VoidCallback? onCollapse;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(14, 10, 8, 2),
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
          if (onFriends != null)
            IconButton(
              icon: Badge(
                isLabelVisible: pending > 0,
                backgroundColor: AppColors.gold,
                label: Text(
                  '$pending',
                  style: const TextStyle(
                    color: AppColors.darkInk,
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
          if (onCollapse != null)
            IconButton(
              key: const Key('table-chat-collapse'),
              icon: const Icon(Icons.chevron_right),
              tooltip: 'Collapse chat',
              onPressed: onCollapse,
            ),
          if (onClose != null)
            IconButton(
              key: const Key('table-chat-close'),
              icon: const Icon(Icons.close),
              tooltip: 'Close chat',
              onPressed: onClose,
            ),
        ],
      ),
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

/// One responsive chat shell for the online table surfaces.
///
/// Wide windows dock the panel on the right and reserve its width on the
/// layout edge, so the board/lobby is narrower, centred in what remains and
/// never covered. The dock's header carries a collapse control: the panel
/// folds back to the same launcher the phone uses, the content reclaims the
/// width, and the panel subtree keeps its draft and recording session. Narrow
/// windows keep the content full-bleed and hide the panel off the right edge
/// behind a launcher, sliding it back in as an overlay with a tappable scrim
/// and a labelled close control. The panel itself is the same subtree in
/// every mode, so the draft and the transcript survive a breakpoint change.
class ResponsiveChatDock extends StatefulWidget {
  const ResponsiveChatDock({
    super.key,
    required this.client,
    required this.child,
    this.showFriends = true,
  });

  final OnlineClient client;

  /// The board or lobby body this chat belongs beside.
  final Widget child;

  /// Passed through to [TableChatPanel]. Tests turn it off to avoid the
  /// friends HTTP read; production keeps the doorway.
  final bool showFriends;

  @override
  State<ResponsiveChatDock> createState() => _ResponsiveChatDockState();
}

class _ResponsiveChatDockState extends State<ResponsiveChatDock> {
  /// Narrow only: the overlay is open. Wide uses [_collapsed] instead — the
  /// dock is part of the layout until the player folds it away.
  bool _open = false;

  /// Wide only: the dock is folded back to the launcher. Kept separate from
  /// [_open] because the two layouts have different doors; crossing the
  /// breakpoint with a collapsed dock must not pop the phone overlay open.
  bool _collapsed = false;

  /// The last `chatOpen` value handed to the client. Kept here rather than
  /// read back from the client so a delayed post-frame callback cannot
  /// clobber a newer layout with an older answer.
  bool? _reportedChatOpen;

  @override
  void initState() {
    super.initState();
    widget.client.addListener(_onClient);
  }

  @override
  void didUpdateWidget(ResponsiveChatDock oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.client != widget.client) {
      oldWidget.client.setChatOpen(false);
      oldWidget.client.removeListener(_onClient);
      widget.client.addListener(_onClient);
      _reportedChatOpen = null;
    }
  }

  @override
  void dispose() {
    widget.client.removeListener(_onClient);
    widget.client.setChatOpen(false);
    super.dispose();
  }

  void _onClient() {
    if (mounted) setState(() {});
  }

  void _setOpen(bool open) {
    if (_open == open) return;
    setState(() => _open = open);
  }

  void _setCollapsed(bool collapsed) {
    if (_collapsed == collapsed) return;
    setState(() => _collapsed = collapsed);
  }

  /// Whether the reader can see the transcript right now: always on the
  /// docked layout, only while the overlay is open on narrow windows. The
  /// client uses this for unread dots and message chimes.
  void _reportChatOpen(bool visible) {
    if (_reportedChatOpen == visible) return;
    _reportedChatOpen = visible;
    // `setChatOpen` may clear the unread count and listeners may rebuild.
    // Doing that during build would be a setState-in-build, so the handoff
    // waits one frame — the same frame the panel is already on screen for.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || _reportedChatOpen != visible) return;
      widget.client.setChatOpen(visible);
    });
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final wide = constraints.maxWidth >= kChatDockBreakpoint;
        final docked = wide && !_collapsed;
        final visible = docked || (!wide && _open);
        final overlayWidth = math.min(
          kChatOverlayMaxWidth,
          math.max(0.0, constraints.maxWidth - 24),
        );
        _reportChatOpen(visible);

        return CallbackShortcuts(
          bindings: {
            const SingleActivator(LogicalKeyboardKey.escape): () {
              if (wide && !_collapsed) {
                _setCollapsed(true);
              } else if (!wide && _open) {
                _setOpen(false);
              }
            },
          },
          child: Stack(
            clipBehavior: Clip.hardEdge,
            children: [
              Positioned.fill(
                key: const ValueKey('chat-dock-content-slot'),
                child: AnimatedPadding(
                  // The docked panel owns this strip; the content is laid
                  // out beside it, never underneath it. Collapsing animates
                  // the strip away so the board/lobby gets the whole window
                  // back without a layout jump.
                  duration: kChatDockMotion,
                  curve: Curves.easeOutCubic,
                  padding: EdgeInsets.only(
                    right: docked ? kChatDockWidth + kChatDockGutter : 0,
                  ),
                  child: KeyedSubtree(
                    key: const Key('chat-dock-content'),
                    child: widget.child,
                  ),
                ),
              ),
              if (!wide) ...[
                Positioned.fill(
                  key: const ValueKey('chat-dock-scrim-slot'),
                  child: IgnorePointer(
                    ignoring: !_open,
                    child: AnimatedOpacity(
                      opacity: _open ? 1 : 0,
                      duration: kChatDockMotion,
                      child: GestureDetector(
                        key: const Key('table-chat-scrim'),
                        behavior: HitTestBehavior.opaque,
                        onTap: () => _setOpen(false),
                        child: ColoredBox(
                          color: Colors.black.withValues(alpha: 0.52),
                        ),
                      ),
                    ),
                  ),
                ),
              ],
              if ((!wide && !_open) || (wide && _collapsed))
                Positioned(
                  key: const ValueKey('chat-dock-launcher-slot'),
                  right: 16,
                  bottom: 16,
                  child: SafeArea(
                    top: false,
                    left: false,
                    child: _ChatLauncher(
                      unread: widget.client.unreadChats,
                      onPressed: wide
                          ? () => _setCollapsed(false)
                          : () => _setOpen(true),
                    ),
                  ),
                ),
              Positioned(
                // Keyed so the panel subtree is reparented, not rebuilt,
                // when the conditional scrim/launcher siblings appear or
                // disappear across the breakpoint. That is what keeps the
                // draft and the recording session alive.
                key: const ValueKey('chat-dock-panel-slot'),
                top: wide ? 0 : 12,
                bottom: wide ? 0 : 12,
                right: wide ? 0 : 12,
                width: wide ? kChatDockWidth : overlayWidth,
                child: AnimatedSlide(
                  offset: visible ? Offset.zero : const Offset(1.08, 0),
                  duration: kChatDockMotion,
                  curve: Curves.easeOutCubic,
                  child: IgnorePointer(
                    ignoring: !visible,
                    child: ExcludeFocus(
                      excluding: !visible,
                      child: ExcludeSemantics(
                        excluding: !visible,
                        child: TickerMode(
                          enabled: visible,
                          child: Material(
                            key: const Key('table-chat-panel'),
                            color: AppColors.feltLight,
                            elevation: wide ? 0 : 14,
                            clipBehavior: Clip.antiAlias,
                            shape: RoundedRectangleBorder(
                              borderRadius: wide
                                  ? BorderRadius.zero
                                  : BorderRadius.circular(20),
                              side: BorderSide(
                                color: AppColors.gold.withValues(
                                  alpha: wide ? 0.18 : 0.32,
                                ),
                              ),
                            ),
                            child: TableChatPanel(
                              client: widget.client,
                              showFriends: widget.showFriends,
                              onClose: wide ? null : () => _setOpen(false),
                              onCollapse: wide && !_collapsed
                                  ? () => _setCollapsed(true)
                                  : null,
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

/// The narrow-layout entry point. A gold, labelled circle with the unread
/// badge; 52 px so it clears the 44 px touch-target floor with room to
/// breathe.
class _ChatLauncher extends StatelessWidget {
  const _ChatLauncher({required this.unread, required this.onPressed});

  final int unread;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.35),
            blurRadius: 14,
            offset: const Offset(0, 5),
          ),
        ],
      ),
      child: IconButton.filled(
        key: const Key('table-chat-launcher'),
        icon: Badge(
          isLabelVisible: unread > 0,
          backgroundColor: AppColors.danger,
          label: Text(
            unread > 9 ? '9+' : '$unread',
            style: const TextStyle(
              color: AppColors.darkInk,
              fontSize: 9,
              fontWeight: FontWeight.w900,
            ),
          ),
          child: const Icon(Icons.forum_outlined),
        ),
        tooltip: unread > 0
            ? 'Open table chat ($unread new)'
            : 'Open table chat',
        constraints: const BoxConstraints.tightFor(width: 52, height: 52),
        style: IconButton.styleFrom(
          backgroundColor: AppColors.gold,
          foregroundColor: AppColors.darkInk,
        ),
        onPressed: onPressed,
      ),
    );
  }
}
