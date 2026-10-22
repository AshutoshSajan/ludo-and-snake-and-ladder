import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show Clipboard, ClipboardData;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../app_router.dart';
import '../app_routes.dart';
import '../providers/app_providers.dart';
import '../ui/page_app_bar.dart';
import '../ui/shared/player_actions_sheet.dart';
import '../ui/shared/responsive_chat_dock.dart';
import '../ui/shared/voice_button.dart';

import '../engine/ludo/ludo_models.dart';
import '../services/friend_client.dart';
import '../services/friend_signals.dart';
import '../services/join_link.dart';
import '../services/online_client.dart';
import '../services/share_link.dart';
import '../services/sound_service.dart';
import '../services/storage_service.dart';
import '../ui/ludo/ludo_view.dart';
import '../ui/snakes/online_snakes_view.dart';
import 'friends_screen.dart';
import 'invite_watcher.dart';
import '../ui/theme.dart';

/// Builds the client a connect or invite handoff uses. Production leaves
/// [OnlineLobbyScreen.clientBuilder] null and this default is a real socket;
/// tests inject a fake-channel factory so an auto-join never dials out.
typedef OnlineClientBuilder = OnlineClient Function({
  required String serverUrl,
  required String seatId,
  required String name,
  required String gameType,
  required int capacity,
});

OnlineClient _defaultClient({
  required String serverUrl,
  required String seatId,
  required String name,
  required String gameType,
  required int capacity,
}) => OnlineClient(
  serverUrl,
  seatId: seatId,
  name: name,
  gameType: gameType,
  capacity: capacity,
);

/// Online lobby: connect to an authoritative Ludo server, create or join a
/// room, and jump into the game once the host starts it.
///
/// The server owns the rules and the dice; this screen only renders what the
/// server reports (`OnlineClient`) and forwards the player's intents.
class OnlineLobbyScreen extends StatefulWidget {
  const OnlineLobbyScreen({super.key, this.startup, this.clientBuilder});

  /// Optional entry handoff from the friends feature or a `/join/<code>`
  /// URL: the inviter walks in with a live [OnlineStartup.adoptedClient]
  /// (their room already exists, the invite carries its code), the invitee
  /// walks in with a [OnlineStartup.joinCode] and auto-joins. Null stays the
  /// plain connect form.
  final OnlineStartup? startup;

  /// Test seam for the client the lobby dials, so a widget test can join
  /// with a fake channel instead of a real server. Null in production.
  final OnlineClientBuilder? clientBuilder;

  /// The server the online screens target by default. Precedence:
  /// 1. `--dart-define=GAME_SERVER_URL=wss://host/ws` (build-time override,
  ///    for split client/server deployments)
  /// 2. same-origin on web — `wss://<page host[:port]>/ws` on https (single
  ///    service deploys like the Render blueprint) or the dev server on
  ///    :8080 over plain http
  /// 3. `ws://localhost:8080/ws` for desktop/mobile dev runs
  static String defaultServerUrl() {
    const configured = String.fromEnvironment('GAME_SERVER_URL');
    if (configured.isNotEmpty) return configured;
    if (kIsWeb && Uri.base.host.isNotEmpty) {
      return sameOriginServerUrl(Uri.base);
    }
    return 'ws://localhost:8080/ws';
  }

  /// Same-origin server URL for a web page URI. Uses the page's authority
  /// (host plus any explicit port) so a nonstandard HTTPS port — e.g. a
  /// load balancer on :8443 — reaches the server; the leaderboard derives
  /// its HTTP origin from the same URL and stays correct too. Plain http
  /// is the local dev case: the page comes from the Flutter dev server,
  /// the game server from :8080.
  ///
  /// A packaged add-on page is NOT same-origin with anything playable.
  /// `chrome-extension://<id>/index.html` has a non-empty host (the id), so
  /// a naive "reuse the page's host" check builds `ws://<extension-id>:8080/ws`
  /// — a URL that can never dial, and the packaged builds failed exactly
  /// that way while the Netlify build (which bakes the URL in via
  /// dart-define) worked. Every non-http(s) scheme therefore gets the hosted
  /// game server: a page served over an add-on scheme has no origin to be
  /// same-as, so there is nothing else it could mean.
  static String sameOriginServerUrl(Uri page) {
    switch (page.scheme) {
      case 'https':
        return 'wss://${page.authority}/ws';
      case 'http':
        return 'ws://${page.host}:8080/ws';
      default:
        return hostedServerUrl;
    }
  }

  /// The hosted game server that unpacked and web builds both play against.
  /// Deliberately a constant rather than a define-only setting: a packaged
  /// build is built once and installed everywhere, so it cannot depend on a
  /// per-deployment dart-define. `GAME_SERVER_URL` still wins where set.
  static const hostedServerUrl = 'wss://ludo-1zpb.onrender.com/ws';

  @override
  State<OnlineLobbyScreen> createState() => _OnlineLobbyScreenState();
}

/// Startstate the friends feature hands the lobby: either a client that
/// already opened a room (the inviter, whose invite referenced that
/// room's code) or a room code to join (the invitee).
class OnlineStartup {
  const OnlineStartup({this.joinCode, this.adoptedClient, this.watch = false});

  /// The invitee path: join this room the moment identity is restored.
  final String? joinCode;

  /// The inviter path: this client is already connected (or connecting)
  /// to a room; the lobby adopts it instead of showing the connect form.
  final OnlineClient? adoptedClient;

  /// The `/join/<code>?watch=1` path: open the room as a spectator rather
  /// than taking a seat.
  final bool watch;
}

class _OnlineLobbyScreenState extends State<OnlineLobbyScreen> {
  // The server target is a build-time fact (dart-define, same-origin, or
  // the dev default) — an edit box for it invited players to point the
  // app at a foreign relay (playtest: "server url ... should be internal
  // only"). `defaultServerUrl()` answers everywhere a client is built.
  final _nameCtrl = TextEditingController();
  final _codeCtrl = TextEditingController();

