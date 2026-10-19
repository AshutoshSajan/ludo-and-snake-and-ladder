import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show Clipboard, ClipboardData;

import '../ui/page_app_bar.dart';
import '../ui/shared/chat_line_view.dart';
import '../ui/shared/gif_picker_sheet.dart';
import '../ui/shared/keyboard_content.dart';
import '../ui/shared/note_composer.dart';
import '../ui/shared/player_actions_sheet.dart';
import '../ui/shared/voice_button.dart';

import '../engine/ludo/ludo_models.dart';
import '../services/friend_client.dart';
import '../services/online_client.dart';
import '../services/storage_service.dart';
import '../ui/ludo/ludo_view.dart';
import '../ui/snakes/online_snakes_view.dart';
import 'friends_screen.dart';
import '../ui/theme.dart';

/// Online lobby: connect to an authoritative Ludo server, create or join a
/// room, and jump into the game once the host starts it.
///
/// The server owns the rules and the dice; this screen only renders what the
/// server reports (`OnlineClient`) and forwards the player's intents.
class OnlineLobbyScreen extends StatefulWidget {
  const OnlineLobbyScreen({super.key, this.startup});

  /// Optional entry handoff from the friends feature: the inviter walks
  /// in with a live [OnlineStartup.adoptedClient] (their room already
  /// exists, the invite carries its code), the invitee walks in with a
  /// [OnlineStartup.joinCode] and auto-joins. Null stays the plain
  /// connect form.
  final OnlineStartup? startup;

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
  const OnlineStartup({this.joinCode, this.adoptedClient});

  /// The invitee path: join this room the moment identity is restored.
  final String? joinCode;

  /// The inviter path: this client is already connected (or connecting)
  /// to a room; the lobby adopts it instead of showing the connect form.
  final OnlineClient? adoptedClient;
}

class _OnlineLobbyScreenState extends State<OnlineLobbyScreen> {
  final _serverCtrl = TextEditingController();
  final _nameCtrl = TextEditingController();
  final _codeCtrl = TextEditingController();
  final _chatCtrl = TextEditingController();

  /// Whether the voice-note control currently owns the composer row —
  /// the field, GIF and send step aside while the mic is live.
  bool _chatRecording = false;

  OnlineClient? _client;
  bool _spectate = false; // "Watch" instead of "Join" in the connect form

