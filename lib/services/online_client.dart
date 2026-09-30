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
import '../engine/snakes/snakes_engine.dart';

/// How a seat is being held: the person is at their device, the table is
/// playing for them, or they have walked out.
enum SeatStatus { connected, auto, left }

/// One lobby seat as reported by the server.
class LobbySeat {
  LobbySeat({
    required this.name,
    required this.color,
    this.seatId = '',
    this.status = SeatStatus.connected,
    this.live = true,
  });

  /// Builds from the server's `seats` entry, and from the lighter `lobby`
  /// entry that only carries a name and a color — everything else falls back
  /// to "a person is sitting here".
  factory LobbySeat.fromJson(Map<String, dynamic> j) {
    var status = SeatStatus.connected;
    if (j['auto'] == true) status = SeatStatus.auto;
    if (j['left'] == true) status = SeatStatus.left;
    return LobbySeat(
      name: j['name'] as String? ?? '?',
      color: LudoColor.values.byName(j['color'] as String),
      seatId: j['seatId'] as String? ?? '',
      status: status,
      live: j['connected'] as bool? ?? true,
    );
  }

  final String name;
  final LudoColor color;

  /// The profile holding this seat — how we know whether *we* are the one
  /// who switched on autoplay. Empty in the lighter `lobby` roster.
  final String seatId;
  final SeatStatus status;

  /// Whether a live socket is holding this seat right now. When it is not,
  /// the table is waiting on someone whose device has gone quiet — which the
  /// people waiting read as "the game has frozen" unless the screen says
  /// otherwise. Defaults to true so a roster that omits the field never
  /// accuses an innocent player of being away.
  final bool live;

  /// Still in the game (playing themselves, or having handed the seat to the
  /// table) as opposed to having left, whose pieces sit untouched.
  bool get inGame => status != SeatStatus.left;
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

/// The leaderboard request reached the server and the server *answered* with
/// an error status. The connection is fine; the data is not — a 500 here
/// means the server's own store failed (e.g. its Turso credentials), which
/// is a different fix from "nothing is listening at this URL". Keeping the
/// two apart in the type means the UI can never confuse them again.
class LeaderboardServerException implements Exception {
  LeaderboardServerException(this.statusCode, this.body);

  final int statusCode;
  final String body;

  @override
  String toString() => 'Leaderboard request failed (HTTP $statusCode)';
}

enum OnlineStatus { idle, connecting, reconnecting, inLobby, playing, error }

class OnlineClient extends ChangeNotifier {
  OnlineClient(
    this.serverUrl, {
    required this.seatId,
    required this.name,
    this.gameType = 'ludo',
    this.quickMatch = false,
    WebSocketChannel Function(Uri uri)? channelFactory,
  }) : _channelFactory = channelFactory ?? WebSocketChannel.connect;

  /// e.g. 'ws://localhost:8080/ws'
  final String serverUrl;
  final String seatId; // profile id — our identity across reconnects
  final String name;

  /// Which game to play when creating a room ('ludo' | 'snakes'). Joiners
  /// have their value overwritten by the room's real game type on 'joined'.
  String gameType;

  /// Quick match: with no room code, the server pairs us with the first
  /// waiting room of [gameType] (creating one if none exists) instead of
  /// always opening a fresh room.
  bool quickMatch;

  /// Overridable for tests (fake WebSocket channels).
  final WebSocketChannel Function(Uri) _channelFactory;