  OnlineClient? _client;
  bool _spectate = false; // "Watch" instead of "Join" in the connect form

  /// The room code that arrived with an invite, held while a first-time
  /// player chooses a display name. The code stays in the room-code field
  /// too, so the ordinary Join path works if they dismiss the invite card.
  String? _inviteCode;

  /// A first-time invitee has no saved name yet: show the invite card and
  /// wait for a name instead of joining anonymously under the generated
  /// default. A player with a saved name skips straight into the room.
  bool _inviteNeedsName = false;

  /// Pending friend requests, polled so the app bar's friends doorway can
  /// wear a badge while the table sits waiting. One client per screen;
  /// the poll is cadence, the badge repainted only when the count moves.
  FriendClient? _friendClient;

  /// The latest friends-tray snapshot from the lobby's 8s poll — the same
  /// read that drives the badge also decides what each seat row offers
  /// (add / sent / friends / accept).
  FriendState? _friendState;

  /// The seat id a friend action is in flight for, so one slow link
  /// cannot fire a request twice.
  String? _workingSeat;

  /// The last rendered relationship picture — polled state only re-renders
  /// the seats when it changes.
  Set<String>? _stateSignature;

  /// The server URL [_friendClient] was built for — the lobby can move
  /// (a custom server typed in, a route-carried deep link), and a tray
  /// polled on the wrong origin would badge requests that live elsewhere.
  String _friendUrl = '';
  Timer? _friendsPoll;
  int _incomingRequests = 0;

  /// Game the host picks when creating a room; joiners inherit the room's.
  String _gameType = 'ludo';

  /// Table size the host asks a created room to close at. Join-with-code
  /// ignores it — joiners inherit the room's size — and the default keeps
  /// today's open four-seat table.
  int _players = 4;

  /// Seat ids on the previous roster. The first roster primes the set — the
  /// people already in the room must not chime on arrival — and every id that
  /// appears afterwards is a player taking a seat.
  Set<String> _knownSeatIds = {};
  bool _seatsPrimed = false;

  /// The persisted online identity: a stable player id plus a display name.
  ///
  /// Both used to be asked for, or invented, every time. The id in particular
  /// was generated per session, and the server keys recorded results by it, so
  /// every session was a different player with no memory of the last one —
  /// which is why the online career never accumulated. Created on first use,
  /// reused afterwards, and editable from the connect form.
  String _seatId = '';
  String _name = '';

  @override
  void initState() {
    super.initState();
    // The app-level watcher is the fastest reader of the friends state;
    // its shared count paints this badge immediately instead of waiting
    // for this screen's slower tray poll.
    friendSignals.incomingRequests.addListener(_onFriendSignals);
    _incomingRequests = friendSignals.incomingRequests.value;
    // The inviter's handoff: an already-live client is adopted before
    // the first build, so the lobby panel draws with it from frame one.
    final adopted = widget.startup?.adoptedClient;
    if (adopted != null) {
      adopted.addListener(() => setState(() {}));
      // A server push is the real-time half of the friends lifecycle: the
      // watcher still owns the poll, this just tells it there is something
      // to read now instead of on the next five-second beat.
      adopted.onFriendsPulse = inviteWatcher.poke;
      _client = adopted;
      _watchSeats(adopted);
    }
    _restoreIdentity();
    // The friends badge lives as long as the lobby does: 8s polls from
    // the moment a client exists, immediate on return from Friends.
    _friendsPoll = Timer.periodic(
      const Duration(seconds: 8),
      (_) => _pollTrays(),
    );
  }

  Future<void> _pollTrays() async {
    final client = _client;
    if (client == null) return;
    // Follow the room's own origin: the friend trays live on the same
    // server the WS connects to, whatever the connect form holds now.
    if (_friendClient == null || _friendUrl != client.serverUrl) {
      _friendClient?.close();
      _friendClient = FriendClient(serverUrl: client.serverUrl);
      _friendUrl = client.serverUrl;
    }
    try {
      final state = await _friendClient!.state(
        seatId: client.seatId,
        name: client.name,
      );
      if (!mounted) return;
      friendSignals.update(
        requests: state.incoming.length,
        invites: state.invites.where((i) => i.pending).length,
      );
      if (state.incoming.length != _incomingRequests) {
        setState(() => _incomingRequests = state.incoming.length);
      }
      // Rows re-render only when the relationship picture actually moved:
      // friend ids, pending requests both ways — the badge count is a part
      // of that but not the whole of it.
      final signature = {
        for (final f in state.friends) f.profile.seatId,
        for (final r in state.incoming) '${r.id}:${r.seatId}',
        for (final r in state.outgoing) '${r.id}:${r.seatId}',
      };
      if (_stateSignature == null || !setEquals(_stateSignature, signature)) {
        setState(() {
          _stateSignature = signature;
          _friendState = state;
        });
      }
    } on FriendException {
      // A silent badge is a smaller failure than a lobby that nags; the
      // friends screen reports its own errors once opened.
    }
  }