  /// Pending friend requests, polled so the app bar's friends doorway can
  /// wear a badge while the table sits waiting. One client per screen;
  /// the poll is cadence, the badge repainted only when the count moves.
  FriendClient? _friendClient;

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
    _serverCtrl.text = OnlineLobbyScreen.defaultServerUrl();
    // The inviter's handoff: an already-live client is adopted before
    // the first build, so the lobby panel draws with it from frame one.
    final adopted = widget.startup?.adoptedClient;
    if (adopted != null) {
      adopted.addListener(() => setState(() {}));
      _client = adopted;
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
      if (state.incoming.length != _incomingRequests) {
        setState(() => _incomingRequests = state.incoming.length);
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
    // A first-time player is given a name rather than an empty field, and it
    // is derived from their id so it is stable: the same player is always the
    // same "Swift Otter", rather than a new name each visit filling the
    // leaderboard with rows of the same person.
    final resolved = name.isNotEmpty ? name : _defaultNameFor(id);
    setState(() {
      _seatId = id;
      _nameCtrl.text = resolved;
      _name = resolved;
    });
    if (name.isEmpty) {
      // Persist it now, so it is the same name next time even before they play.
      await StorageService().saveOnlineName(resolved);
    }
    // The invitee's handoff: with identity in hand, join the invited room
    // straight away — the code came from the accepted invite.
    final joinCode = widget.startup?.joinCode;
    if (!mounted || joinCode == null) return;
    _codeCtrl.text = joinCode;
    _connect(createRoom: false, codeOverride: joinCode);
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

  @override
  void dispose() {
    _friendsPoll?.cancel();
    _friendClient?.close();
    _client?.dispose();
    _serverCtrl.dispose();
    _nameCtrl.dispose();
    _codeCtrl.dispose();
    _chatCtrl.dispose();
    super.dispose();
  }

  void _connect({bool createRoom = true, String? codeOverride}) {
    final name = _nameCtrl.text.trim();
    if (name.isEmpty) {
      _showSnack('Pick a display name first');
      return;
    }
    final code = codeOverride ?? _codeCtrl.text.trim();
    if (!createRoom && code.length != 4) {
      _showSnack(
        _spectate ? 'Enter a room code to watch' : 'Room codes are 4 letters',
      );
      return;
    }
    // Remembered on connect, so the next visit offers the same name instead of
    // asking for it again.
    _rememberName(name);
    final client = OnlineClient(
      _serverCtrl.text.trim(),
      seatId: _seatId,
      name: name,
      gameType: _gameType,
      // The table size rides only when this hello creates (or matches
      // into) a room; a join submits a code and inherits the room's size
      // on the first lobby feed.
      capacity: createRoom ? _players : 4,
    )..addListener(() => setState(() {}));
    setState(() => _client = client);
    client.connect(
      code: createRoom ? null : code,
      spectate: !createRoom && _spectate,
    );
  }

  void _showSnack(String text) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(text)));
  }

  Future<void> _disconnect() async {
    await _client?.disconnect();
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
                      isLabelVisible: _incomingRequests > 0,
                      backgroundColor: AppColors.gold,
                      label: Text(
                        '$_incomingRequests',
                        style: const TextStyle(
                          color: AppColors.ink,
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
                      await Navigator.of(context).push(
                        MaterialPageRoute(
                          builder: (_) => const FriendsScreen(),
                        ),
                      );
                      // The tray may have changed inside; refresh now
                      // rather than waiting out the next tick.
                      if (mounted) await _pollTrays();
                    },
                  ),
                // No message icon here. Chat lives on the game board's app bar,
                // next to sound and autoplay, which is where a player is once
                // a room exists. A second chat icon in the lobby put the same
                // control in two places.
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
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 460),
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: switch (client) {
                  null => _connectForm(),
                  OnlineClient c
                      when c.gameType == 'snakes' && c.snakesState != null =>
                    OnlineSnakesView(client: c, onLeave: _disconnectAndClose),
                  OnlineClient c when c.state != null => LudoGameView(
                    onlineClient: c,
                    onlineSeatId: c.seatId,
                    onOnlineLeave: _disconnectAndClose,
                  ),
                  OnlineClient _ => _lobby(client),
                },
              ),
            ),
          ),
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
        _field(_serverCtrl, 'Server URL', 'ws://localhost:8080/ws'),
        const SizedBox(height: 12),
        _field(
          _nameCtrl,
          'Your name',
          _name.isEmpty ? 'e.g. Asha' : 'saved \u2014 tap to change',
        ),
        // The id is shown rather than hidden: it is what the leaderboard
        // records, so a player can see which identity their wins belong to.
        if (_seatId.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 6, left: 4),
            child: Text(
              'Player ID $_seatId \u00b7 reused every time',
              style: const TextStyle(fontSize: 11, color: Colors.white38),
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
                controller: _codeCtrl,
                textCapitalization: TextCapitalization.characters,
                maxLength: 4,
                style: const TextStyle(color: AppColors.ivory),
                decoration: InputDecoration(
                  counterText: '',
                  labelText: 'Room code',
                  hintText: 'ABCD',
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

  Widget _field(TextEditingController ctrl, String label, String hint) {
    return TextField(
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
                : IconButton(
                    icon: const Icon(Icons.more_vert),
                    tooltip: 'Friend, block or report',
                    onPressed: () => _playerMenu(seat),
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
        // Table talk, inline in the lobby only. Once the game starts this
        // screen is replaced by the board, which has its own chat control in
        // the app bar; the two are separate surfaces, not two views of one
        // panel, so the lobby keeps its inline list and never opens the sheet.
        for (final line in client.chat.reversed.take(6))
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 2),
            child: ChatLineView(line: line, compact: true, myName: client.name),
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
        if (!spectating)
          Row(
            children: [
              if (!_chatRecording) ...[
                IconButton(
                  icon: const Icon(Icons.gif_box, color: AppColors.gold),
                  tooltip: 'Send a GIF',
                  onPressed: () => GifPickerSheet.show(
                    context,
                    serverUrl: client.serverUrl,
                    onPick: (url) => client.sendGif(url),
                  ),
                ),
                Expanded(
                  child: TextField(
                    controller: _chatCtrl,
                    style: const TextStyle(color: AppColors.ivory),
                    onSubmitted: (_) => _sendChat(client),
                    // Same keyboard-GIF story the table chat sheet has:
                    // one insertion behavior across every chat surface.
                    contentInsertionConfiguration: keyboardGifInsertion(
                      send: ({required bytes, required mime}) =>
                          client.sendKeyboardGif(bytes: bytes, mime: mime),
                      sendLink: client.sendGif,
                      onError: (message) =>
                          ScaffoldMessenger.of(context)
                              .showSnackBar(SnackBar(content: Text(message))),
                    ),
                    decoration: InputDecoration(
                      labelText: 'Say something…',
                      labelStyle: const TextStyle(color: AppColors.ivory),
                      enabledBorder: _border(AppColors.ivory.withAlpha(90)),
                      focusedBorder: _border(AppColors.gold),
                    ),
                  ),
                ),
                IconButton(
                  icon: const Icon(Icons.send, color: AppColors.gold),
                  tooltip: 'Send chat',
                  onPressed: () => _sendChat(client),
                ),
              ],
              // The voice control must not be rebuilt while it holds a mic
              // session — see [NoteComposer]; the row's other members make
              // way while it records.
              // Flex follows the state: idle, the composer is one mic
              // chip and takes only its intrinsic width (a flex slot on
              // an idle composer split the row in half and left the text
              // field — and the row's right edge — short of the panel);
              // while recording the bar takes the row. The Flexible type
              // never changes, so the mic session survives the rebuild.
              Flexible(
                flex: _chatRecording ? 1 : 0,
                child: NoteComposer(
                  send: (recording) => client.sendVoiceNote(
                    bytes: recording.bytes,
                    mime: recording.mime,
                    durMs: recording.durMs,
                  ),
                  onError: (message) =>
                      ScaffoldMessenger.of(context)
                          .showSnackBar(SnackBar(content: Text(message))),
                  onRecordingChanged: (recording) => setState(() {
                    _chatRecording = recording;
                  }),
                ),
              ),
            ],
          ),
      ],
    );
  }

  void _sendChat(OnlineClient client) {
    final text = _chatCtrl.text.trim();
    if (text.isEmpty) return;
    client.sendChat(text);
    _chatCtrl.clear();
  }

  Color _colorOf(LudoColor c) => switch (c) {
    LudoColor.red => AppColors.ludoRed,
    LudoColor.blue => AppColors.ludoBlue,
    LudoColor.yellow => AppColors.ludoYellow,
    LudoColor.green => AppColors.ludoGreen,
  };
}

