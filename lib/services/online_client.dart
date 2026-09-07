/// WebSocket client for the authoritative Ludo server (`bin/server.dart`).
///
/// Sends *intents* only ('roll', 'move'); the actual game state always
/// arrives as server snapshots via [updates]. Pure Flutter (web_socket_channel),
/// so it works on web, desktop, and mobile.
library;

import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:web_socket_channel/web_socket_channel.dart';

import '../engine/ludo/ludo_models.dart';

/// One lobby seat as reported by the server.
class LobbySeat {
  LobbySeat({required this.name, required this.color});

  final String name;
  final LudoColor color;
}

/// One aggregated row of the server-side leaderboard.
class LeaderboardRow {
  LeaderboardRow({
    required this.name,
    required this.wins,
    required this.games,
    required this.avgRank,
  });

  factory LeaderboardRow.fromJson(Map<String, dynamic> j) => LeaderboardRow(
        name: j['name'] as String? ?? '?',
        wins: j['wins'] as int? ?? 0,
        games: j['games'] as int? ?? 0,
        avgRank: (j['avgRank'] as num?)?.toDouble() ?? 0,
      );

  final String name;
  final int wins; // first-place finishes
  final int games;
  final double avgRank; // lower is better; 1.0 = always first
}

/// The parsed GET /leaderboard response.
class LeaderboardData {
  LeaderboardData({required this.games, required this.rows});

  factory LeaderboardData.fromJson(Map<String, dynamic> j) => LeaderboardData(
        games: j['games'] as int? ?? 0,
        rows: [
          for (final r in (j['players'] as List? ?? []))
            LeaderboardRow.fromJson(r as Map<String, dynamic>),
        ],
      );

  final int games; // total finished games on the server
  final List<LeaderboardRow> rows;
}

enum OnlineStatus { idle, connecting, reconnecting, inLobby, playing, error }

class OnlineClient extends ChangeNotifier {
  OnlineClient(
    this.serverUrl, {
    required this.seatId,
    required this.name,
    WebSocketChannel Function(Uri uri)? channelFactory,
  }) : _channelFactory = channelFactory ?? WebSocketChannel.connect;

  /// e.g. 'ws://localhost:8080/ws'
  final String serverUrl;
  final String seatId; // profile id — our identity across reconnects
  final String name;

  /// Overridable for tests (fake WebSocket channels).
  final WebSocketChannel Function(Uri) _channelFactory;

  /// Fetches the server leaderboard over plain HTTP. [serverUrl] is the
  /// WebSocket URL (ws://host:port/ws); the matching http(s) origin is used.
  /// Throws on network errors or a non-200 response.
  static Future<LeaderboardData> fetchLeaderboard(String serverUrl,
      {http.Client? httpClient, Duration timeout = const Duration(seconds: 5)}) async {
    final ws = Uri.parse(serverUrl);
    final base = ws.replace(
      scheme: ws.scheme == 'wss' ? 'https' : 'http',
      path: '/leaderboard',
    );
    final client = httpClient ?? http.Client();
    try {
      final resp = await client.get(base).timeout(timeout);
      if (resp.statusCode != 200) {
        throw Exception('Leaderboard request failed (HTTP ${resp.statusCode})');
      }
      return LeaderboardData.fromJson(
          jsonDecode(resp.body) as Map<String, dynamic>);
    } finally {
      if (httpClient == null) client.close();
    }
  }

  WebSocketChannel? _channel;
  StreamSubscription<dynamic>? _sub;

  OnlineStatus status = OnlineStatus.idle;
  String? errorText;

  String? roomCode;
  LudoColor? myColor;
  bool started = false;
  final lobbySeats = <LobbySeat>[];

  /// Latest authoritative snapshot, decoded. Null until the game starts.
  LudoState? state;
  int _seenRollSeq = 0;

  /// Fire-and-forget chat lines: (from, text).
  final chat = <({String from, String text})>[];

  // Reconnect state: we keep the join code and identity, and retry with
  // exponential backoff until the server answers hello again.
  String? _joinCode;
  bool _userClosed = false;
  int _reconnectAttempts = 0;
  Timer? _reconnectTimer;
  static const _maxReconnectAttempts = 5;
  static const _reconnectBaseDelay = Duration(milliseconds: 500);

  bool get connected =>
      status == OnlineStatus.inLobby || status == OnlineStatus.playing;

  bool get isMyTurn => state != null && started && connected;

  void _send(Map<String, dynamic> msg) {
    final ch = _channel;
    if (ch == null || ch.closeCode != null) return;
    ch.sink.add(jsonEncode(msg));
  }

