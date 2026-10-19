/// The player directory: every registered player on the server, one row
/// each, with a one-tap friend request.
///
/// Discovery used to run only on friend codes — which assumes you can ask
/// the person you just met for a six-character string neither of you knows
/// where to find (the playtest round's exact report). The directory is the
/// other half: browse who exists, see their id, send the request straight
/// from the row.
///
/// The rows are public presence (name, code, id); every relationship
/// decision still runs through the caller's own request/respond calls, so
/// this screen grants nothing by itself. Relationship states resolve
/// against the same state bundle the friends tray reads, and each state
/// has its own row answer: you, already friends, request sent, request
/// waiting on you (accept right here), blocked, or the Add button.
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show Clipboard, ClipboardData;

import '../services/friend_client.dart';
import '../services/online_client.dart' show DefaultNames;
import '../services/server_url.dart';
import '../services/storage_service.dart';
import '../ui/page_app_bar.dart';
import '../ui/shared/player_avatar.dart';
import '../ui/theme.dart';

/// The player directory behind the friends tray's browse action.
class PlayerDirectoryScreen extends StatefulWidget {
  const PlayerDirectoryScreen({super.key, this.client});

  /// Test injection point; null builds the real same-origin client.
  final FriendClient? client;

  @override
  State<PlayerDirectoryScreen> createState() => _PlayerDirectoryScreenState();
}

class _PlayerDirectoryScreenState extends State<PlayerDirectoryScreen> {
  late final FriendClient _client;

  /// Whether this screen created (and therefore must retire) the client.
  late final bool _ownsClient;

  /// The stable online identity — restored exactly like the friends tray,
  /// so a request sent from here is the same person's request everywhere.
  String _seatId = '';
  String _myName = '';

  /// Null = still loading. The two loads run together; the screen draws
  /// when both have landed.
  List<FriendProfile>? _players;
  FriendState? _state;

  String _query = '';

  /// Seat ids with an in-flight add — the row's button shows progress and
  /// cannot double-fire while its request is away.
  final Set<String> _sending = {};

  String? _error;

  @override
  void initState() {
    super.initState();
    _client = widget.client ?? FriendClient(serverUrl: defaultServerUrl());
    _ownsClient = widget.client == null;
    _restore();
  }

  @override
  void dispose() {
    if (_ownsClient) _client.close();
    super.dispose();
  }

  Future<void> _restore() async {
    final storage = StorageService();
    final id = await storage.loadOnlinePlayerId();
    final name = await storage.loadOnlineName();
    final resolved = name.isNotEmpty ? name : DefaultNames.unique(playerId: id);
    if (!mounted) return;
    setState(() {
      _seatId = id;
      _myName = resolved;
    });
    if (name.isEmpty) {
      await StorageService().saveOnlineName(resolved);
    }
    await _load();
  }

  Future<void> _load() async {
    setState(() {
      _error = null;
      if (_players == null && _state == null) _players = null;
    });
    try {
      final players = _client.players();
      final state = _client.state(seatId: _seatId, name: _myName);
      final both = await Future.wait([players, state]);
      if (!mounted) return;
      setState(() {
        _players = both[0] as List<FriendProfile>;
        _state = both[1] as FriendState;
      });
    } on FriendException catch (e) {
      if (!mounted) return;
      setState(() {
        _error = '$e'.replaceFirst('FriendException: ', '');
        _players ??= [];
      });
    }
  }

  bool _isFriend(String seatId) =>
      _state?.friends.any((f) => f.seatId == seatId) ?? false;

  bool _isBlocked(String seatId) =>
      _state?.blocked.any((b) => b.seatId == seatId) ?? false;

  FriendRequestView? _incomingFrom(String seatId) {
    for (final r in _state?.incoming ?? const []) {
      if (r.seatId == seatId) return r;
    }
    return null;
  }

  bool _outgoingTo(String seatId) =>
      _state?.outgoing.any((r) => r.seatId == seatId) ?? false;

  Future<void> _accept(FriendRequestView r) async {
    final ok = await _client.respond(seatId: _seatId, id: r.id, accept: true);
    if (!mounted) return;
    _showSnack(ok ? 'You are friends with ${r.name}' : 'Could not accept');
    await _load();
  }

