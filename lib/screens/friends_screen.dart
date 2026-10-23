/// Friends: the tray screen (my code, requests both directions, live
/// play invites, the friend list with unread dots, blocked players) and
/// the 1:1 DM chat (WhatsApp-style bubbles, identicon avatars, like +
/// reply with a visible quote), plus the "play a game" handoff that
/// opens a room and pushes its code as an invite.
///
/// Everything here talks to the friends HTTP endpoints through
/// [FriendClient]; identity is the seat id the online screens already
/// use plus my display name — the same assert-with-nothing flow as the
/// WS hello, watched over by the server's per-IP throttles.
library;

import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show Clipboard, ClipboardData;
import 'package:shared_preferences/shared_preferences.dart';

import '../app_router.dart';
import '../app_routes.dart';
import '../services/friend_client.dart';
import '../services/online_client.dart';
import '../services/server_url.dart';
import '../services/storage_service.dart';
import '../ui/club_widgets.dart';
import '../ui/page_app_bar.dart';
import '../ui/shared/player_actions_sheet.dart';
import '../ui/shared/chat_line_view.dart';
import '../ui/shared/player_avatar.dart';
import '../ui/theme.dart';
import 'online_lobby_screen.dart';

/// Per-pair read markers, persisted: key = friend's seat id, value =
/// the highest message id I have laid eyes on. The friends list compares
/// a pair's `latest` against this to draw the unread dot; the chat
/// screen advances the marker the moment its poll returns.
class FriendReadMarkers {
  const FriendReadMarkers._();

  static const _key = 'gc.friendRead';

  static Future<Map<String, int>> load() async {
    final sp = await SharedPreferences.getInstance();
    final raw = sp.getString(_key);
    if (raw == null || raw.isEmpty) return {};
    try {
      final decoded = jsonDecode(raw) as Map<String, dynamic>;
      return {
        for (final e in decoded.entries) e.key: (e.value as num?)?.toInt() ?? 0,
      };
    } catch (_) {
      return {};
    }
  }

  static Future<void> save(Map<String, int> markers) async {
    final sp = await SharedPreferences.getInstance();
    await sp.setString(_key, jsonEncode(markers));
  }

  /// Advances one pair's marker forward (never back — a stale poll from
  /// a slow device must not resurrect an unread dot).
  static Future<void> stamp(String seatId, int latestSeen) async {
    final all = await load();
    final known = all[seatId] ?? 0;
    if (latestSeen <= known) return;
    all[seatId] = latestSeen;
    await save(all);
  }
}

class FriendsScreen extends StatefulWidget {
  const FriendsScreen({super.key, this.client});

  /// Test injection point; null builds the real same-origin client.
  final FriendClient? client;

  @override
  State<FriendsScreen> createState() => _FriendsScreenState();
}

class _FriendsScreenState extends State<FriendsScreen> {
  late final FriendClient _client;

  /// The stable online identity — the same id the online lobby plays
  /// with — so a friend code granted anywhere grants the same person.
  String _seatId = '';
  String _myName = '';

  FriendState? _state;

  /// Who has caught up on which message, so pending dots resolve as
  /// soon as they should.
  late Map<String, int> _read = {};

  Timer? _poller;
  String? _busyText;

  @override
  void initState() {
    super.initState();
    _client = widget.client ?? FriendClient(serverUrl: defaultServerUrl());
    _restore();
  }

  @override
  void dispose() {
    _poller?.cancel();
    _client.close();
    super.dispose();
  }

  Future<void> _restore() async {
    final storage = StorageService();
    final id = await storage.loadOnlinePlayerId();
    final name = await storage.loadOnlineName();
    // A first-time player gets the lobby's stable derived name, so the
    // friends tray and the connect form can never disagree about identity.
    final resolved = name.isNotEmpty ? name : DefaultNames.unique(playerId: id);
    if (!mounted) return;
    setState(() {
      _seatId = id;
      _myName = resolved;
      _state = null;
    });
    if (name.isEmpty) {
      // Persist now — same behavior as the lobby — so the next visit,
      // whichever surface it lands on, uses the same name.
      await StorageService().saveOnlineName(resolved);
    }
    _read = await FriendReadMarkers.load();
    if (!mounted) return;
    setState(() => _read = _read);
    await _refresh();
    // The tray is the poll: one call returns everything the screen shows.
    _poller = Timer.periodic(const Duration(seconds: 6), (_) => _refresh());
  }

  /// The last bundle's fingerprint: when nothing changed between polls
  /// there is nothing to redraw — a steady 6s poll must not keep the
  /// frame pipeline (and the battery) awake.
  String _fingerprint = '';