  Future<void> _restoreIdentity() async {
    final storage = StorageService();
    final id = await storage.loadOnlinePlayerId();
    final name = await storage.loadOnlineName();
    if (!mounted) return;
    final hadStoredName = name.isNotEmpty;
    // A first-time player is given a name rather than an empty field, and it
    // is derived from their id so it is stable: the same player is always the
    // same "Swift Otter", rather than a new name each visit filling the
    // leaderboard with rows of the same person.
    final resolved = hadStoredName ? name : _defaultNameFor(id);
    setState(() {
      _seatId = id;
      _nameCtrl.text = resolved;
      _name = resolved;
    });

    final joinCode = widget.startup?.joinCode;
    final watch = widget.startup?.watch ?? false;
    if (joinCode == null) {
      if (!hadStoredName) {
        // Plain first visit: persist the generated name now, so it is the
        // same name next time even before they play.
        await StorageService().saveOnlineName(resolved);
      }
      return;
    }

    final code = normalizeJoinCode(joinCode);
    _codeCtrl.text = code;
    if (!hadStoredName) {
      // A first-time invitee picks their own name: keep the code prefilled
      // and show the invite card instead of joining under a name they never
      // chose. The dedicated button on the card joins once they are ready.
      setState(() {
        _inviteCode = code;
        _inviteNeedsName = true;
        _spectate = watch;
      });
      return;
    }
    // A returning player stands on their saved identity, so the invite
    // needs no tap: join the room the link named.
    setState(() => _spectate = watch);
    _connect(createRoom: false, codeOverride: code);
  }

  /// A stable default name for [id], mixed from the id itself so it is
  /// reproducible rather than a fresh draw on every visit.
  String _defaultNameFor(String id) {
    // Base-36 digits of the id give a seed that is unique per player.
    var salt = 0;
    for (final unit in id.codeUnits) {
      salt = (salt * 31 + unit) & 0x7fffffff;
    }
    return DefaultNames.unique(playerId: id);
  }

  /// The player menu off a roster row: the sheet everything about that
  /// seatmate routes through, addressed by seat id (names collide).
  /// The one-tap room add. Direct request, outcome named in the snack:
  /// when the reverse request is already pending the server accepts on
  /// the spot and the row flips to Friends on the refresh that follows.
  Future<void> _addFriend(LobbySeat seat) async {
    final client = _client;
    final friendClient = _friendClient;
    if (client == null || friendClient == null || _workingSeat != null) {
      return;
    }
    setState(() => _workingSeat = seat.seatId);
    try {
      final status = await friendClient.request(
        seatId: client.seatId,
        name: client.name,
        target: seat.seatId,
        targetName: seat.name,
      );
      _showSnack(
        status == 'accepted'
            ? 'You and ${seat.name} are now friends'
            : 'Friend request sent to ${seat.name}',
      );
    } on FriendException catch (e) {
      _showSnack(e.text);
    } finally {
      if (mounted) setState(() => _workingSeat = null);
    }
    // The row's chip follows the server, not a guess: one immediate poll
    // repaints Sent/Friends without waiting for the 8s beat.
    await _pollTrays();
  }

  /// Accepting a friend request straight from the row: the request id
  /// rides the polled tray state the row was rendered from.
  Future<void> _acceptFriendFromRow(LobbySeat seat) async {
    final client = _client;
    final friendClient = _friendClient;
    final pending = [
      for (final r in _friendState?.incoming ?? const <FriendRequestView>[])
        if (r.seatId == seat.seatId) r,
    ];
    if (client == null ||
        friendClient == null ||
        pending.isEmpty ||
        _workingSeat != null) {
      return;
    }
    setState(() => _workingSeat = seat.seatId);
    try {
      final ok = await friendClient.respond(
        seatId: client.seatId,
        id: pending.first.id,
        accept: true,
      );
      _showSnack(
        ok
            ? 'You and ${seat.name} are now friends'
            : 'Could not accept — try again',
      );
    } on FriendException catch (e) {
      _showSnack(e.text);
    } finally {
      if (mounted) setState(() => _workingSeat = null);
    }
    await _pollTrays();
  }

  void _playerMenu(LobbySeat seat) {
    final client = _client;
    if (client == null || seat.seatId == client.seatId) return;
    unawaited(
      PlayerActionsSheet.show(
        context,
        serverUrl: client.serverUrl,
        mySeatId: client.seatId,
        myName: client.name,
        peerSeatId: seat.seatId,
        peerName: seat.name,
      ),
    );
  }

  /// Remembers the name so it is offered next time. The id is never changed
  /// here: changing it would orphan the career already recorded under it.
  Future<void> _rememberName(String name) async {
    _name = name;
    await StorageService().saveOnlineName(name);
  }

  void _onFriendSignals() {
    if (!mounted) return;
    final pending = friendSignals.incomingRequests.value;
    if (pending != _incomingRequests) {
      setState(() => _incomingRequests = pending);
    }
  }

  /// Announces a player taking a seat with the join chime.
  ///
  /// The roster repeats on every change and after a reconnect, so the new-id
  /// set difference is the join event. The first roster only primes the set
  /// (walking into a room must not chime at the people already there), our
  /// own seat never chimes, and a reconnecting seat keeps its id so it stays
  /// silent — the sound means "someone new sat down", not "the roster moved".
  void _watchSeats(OnlineClient client) {
    client.onSeats = () {
      if (!mounted || !identical(client, _client)) return;
      final ids = {
        for (final s in client.lobbySeats)
          if (s.seatId.isNotEmpty) s.seatId,
      };
      if (!_seatsPrimed) {
        _seatsPrimed = true;
        _knownSeatIds = ids;
        return;
      }
      final joined = ids
          .difference(_knownSeatIds)
          .where((id) => id != client.seatId);
      _knownSeatIds = ids;
      if (joined.isEmpty) return;
      ProviderScope.containerOf(
        context,
        listen: false,
      ).read(soundServiceProvider).join();
      Haptics.light();
    };
  }

  @override
  void dispose() {
    friendSignals.incomingRequests.removeListener(_onFriendSignals);
    _friendsPoll?.cancel();
    _friendClient?.close();
    _client?.dispose();
    _nameCtrl.dispose();
    _codeCtrl.dispose();
    super.dispose();
  }