  Future<void> _add(FriendProfile p) async {
    final go = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Add ${p.name}?'),
        content: Row(
          children: [
            PlayerAvatar(seed: p.seatId, size: 40, circular: true),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                'Their id is ${p.seatId}. '
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
    setState(() => _sending.add(p.seatId));
    try {
      final status = await _client.request(
        seatId: _seatId,
        name: _myName,
        target: p.seatId,
      );
      if (!mounted) return;
      _showSnack(
        status == 'accepted'
            ? 'They added you back — you are friends!'
            : 'Request sent',
      );
    } on FriendException catch (e) {
      if (mounted) _showSnack('$e'.replaceFirst('FriendException: ', ''));
    } finally {
      if (mounted) setState(() => _sending.remove(p.seatId));
    }
    await _load();
  }

  void _showSnack(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  @override
  Widget build(BuildContext context) {
    final loading = _players == null;
    return Scaffold(
      appBar: PageAppBar(title: 'Players'),
      body: Container(
        decoration: const BoxDecoration(
          gradient: RadialGradient(
            center: Alignment(0, -0.4),
            radius: 1.4,
            colors: [AppColors.feltLight, AppColors.felt],
          ),
        ),
        child: SafeArea(
          // The reading-width column, like every screen: the header above
          // constrains itself to the same width.
          child: ContentColumn(
            child: loading
                ? const Center(
                    child: CircularProgressIndicator(color: AppColors.gold),
                  )
                : Column(
                    children: [
                      Padding(
                        padding: const EdgeInsets.fromLTRB(12, 12, 12, 4),
                        child: TextField(
                          onChanged: (v) => setState(() => _query = v),
                          decoration: InputDecoration(
                            prefixIcon: const Icon(Icons.search),
                            hintText: 'Search by name or id',
                            filled: true,
                            fillColor: Colors.white.withValues(alpha: 0.07),
                            border: OutlineInputBorder(
                              borderRadius: BorderRadius.circular(12),
                              borderSide: BorderSide.none,
                            ),
                          ),
                        ),
                      ),
                      if (_error != null)
                        Padding(
                          padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
                          child: Column(
                            children: [
                              Text(
                                _error!,
                                textAlign: TextAlign.center,
                                style: const TextStyle(color: AppColors.ivory),
                              ),
                              TextButton(
                                onPressed: _load,
                                child: const Text('Try again'),
                              ),
                            ],
                          ),
                        ),
                      Expanded(child: _list()),
                    ],
                  ),
          ),
        ),
      ),
    );
  }

  Widget _list() {
    final players = _players ?? const [];
    // A total failure (nothing loaded) reads once — in the error block
    // above — not twice with a contradictory "No players yet" under it.
    if (_error != null && players.isEmpty) return const SizedBox.shrink();
    if (players.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text(
            'No players yet — invite someone to a game table first.',
            textAlign: TextAlign.center,
            style: const TextStyle(color: AppColors.ivory, height: 1.6),
          ),
        ),
      );
    }
    final q = _query.trim().toLowerCase();
    final shown = q.isEmpty
        ? players
        : players
              .where(
                (p) =>
                    p.name.toLowerCase().contains(q) ||
                    p.seatId.toLowerCase().contains(q) ||
                    p.code.toLowerCase().contains(q),
              )
              .toList();
    if (shown.isEmpty) {
      return Center(
        child: Text(
          'No player matches “$_query”',
          style: const TextStyle(color: AppColors.ivory),
        ),
      );
    }
    return RefreshIndicator(
      onRefresh: _load,
      color: AppColors.gold,
      child: ListView(
        padding: const EdgeInsets.all(12),
        children: [for (final p in shown) _row(p)],
      ),
    );
  }

  Widget _row(FriendProfile p) {
    final isMe = p.seatId == _seatId;
    final friend = _isFriend(p.seatId);
    final blocked = _isBlocked(p.seatId);
    final incoming = _incomingFrom(p.seatId);
    final outgoing = _outgoingTo(p.seatId);
    final sending = _sending.contains(p.seatId);

    // The one trailing control the row's relationship state answers with.
    Widget trailing;
    if (isMe) {
      trailing = const _RowChip(label: 'You');
    } else if (friend) {
      trailing = const _RowChip(label: 'Friends');
    } else if (blocked) {
      trailing = const _RowChip(label: 'Blocked');
    } else if (incoming != null) {
      trailing = FilledButton(
        // The row that answers "they asked me first": accept right here —
        // the tray still works, but nobody should have to know that.
        onPressed: sending ? null : () => _accept(incoming),
        child: const Text('Accept'),
      );
    } else if (outgoing) {
      trailing = const _RowChip(label: 'Sent');
    } else {
      trailing = FilledButton.tonal(
        onPressed: sending ? null : () => _add(p),
        child: sending
            ? const SizedBox(
                width: 18,
                height: 18,
                child: CircularProgressIndicator(strokeWidth: 2),
              )
            : const Text('Add'),
      );
    }

    return Opacity(
      opacity: blocked ? 0.55 : 1,
      child: Card(
        color: Colors.white.withValues(alpha: 0.06),
        margin: const EdgeInsets.only(bottom: 8),
        child: ListTile(
          leading: PlayerAvatar(seed: p.seatId, size: 40, circular: true),
          title: Text(
            p.name,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(
              color: AppColors.ivory,
              fontWeight: FontWeight.w700,
            ),
          ),
          subtitle: Text(
            // The id the add flow used to demand from thin air, now shown —
            // and copyable, because reading it aloud is not the point.
            'id: ${p.seatId} · code: ${p.code}',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(color: AppColors.ivory, fontSize: 12),
          ),
          isThreeLine: false,
          trailing: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (!isMe)
                IconButton(
                  icon: const Icon(Icons.copy, size: 20),
                  tooltip: 'Copy player id',
                  onPressed: () async {
                    await Clipboard.setData(ClipboardData(text: p.seatId));
                    if (mounted) _showSnack('Player id copied');
                  },
                ),
              trailing,
            ],
          ),
        ),
      ),
    );
  }
}

/// A non-interactive relationship state: the row says the truth and asks
/// for nothing.
class _RowChip extends StatelessWidget {
  const _RowChip({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Text(
        label,
        style: const TextStyle(color: AppColors.ivory, fontSize: 12),
      ),
    );
  }
}