  Future<void> _refresh() async {
    if (_seatId.isEmpty || _myName.isEmpty) return;
    try {
      final state = await _client.state(seatId: _seatId, name: _myName);
      String fingerprint(FriendState s) =>
          '${s.me.code}|${s.friends.map((f) => '${f.seatId}:${f.latest}').join(',')}'
          '|${s.table.map((t) => t.seatId).join(',')}'
          '|${s.incoming.map((r) => '${r.id}:${r.seatId}').join(',')}'
          '|${s.outgoing.map((r) => '${r.id}:${r.seatId}').join(',')}'
          '|${s.invites.map((i) => '${i.id}:${i.status}').join(',')}'
          '|${s.blocked.map((b) => b.seatId).join(',')}';
      final next = fingerprint(state);
      if (!mounted) return;
      if (next == _fingerprint) {
        // Same world; skip the repaint (polling is cadence, not churn).
        return;
      }
      _fingerprint = next;
      setState(() => _state = state);
    } on FriendException catch (e) {
      // First-fetch failure keeps the form quiet; a steady poller says it.
      if (_state == null && mounted) {
        setState(() => _busyText = e.text);
      }
    }
  }

  void _showSnack(String text) {
    // The reading-column toast — the same shape every other screen uses,
    // so "friend added" and its siblings never stretch edge to edge on a
    // desktop window while the page below stays in the column.
    showSnackInColumn(context, text);
  }

  // ------------------------------------------------------------- actions