/// The lobby's room-code card. Copying is a first-class button, not a hope:
/// the code used to be the only thing in the card, with copying left to the
/// platform's text selection — and a long-press selection on big,
/// letter-spaced text is unreliable on phone browsers, so mobile players
/// could not share the code at all. The button copies through the clipboard
/// channel, which browsers honour for a user tap.
class RoomCodeCard extends StatelessWidget {
  const RoomCodeCard({super.key, required this.code});

  /// The room's code, or null while the server has not confirmed a room yet.
  final String? code;

  Future<void> _copy(BuildContext context) async {
    final value = code;
    if (value == null) return;
    try {
      await Clipboard.setData(ClipboardData(text: value));
    } catch (_) {
      // Clipboard write can be denied (insecure origin, old browser). The
      // code is still selectable by hand — say so instead of failing silent.
      if (context.mounted) {
        ScaffoldMessenger.of(context)
          ..hideCurrentSnackBar()
          ..showSnackBar(
            const SnackBar(
              content: Text('Could not copy — please select the code by hand'),
            ),
          );
      }
      return;
    }
    if (context.mounted) {
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(
          SnackBar(content: Text('$value copied — send it to your friends')),
        );
    }
  }

  @override
  Widget build(BuildContext context) {
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
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  SelectableText(
                    code ?? '····',
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
                    onPressed: code == null ? null : () => _copy(context),
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
          ],
        ),
      ),
    );
  }
}