  void _connect({bool createRoom = true, String? codeOverride}) {
    final name = _nameCtrl.text.trim();
    if (name.isEmpty) {
      _showSnack('Pick a display name first');
      return;
    }
    final code = normalizeJoinCode(codeOverride ?? _codeCtrl.text);
    if (!createRoom && !RegExp(r'^[A-Za-z0-9]{4}$').hasMatch(code)) {
      _showSnack(
        _spectate
            ? 'Enter a 4-character room code to watch'
            : 'Room codes are 4 letters or digits',
      );
      return;
    }
    // Remembered on connect, so the next visit offers the same name instead of
    // asking for it again.
    _rememberName(name);
    final build = widget.clientBuilder ?? _defaultClient;
    final client = build(
      serverUrl: OnlineLobbyScreen.defaultServerUrl(),
      seatId: _seatId,
      name: name,
      gameType: _gameType,
      // The table size rides only when this hello creates (or matches
      // into) a room; a join submits a code and inherits the room's size
      // on the first lobby feed.
      capacity: createRoom ? _players : 4,
    )..addListener(() => setState(() {}));
    client.onFriendsPulse = inviteWatcher.poke;
    _seatsPrimed = false;
    _knownSeatIds = {};
    _watchSeats(client);
    setState(() {
      _inviteNeedsName = false;
      _client = client;
    });
    client.connect(
      code: createRoom ? null : code,
      spectate: !createRoom && _spectate,
    );
  }

  void _showSnack(String text, {IconData icon = Icons.info_outline}) {
    // One spoken surface for the whole app: the gold card in the top-right
    // corner, never a white bar across the bottom edge.
    showSnackInColumn(context, text, icon: icon);
  }

  /// Copies the identity under the name field so it can be sent to a friend
  /// (the friends screen discovers players by code, but the id is the thing
  /// the leaderboard and the server keep — the playtest asked to share it).
  Future<void> _copyPlayerId() async {
    if (_seatId.isEmpty) return;
    try {
      await Clipboard.setData(ClipboardData(text: _seatId));
    } catch (_) {
      if (!mounted) return;
      _showSnack(
        'Could not copy — the ID is still shown above',
        icon: Icons.error_outline,
      );
      return;
    }
    if (!mounted) return;
    _showSnack(
      'Player ID $_seatId copied — share it with friends',
      icon: Icons.check_circle_outline,
    );
  }

  Future<void> _disconnect() async {
    await _client?.disconnect();
    _seatsPrimed = false;
    _knownSeatIds = {};
    if (mounted) setState(() => _client = null);
  }

  /// The walk-out path from inside either game view: the intent has already
  /// gone to the server by now, so this only drops the socket and returns to
  /// the connect/lobby form.
  void _disconnectAndClose() {
    _disconnect();
  }