  Future<void> _addFriendFlow() async {
    final target = await _prompt(
      title: 'Add a friend',
      hint: 'Friend code (e.g. PRK7VW) or player id',
    );
    if (target == null || target.isEmpty) return;
    try {
      final profile = await _client.lookup(target);
      if (!mounted) return;
      if (profile == null) {
        _showSnack('No player matches “${target.trim()}”');
        return;
      }
      final go = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: Text('Add ${profile.name}?'),
          content: Row(
            children: [
              PlayerAvatar(seed: profile.seatId, size: 40, circular: true),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  'Their code is ${profile.code}. '
                  'Ask to be table friends!',
                  style: const TextStyle(color: AppColors.ivory),
                ),
              ),
            ],
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
      if (go != true) return;
      final status = await _client.request(
        seatId: _seatId,
        name: _myName,
        target: target,
      );
      if (!mounted) return;
      _showSnack(
        status == 'accepted'
            ? 'They added you back — you are friends!'
            : 'Request sent',
      );
      await _refresh();
    } on FriendException catch (e) {
      if (mounted) _showSnack(e.text);
    }
  }

  Future<void> _respond(FriendRequestView request, bool accept) async {
    try {
      await _client.respond(seatId: _seatId, id: request.id, accept: accept);
      if (mounted) _showSnack(accept ? 'Now friends!' : 'Request declined');
      await _refresh();
    } on FriendException catch (e) {
      if (mounted) _showSnack(e.text);
    }
  }

  Future<void> _withdraw(FriendRequestView request) async {
    try {
      await _client.respond(
        seatId: _seatId,
        id: request.id,
        accept: false,
        withdraw: true,
      );
      if (mounted) _showSnack('Request cancelled');
      await _refresh();
    } on FriendException catch (e) {
      if (mounted) _showSnack(e.text);
    }
  }

  Future<void> _removeFriend(FriendEntry friend) async {
    final sure = await _confirm(
      'Remove ${friend.name}?',
      'They will no longer see your friend code, and the chat between you '
          'stops.',
    );
    if (sure != true) return;
    try {
      await _client.remove(seatId: _seatId, target: friend.seatId);
      if (mounted) _showSnack('${friend.name} removed');
      await _refresh();
    } on FriendException catch (e) {
      if (mounted) _showSnack(e.text);
    }
  }

  Future<void> _block(FriendEntry friend) async {
    final sure = await _confirm(
      'Block ${friend.name}?',
      'Un-friends them and drops every pending request or invite between '
          'you. Neither of you can message, invite, or re-add the other until '
          'one of you is unblocked from Settings-style list below.',
    );
    if (sure != true) return;
    try {
      await _client.block(seatId: _seatId, target: friend.seatId);
      if (mounted) _showSnack('${friend.name} blocked');
      await _refresh();
    } on FriendException catch (e) {
      if (mounted) _showSnack(e.text);
    }
  }

  Future<void> _report(FriendEntry friend) async {
    final reason = await _prompt(
      title: 'Report ${friend.name}',
      hint: 'What happened? (goes to the moderators)',
      multiline: true,
    );
    if (reason == null) return;
    try {
      await _client.report(
        seatId: _seatId,
        target: friend.seatId,
        reason: reason,
      );
      if (mounted) _showSnack('Report sent — thank you');
    } on FriendException catch (e) {
      if (mounted) _showSnack(e.text);
    }
  }

  Future<void> _unblock(FriendBlockView entry) async {
    try {
      await _client.unblock(seatId: _seatId, target: entry.seatId);
      if (mounted) _showSnack('${entry.name} unblocked');
      await _refresh();
    } on FriendException catch (e) {
      if (mounted) _showSnack(e.text);
    }
  }

  Future<void> _answerInvite(FriendInviteView invite, bool accept) async {
    try {
      final code = await _client.respondInvite(
        seatId: _seatId,
        id: invite.id,
        accept: accept,
      );
      if (!mounted) return;
      if (accept && code != null && code.isNotEmpty) {
        pushAppScreen<void>(
          context,
          name: AppRoutes.join(code),
          builder: (_) =>
              OnlineLobbyScreen(startup: OnlineStartup(joinCode: code)),
        );
        return;
      }
      if (accept) {
        _showSnack('Their table is not ready — invite them to start one!');
      } else {
        await _refresh();
      }
    } on FriendException catch (e) {
      if (mounted) _showSnack(e.text);
    }
  }

  /// Opens a room of [game] and, the moment the server hands back its
  /// code, pushes an invite carrying that code. The lobby screen adopts
  /// the same client, so the host lands in the table seats view.
  void _playWithFriend(FriendEntry friend) async {
    final game = await showDialog<String>(
      context: context,
      builder: (ctx) => SimpleDialog(
        title: Text('Invite ${friend.name} to…'),
        children: [
          SimpleDialogOption(
            onPressed: () => Navigator.pop(ctx, 'ludo'),
            child: const Text('Ludo'),
          ),
          SimpleDialogOption(
            onPressed: () => Navigator.pop(ctx, 'snakes'),
            child: const Text('Snakes & Ladders'),
          ),
        ],
      ),
    );
    if (game == null || !mounted) return;

    final lobby = OnlineClient(
      OnlineLobbyScreen.defaultServerUrl(),
      seatId: _seatId,
      name: _myName.isEmpty ? _state?.me.name ?? 'Player' : _myName,
      gameType: game,
      capacity: 4,
    );
    var sent = false;
    void maybeInvite() {
      final code = lobby.roomCode;
      if (sent || code == null || code.isEmpty) return;
      sent = true;
      lobby.removeListener(maybeInvite);
      _client
          .invite(
            seatId: _seatId,
            name: _myName,
            to: friend.seatId,
            game: game,
            code: code,
          )
          .then((_) {
            if (mounted) {
              _showSnack('Invite sent — waiting at the table');
            }
          })
          .catchError((Object e) {
            // The server words its own failures (rate limits, strangers);
            // transport-level breaks get the fix line instead of an
            // exception dump.
            if (mounted) {
              _showSnack(
                e is FriendException
                    ? e.text
                    : 'The play request did not reach them — check your '
                          'connection and try Play again.',
              );
            }
          });
    }

    lobby.addListener(maybeInvite);
    if (!mounted) return;
    final handoff = pushAppScreen<void>(
      context,
      name: AppRoutes.online,
      builder: (_) =>
          OnlineLobbyScreen(startup: OnlineStartup(adoptedClient: lobby)),
    );
    // Connect only after the push so the lobby panel shows the dial.
    try {
      await lobby.connect();
    } catch (e) {
      // An async-void handler would eat this into the zone — answer with
      // the fix instead of a silent tap.
      _abandonHandoff(handoff);
      return;
    }
    if (sent) return;
    // connect() only opens the socket; the code arrives with `joined` a
    // moment later. Waiting for it here is what lets the invite exist:
    // checking roomCode immediately after connect() always saw null and
    // popped the lobby before the server had named the room. The entry's
    // own future races the wait so leaving the lobby early does not make
    // this path speak later on the friends screen.
    final formed = await Future.any<String?>([
      lobby.awaitRoomCode(),
      handoff.popped.then((_) => null),
    ]);
    // `maybeInvite` is the listener path, but a `joined` frame that landed
    // before the listener was attached would leave an open room with no
    // invite in it. The awaited code is the same fact: if the room exists
    // and nothing has been sent, send it now.
    if (!sent && formed != null && formed.isNotEmpty) {
      maybeInvite();
    }
    lobby.removeListener(maybeInvite);
    if (!sent && (formed == null || formed.isEmpty)) {
      _abandonHandoff(handoff);
    }
  }

  /// The handoff died before an invite could be sent: leave the dead
  /// lobby screen (the push already happened) and answer with the fix.
  /// The pop only fires while the handoff's own entry is still the top of
  /// the stack — a user who backed out of the dead lobby first keeps the
  /// friends screen where it is.
  void _abandonHandoff(AppHandle<void> handoff) {
    // The player may have backed out first: stay silent rather than
    // speaking a failure about a screen they already left, and never
    // pop the friends screen they are now looking at.
    if (!mounted || !handoff.isCurrent) return;
    handoff.pop();
    _showSnack(
      'Could not open a table — check the game server, then tap Play again.',
    );
  }

  Future<void> _openChat(FriendEntry friend) async {
    await pushAppScreen<void>(
      context,
      name: AppRoutes.friendsChat(friend.seatId),
      builder: (_) => FriendsChatScreen(
        client: _client,
        me: _seatId,
        myName: _myName,
        peer: friend,
      ),
    ).popped;
    if (!mounted) return;
    await _refresh();
  }

  // ------------------------------------------------------------- prompts

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

  Future<bool?> _confirm(String title, String body) => showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text(title),
      content: Text(body, style: const TextStyle(color: AppColors.ivory)),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(ctx, false),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(ctx, true),
          child: const Text('Yes'),
        ),
      ],
    ),
  );

  // ------------------------------------------------------------- layout

  @override
  Widget build(BuildContext context) {
    final state = _state;
    return Scaffold(
      appBar: PageAppBar(
        title: 'Friends',
        actions: [
          IconButton(
            icon: const Icon(Icons.person_add),
            tooltip: 'Add a friend',
            onPressed: _addFriendFlow,
          ),
        ],
      ),
      body: ClubBackground(
        child: SafeArea(
          // The reading-width column: this screen is a phone list (the
          // header above already constrains itself to the same width), so
          // a desktop window shows the tray as a centered column, not as
          // friend cards stretched edge to edge across a laptop.
          child: ContentColumn(
            child: state == null
                ? Center(
                    child: _busyText != null
                        ? Text(
                            _busyText!,
                            style: const TextStyle(
                              fontFamily: AppFonts.body,
                              color: AppColors.paper,
                            ),
                          )
                        : const CircularProgressIndicator(
                            color: AppColors.gold,
                          ),
                  )
                : RefreshIndicator(
                    onRefresh: _refresh,
                    color: AppColors.gold,
                    child: ListView(
                      padding: const EdgeInsets.fromLTRB(16, 16, 16, 28),
                      children: [
                        _meCode(state.me),
                        // Discovery at the table: everyone seated in the
                        // room the caller is in, who no other section
                        // already shows. The row opens the same actions
                        // sheet a tablemate row in the lobby does —
                        // add, block, report — so the friends screen
                        // needs no second pathway to the same buttons.
                        if (state.table.isNotEmpty) ...[
                          _sectionTitle('At your table'),
                          for (final t in state.table) _tableTile(t),
                        ],
                        if (state.incoming.isNotEmpty) ...[
                          _sectionTitle('Friend requests'),
                          for (final r in state.incoming)
                            _requestTile(r, incoming: true),
                        ],
                        if (state.outgoing.isNotEmpty) ...[
                          _sectionTitle('Sent, waiting'),
                          for (final r in state.outgoing)
                            _requestTile(r, incoming: false),
                        ],
                        if (state.invites.any((i) => i.pending)) ...[
                          _sectionTitle('Play invites'),
                          for (final i in state.invites)
                            if (i.pending) _inviteTile(i),
                        ],
                        if (state.friends.isEmpty)
                          const ClubCard(
                            padding: EdgeInsets.fromLTRB(20, 24, 20, 24),
                            child: Column(
                              children: [
                                ClubSeal(icon: Icons.people_outline, size: 46),
                                SizedBox(height: 12),
                                Text(
                                  'No friends yet.\nAdd the players you meet '
                                  'at a table straight from their row in the '
                                  'room, or tap + for a friend code.',
                                  textAlign: TextAlign.center,
                                  style: TextStyle(
                                    fontFamily: AppFonts.body,
                                    color: AppColors.inkSoft,
                                    fontSize: 13,
                                    height: 1.6,
                                  ),
                                ),
                              ],
                            ),
                          )
                        else ...[
                          _sectionTitle('Your friends'),
                          for (final f in state.friends) _friendTile(f),
                        ],
                        if (state.blocked.isNotEmpty) ...[
                          _sectionTitle('Blocked'),
                          for (final b in state.blocked) _blockedTile(b),
                        ],
                      ],
                    ),
                  ),
          ),
        ),
      ),
    );
  }

  Widget _meCode(FriendProfile me) {
    return ClubCard(
      accent: true,
      padding: const EdgeInsets.fromLTRB(14, 14, 10, 14),
      child: Row(
        children: [
          const ClubSeal(icon: Icons.badge_outlined, size: 42),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  me.name.isEmpty ? 'You' : me.name,
                  style: const TextStyle(
                    fontFamily: AppFonts.body,
                    color: AppColors.ink,
                    fontSize: 15,
                    fontWeight: FontWeight.w800,
                  ),
                ),
                const SizedBox(height: 3),
                Text(
                  'Your friend code: ${me.code}',
                  style: const TextStyle(
                    fontFamily: AppFonts.body,
                    color: AppColors.inkSoft,
                    fontSize: 11.5,
                    fontWeight: FontWeight.w600,
                    letterSpacing: 1.2,
                  ),
                ),
              ],
            ),
          ),
          IconButton(
            icon: const Icon(Icons.copy, size: 18),
            color: AppColors.brassDeep,
            tooltip: 'Copy friend code',
            onPressed: () async {
              await Clipboard.setData(ClipboardData(text: me.code));
              if (mounted) _showSnack('Friend code copied');
            },
          ),
        ],
      ),
    );
  }

  Widget _tableTile(TableMate t) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 7),
      child: ClubCard(
        padding: EdgeInsets.zero,
        radius: 15,
        // The same one-row shape the friend cards use; the trailing add
        // icon and the row's own tap both lead into the actions sheet, so
        // the whole card is the target and nothing is icon-only.
        child: ListTile(
          dense: true,
          onTap: () => _openTableActions(t),
          leading: _avatar(t.seatId),
          title: Text(
            t.name,
            style: const TextStyle(
              fontFamily: AppFonts.body,
              color: AppColors.ink,
              fontWeight: FontWeight.w700,
            ),
          ),
          trailing: TextButton.icon(
            onPressed: () => _openTableActions(t),
            icon: const Icon(Icons.person_add, size: 16),
            label: const Text('Add'),
          ),
        ),
      ),
    );
  }

  /// Someone currently seated at the caller's table: the sheet carries
  /// the add / block / report actions and mints the tablemate's profile
  /// when an add needs one. A background refresh follows, so a request
  /// that just went out hops from this section to "Sent, waiting"
  /// without waiting for the next tick.
  Future<void> _openTableActions(TableMate t) async {
    await PlayerActionsSheet.show(
      context,
      serverUrl: _client.serverUrl,
      mySeatId: _seatId,
      myName: _myName,
      peerSeatId: t.seatId,
      peerName: t.name,
      // The test-injected client drives the sheet's own tray fetch too;
      // production passes null and the sheet builds its own.
      friendClientForTest: widget.client,
    );
    if (mounted) await _refresh();
  }

  Widget _sectionTitle(String text) => Padding(
    padding: const EdgeInsets.only(top: 20, bottom: 8, left: 2),
    child: Row(
      children: [
        Text(
          text,
          style: const TextStyle(
            fontFamily: AppFonts.body,
            color: AppColors.gold,
            fontWeight: FontWeight.w800,
            fontSize: 9.5,
            letterSpacing: 1.7,
          ),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: Container(
            height: 1,
            color: AppColors.gold.withValues(alpha: 0.18),
          ),
        ),
      ],
    ),
  );

  Widget _avatar(String seed) =>
      PlayerAvatar(seed: seed, size: 40, circular: true);

  Widget _requestTile(FriendRequestView r, {required bool incoming}) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 7),
      child: ClubCard(
        padding: EdgeInsets.zero,
        radius: 15,
        child: ListTile(
          leading: _avatar(r.seatId),
          title: Text(
            r.name,
            style: const TextStyle(
              fontFamily: AppFonts.body,
              color: AppColors.ink,
              fontWeight: FontWeight.w700,
            ),
          ),
          subtitle: Text(
            incoming ? 'wants to be your friend' : 'asking them',
            style: const TextStyle(
              fontFamily: AppFonts.body,
              color: AppColors.inkSoft,
              fontSize: 12,
            ),
          ),
          trailing: incoming
              ? Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    IconButton(
                      icon: const Icon(Icons.check_circle_outline),
                      color: AppColors.brassDeep,
                      tooltip: 'Accept',
                      onPressed: () => _respond(r, true),
                    ),
                    IconButton(
                      icon: const Icon(Icons.close),
                      tooltip: 'Decline',
                      onPressed: () => _respond(r, false),
                    ),
                  ],
                )
              : TextButton(
                  onPressed: () => _withdraw(r),
                  child: const Text('Cancel'),
                ),
        ),
      ),
    );
  }

  Widget _inviteTile(FriendInviteView i) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 7),
      child: ClubCard(
        padding: EdgeInsets.zero,
        radius: 15,
        child: ListTile(
          leading: const ClubSeal(icon: Icons.sports_esports, size: 38),
          title: Text(
            i.name,
            style: const TextStyle(
              fontFamily: AppFonts.body,
              color: AppColors.ink,
              fontWeight: FontWeight.w700,
            ),
          ),
          subtitle: Text(
            'invites you to '
            '${i.game == 'snakes' ? 'Snakes & Ladders' : 'Ludo'}'
            ' · room ${i.code.isEmpty ? '(starting)' : i.code}',
            style: const TextStyle(
              fontFamily: AppFonts.body,
              color: AppColors.inkSoft,
              fontSize: 12,
            ),
          ),
          trailing: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              FilledButton(
                onPressed: () => _answerInvite(i, true),
                child: const Text('Join'),
              ),
              const SizedBox(width: 4),
              TextButton(
                onPressed: () => _answerInvite(i, false),
                child: const Text('No'),
              ),
            ],
          ),
        ),
      ),
    );
  }

  void _friendLongPressSheet(FriendEntry f) {
    showModalBottomSheet<void>(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.chat_bubble_outline),
              title: Text('Message ${f.name}'),
              onTap: () {
                Navigator.pop(ctx);
                _openChat(f);
              },
            ),
            ListTile(
              leading: const Icon(Icons.link_off),
              title: Text('Remove ${f.name}'),
              onTap: () {
                Navigator.pop(ctx);
                _removeFriend(f);
              },
            ),
            ListTile(
              leading: const Icon(Icons.block),
              title: Text('Block ${f.name}'),
              onTap: () {
                Navigator.pop(ctx);
                _block(f);
              },
            ),
            ListTile(
              leading: const Icon(Icons.flag_outlined),
              title: Text('Report ${f.name}'),
              onTap: () {
                Navigator.pop(ctx);
                _report(f);
              },
            ),
          ],
        ),
      ),
    );
  }

  Widget _friendTile(FriendEntry f) {
    final latest = f.latest;
    final read = _read[f.seatId] ?? 0;
    final unread = latest > 0 && latest > read;
    return Padding(
      padding: const EdgeInsets.only(bottom: 7),
      child: ClubCard(
        padding: EdgeInsets.zero,
        radius: 15,
        // One compact row like every other card in the app: the instruction
        // line ("tap to chat · long-press for more") used to stretch every
        // card to two display lines — a hint that repeats forever teaches
        // nobody and reads as scaffolding. The gestures it described still
        // exist: tapping opens the chat, holding opens the sheet.
        child: ListTile(
          dense: true,
          onLongPress: () => _friendLongPressSheet(f),
          onTap: () => _openChat(f),
          leading: _avatar(f.seatId),
          title: Text(
            f.name,
            style: const TextStyle(
              fontFamily: AppFonts.body,
              color: AppColors.ink,
              fontWeight: FontWeight.w700,
            ),
          ),
          trailing: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (unread)
                const Padding(
                  padding: EdgeInsets.only(right: 8),
                  child: Icon(
                    Icons.circle,
                    size: 11,
                    color: AppColors.brassDeep,
                  ),
                ),
              TextButton.icon(
                onPressed: () => _playWithFriend(f),
                icon: const Icon(Icons.sports_esports, size: 16),
                label: const Text('Play'),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _blockedTile(FriendBlockView b) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 7),
      child: ClubCard(
        background: AppColors.paperDeep.withValues(alpha: 0.72),
        padding: EdgeInsets.zero,
        radius: 15,
        child: ListTile(
          leading: Opacity(opacity: 0.6, child: _avatar(b.seatId)),
          title: Text(
            b.name.isEmpty ? b.seatId : b.name,
            style: const TextStyle(
              fontFamily: AppFonts.body,
              color: AppColors.inkSoft,
              fontWeight: FontWeight.w600,
            ),
          ),
          subtitle: const Text(
            'cannot contact you',
            style: TextStyle(
              fontFamily: AppFonts.body,
              color: AppColors.inkFaint,
              fontSize: 12,
            ),
          ),
          trailing: TextButton(
            onPressed: () => _unblock(b),
            child: const Text('Unblock'),
          ),
        ),
      ),
    );
  }
}

/// 1:1 DM with a friend: polling reads (the room's chat is a poll, so a
/// DM mirror keeps one mental model), optimistic sends, double-tap and
/// long-press liking, reply-with-quote via the composer bar.
class FriendsChatScreen extends StatefulWidget {
  const FriendsChatScreen({
    super.key,
    required this.client,
    required this.me,
    required this.myName,
    required this.peer,
  });

  final FriendClient client;
  final String me;
  final String myName;
  final FriendEntry peer;

  @override
  State<FriendsChatScreen> createState() => _FriendsChatScreenState();
}

class _FriendsChatScreenState extends State<FriendsChatScreen> {
  final _composer = TextEditingController();
  final _scroll = ScrollController();

  /// Ascending by id — the server pages oldest-first on purpose.
  final List<FriendMessageView> _messages = [];
  int _lastKnown = 0;
  FriendMessageView? _replyTo;
  Timer? _poller;

  @override
  void initState() {
    super.initState();
    _poll();
    _poller = Timer.periodic(const Duration(seconds: 3), (_) => _poll());
  }

  @override
  void dispose() {
    _poller?.cancel();
    _composer.dispose();
    _scroll.dispose();
    super.dispose();
  }

  Future<void> _poll() async {
    if (widget.me.isEmpty) return;
    try {
      final since = _messages.isEmpty ? null : _lastKnown;
      final page = await widget.client.chat(
        seatId: widget.me,
        peer: widget.peer.seatId,
        since: since,
      );
      if (!mounted) return;
      final known = {for (final m in _messages) m.id};
      var changed = false;
      for (final m in page.messages) {
        if (known.contains(m.id)) continue;
        _messages.add(m);
        changed = true;
      }
      // An optimistic send that the server now echoes with a real id
      // steps aside for the server truth (ids, likes arrive with it).
      final before = _messages.length;
      final echoed = page.messages
          .where((m) => m.fromMe)
          .map((m) => m.body)
          .toSet();
      _messages.removeWhere((m) => m.id < 0 && echoed.contains(m.body));
      if (_messages.length != before) changed = true;
      if (page.latest > _lastKnown) _lastKnown = page.latest;
      // Reading advances the marker the moment the page lands.
      if (page.latest > 0) {
        await FriendReadMarkers.stamp(widget.peer.seatId, page.latest);
      }
      if (changed && mounted) {
        setState(() {});
        _scrollDownSoon();
      }
    } on FriendException catch (_) {
      // A quiet poller: the tray screen owns the loud errors.
    }
  }

  void _scrollDownSoon() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_scroll.hasClients) return;
      _scroll.animateTo(
        _scroll.position.maxScrollExtent,
        duration: const Duration(milliseconds: 220),
        curve: Curves.easeOut,
      );
    });
  }

  Future<void> _send() async {
    final text = _composer.text.trim();
    if (text.isEmpty) return;
    final reply = _replyTo;
    final replyId = reply != null && reply.id >= 0 ? reply.id : null;
    final echo = FriendMessageView(
      id: -1 - _messages.length,
      fromMe: true,
      body: text,
      liked: false,
      sinceMs: DateTime.now().millisecondsSinceEpoch,
      replyTo: replyId,
      replyFromMe: reply?.fromMe,
      replyBody: reply?.body,
    );
    setState(() {
      _replyTo = null;
      _composer.clear();
      _messages.add(echo);
    });
    _scrollDownSoon();
    try {
      final fresh = await widget.client.send(
        seatId: widget.me,
        to: widget.peer.seatId,
        body: text,
        replyTo: replyId,
      );
      if (!mounted) return;
      final echoIndex = _messages.indexWhere((m) => m.id == echo.id);
      if (echoIndex == -1) {
        // The poll already replaced it with server truth.
        return;
      }
      setState(() => _messages[echoIndex] = fresh);
      if (fresh.id > _lastKnown) _lastKnown = fresh.id;
      await FriendReadMarkers.stamp(widget.peer.seatId, fresh.id);
    } on FriendException catch (e) {
      if (mounted) {
        setState(() => _messages.removeWhere((m) => m.id == echo.id));
        showSnackInColumn(context, e.text, icon: Icons.error_outline);
      }
    }
  }

  Future<void> _toggleLike(FriendMessageView m) async {
    if (m.id < 0) return;
    final i = _messages.indexWhere((x) => x.id == m.id);
    if (i == -1) return;
    final liked = !m.liked;
    setState(() {
      _messages[i] = FriendMessageView(
        id: m.id,
        fromMe: m.fromMe,
        body: m.body,
        liked: liked,
        sinceMs: m.sinceMs,
        replyTo: m.replyTo,
        replyFromMe: m.replyFromMe,
        replyBody: m.replyBody,
      );
    });
    try {
      await widget.client.like(
        seatId: widget.me,
        messageId: m.id,
        liked: liked,
      );
    } on FriendException catch (_) {
      await _poll();
    }
  }

  void _startReply(FriendMessageView m) {
    setState(() => _replyTo = m);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) FocusScope.of(context).unfocus();
    });
  }

  void _messageActionsSheet(FriendMessageView m) {
    showModalBottomSheet<void>(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.reply),
              title: Text(m.fromMe ? 'Reply to yourself' : 'Reply to them'),
              onTap: () {
                Navigator.pop(ctx);
                _startReply(m);
              },
            ),
            ListTile(
              leading: Icon(m.liked ? Icons.favorite : Icons.favorite_border),
              title: Text(m.liked ? 'Unlike' : 'Like'),
              onTap: () {
                Navigator.pop(ctx);
                _toggleLike(m);
              },
            ),
          ],
        ),
      ),
    );
  }

  // ------------------------------------------------------------- layout

  @override
  Widget build(BuildContext context) {
    final peer = widget.peer;
    return Scaffold(
      appBar: PageAppBar(title: peer.name),
      body: ClubBackground(
        child: SafeArea(
          // The same reading-width column as every other screen: the DM
          // thread is a phone conversation, so on a desktop window the
          // bubbles and the composer sit in the centered column the header
          // draws, not stretched the width of the laptop.
          child: ContentColumn(
            child: Column(
              children: [
                Expanded(
                  child: _messages.isEmpty
                      ? Center(
                          child: Text(
                            'Say hi to ${peer.name} — the first message '
                            'is the hardest',
                            style: const TextStyle(
                              fontFamily: AppFonts.body,
                              color: AppColors.paperDeep,
                              fontSize: 14,
                            ),
                          ),
                        )
                      : ListView.builder(
                          controller: _scroll,
                          padding: const EdgeInsets.all(12),
                          itemCount: _messages.length,
                          itemBuilder: (context, i) {
                            final m = _messages[i];
                            return _bubble(m);
                          },
                        ),
                ),
                _composerBar(),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _bubble(FriendMessageView m) {
    final myLabel = widget.myName.isEmpty ? 'You' : widget.myName;
    return GestureDetector(
      onLongPress: () => _messageActionsSheet(m),
      onDoubleTap: () => _toggleLike(m),
      child: Padding(
        padding: const EdgeInsets.only(bottom: 2),
        child: ChatLineView(
          line: ChatLine(
            from: m.fromMe ? myLabel : widget.peer.name,
            text: m.body,
            at: m.sinceMs,
          ),
          myName: m.fromMe ? myLabel : '',
          avatar: PlayerAvatar(
            seed: m.fromMe ? widget.me : widget.peer.seatId,
            size: 30,
            circular: true,
          ),
          liked: m.liked,
          quote: m.replyBody == null
              ? null
              : _quoteStrip(
                  author: m.replyFromMe == true ? myLabel : widget.peer.name,
                  body: m.replyBody!,
                ),
        ),
      ),
    );
  }

  Widget _quoteStrip({required String author, required String body}) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(8),
        border: Border(left: BorderSide(width: 3, color: AppColors.gold)),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            author,
            style: const TextStyle(
              color: AppColors.gold,
              fontSize: 11,
              fontWeight: FontWeight.w800,
            ),
          ),
          Text(
            body,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              color: AppColors.ivory.withValues(alpha: 0.75),
              fontSize: 12,
            ),
          ),
        ],
      ),
    );
  }

  Widget _composerBar() {
    final meName = widget.myName.isEmpty ? 'You' : widget.myName;
    return Column(
      children: [
        if (_replyTo != null)
          Container(
            color: Colors.white.withValues(alpha: 0.07),
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
            child: Row(
              children: [
                Expanded(
                  child: _quoteStrip(
                    author: _replyTo!.fromMe ? meName : widget.peer.name,
                    body: _replyTo!.body.isEmpty
                        ? '(a message)'
                        : _replyTo!.body,
                  ),
                ),
                IconButton(
                  icon: const Icon(Icons.close, size: 18),
                  tooltip: 'Cancel reply',
                  onPressed: () => setState(() => _replyTo = null),
                ),
              ],
            ),
          ),
        Padding(
          padding: const EdgeInsets.all(10),
          child: Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _composer,
                  maxLines: 4,
                  minLines: 1,
                  onSubmitted: (_) => _send(),
                  decoration: const InputDecoration(
                    hintText: 'Message…',
                    border: OutlineInputBorder(),
                    isDense: true,
                  ),
                ),
              ),
              const SizedBox(width: 8),
              IconButton.filled(
                onPressed: _send,
                icon: const Icon(Icons.send),
                tooltip: 'Send',
              ),
            ],
          ),
        ),
      ],
    );
  }
}
