/// WebSocket client for the authoritative Ludo server (`bin/server.dart`).
///
/// Sends *intents* only ('roll', 'move'); the actual game state always
/// arrives as server snapshots via [updates]. Pure Flutter (web_socket_channel),
/// so it works on web, desktop, and mobile.
library;

import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

import '../engine/ludo/ludo_models.dart';

/// One lobby seat as reported by the server.
class LobbySeat {
  LobbySeat({required this.name, required this.color});

  final String name;
  final LudoColor color;
}

enum OnlineStatus { idle, connecting, inLobby, playing, error }

class OnlineClient extends ChangeNotifier {
  OnlineClient(this.serverUrl, {required this.seatId, required this.name});

  /// e.g. 'ws://localhost:8080/ws'
  final String serverUrl;
  final String seatId; // profile id — our identity across reconnects
  final String name;

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
    status = OnlineStatus.connecting;
    errorText = null;
    notifyListeners();
    try {
      _channel = WebSocketChannel.connect(Uri.parse(serverUrl));
      _sub = _channel!.stream.listen(_onMessage, onDone: _onClosed,
          onError: (_) => _onClosed());
      _send({
        'type': 'hello',
        'seatId': seatId,
        'name': name,
        if (code != null && code.isNotEmpty) 'code': code,
        if (preferredColor != null) 'color': preferredColor.name,
      });
    } catch (e) {
      status = OnlineStatus.error;
      errorText = 'Could not reach server: $e';
      notifyListeners();
    }
  }

  void _onClosed() {
    status = OnlineStatus.idle;
    notifyListeners();
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
    await _sub?.cancel();
    await _channel?.sink.close();
    _channel = null;
    status = OnlineStatus.idle;
    notifyListeners();
  }

  @override
  void dispose() {
    _sub?.cancel();
    _channel?.sink.close();
    super.dispose();
  }
}