  @override
  Widget build(BuildContext context) {
    final client = _client;
    // Once a room is live the board draws its own Scaffold and app bar. The
    // lobby's bar used to stay wrapped around it, so online play showed two
    // stacked title bars — "Play Online" above the game's own — where local
    // play shows one. The bar belongs to the lobby; the board brings its own.
    final inGame =
        client != null && (client.state != null || client.snakesState != null);
    return Scaffold(
      appBar: inGame
          ? null
          : PageAppBar(
              title: 'Play Online',
              actions: [
                // The friends doorway: a badge when a friend request is
                // waiting answers "did anyone want to be my friend?"
                // without leaving the table, and the friends screen it
                // opens owns the full accept/decline tray.
                if (client != null)
                  IconButton(
                    icon: Badge(
                      key: const ValueKey('lobby-friends-badge'),
                      isLabelVisible: _incomingRequests > 0,
                      backgroundColor: AppColors.danger,
                      textColor: Colors.white,
                      label: Text(
                        '$_incomingRequests',
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 9,
                          fontWeight: FontWeight.w900,
                        ),
                      ),
                      child: const Icon(Icons.group_outlined),
                    ),
                    tooltip: _incomingRequests > 0
                        ? 'Friends ($_incomingRequests request${_incomingRequests == 1 ? '' : 's'} waiting)'
                        : 'Friends',
                    onPressed: () async {
                      await pushAppScreen<void>(
                        context,
                        name: AppRoutes.friends,
                        builder: (_) => const FriendsScreen(),
                      ).popped;
                      // The tray may have changed inside; refresh now
                      // rather than waiting out the next tick.
                      if (mounted) await _pollTrays();
                    },
                  ),
                // No message icon here. Table chat belongs to the
                // screen-level dock below (docked beside the table on a wide
                // window, an overlay on a phone), so a second icon here would
                // give the same chat two entry points.
                if (client != null)
                  IconButton(
                    icon: const Icon(Icons.close),
                    tooltip: 'Leave and disconnect',
                    onPressed: () async {
                      // Say something on the way out rather than just hanging
                      // up: the room hears that the seat is given up, and the
                      // people still in the lobby are told who went instead of
                      // waiting on a chair that nobody is coming back to.
                      await client.sendLeave();
                      if (!context.mounted) return;
                      Navigator.of(context).pop();
                    },
                  ),
              ],
            ),
      body: Container(
        decoration: const BoxDecoration(
          gradient: RadialGradient(
            center: Alignment(0, -0.4),
            radius: 1.4,
            colors: [AppColors.feltLight, AppColors.felt],
          ),
        ),
        child: SafeArea(
          child: switch (client) {
            // Rule 11: the lobby and the join form are reading-width
            // screens — they use the same column the header above does,
            // so on a desktop window the room code card can no longer
            // read wider than anything around it. The board branches
            // stay full-bleed: a game board wants every pixel.
            null => ContentColumn(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: _connectForm(),
              ),
            ),
            OnlineClient c
                when c.gameType == 'snakes' && c.snakesState != null =>
              ResponsiveChatDock(
                client: c,
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: OnlineSnakesView(
                    client: c,
                    onLeave: _disconnectAndClose,
                  ),
                ),
              ),
            OnlineClient c when c.state != null => ResponsiveChatDock(
              client: c,
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: LudoGameView(
                  onlineClient: c,
                  onlineSeatId: c.seatId,
                  onOnlineLeave: _disconnectAndClose,
                ),
              ),
            ),
            OnlineClient c => ResponsiveChatDock(
              client: c,
              child: ContentColumn(
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: _lobby(c),
                ),
              ),
            ),
          },
        ),
      ),
    );
  }

  // ------------------------------------------------------------ connect form

  Widget _connectForm() {
    return ListView(
      shrinkWrap: true,
      children: [
        const Icon(Icons.wifi, size: 48, color: AppColors.gold),
        const SizedBox(height: 8),
        Center(
          child: Text(
            // Names the game the Ludo/Snakes toggle below has selected, so the
            // pitch matches what this room will actually be. It used to say
            // "Ludo" unconditionally, which made the whole screen read as
            // Ludo-only to anyone looking for online Snakes.
            'Play ${_gameType == 'snakes' ? 'Snakes & Ladders' : 'Ludo'} '
            'online against friends',
            style: const TextStyle(color: AppColors.ivory, fontSize: 16),
          ),
        ),
        const SizedBox(height: 24),
        if (_inviteNeedsName && _inviteCode != null) ...[
          _inviteCard(_inviteCode!),
          const SizedBox(height: 16),
        ],
        _field(
          _nameCtrl,
          'Your name',
          _name.isEmpty ? 'e.g. Asha' : 'saved \u2014 tap to change',
          fieldKey: const Key('online-name-field'),
        ),
        // The id is shown rather than hidden: it is what the leaderboard
        // records, so a player can see which identity their wins belong to.
        // Tapping copies it — the playtest wanted to hand it to a friend
        // without selecting a 14-character string on a phone.
        if (_seatId.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 8, left: 4, right: 4),
            child: Align(
              alignment: Alignment.centerLeft,
              child: Tooltip(
                message: 'Copy your player ID',
                child: InkWell(
                  key: const Key('copy-player-id'),
                  onTap: _copyPlayerId,
                  borderRadius: BorderRadius.circular(10),
                  child: Container(
                    constraints: const BoxConstraints(minHeight: 44),
                    padding: const EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 8,
                    ),
                    decoration: BoxDecoration(
                      color: Colors.black.withValues(alpha: 0.22),
                      borderRadius: BorderRadius.circular(10),
                      border: Border.all(color: AppColors.gold.withAlpha(90)),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const Icon(
                          Icons.badge_outlined,
                          size: 16,
                          color: AppColors.gold,
                        ),
                        const SizedBox(width: 8),
                        Text(
                          'Player ID $_seatId \u00b7 tap to copy',
                          style: const TextStyle(
                            fontSize: 11.5,
                            color: AppColors.ivoryDark,
                          ),
                        ),
                        const SizedBox(width: 8),
                        const Icon(Icons.copy, size: 15, color: AppColors.gold),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
        const SizedBox(height: 24),
        SegmentedButton<String>(
          segments: const [
            ButtonSegment(
              value: 'ludo',
              label: Text('Ludo'),
              icon: Icon(Icons.casino_outlined),
            ),
            ButtonSegment(
              value: 'snakes',
              label: Text('Snakes'),
              icon: Icon(Icons.grid_on_outlined),
            ),
          ],
          selected: {_gameType},
          onSelectionChanged: (sel) => setState(() => _gameType = sel.first),
        ),
        const SizedBox(height: 16),
        // The table size the room closes at — the same "chip row" the
        // offline setup screen uses, for one shared visual language. It
        // applies to the Create path: a join submits a code and inherits
        // the room's size, so a two-seat room stays a two-seat room no
        // matter who fills the second chair.
        const Text(
          'Players at the table',
          style: TextStyle(color: AppColors.ivory, fontWeight: FontWeight.w700),
        ),
        const SizedBox(height: 6),
        Wrap(
          spacing: 8,
          children: [
            for (var n = 2; n <= 4; n++)
              ChoiceChip(
                label: Text('$n'),
                selected: _players == n,
                onSelected: (_) => setState(() => _players = n),
              ),
          ],
        ),
        const SizedBox(height: 12),
        FilledButton.icon(
          icon: const Icon(Icons.add_circle_outline),
          label: const Text('Create a room'),
          onPressed: () => _connect(createRoom: true),
        ),
        const SizedBox(height: 12),
        Row(
          children: [
            Expanded(
              child: TextField(
                key: const Key('room-code-field'),
                controller: _codeCtrl,
                textCapitalization: TextCapitalization.characters,
                maxLength: 4,
                style: const TextStyle(color: AppColors.ivory),
                decoration: InputDecoration(
                  counterText: '',
                  labelText: 'Room code',
                  hintText: 'A2B3',
                  labelStyle: const TextStyle(color: AppColors.ivory),
                  hintStyle: TextStyle(color: AppColors.ivory.withAlpha(90)),
                  enabledBorder: _border(AppColors.ivory.withAlpha(90)),
                  focusedBorder: _border(AppColors.gold),
                ),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: FilledButton.tonalIcon(
                icon: const Icon(Icons.login),
                label: const Text('Join'),
                onPressed: () {
                  setState(() => _spectate = false);
                  _connect(createRoom: false);
                },
              ),
            ),
          ],
        ),
        const SizedBox(height: 8),
        Center(
          child: TextButton.icon(
            icon: Icon(
              _spectate ? Icons.visibility : Icons.visibility_outlined,
              size: 18,
            ),
            label: Text(
              _spectate
                  ? 'Spectating — tap again to cancel'
                  : 'Just want to watch? Spectate a room',
            ),
            style: TextButton.styleFrom(
              foregroundColor: _spectate
                  ? AppColors.gold
                  : AppColors.ivory.withAlpha(150),
            ),
            onPressed: () {
              setState(() => _spectate = !_spectate);
              if (!_spectate) return;
              final code = _codeCtrl.text.trim();
              final name = _nameCtrl.text.trim();
              if (name.isEmpty) {
                _showSnack('Pick a display name first');
              } else if (code.length == 4) {
                _connect(createRoom: false);
              }
            },
          ),
        ),
      ],
    );
  }

  OutlineInputBorder _border(Color c) => OutlineInputBorder(
    borderSide: BorderSide(color: c),
    borderRadius: BorderRadius.circular(10),
  );

  /// The first-time invitee's landing: the room code is already in the
  /// field below, and this card names whose table it is and gives the one
  /// tap that joins. The name field below it is prefilled with the stable
  /// default name; the card waits so a player can choose their own first
  /// (and so the `Join` button next to the code still works on its own).
  Widget _inviteCard(String code) {
    return Card(
      key: const Key('invite-card'),
      color: AppColors.feltLight,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              _spectate
                  ? "You're invited to watch room $code"
                  : "You're invited to room $code",
              textAlign: TextAlign.center,
              style: const TextStyle(
                color: AppColors.gold,
                fontSize: 16,
                fontWeight: FontWeight.w800,
              ),
            ),
            const SizedBox(height: 6),
            Text(
              _spectate
                  ? 'Choose a name, then watch the table.'
                  : 'Choose a name, then join your friend at the table.',
              textAlign: TextAlign.center,
              style: TextStyle(
                color: AppColors.ivory.withAlpha(170),
                fontSize: 12.5,
              ),
            ),
            const SizedBox(height: 12),
            FilledButton.icon(
              key: const Key('join-invited-room'),
              icon: const Icon(Icons.login),
              label: Text('Join room $code'),
              onPressed: () => _connect(createRoom: false, codeOverride: code),
            ),
          ],
        ),
      ),
    );
  }

  Widget _field(
    TextEditingController ctrl,
    String label,
    String hint, {
    Key? fieldKey,
  }) {
    return TextField(
      key: fieldKey,
      controller: ctrl,
      style: const TextStyle(color: AppColors.ivory),
      decoration: InputDecoration(
        labelText: label,
        hintText: hint,
        labelStyle: const TextStyle(color: AppColors.ivory),
        hintStyle: TextStyle(color: AppColors.ivory.withAlpha(90)),
        enabledBorder: _border(AppColors.ivory.withAlpha(90)),
        focusedBorder: _border(AppColors.gold),
      ),
    );
  }

  // ------------------------------------------------------------------ lobby

  Widget _lobby(OnlineClient client) {
    if (client.status == OnlineStatus.connecting ||
        client.status == OnlineStatus.reconnecting) {
      // A sleeping free-tier host refuses the first few sockets while the
      // platform wakes it. That is a wait, not a failure, so it is named as
      // one — otherwise the first Play press after an idle spell looks broken.
      final waking = client.waitingForColdStart;
      final back = client.status == OnlineStatus.reconnecting;
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const CircularProgressIndicator(),
            const SizedBox(height: 14),
            Text(
              waking
                  ? 'Starting the game server…'
                  : back
                  ? 'Connection lost — reconnecting…'
                  : 'Connecting…',
              style: const TextStyle(color: AppColors.ivory, fontSize: 14),
            ),
            if (waking) ...[
              const SizedBox(height: 8),
              const Padding(
                padding: EdgeInsets.symmetric(horizontal: 32),
                child: Text(
                  'Free hosting sleeps when idle, so the first game of a '
                  'session can take up to a minute to wake up.',
                  textAlign: TextAlign.center,
                  style: TextStyle(color: AppColors.ivoryDark, fontSize: 12),
                ),
              ),
            ],
          ],
        ),
      );
    }
    if (client.status == OnlineStatus.error) {
      return ListView(
        shrinkWrap: true,
        children: [
          const Icon(Icons.cloud_off, size: 44, color: AppColors.danger),
          const SizedBox(height: 8),
          Center(
            child: Text(
              client.errorText ?? 'Something went wrong',
              style: const TextStyle(color: AppColors.ivory),
            ),
          ),
          const SizedBox(height: 16),
          FilledButton.icon(
            icon: const Icon(Icons.refresh),
            label: const Text('Try again'),
            onPressed: _disconnect,
          ),
        ],
      );
    }
    final roster = client.lobbySeats;
    // The seats still in the room, and the ones someone vacated by walking
    // out. Kept apart on purpose: a name nobody is waiting for any more must
    // not hold up the host's Start button or pad the "waiting for players"
    // count, but it still explains why the room suddenly has an empty chair.
    final seats = [
      for (final s in roster)
        if (s.inGame) s,
    ];
    final gone = [
      for (final s in roster)
        if (!s.inGame) s,
    ];
    final iAmHost = seats.isNotEmpty && client.myColor == seats.first.color;
    final spectating = client.isSpectator;
    final muted = TextStyle(
      color: AppColors.ivory.withAlpha(150),
      fontSize: 12,
    );
    return ListView(
      shrinkWrap: true,
      children: [
        if (spectating)
          const Padding(
            padding: EdgeInsets.only(bottom: 8),
            child: Center(
              child: Chip(
                avatar: Icon(Icons.visibility, size: 16),
                label: Text('Spectating'),
                visualDensity: VisualDensity.compact,
              ),
            ),
          ),
        RoomCodeCard(code: client.roomCode),
        const SizedBox(height: 12),
        if (client.errorText != null)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Text(
              client.errorText!,
              style: const TextStyle(color: AppColors.danger),
            ),
          ),
        for (final seat in seats)
          ListTile(
            leading: CircleAvatar(
              backgroundColor: _colorOf(seat.color),
              child: Text(
                seat.name.isNotEmpty ? seat.name[0].toUpperCase() : '?',
                style: const TextStyle(color: Colors.white),
              ),
            ),
            title: Text(
              seat.name,
              style: const TextStyle(color: AppColors.ivory),
            ),
            subtitle: switch ((seat.status, seat.live)) {
              (SeatStatus.auto, _) => Text(
                seat.color == client.myColor
                    ? 'Autoplay — the table will play your turns'
                    : 'Autoplay — the table will play for them',
                style: muted,
              ),
              (_, false) => Text(
                seat.color == client.myColor
                    ? 'Your connection to this room has dropped'
                    : 'Connection lost — waiting for them',
                style: muted,
              ),
              _ => null,
            },
            trailing: seat.seatId == client.seatId
                ? const Chip(
                    label: Text('You'),
                    visualDensity: VisualDensity.compact,
                  )
                : seat.seatId.isEmpty
                // A bare name-and-color row (the light lobby feed) cannot
                // be addressed by id — no menu rather than a menu that
                // fails at tap time.
                ? null
                : Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      SeatFriendControl(
                        state: _friendState,
                        peerSeatId: seat.seatId,
                        peerName: seat.name,
                        busy: _workingSeat == seat.seatId,
                        onAdd: () => _addFriend(seat),
                        onAccept: () => _acceptFriendFromRow(seat),
                      ),
                      IconButton(
                        icon: const Icon(Icons.more_vert),
                        tooltip: 'Friend, block or report',
                        onPressed: () => _playerMenu(seat),
                      ),
                    ],
                  ),
          ),
        for (final seat in gone)
          ListTile(
            dense: true,
            leading: CircleAvatar(
              backgroundColor: _colorOf(seat.color).withAlpha(80),
              child: const Icon(Icons.person_off, size: 18),
            ),
            title: Text('${seat.name} left the room', style: muted),
            trailing: seat.seatId != client.seatId
                ? IconButton(
                    icon: const Icon(Icons.more_vert, size: 20),
                    tooltip: 'Friend, block or report',
                    onPressed: () => _playerMenu(seat),
                  )
                : null,
          ),
        // Seating stops at the room's table size, so the wait line tracks
        // the host's chosen size — (1/3) for a three-seat room, and gone
        // entirely once the room is full.
        if (seats.length < client.capacity && !spectating)
          ListTile(
            leading: const CircleAvatar(
              child: Icon(Icons.person_add_alt, size: 18),
            ),
            title: Text(
              'Waiting for players… (${seats.length}/${client.capacity})',
              style: TextStyle(color: AppColors.ivory.withAlpha(150)),
            ),
          ),
        if (client.spectatorNames.isNotEmpty)
          ListTile(
            leading: const CircleAvatar(
              child: Icon(Icons.visibility, size: 18),
            ),
            title: Text(
              'Watching: ${client.spectatorNames.join(', ')}',
              style: TextStyle(color: AppColors.ivory.withAlpha(150)),
            ),
          ),
        const SizedBox(height: 12),
        if (!spectating)
          FilledButton.icon(
            icon: const Icon(Icons.play_arrow),
            label: Text(
              client.started
                  ? 'Game starting…'
                  : iAmHost
                  ? 'Start game'
                  : 'Waiting for the host to start',
            ),
            onPressed: client.started || !iAmHost || seats.length < 2
                ? null
                : client.sendStart,
          ),
        const SizedBox(height: 16),
        // Table voice: peer-to-peer audio through the room's WebSocket
        // signalling. Spectators have no seat, so no mic.
        if (!spectating)
          Row(
            children: [
              // The label leads: the row reads "Voice" before anything,
              // instead of making the player decode two mic-adjacent
              // icons first, and it carries the live state once joined
              // ("Table voice on" / "— muted"). The mute mic appears
              // only after joining ([MicButton] hides itself till then),
              // so the room screen shows a single voice affordance.
              Text(
                client.voiceJoined
                    ? (client.voiceMuted ? 'Voice — muted' : 'Table voice on')
                    : 'Voice',
                style: TextStyle(
                  color: AppColors.ivory.withAlpha(150),
                  fontSize: 12,
                ),
              ),
              const SizedBox(width: 4),
              VoiceButton(client: client),
              MicButton(client: client),
            ],
          ),
        // Talk state plays on the mic button (the gold beam), exactly like
        // on the game views: a second indicator here — a chip row that grew
        // whenever anyone spoke — kept shoving the controls around while
        // callers talked, which read like the screen was breaking.
      ],
    );
  }

  Color _colorOf(LudoColor c) => switch (c) {
    LudoColor.red => AppColors.ludoRed,
    LudoColor.blue => AppColors.ludoBlue,
    LudoColor.yellow => AppColors.ludoYellow,
    LudoColor.green => AppColors.ludoGreen,
  };
}