  Future<void> connect({String? code, LudoColor? preferredColor}) async {
    assert(status == OnlineStatus.idle || status == OnlineStatus.error);
    _userClosed = false;
    _reconnectAttempts = 0;
    _joinCode = code;
    status = OnlineStatus.connecting;
    errorText = null;
    notifyListeners();
    await _openAndHello(preferredColor: preferredColor);
  }

  Future<void> _openAndHello({LudoColor? preferredColor}) async {
    try {
      _channel = _channelFactory(Uri.parse(serverUrl));
      _sub = _channel!.stream.listen(_onMessage, onDone: _onClosed,
          onError: (_) => _onClosed());
      _send({
        'type': 'hello',
        'seatId': seatId,
        'name': name,
        if (_joinCode != null && _joinCode!.isNotEmpty) 'code': _joinCode,
        if (preferredColor != null) 'color': preferredColor.name,
      });
    } catch (e) {
      status = OnlineStatus.error;
      errorText = 'Could not reach server: $e';
      notifyListeners();
    }
  }

  void _onClosed() {
    if (_userClosed) {
      status = OnlineStatus.idle;
      notifyListeners();
      return;
    }
    // A dropped socket can surface as error AND done — handle it once.
    if (status == OnlineStatus.reconnecting && _reconnectTimer != null) return;
    _sub?.cancel();
    _sub = null;
    // Unplanned drop (network blip, server bounce): retry with backoff.
    if (_reconnectAttempts >= _maxReconnectAttempts) {
      status = OnlineStatus.error;
      errorText = 'Connection lost — could not reach the server.';
      notifyListeners();
      return;
    }
    final delay = _reconnectBaseDelay * (1 << _reconnectAttempts);
    _reconnectAttempts++;
    status = OnlineStatus.reconnecting;
    notifyListeners();
    _reconnectTimer = Timer(delay, () {
      _reconnectTimer = null; // so a later drop is handled again
      _openAndHello();
    });
  }

  void _onMessage(dynamic data) {
    final Map<String, dynamic> msg;
    try {
      msg = jsonDecode(data as String) as Map<String, dynamic>;
    } catch (_) {
      return;
    }
    switch (msg['type'] as String?) {
      case 'joined':
        roomCode = msg['code'] as String;
        myColor = LudoColor.values.byName(msg['color'] as String);
        status = OnlineStatus.inLobby;
        _reconnectAttempts = 0; // we're back on the wire
      case 'lobby':
        started = msg['started'] as bool? ?? false;
        lobbySeats
          ..clear()
          ..addAll([
            for (final s in (msg['seats'] as List? ?? []))
              LobbySeat(
                name: (s as Map)['name'] as String,
                color: LudoColor.values.byName(s['color'] as String),
              ),
          ]);
      case 'state':
        final incoming = LudoState.fromJson(
            Map<String, dynamic>.from(msg['state'] as Map));
        // Dice sound on every new roll (rollSeq-based, like local play).
        if (incoming.rollSeq != _seenRollSeq) {
          _seenRollSeq = incoming.rollSeq;
          onRoll?.call();
        }
        onState?.call(state, incoming);
        state = incoming;
        started = true;
        status = OnlineStatus.playing;
      case 'chat':
        chat.add((
          from: msg['from'] as String,
          text: msg['text'] as String,
        ));
        onChat?.call();
      case 'error':
        errorText = msg['text'] as String;
        status = OnlineStatus.error;
        // A definitive rejection (bad code, gone room) — stop retrying.
        _reconnectTimer?.cancel();
        _userClosed = true;
        _channel?.sink.close();
        _channel = null;
    }
    notifyListeners();
  }

  /// Hooks used by the session adapter (sounds, animation replay).
  void Function()? onRoll;
  void Function(LudoState? oldState, LudoState newState)? onState;
  void Function()? onChat;

  // ------------------------------------------------------------ intents

  void sendStart() => _send({'type': 'start'});
  void sendRoll() => _send({'type': 'roll'});
  void sendMove(int tokenIndex) => _send({'type': 'move', 'token': tokenIndex});
  void sendChat(String text) => _send({'type': 'chat', 'text': text});

  Future<void> disconnect() async {
    _userClosed = true;
    _reconnectTimer?.cancel();
    _reconnectTimer = null;
    // Reflect the leave immediately so the UI doesn't flash a spinner
    // while the socket cleanup below settles.
    status = OnlineStatus.idle;
    notifyListeners();
    await _sub?.cancel();
    _sub = null;
    await _channel?.sink.close();
    _channel = null;
  }

  @override
  void dispose() {
    _userClosed = true;
    _reconnectTimer?.cancel();
    _reconnectTimer = null;
    _sub?.cancel();
    _channel?.sink.close();
    super.dispose();
  }
}
