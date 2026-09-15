import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../engine/ludo/ludo_models.dart';
import '../services/online_client.dart';
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

  /// On web the server is typically the same host the app was served from,
  /// just on the dedicated WebSocket port. Shared with the online
  /// leaderboard screen so both target the same server by default.
  static String defaultServerUrl() {
    if (kIsWeb && Uri.base.host.isNotEmpty) {
      return 'ws://${Uri.base.host}:8080/ws';
    }
    return 'ws://localhost:8080/ws';
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
  final String _seatId =
      'u${DateTime.now().microsecondsSinceEpoch.toRadixString(36)}'
      '${Random().nextInt(1 << 16).toRadixString(36)}';

  @override
  void initState() {
    super.initState();
    _serverCtrl.text = OnlineLobbyScreen.defaultServerUrl();
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
          _spectate ? 'Enter a room code to watch' : 'Room codes are 4 letters');
      return;
    }
    final client = OnlineClient(
      _serverCtrl.text.trim(),
      seatId: _seatId,
      name: name,
      gameType: _gameType,
    )..addListener(() => setState(() {}));
    setState(() => _client = client);
    client.connect(code: createRoom ? null : code, spectate: !createRoom && _spectate);
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

  /// Leave button inside the snakes game view: drop the socket and return
  /// to the connect/lobby form.
  void _disconnectAndClose() {
    _disconnect();
  }

  @override
  Widget build(BuildContext context) {
    final client = _client;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Online Ludo'),
        actions: [
          if (client != null && client.state == null)
            IconButton(
              icon: const Icon(Icons.close),
              tooltip: 'Leave and disconnect',
              onPressed: () async {
                await _disconnect();
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
                  OnlineClient c when c.gameType == 'snakes' &&
                          c.snakesState != null =>
                    OnlineSnakesView(client: c, onLeave: _disconnectAndClose),
                  OnlineClient c when c.state != null => LudoGameView(
                      onlineClient: c,
                      onlineSeatId: c.seatId,
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
        const Center(
          child: Text(
            'Play Ludo online against friends',
            style: TextStyle(color: AppColors.ivory, fontSize: 16),
          ),
        ),
        const SizedBox(height: 24),
        _field(_serverCtrl, 'Server URL', 'ws://localhost:8080/ws'),
        const SizedBox(height: 12),
        _field(_nameCtrl, 'Your name', 'e.g. Asha'),
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
            label: Text(_spectate
                ? 'Spectating — tap again to cancel'
                : 'Just want to watch? Spectate a room'),
            style: TextButton.styleFrom(
              foregroundColor:
                  _spectate ? AppColors.gold : AppColors.ivory.withAlpha(150),
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
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          const CircularProgressIndicator(),
          const SizedBox(height: 12),
          Text(
            back ? 'Connection lost — reconnecting…' : 'Connecting…',
            style: const TextStyle(color: AppColors.ivory, fontSize: 14),
          ),
        ]),
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
    final seats = client.lobbySeats;
    final iAmHost = seats.isNotEmpty && client.myColor == seats.first.color;
    final spectating = client.isSpectator;
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
            trailing: seat.color == client.myColor
                ? const Chip(
                    label: Text('You'),
                    visualDensity: VisualDensity.compact,
                  )
                : null,
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