/// One friend action per seated row, reflection included.
///
/// The playtest asked for the players **in the current room** — username
/// and a button to send a friend request directly — because stepping
/// through a menu, or hunting down an id nobody prints, is how adding a
/// friend became work. The lobby already polls the friends tray every few
/// seconds, so the same state that lights the badge also decides what the
/// row shows: friends read as a chip, own pending requests as "Sent", an
/// incoming request turns into an Accept, and anyone else gets the
/// one-tap add. Rows without a server-wide view of themselves (the state
/// has not arrived yet) still show the add — the endpoint is idempotent
/// and the tap reports its own outcome.
class SeatFriendControl extends StatelessWidget {
  const SeatFriendControl({
    required this.state,
    required this.peerSeatId,
    required this.peerName,
    required this.busy,
    required this.onAdd,
    required this.onAccept,
    super.key,
  });

  /// The lobby's latest friends-tray state, or null before the first poll.
  final FriendState? state;

  /// The row's profile id and display name.
  final String peerSeatId;
  final String peerName;

  /// While a request for this row is in flight the buttons sleep — a slow
  /// link must not double-fire a friend request.
  final bool busy;
  final VoidCallback onAdd;
  final VoidCallback onAccept;

  @override
  Widget build(BuildContext context) {
    final s = state;
    if (s != null) {
      final isFriend = s.friends.any((f) => f.profile.seatId == peerSeatId);
      if (isFriend) {
        return Chip(
          label: const Text('Friends'),
          visualDensity: VisualDensity.compact,
        );
      }
      final mine = s.outgoing.any((r) => r.seatId == peerSeatId);
      if (mine) {
        return Chip(
          label: const Text('Sent'),
          visualDensity: VisualDensity.compact,
        );
      }
      final incoming = [
        for (final r in s.incoming)
          if (r.seatId == peerSeatId) r,
      ];
      if (incoming.isNotEmpty) {
        return FilledButton.tonal(
          onPressed: busy ? null : onAccept,
          style: FilledButton.styleFrom(
            visualDensity: VisualDensity.compact,
            tapTargetSize: MaterialTapTargetSize.shrinkWrap,
          ),
          child: const Text('Accept'),
        );
      }
    }
    return FilledButton.tonal(
      onPressed: busy ? null : onAdd,
      style: FilledButton.styleFrom(
        visualDensity: VisualDensity.compact,
        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
      ),
      child: const Text('+ Add'),
    );
  }
}

