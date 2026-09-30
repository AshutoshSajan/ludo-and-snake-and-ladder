import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../engine/ludo/ludo_models.dart';
import '../services/online_client.dart';
import '../services/storage_service.dart';
import '../ui/ludo/ludo_view.dart';
import '../ui/snakes/online_snakes_view.dart';
import '../ui/theme.dart';

/// Online lobby: connect to an authoritative Ludo server, create or join a
/// room, and jump into the game once the host starts it.
///
/// The server owns the rules and the dice; this screen only renders what the
/// server reports (`OnlineClient`) and forwards the player's intents.
class OnlineLobbyScreen extends StatefulWidget {
  const OnlineLobbyScreen({super.key});

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
  static String sameOriginServerUrl(Uri page) {
    return page.scheme == 'https'
        ? 'wss://${page.authority}/ws'
        : 'ws://${page.host}:8080/ws';
  }

  @override
  State<OnlineLobbyScreen> createState() => _OnlineLobbyScreenState();
}

class _OnlineLobbyScreenState extends State<OnlineLobbyScreen> {
  final _serverCtrl = TextEditingController();
  final _nameCtrl = TextEditingController();
  final _codeCtrl = TextEditingController();
  final _chatCtrl = TextEditingController();

  OnlineClient? _client;
  bool _spectate = false; // "Watch" instead of "Join" in the connect form

  /// Game the host picks when creating a room; joiners inherit the room's.
  String _gameType = 'ludo';

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
    _restoreIdentity();
  }

  Future<void> _restoreIdentity() async {
    final storage = StorageService();
    final id = await storage.loadOnlinePlayerId();
    final name = await storage.loadOnlineName();
    if (!mounted) return;
    setState(() {
      _seatId = id;
      if (name.isNotEmpty) _nameCtrl.text = name;
      _name = name;
    });
  }

  /// Remembers the name so it is offered next time. The id is never changed
  /// here: changing it would orphan the career already recorded under it.
  Future<void> _rememberName(String name) async {
    _name = name;
    await StorageService().saveOnlineName(name);
  }

  @override
  void dispose() {
    _client?.dispose();
    _serverCtrl.dispose();
    _nameCtrl.dispose();
    _codeCtrl.dispose();
    _chatCtrl.dispose();
    super.dispose();
  }

  void _connect({bool createRoom = true}) {
    final name = _nameCtrl.text.trim();
    if (name.isEmpty) {
      _showSnack('Pick a display name first');
      return;
    }
    final code = _codeCtrl.text.trim();
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
    return Scaffold(
      appBar: AppBar(
        title: const Text('Play Online'),
        actions: [
          if (client != null && client.state == null)
            IconButton(
              icon: const Icon(Icons.close),
              tooltip: 'Leave and disconnect',
              onPressed: () async {
                // Say something on the way out rather than just hanging up:
                // the room hears that the seat is given up, and the people
                // still in the lobby are told who went instead of waiting on
                // a chair that nobody is coming back to.
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
      final back = client.status == OnlineStatus.reconnecting;
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const CircularProgressIndicator(),
            const SizedBox(height: 12),
            Text(
              back ? 'Connection lost — reconnecting…' : 'Connecting…',
              style: const TextStyle(color: AppColors.ivory, fontSize: 14),
            ),
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
        Card(
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
                SelectableText(
                  client.roomCode ?? '····',
                  style: const TextStyle(
                    color: AppColors.gold,
                    fontSize: 34,
                    fontWeight: FontWeight.w800,
                    letterSpacing: 8,
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
        ),
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
            trailing: seat.color == client.myColor
                ? const Chip(
                    label: Text('You'),
                    visualDensity: VisualDensity.compact,
                  )
                : null,
          ),
        for (final seat in gone)
          ListTile(
            dense: true,
            leading: CircleAvatar(
              backgroundColor: _colorOf(seat.color).withAlpha(80),
              child: const Icon(Icons.person_off, size: 18),
            ),
            title: Text('${seat.name} left the room', style: muted),
          ),
        if (seats.length < 4 && !spectating)
          ListTile(
            leading: const CircleAvatar(
              child: Icon(Icons.person_add_alt, size: 18),
            ),
            title: Text(
              'Waiting for players… (${seats.length}/4)',
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
        // Light-weight table talk while everyone gathers.
        for (final line in client.chat.reversed.take(6))
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 2),
            child: Text(
              '${line.from}: ${line.text}',
              style: TextStyle(
                color: AppColors.ivory.withAlpha(200),
                fontSize: 13,
              ),
            ),
          ),
        if (!spectating)
          Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _chatCtrl,
                  style: const TextStyle(color: AppColors.ivory),
                  onSubmitted: (_) => _sendChat(client),
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