  /// Fetches the server leaderboard over plain HTTP. [serverUrl] is the
  /// WebSocket URL (ws://host:port/ws); the matching http(s) origin is used.
  /// Throws [LeaderboardServerException] when the server answers with a
  /// non-200 status, and the underlying error when it never answers at all.
  ///
  /// One retry: a hosted instance that has been asleep answers the first
  /// request while it is still booting — the socket is up but its database
  /// pool is not, or a free tier box answers nothing at all. One second later
  /// the same request usually succeeds, and a player who saw "could not
  /// load" once and taps again is told the truth about a service that was
  /// fine the whole time. A 4xx is a settled answer and is never retried.
  static Future<LeaderboardData> fetchLeaderboard(
    String serverUrl, {
    http.Client? httpClient,
    Duration timeout = const Duration(seconds: 5),
    int attempts = 2,
    Duration retryDelay = const Duration(milliseconds: 900),
  }) async {
    final ws = Uri.parse(serverUrl);
    final base = ws.replace(
      scheme: ws.scheme == 'wss' ? 'https' : 'http',
      path: '/leaderboard',
    );
    final client = httpClient ?? http.Client();
    try {
      Object? pending;
      for (var attempt = 0; attempt < attempts; attempt++) {
        if (attempt > 0) await Future<void>.delayed(retryDelay);
        try {
          final resp = await client.get(base).timeout(timeout);
          if (resp.statusCode != 200) {
            final failure = LeaderboardServerException(
              resp.statusCode,
              resp.body,
            );
            if (resp.statusCode < 500) throw failure;
            pending = failure;
            continue;
          }
          return LeaderboardData.fromJson(
            jsonDecode(resp.body) as Map<String, dynamic>,
          );
        } on LeaderboardServerException {
          rethrow;
        } catch (e) {
          pending = e; // never answered at all — worth the one retry
        }
      }
      throw pending ?? StateError('leaderboard request made no attempt');
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

  /// Latest authoritative Snakes & Ladders snapshot (snakes rooms only).
  SnakesState? snakesState;
  int _seenRollSeq = 0;

  /// Fire-and-forget chat lines: (from, text).
  final chat = <({String from, String text})>[];

  /// Set when the server announces a walk-out, cleared by [clearLeftNotice]
  /// once the screen has shown it. Kept on the client rather than folded into
  /// the seat list because a toast is a one-time event while the seat list is
  /// a standing fact — both are needed: the toast explains the moment, the
  /// list keeps the corner greyed out afterwards.
  String? leftNotice;

  void clearLeftNotice() {
    if (leftNotice == null) return;
    leftNotice = null;
    notifyListeners();
  }

  /// Our own seat's autoplay state, as the table sees it. Drives the toggle
  /// so it can never disagree with the server, and survives a reconnect
  /// because it is relearned from the `seats` broadcast on rejoin.
  bool get iAmAuto =>
      lobbySeats.any((s) => s.seatId == seatId && s.status == SeatStatus.auto);

  /// Names of everyone who walked out, for the corner labels and the results.
  List<String> get leftNames => [
    for (final s in lobbySeats)
      if (s.status == SeatStatus.left) s.name,
  ];

  // Reconnect state: we keep the join code and identity, and retry with
  // exponential backoff until the server answers hello again.
  String? _joinCode;
  bool _spectating = false;

  /// True once the server seated us as a read-only watcher. Spectators see
  /// everything but can never roll, move, or claim a seat.
  bool get isSpectator => _spectating;

  /// Spectator names from the latest lobby roster (players see this too, as
  /// a "watching" line).
  final spectatorNames = <String>[];

  bool _userClosed = false;
  int _reconnectAttempts = 0;
  Timer? _reconnectTimer;
  static const _maxReconnectAttempts = 5;
  static const _reconnectBaseDelay = Duration(milliseconds: 500);

  /// The replica that owns our room, learned from a reroute error (the
  /// server attaches `owner` when a join/reconnect lands on a replica that
  /// does not hold the room). Sent back as `?owner=` so the load balancer
  /// pins the connection to the owning replica instead of the hash slot.
  String? _routeHint;

  bool get connected =>
      status == OnlineStatus.inLobby || status == OnlineStatus.playing;

  bool get isMyTurn =>
      !_spectating &&
      started &&
      connected &&
      (gameType == 'snakes' ? snakesState != null : state != null);

  void _send(Map<String, dynamic> msg) {
    final ch = _channel;
    if (ch == null || ch.closeCode != null) return;
    ch.sink.add(jsonEncode(msg));
  }

  Future<void> connect({
    String? code,
    LudoColor? preferredColor,
    bool spectate = false,
  }) async {
    assert(status == OnlineStatus.idle || status == OnlineStatus.error);
    _userClosed = false;
    _reconnectAttempts = 0;
    _routeHint = null;
    // Canonicalize up front: the server stores rooms under the uppercase
    // code, and we hash-route by `?code=` — a lowercase-typed code must not
    // be pinned to a different replica than the room's uppercase one.
    _joinCode = code?.trim().toUpperCase();
    _spectating = spectate;
    status = OnlineStatus.connecting;
    errorText = null;
    notifyListeners();
    await _openAndHello(preferredColor: preferredColor);
  }

  Future<void> _openAndHello({LudoColor? preferredColor}) async {
    try {
      // Carry the room code in the URL: a room-affinity load balancer
      // (deploy/nginx.conf hashes the ?code= query parameter consistently)
      // must route a join — and a reconnect — consistently. The code still
      // rides in `hello`, which the server treats as authoritative.
      //
      // Hashing by code is not ownership, though: a room is created on
      // whichever replica the code-less first connection landed on, so a
      // later join/reconnect can hash to a replica that does not hold the
      // room. When that happens the server answers with a reroute error
      // carrying the owning instance, which we retry with as `?owner=` —
      // nginx's map pins such requests to the owning replica directly.
      // Unknown at first connect (room creation, quick match): we land
      // anywhere, create the room there, and every later open carries the
      // code learned from 'joined'.
      var uri = Uri.parse(serverUrl);
      final params = {...uri.queryParameters};
      if (_joinCode != null && _joinCode!.isNotEmpty) {
        // Always the canonical uppercase spelling: the load balancer hashes
        // this value, and the room lives under the uppercase code the
        // server stored — a lowercase copy would hash to another bucket.
        params['code'] = _joinCode!.toUpperCase();
      }
      if (_routeHint != null) {
        params['owner'] = _routeHint!;
      }
      if (params.isNotEmpty) uri = uri.replace(queryParameters: params);
      _channel = _channelFactory(uri);
      _sub = _channel!.stream.listen(
        _onMessage,
        onDone: _onClosed,
        onError: (_) => _onClosed(),
      );
      _send({
        'type': 'hello',
        'seatId': seatId,
        'name': name,
        'game': gameType,
        if (quickMatch && (_joinCode == null || _joinCode!.isEmpty))
          'match': true,
        if (_joinCode != null && _joinCode!.isNotEmpty) 'code': _joinCode,
        if (preferredColor != null) 'color': preferredColor.name,
        if (_spectating) 'spectate': true,
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
        // Remember the room we were actually seated in so a quick-match
        // reconnect lands back with the same strangers, not a new match.
        _joinCode = roomCode;
        gameType = msg['game'] as String? ?? gameType;
        _spectating = msg['spectator'] as bool? ?? _spectating;
        final colorName = msg['color'] as String?;
        myColor = colorName == null ? null : LudoColor.values.byName(colorName);
        status = OnlineStatus.inLobby;
        _reconnectAttempts = 0; // we're back on the wire
      case 'lobby':
        started = msg['started'] as bool? ?? false;
        lobbySeats
          ..clear()
          ..addAll([
            for (final s in (msg['seats'] as List? ?? []))
              LobbySeat.fromJson((s as Map).cast<String, dynamic>()),
          ]);
        spectatorNames
          ..clear()
          ..addAll([
            for (final n in (msg['spectators'] as List? ?? [])) n as String,
          ]);
      case 'seats':
        // The per-seat status feed: autoplay badges, disconnected links, and
        // the corners that are now empty because someone walked out. It
        // arrives on every change and right after a join, so a rejoin finds
        // the badges already correct.
        lobbySeats
          ..clear()
          ..addAll([
            for (final s in (msg['seats'] as List? ?? []))
              LobbySeat.fromJson((s as Map).cast<String, dynamic>()),
          ]);
        onSeats?.call();
      case 'left':
        // Worth a line of its own: without it a departing player's pieces
        // just stop moving and the reason stays invisible.
        leftNotice = '${msg['name'] as String? ?? 'A player'} left the game';
        onLeft?.call(leftNotice!);
      case 'state':
        if ((msg['game'] as String?) == 'snakes') {
          final incoming = SnakesState.fromJson(
            Map<String, dynamic>.from(msg['state'] as Map),
          );
          // Dice sound on a fresh roll: phase moved roll -> move.
          if (snakesState?.phase == SnakesPhase.awaitingRoll &&
              incoming.phase == SnakesPhase.awaitingMove) {
            onRoll?.call();
          }
          onSnakesState?.call(snakesState, incoming);
          snakesState = incoming;
        } else {
          final incoming = LudoState.fromJson(
            Map<String, dynamic>.from(msg['state'] as Map),
          );
          // Dice sound on every new roll (rollSeq-based, like local play).
          if (incoming.rollSeq != _seenRollSeq) {
            _seenRollSeq = incoming.rollSeq;
            onRoll?.call();
          }
          onState?.call(state, incoming);
          state = incoming;
        }
        started = true;
        status = OnlineStatus.playing;
      case 'chat':
        chat.add((from: msg['from'] as String, text: msg['text'] as String));
        onChat?.call();
      case 'roomClosed':
        // The authority dropped an abandoned room (grace period expired).
        errorText = 'The room has closed.';
        status = OnlineStatus.error;
        _userClosed = true;
        _channel?.sink.close();
        _channel = null;
      case 'error':
        final owner = msg['owner'] as String?;
        if (owner != null && owner.isNotEmpty && !_userClosed) {
          // The room lives on another replica — this is a routing problem,
          // not a definitive rejection. Reroute: remember the owner and let
          // the socket close so the normal reconnect path retries with
          // `?owner=`, which the load balancer turns into a direct hop.
          // Still counts against the reconnect budget, so a persistent
          // failure (e.g. the owner replica dying mid-reroute) terminates.
          _routeHint = owner;
          status = OnlineStatus.reconnecting;
          notifyListeners();
          _channel?.sink.close();
          _channel = null;
          break;
        }
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
  void Function(SnakesState? oldState, SnakesState newState)? onSnakesState;
  void Function()? onChat;

  /// Seat-status changes (autoplay badges, corners emptied by a walk-out) and
  /// the walk-out announcement itself, which the screen turns into a toast.
  void Function()? onSeats;
  void Function(String notice)? onLeft;

  // ------------------------------------------------------------ intents

  void sendStart() => _spectating ? _noop() : _send({'type': 'start'});
  void sendRoll() => _spectating ? _noop() : _send({'type': 'roll'});
  void sendMove(int tokenIndex) =>
      _spectating ? _noop() : _send({'type': 'move', 'token': tokenIndex});

  /// Snakes & Ladders: the roll fully determines the move, so the intent
  /// carries no token.
  void sendSnakesMove() => _spectating ? _noop() : _send({'type': 'move'});
  void sendChat(String text) =>
      _spectating ? _noop() : _send({'type': 'chat', 'text': text});

  /// Hand the seat to the table. The decision lives on the server, so the
  /// table keeps playing our turn when this tab is closed, the phone is
  /// locked, or the app is killed outright — which is the whole point: nobody
  /// waits for a player who stepped away. A human who comes back can still
  /// roll and move by hand; the driver only steps in when a turn is pending.
  void sendAutoplay(bool on) =>
      _spectating ? _noop() : _send({'type': 'autoplay', 'on': on});

  /// Walk out on purpose. Unlike a dropped link — which the table reads as a
  /// wobble and waits through — this releases the seat, lifts our pieces off
  /// the board so they stop blocking squares, and tells everyone who went.
  /// Spectators just hang up: leaving a room you never sat in is not news.
  Future<void> sendLeave() async {
    if (!_spectating) _send({'type': 'leave'});
    await disconnect();
  }

  /// Spectators are read-only; their intents are dropped client-side so the
  /// server never even sees them.
  void _noop() {}

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