/// The lobby's room-code card. Copying is a first-class button, not a hope:
/// the code used to be the only thing in the card, with copying left to the
/// platform's text selection — and a long-press selection on big,
/// letter-spaced text is unreliable on phone browsers, so mobile players
/// could not share the code at all. The button copies through the clipboard
/// channel, which browsers honour for a user tap.
class RoomCodeCard extends StatelessWidget {
  const RoomCodeCard({super.key, required this.code, this.base});

  /// The room's code, or null while the server has not confirmed a room yet.
  final String? code;

  /// The page URI the join link resolves from. Defaults to [Uri.base] (the
  /// running page); tests inject a stable origin.
  final Uri? base;

  /// Canonical uppercase spelling: the server keys rooms by it and the load
  /// balancer hashes it, so a lowercase display must never be copied.
  String? get _value => code == null ? null : normalizeJoinCode(code!);

  String? get _link {
    final value = _value;
    if (value == null) return null;
    // Only a page served over http(s) can service `/join/<code>`: a native
    // build has no origin, and a packaged add-on page lives under an
    // extension scheme where the path means nothing. `base` is the test
    // seam that bypasses the live-page check.
    if (base == null) {
      if (!kIsWeb) return null;
      final scheme = Uri.base.scheme;
      if (scheme != 'http' && scheme != 'https') return null;
    }
    return joinLinkFor(value, base: base);
  }

  Future<void> _copyCode(BuildContext context) async {
    final value = _value;
    if (value == null) return;
    await _copy(
      context,
      value: value,
      done: '$value copied — send it to your friends',
      failed: 'Could not copy — please select the code by hand',
    );
  }

  Future<void> _copyLink(BuildContext context) async {
    final link = _link;
    if (link == null) return;
    await _copy(
      context,
      value: link,
      done: 'Join link copied — send it to your friends',
      failed: 'Could not copy the link — select it and copy by hand',
    );
  }

  /// Opens the operating system's share sheet where the browser has one.
  /// Every other case — no Web Share API, an insecure origin, the player
  /// dismissing the sheet — falls back to the copy path, so the button is
  /// never a dead end.
  Future<void> _share(BuildContext context) async {
    final link = _link;
    if (link == null) return;
    final shared = await shareJoinLink(link);
    if (!context.mounted) return;
    if (shared) {
      showSnackInColumn(context, 'Join link shared', icon: Icons.ios_share);
      return;
    }
    await _copyLink(context);
  }

  Future<void> _copy(
    BuildContext context, {
    required String value,
    required String done,
    required String failed,
  }) async {
    try {
      await Clipboard.setData(ClipboardData(text: value));
    } catch (_) {
      // Clipboard write can be denied (insecure origin, old browser). The
      // value is still selectable by hand — say so instead of failing silent.
      if (context.mounted) {
        showSnackInColumn(context, failed, icon: Icons.error_outline);
      }
      return;
    }
    if (context.mounted) {
      showSnackInColumn(context, done, icon: Icons.check_circle_outline);
    }
  }

  @override
  Widget build(BuildContext context) {
    final value = _value;
    final link = _link;
    return Card(
      color: AppColors.feltLight,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          children: [
            const Text(
              'Room code',
              style: TextStyle(color: AppColors.ivory, fontSize: 13),
            ),
            const SizedBox(height: 4),
            Center(
              child: Wrap(
                alignment: WrapAlignment.center,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  SelectableText(
                    value ?? '····',
                    style: const TextStyle(
                      color: AppColors.gold,
                      fontSize: 34,
                      fontWeight: FontWeight.w800,
                      letterSpacing: 8,
                    ),
                  ),
                  const SizedBox(width: 8),
                  IconButton(
                    icon: const Icon(Icons.copy, color: AppColors.gold),
                    tooltip: 'Copy room code',
                    onPressed: value == null ? null : () => _copyCode(context),
                  ),
                  if (link != null)
                    IconButton(
                      icon: const Icon(Icons.ios_share, color: AppColors.gold),
                      tooltip: 'Share join link',
                      onPressed: () => _share(context),
                    ),
                ],
              ),
            ),
            const SizedBox(height: 4),
            Text(
              'Share it so friends can join',
              style: TextStyle(
                color: AppColors.ivory.withAlpha(150),
                fontSize: 12,
              ),
            ),
            if (link != null) ...[
              const SizedBox(height: 12),
              OutlinedButton.icon(
                key: const Key('copy-join-link'),
                icon: const Icon(Icons.link, size: 18),
                label: const Text('Copy join link'),
                onPressed: () => _copyLink(context),
              ),
              const SizedBox(height: 6),
              SelectableText(
                link,
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: AppColors.ivory.withAlpha(150),
                  fontSize: 11.5,
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
