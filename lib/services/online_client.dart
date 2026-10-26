/// WebSocket client for the authoritative Ludo server (`bin/server.dart`).
///
/// Sends *intents* only ('roll', 'move'); the actual game state always
/// arrives as server snapshots via [updates]. Pure Flutter (web_socket_channel),
/// so it works on web, desktop, and mobile.
library;

import 'dart:async';
import 'dart:math';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:web_socket_channel/web_socket_channel.dart';

import '../engine/ludo/ludo_models.dart';
import '../engine/snakes/snakes_engine.dart';
import 'voice_room.dart';
import 'voice_rtc.dart';

/// How a seat is being held: the person is at their device, the table is
/// playing for them, or they have walked out.
enum SeatStatus { connected, auto, left }

/// How the seat in [OnlineClient.leftNotice] stopped playing, so the game
/// views can match the alert's glyph to the wording in one place: the
/// table carries a seat off when five turns go silent (`removed`), while a
/// walk-out (`walkedOut`) is a decision the player made by hand.
enum SeatExitKind { removed, walkedOut }

/// The turn timer's eviction budget, as the server's default builds it.
/// The copy that counts against it ("missed 2 · 3 left", "count of 5")
/// reaches the client beside the misses themselves; if a room ever gets a
/// different budget, the constant travels with that broadcast instead of
/// staying a hard-coded five.
const int maxTurnMisses = 5;

/// The WS server URL's http(s) origin, where the voice-note store (and
/// any other REST surface) lives. Kept public for the tests and for
/// callers that frame player-facing links.
Uri _httpOriginOf(String serverUrl, String path) {
  final ws = Uri.parse(serverUrl);
  return ws.replace(scheme: ws.scheme == 'wss' ? 'https' : 'http', path: path);
}

/// One recorded voice note in chat: the playback URL (absolute — the
/// chat broadcast carries a relative server path; the client joins it to
/// the game server's origin here, once, at parse time) and its duration
/// as the server recorded it.
class VoiceNote {
  const VoiceNote({required this.url, required this.durMs});

  factory VoiceNote.fromJson(Map<String, dynamic> j, String serverUrl) =>
      VoiceNote(
        url: _httpOriginOf(serverUrl, j['url'] as String? ?? '').toString(),
        durMs: (j['dur'] as num?)?.toInt() ?? 0,
      );

  final String url;
  final int durMs;

  /// '0:07' / '1:03' — the way a voice pill is read at a glance.
  String get clock {
    final s = (durMs / 1000).round();
    final m = s ~/ 60;
    return '$m:${(s % 60).toString().padLeft(2, '0')}';
  }
}

/// One table-chat line: a sentence, an inline GIF and/or a voice note.
/// The `gif` is the full-resolution https URL and `note` an uploaded
/// recording — the room's server builds both (see `_chatGif` and
/// `_chatNote`), so they are exactly what the store vouched for.
/// `color` paints the bubble with the sender's seat; `at` is the epoch
/// ms the line was said.
class ChatLine {
  const ChatLine({
    required this.from,
    this.text = '',
    this.gif,
    this.note,
    this.color,
    this.at,
    this.seatId = '',
  });

  factory ChatLine.fromJson(Map<String, dynamic> j, {String? serverUrl}) =>
      ChatLine(
        from: j['from'] as String,
        text: j['text'] as String? ?? '',
        gif: j['gif'] as String?,
        note: j['note'] == null
            ? null
            : (serverUrl == null
                  ? null
                  : VoiceNote.fromJson(
                      (j['note'] as Map).cast<String, dynamic>(),
                      serverUrl,
                    )),
        color: LudoColor.tryParse(j['color'] as String? ?? ''),
        at: (j['at'] as num?)?.toInt(),
        // The author's seat id, from the server's chat broadcast. It keys
        // friendship (add / block / report address the id, not the name —
        // names collide and get ambiguity tags). Older lines relaid by
        // server versions lack it; the send/block affordances simply stay
        // quiet for them.
        seatId: j['seatId'] as String? ?? '',
      );

  final String from;
  final String text;
  final String? gif;
  final VoiceNote? note;
  final LudoColor? color;
  final int? at;

  /// The author's seat id when the server broadcasts it ('' on lines from
  /// older server versions). Friends actions address this, never the name.
  final String seatId;

  /// '14:32' — fresh enough to matter in a tablet session, and cheap: no
  /// date math, just the wall clock at arrival.
  String get clock {
    final t = DateTime.fromMillisecondsSinceEpoch(at ?? 0);
    final h = t.hour.toString().padLeft(2, '0');
    final m = t.minute.toString().padLeft(2, '0');
    return '$h:$m';
  }
}

/// One lobby seat as reported by the server.
class LobbySeat {
  LobbySeat({
    required this.name,
    required this.color,
    this.seatId = '',
    this.status = SeatStatus.connected,
    this.live = true,
    this.misses = 0,
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
      misses: (j['misses'] as num?)?.toInt() ?? 0,
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

  /// Consecutive turn-timer misses the seat has let lapse while everyone
  /// watched. Zero for seats that answer their clock; five means the server
  /// dropped them. Zero on any roster a pre-timer server sends.
  final int misses;

  /// Still in the game (playing themselves, or having handed the seat to the
  /// table) as opposed to having left, whose pieces sit untouched.
  bool get inGame => status != SeatStatus.left;
}

/// A friendly default name for a first-time player.
///
/// A new player is handed something they can play with immediately rather than
/// an empty text field — and, more importantly, something *stable*, because the
/// name is saved and reused. A name that changed on every visit would be worse
/// than none: the leaderboard would fill with rows of the same person under
/// different names.
///
/// Deliberately built from two small word lists rather than pulled in as a
/// package. A name generator is a dozen lines; a dependency is a permanent
/// supply-chain surface, a `pubspec.lock` entry and a future version bump, for
/// something the app only needs once. The `names` package would also be the
/// wrong shape: it has no notion of being reproducible, which is the one
/// property that actually matters here — a second call must return the same
/// name for the same player.
class DefaultNames {
  DefaultNames._();

  static const _adjectives = <String>[
    'Swift',
    'Quiet',
    'Bold',
    'Lucky',
    'Clever',
    'Brave',
    'Calm',
    'Bright',
    'Nimble',
    'Steady',
    'Sharp',
    'Keen',
    'Merry',
    'Quick',
    'Silent',
    'Witty',
  ];

  static const _animals = <String>[
    'Otter',
    'Falcon',
    'Heron',
    'Badger',
    'Marten',
    'Ibis',
    'Lynx',
    'Raven',
    'Sparrow',
    'Tapir',
    'Vole',
    'Wren',
    'Gecko',
    'Ibex',
    'Kite',
    'Newt',
  ];

  /// A name like `Swift Otter`.
  ///
  /// With a [salt] the result is *deterministic* — the same salt always yields
  /// the same name, which is the whole point: a player's name is derived from
  /// their id, so they are the same "Swift Otter" on every visit and their
  /// leaderboard career stays in one row. Mixing any randomness into the
  /// salted path would defeat that, so a salt bypasses the generator entirely.
  /// Without one, a name is drawn at random.
  static String generate({int? salt, Random? random}) {
    if (salt != null) {
      final a = _adjectives[salt.abs() % _adjectives.length];
      final n = _animals[(salt.abs() ~/ 7) % _animals.length];
      return '$a $n';
    }
    final rnd = random ?? Random();
    return '${_adjectives[rnd.nextInt(_adjectives.length)]} '
        '${_animals[rnd.nextInt(_animals.length)]}';
  }

  /// A default name that is *uniquely* this player's.
  ///
  /// The word pair alone is not enough: 16x16 is 256 names, so a handful of
  /// players would collide almost immediately, and two "Swift Otter" rows on
  /// the leaderboard are indistinguishable. The suffix is derived from the id,
  /// so the name stays friendly, stable, and distinct — and because it comes
  /// from the same value the leaderboard groups by, it cannot drift from the
  /// identity it represents.
  static String unique({required String playerId}) {
    var hash = 0;
    for (final unit in playerId.codeUnits) {
      hash = (hash * 31 + unit) & 0x7fffffff;
    }
    final base = generate(salt: hash);
    // Four base-32 characters from the hash: short enough to read aloud, wide
    // enough that collisions are vanishingly rare.
    final tag = (hash % 0x10000)
        .toRadixString(32)
        .toUpperCase()
        .padLeft(4, '0');
    return '$base $tag';
  }
}

class LeaderboardRow {
  LeaderboardRow({
    required this.name,
    required this.wins,
    required this.games,
    required this.avgRank,
    this.seatId = '',
  });

  factory LeaderboardRow.fromJson(Map<String, dynamic> j) => LeaderboardRow(
    name: j['name'] as String? ?? '?',
    wins: j['wins'] as int? ?? 0,
    games: j['games'] as int? ?? 0,
    avgRank: (j['avgRank'] as num?)?.toDouble() ?? 0,
    // The id the server groups by. Carried so the row's avatar is derived from
    // the same value rather than from the display name, which two players may
    // share.
    seatId: j['seatId'] as String? ?? '',
  );

  final String name;
  final int wins; // first-place finishes
  final int games;
  final double avgRank; // lower is better; 1.0 = always first

  /// The id the server grouped by — the player's stable identity. Used to
  /// derive this row's avatar, so the face is tied to the player rather than
  /// to a display name two players may share. Empty on an older server that
  /// does not send it.
  final String seatId;
}

/// The parsed GET /leaderboard response.
class LeaderboardData {
  LeaderboardData({
    required this.games,
    required this.rows,
    this.game = 'all',
    this.gamesByGame = const {},
  });

  factory LeaderboardData.fromJson(Map<String, dynamic> j) => LeaderboardData(
    games: j['games'] as int? ?? 0,
    game: j['game'] as String? ?? 'all',
    gamesByGame: {
      for (final e in (j['gamesByGame'] as Map? ?? {}).entries)
        e.key as String: (e.value as num?)?.toInt() ?? 0,
    },
    rows: [
      for (final r in (j['players'] as List? ?? []))
        LeaderboardRow.fromJson(r as Map<String, dynamic>),
    ],
  );

  final int games; // total finished games on the server
  final List<LeaderboardRow> rows;

  /// Which game this board covers: 'ludo', 'snakes', or 'all' for the
  /// combined board. Older servers omit it, so 'all' is the default.
  final String game;

  /// Finished-game count per game, so the UI can label its tabs without a
  /// request per tab. Empty on older servers.
  final Map<String, int> gamesByGame;

  int get ludoGames => gamesByGame['ludo'] ?? 0;
  int get snakesGames => gamesByGame['snakes'] ?? 0;

  /// Whether the server told us the split. False on a server old enough to
  /// predate per-game boards, where the tabs would show nothing.
  bool get hasPerGameCounts => gamesByGame.isNotEmpty;
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
    this.credential = '',
    this.gameType = 'ludo',
    this.quickMatch = false,
    this.capacity = 4,
    WebSocketChannel Function(Uri uri)? channelFactory,
    this._voiceBackend,
  }) : _channelFactory = channelFactory ?? WebSocketChannel.connect;

  /// e.g. 'ws://localhost:8080/ws'
  final String serverUrl;
  final String seatId; // profile id — our identity across reconnects
  final String name;

  /// The friends credential paired with [seatId] — the device's private
  /// identity half. The friends server binds it to the seat id, so the
  /// friends calls this client's screens make carry it as `Authorization:
  /// Bearer`; the seat id alone stays the public roster value and proves
  /// nothing. Empty in the older constructions and most tests, which
  /// never touch the friends HTTP plane.
  final String credential;

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
  /// Patient by default, and patient for the same reason the socket is: a
  /// free-tier host that has been asleep *refuses* connections while it wakes
  /// rather than hanging on them, so every attempt here fails instantly and the
  /// whole budget is spent in seconds. A flat five 900ms gaps totalled about
  /// 4.5 seconds, which is not a cold start — Render's free box routinely takes
  /// tens of seconds — so a player who opened the leaderboard on a quiet server
  /// was told "could not reach" about a service that was merely asleep. The
  /// delay now doubles, matching the socket's 10-attempt budget.
  ///
  /// A 4xx is a settled answer and is never retried; only a refusal or a 5xx
  /// is worth waiting out.
  /// Whether a body plausibly holds the leaderboard JSON.
  ///
  /// Checked before decoding rather than by catching the decode failure, so
  /// the "wrong server" case can be told apart from a truncated or corrupt
  /// response.
  static bool _looksLikeJson(String body) =>
      body.trimLeft().startsWith('{') || body.trimLeft().startsWith('[');

  /// A short, safe description of what actually arrived, for the error body.
  static String _describeBody(String body) {
    final head = body.trimLeft();
    if (head.startsWith('<')) {
      return 'an HTML page — the server URL probably points at the web app '
          'instead of the game server';
    }
    return 'a ${body.length}-byte body that is not JSON';
  }

  static Future<LeaderboardData> fetchLeaderboard(
    String serverUrl, {
    String? game,
    http.Client? httpClient,
    Duration timeout = const Duration(seconds: 10),
    int attempts = 10,
    Duration retryDelay = const Duration(milliseconds: 400),
  }) async {
    final ws = Uri.parse(serverUrl);
    var base = ws.replace(
      scheme: ws.scheme == 'wss' ? 'https' : 'http',
      path: '/leaderboard',
    );
    // A server old enough to predate per-game boards ignores an unknown query
    // parameter and answers with its combined board, so sending one is safe
    // either way — a newer server narrows the board, an older one does not.
    if (game != null) {
      base = base.replace(queryParameters: {'game': game});
    }
    final client = httpClient ?? http.Client();
    try {
      Object? pending;
      for (var attempt = 0; attempt < attempts; attempt++) {
        // Doubling backoff: 400ms * (1+2+...+9) is ~18s of waiting, past a
        // free-tier cold start, while the early attempts stay quick so a server
        // that is only briefly busy is not made to wait.
        if (attempt > 0) {
          await Future<void>.delayed(retryDelay * (1 << (attempt - 1)));
        }
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
          if (resp.statusCode == 200 && !_looksLikeJson(resp.body)) {
            // A 200 that is not JSON is not a flaky answer, it is the wrong
            // server — and retrying it burns the whole cold-start budget before
            // failing with a bare FormatException that names nothing. The usual
            // cause: GAME_SERVER_URL was not baked into the build, so the
            // client asks its own origin, the SPA rule answers with
            // index.html, and a web page arrives where the API should be.
            throw LeaderboardServerException(
              resp.statusCode,
              'expected JSON, got ${_describeBody(resp.body)}',
            );
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

  /// Table size of the room: requested by the host at creation (this client
  /// when creating, absent joiners default), then replaced by the room's
  /// real value on every lobby feed — so a joiner who asked for nothing
  /// still displays the host's chosen "(n/size)".
  int capacity = 4;

  /// Latest authoritative snapshot, decoded. Null until the game starts.
  LudoState? state;

  /// Latest authoritative Snakes & Ladders snapshot (snakes rooms only).
  SnakesState? snakesState;
  int _seenRollSeq = 0;

  /// Fire-and-forget chat lines: (from, text).
  final chat = <ChatLine>[];

  /// Set when the server announces a seat event worth a toast — a walk-out,
  /// a timed-out turn — and cleared by [clearLeftNotice] once the screen has
  /// shown it. Kept on the client rather than folded into the seat list
  /// because a toast is a one-time event while the seat list is a standing
  /// fact — both are needed: the toast explains the moment, the list keeps
  /// the corner greyed out afterwards.
  String? leftNotice;

  /// How the seat in [leftNotice] left, set in the same breath and cleared
  /// with it: the alert that carries the line reads this instead of
  /// re-parsing the sentence.
  SeatExitKind? leftExit;

  void clearLeftNotice() {
    if (leftNotice == null) return;
    leftNotice = null;
    leftExit = null;
    notifyListeners();
  }

  /// The evicted seat's end card has been shown: consume the flag so later
  /// notifications (transport chatter, other notices) cannot show it twice.
  /// A fresh `joined` resets it, like [leftNotice]'s cache-cycle here.
  void clearMySeatEviction() => _mySeatEvicted = false;

  /// Milliseconds the on-turn seat has left to act, measured when the latest
  /// state broadcast was built. Null on any snapshot without a running
  /// timer (pre-timer servers, no game, nobody at the table). The screens
  /// count down from this locally instead of parsing server wall-clock.
  int? turnMs;

  /// Consecutive turn-timer misses per seat id, from the state broadcast.
  /// Empty when nothing has been missed — a table where everyone answers
  /// their clock carries no extra chatter.
  final seatMisses = <String, int>{};

  /// Miss count for [seatId] — zero until the server says otherwise.
  int missesOf(String seatId) => seatMisses[seatId] ?? 0;

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

  /// Whether a socket has ever reached `joined` since the last [connect].
  ///
  /// The discriminator between a refused connection and a dropped one. A
  /// refusal arrives before anything was ever established, and must spend the
  /// cold-start budget; a drop arrives after a good session and is the
  /// reconnect path's business. Both surface at [_onClosed], which is the only
  /// place that can tell them apart.
  bool _everEstablished = false;
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
    // A new attempt gets a new warm-up window; the old one is spent.
    _coldStartAttempts = 0;
    waitingForColdStart = false;
    _coldStartTimer?.cancel();
    // A fresh connect has established nothing yet, so its failures are
    // refusals again rather than drops.
    _everEstablished = false;
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

  /// Waits for the authoritative room code the server assigns with `joined`.
  ///
  /// [connect] resolves once the socket is open and the `hello` is sent; the
  /// code arrives on a later server message. Callers that read [roomCode]
  /// straight after awaiting [connect] will almost always see null — the
  /// inviter handoff did exactly that and tore down a room that was about to
  /// form. This waits for the code (or [timeout], returning null), and does
  /// not need the caller to listen for it.
  Future<String?> awaitRoomCode({
    Duration timeout = const Duration(seconds: 45),
  }) {
    final current = roomCode;
    if (current != null && current.isNotEmpty) return Future.value(current);
    final done = Completer<String?>();
    void seeCode() {
      final code = roomCode;
      if (code == null || code.isEmpty) return;
      if (!done.isCompleted) done.complete(code);
    }

    addListener(seeCode);
    return done.future
        .timeout(timeout, onTimeout: () => null)
        .whenComplete(() => removeListener(seeCode));
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
        // Room creators (and quick match, which creates too) name the table
        // size they want the room to close at. Join-with-code omits it: the
        // room already exists and joiners inherit its size.
        if (_joinCode == null || _joinCode!.isEmpty) 'players': capacity,
        if (_joinCode != null && _joinCode!.isNotEmpty) 'code': _joinCode,
        if (preferredColor != null) 'color': preferredColor.name,
        if (_spectating) 'spectate': true,
      });
    } catch (e) {
      // The socket was refused or reset. On a sleeping free-tier host this is
      // not a failure, it is a cold start: the platform is waking the process
      // and the proxy answers with an error until it is listening. Give it a
      // warm-up window rather than reporting "Could not reach server" to
      // someone who simply pressed Play a moment early.
      if (_userClosed) return;
      if (_scheduleColdStart()) return;
      waitingForColdStart = false;
      status = OnlineStatus.error;
      errorText =
          'Could not reach the game server.\n'
          'It may still be starting up — free hosting can take up to a '
          'minute after being idle. Try again in a moment.';
      notifyListeners();
    }
  }

  /// Books a cold-start re-probe. Returns false once the budget is spent, so
  /// the caller can fall through to reporting the failure.
  ///
  /// Split out of the `catch` in [_openAndHello] because the refusal has two
  /// shapes and both must spend the *same* budget:
  ///
  ///  * a synchronous throw from the channel factory, and
  ///  * the ordinary case — [WebSocketChannel.connect] hands back a channel
  ///    synchronously and only reports the failure later, as an error on the
  ///    stream.
  ///
  /// Only the first was caught. The second reached [_onClosed], which spends
  /// the *reconnect* budget: 5 attempts at 500ms doubling, 15.5s total, ending
  /// in "Connection lost — could not reach the server". That is shorter than
  /// the 22s cold-start window, and it reports a dropped connection for
  /// something that never connected — which is exactly what a player pressing
  /// Play against a sleeping free-tier host hits.
  bool _scheduleColdStart() {
    // The refusal arrives as both an error and a done event. Without this the
    // pair would book two re-probes and burn the window twice as fast.
    if (waitingForColdStart && _coldStartTimer?.isActive == true) return true;
    final attempt = _coldStartAttempts + 1;
    if (attempt > maxColdStartAttempts) return false;
    _coldStartAttempts = attempt;
    waitingForColdStart = true;
    // Back off gently: the host usually answers within a few seconds, and a
    // tight loop would just burn the window.
    final delay = coldStartBaseDelay * attempt;
    notifyListeners();
    _coldStartTimer?.cancel();
    _coldStartTimer = Timer(delay, _openAndHello);
    return true;
  }

  /// True while we are waiting out a sleeping host to wake. The UI shows a
  /// loader rather than an error, because nothing has actually gone wrong yet.
  bool waitingForColdStart = false;

  Timer? _coldStartTimer;
  int _coldStartAttempts = 0;

  /// How many times to re-probe before giving up. With the delay below this is
  /// 400ms * (1+2+...+10) = 22s of wake-up, comfortably past a free-tier cold
  /// start.
  static const maxColdStartAttempts = 10;

  /// First re-probe delay; each subsequent attempt doubles it. Not final so
  /// tests can shrink it rather than spend 22 seconds proving it gives up.
  static Duration coldStartBaseDelay = const Duration(milliseconds: 400);

  /// Re-opens the socket from an [OnlineStatus.error] surface, after the
  /// reconnect budget ran out. A live or connecting client has its own
  /// flow; a spent one sat ("Connection lost — could not reach the
  /// server") without a way back in. The room code rides along exactly
  /// like the reconnect path does, so the rejoin lands on the table again
  /// — finished mid-victory or not, the end screen greets what it finds.
  void retry() {
    assert(
      status == OnlineStatus.error || status == OnlineStatus.idle,
      'retry is for a spent connection, not for interrupting a live one',
    );
    _reconnectTimer?.cancel();
    _reconnectTimer = null;
    _reconnectAttempts = 0;
    _coldStartTimer?.cancel();
    _coldStartAttempts = 0;
    waitingForColdStart = false;
    status = OnlineStatus.connecting;
    errorText = null;
    notifyListeners();
    _openAndHello();
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
    // Never established: this is a refused first connection, not a drop.
    // WebSocketChannel.connect reports a refusal asynchronously, so it lands
    // here rather than in the catch above, and it used to be charged to the
    // reconnect budget below — 5 attempts, 15.5s, "Connection lost". A host
    // still waking from sleep routinely needs longer than that, so a player
    // creating a room on an idle free-tier server was told the connection had
    // dropped when in truth it had never opened. Spend the cold-start budget
    // instead, which is sized for exactly this wake-up.
    if (!_everEstablished) {
      if (_scheduleColdStart()) return;
      waitingForColdStart = false;
      status = OnlineStatus.error;
      errorText =
          'Could not reach the game server.\n'
          'It may still be starting up — free hosting can take up to a '
          'minute after being idle. Try again in a moment.';
      notifyListeners();
      return;
    }
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

  /// Feeds one raw server frame through the normal inbound path.
  ///
  /// Exists so tests can drive the client without standing up a WebSocket.
  /// The unread-dot rules are the kind of thing that silently regresses — they
  /// involve two pieces of state that have to agree — and a test that needs a
  /// live socket for them will simply not get written.
  @visibleForTesting
  void debugHandleMessage(dynamic data) => _onMessage(data);

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
        // The socket is live and the server owns us. From here on a close is a
        // drop, not a refusal.
        _everEstablished = true;
        // A cold-start re-probe succeeded, so stop claiming we are waiting for
        // a sleeping host. Without this the UI sits behind its loader even
        // though the room was created — the fix for "gave up too early" would
        // have introduced "never stops loading".
        if (waitingForColdStart) {
          waitingForColdStart = false;
          _coldStartTimer?.cancel();
          _coldStartTimer = null;
        }
        // Remember the room we were actually seated in so a quick-match
        // reconnect lands back with the same strangers, not a new match.
        _joinCode = roomCode;
        gameType = msg['game'] as String? ?? gameType;
        _spectating = msg['spectator'] as bool? ?? _spectating;
        final colorName = msg['color'] as String?;
        myColor = colorName == null ? null : LudoColor.values.byName(colorName);
        // A (re)join is a clean slate: whatever eviction this client saw
        // last belongs to the room we just left.
        _mySeatEvicted = false;
        status = OnlineStatus.inLobby;
        _reconnectAttempts = 0; // we're back on the wire
      case 'lobby':
        started = msg['started'] as bool? ?? false;
        // The room's table size, broadcast since creation. The host's
        // "waiting (n/size)" and the guest's agree — one value, one room.
        capacity = msg['capacity'] as int? ?? capacity;
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
        // Where the voice mesh follows the roster — but only for a join in
        // progress: pre-arming peers without a mic grants nothing and would
        // burn an RTCPeerConnection per seat for players who never speak.
        final v = _voice;
        if (v != null && v.enabled) {
          v.updateSeats(lobbySeats.map((s) => s.seatId).toSet(), seatId);
        }
      case 'voice':
        // Signalling for a session I joined; a client that never enabled
        // voice drops these (its mic is off, an unanswered offer is
        // exactly what the sender's ICE lifecycle already tolerates).
        final v = _voice;
        if (v != null) {
          unawaited(
            v.onSignal((
              k: msg['k'] as String,
              from: msg['from'] as String,
              s: msg['s'] as String,
            )),
          );
        }
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
        // The corner dots read their strikes from here as well. The last
        // seats frame before an eviction carries the fifth strike, and no
        // state frame ever follows it for the removed seat — without this
        // the dots show one strike fewer than the strip's miss chip.
        seatMisses
          ..clear()
          ..addAll({
            for (final s in (msg['seats'] as List? ?? []))
              if ((s as Map)['misses'] is num)
                (s['seatId'] as String): (s['misses'] as num).toInt(),
          });
        onSeats?.call();
      case 'left':
        // Worth a line of its own: without it a departing player's pieces
        // just stop moving and the reason stays invisible. A 'timeout'
        // reason is the turn timer's five-missed-turns eviction, and its
        // wording tells the table what actually happened to the seat. The
        // seat id rides along (older servers omit it) so a client can know
        // when the removal happened to ITS OWN seat — the one case where
        // staying on the board is staring at a game that dropped you.
        final reason = msg['reason'] as String?;
        final gone = msg['name'] as String? ?? 'A player';
        final goneSeat = msg['seatId'] as String? ?? '';
        final mine = goneSeat.isNotEmpty && goneSeat == seatId;
        _mySeatEvicted = mine && reason == 'timeout';
        // One decision, two surfaces: the words for the table and the kind
        // for the alert's glyph are set together and cleared together.
        leftExit = reason == 'timeout'
            ? SeatExitKind.removed
            : SeatExitKind.walkedOut;
        leftNotice = reason == 'timeout'
            ? (mine
                  ? 'You were removed — five turns missed'
                  : '$gone was removed — five turns missed')
            : (mine ? 'You left the game' : '$gone left the game');
        onLeft?.call(leftNotice!);
      case 'turnMissed':
        // Deliberately silent: the strike dots on the missed seat's corner
        // (fed by the `seats` frame) already answer "why did that turn
        // burn", and the turn clock above the plate answers "how long".
        // A toast repeating both at the top of the board reads as a third
        // state to keep in the corner of your eye, so the miss event is
        // consumed and no words appear. The server still sends the event —
        // removal notices below are the only miss story the table hears.
        break;
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
        // Turn-clock teardown: remaining milliseconds for the countdown
        // chip, and the standing per-seat miss counts the strip displays.
        turnMs = (msg['turnMs'] as num?)?.toInt();
        seatMisses.clear();
        final misses = msg['misses'];
        if (misses is Map) {
          for (final e in misses.entries) {
            if (e.value is num) {
              seatMisses[e.key as String] = (e.value as num).toInt();
            }
          }
        }
        started = true;
        status = OnlineStatus.playing;
      case 'turnTimer':
        // The freshly armed countdown for the seat on turn (arming happens
        // after a state change, so its own state snapshot cannot carry it).
        // Re-baselining the client chip here is the point — the deadline is
        // the seat's full window from right now.
        turnMs = (msg['turnMs'] as num?)?.toInt();
      case 'friendPulse':
        // The payload is deliberately empty: the watcher reads the state
        // bundle itself, so the socket never becomes a second source of
        // truth for requests or invites.
        onFriendsPulse?.call();
      case 'chat':
        final line = ChatLine.fromJson(msg, serverUrl: serverUrl);
        chat.add(line);
        // Unread only accumulates while the chat surface is closed. A message
        // that arrives while the reader is looking at it is read by
        // definition, and counting it would leave a dot that never clears.
        if (!chatOpen) {
          unreadChats += 1;
          // Audible, because a dot is easy to miss and the point of a message
          // is that it reaches you. Plays for unread arrivals only: while the
          // sheet is open you are already reading, and a chime per line would
          // be noise.
          onMessageArrived?.call(line);
        }
        onChat?.call(line);
      case 'roomClosed':
        // The authority dropped an abandoned room (grace period expired).
        errorText = 'The room has closed.';
        status = OnlineStatus.error;
        _userClosed = true;
        _teardownVoice();
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
        _teardownVoice();
        _channel?.sink.close();
        _channel = null;
    }
    notifyListeners();
  }

  /// The room is gone — there is no seat to hand a hangup to, so peers
  /// are closed without farewell and the mic is released. The joined
  /// state clears outright; the voice button flips to off.
  void _teardownVoice() {
    final v = _voice;
    if (v != null) unawaited(v.abandoned());
  }

  /// Hooks used by the session adapter (sounds, animation replay).
  void Function()? onRoll;
  void Function(LudoState? oldState, LudoState newState)? onState;
  void Function(SnakesState? oldState, SnakesState newState)? onSnakesState;

  /// Fired for each incoming chat line, with its sender and text, so the
  /// screen can raise a notification and repaint the unread dot.
  void Function(ChatLine message)? onChat;

  /// Whether the chat surface is on screen. The sheet sets this while it is
  /// open; the client only needs it to decide whether an arriving line is
  /// unread and whether to chime.
  bool chatOpen = false;

  /// Chat lines that arrived while [chatOpen] was false. Drives the red dot on
  /// the chat icon; cleared by [markChatRead] the moment the sheet opens.
  int unreadChats = 0;

  /// Called for each line that arrives while the chat is closed, so the view
  /// can play the notification. Separate from [onChat] on purpose: [onChat]
  /// fires for every line, and only the unread ones should make a noise.
  void Function(ChatLine message)? onMessageArrived;

  /// A server push that the friends picture moved — a new request or play
  /// invite. The app-level [InviteWatcher] owns the poll; this hook lets a
  /// live socket turn the next five-second beat into an immediate read.
  void Function()? onFriendsPulse;

  // ------------------------------------------------------- voice chat
  //
  // One VoiceRoom per client, created on first use. It outlives reconnects
  // (the P2P mesh carries on while the socket re-attaches) and dies with
  // the room session, not the widget tree — a board screen swap must not
  // end a call someone is still talking in.

  final VoiceBackend? _voiceBackend;
  VoiceRoom? _voice;

  VoiceBackend get _effectiveVoiceBackend =>
      _voiceBackend ?? FlutterVoiceBackend();

  bool get voiceJoined => _voice?.enabled ?? false;
  bool get voiceMuted => _voice?.muted ?? false;

  /// Seat ids believed to be speaking right now (self included when this
  /// voice is unmuted and the mic hears speech). Backs the speaking
  /// indicator; repaints ride the [VoiceRoom]'s change hook.
  Set<String> get voiceSpeaking => _voice?.speaking ?? const {};

  /// The speaking seats as display names for the indicator: this seat is
  /// "You", the rest resolve through the lobby roster, falling back to
  /// the raw seat id when the roster has never heard of them.
  List<String> get voiceSpeakingNames {
    final names = {for (final s in lobbySeats) s.seatId: s.name};
    return [
      for (final seat in voiceSpeaking)
        seat == seatId ? 'You' : (names[seat] ?? seat),
    ];
  }

  /// Seat ids whose audio peers are mounted right now.
  List<String> get voicePeers => _voice?.peers ?? const [];

  /// Whether the local mic is captured. Permission lives behind this:
  /// nothing (no audio element, no peer) is created before the user asks
  /// for voice, so the browser prompt only ever appears deliberately.
  VoiceRoom get voice => _voice ??= VoiceRoom(
    backend: _effectiveVoiceBackend,
    sendSignal: _sendVoiceSignal,
    onChanged: notifyListeners,
  );

  /// Joins the table voice. False when the mic was refused — the caller
  /// surfaces that rather than flipping the button into a silent state.
  Future<bool> joinVoice() async {
    if (_spectating) return false;
    // The seat roster must be known before offers are elected; feeding it
    // here ensures a join during a lagging lobby feed still meshes.
    voice.updateSeats(
      lobbySeats.map((s) => s.seatId).where((id) => id.isNotEmpty).toSet(),
      seatId,
    );
    return voice.enable();
  }

  /// Leaves the table voice and tells every peer so their side drops fast.
  Future<void> leaveVoice() => voice.disable();

  /// Local mute — toggles the track, sends nothing.
  void setVoiceMuted(bool muted) => voice.setMuted(muted);

  void _sendVoiceSignal(String k, String to, String s) {
    if (_spectating) return;
    _send({'type': 'voice', 'k': k, 'to': to, 's': s});
  }

  /// Show the chat. Reading and opening are the same act, so opening clears
  /// the unread count immediately rather than waiting for the sheet to close.
  void setChatOpen(bool open) {
    chatOpen = open;
    if (open) markChatRead();
  }

  void markChatRead() => unreadChats = 0;

  /// Seat-status changes (autoplay badges, corners emptied by a walk-out) and
  /// the walk-out announcement itself, which the screen turns into a toast.
  void Function()? onSeats;
  void Function(String notice)? onLeft;

  /// True the moment the server walked *this* seat out of the table — five
  /// consecutive turns missed on the turn timer. The server says so with the
  /// seat id riding the `left` broadcast, because "Ashutosh was removed"
  /// toward a table of two leaves one player knowing it is about them and
  /// the other arguing: the game screens read this to finish the exit the
  /// server started (a toast, then back to the lobby) instead of leaving
  /// the removed seat staring at a table it is no longer part of — which is
  /// exactly what looked like a frozen game when the other player already
  /// held their win.
  bool get mySeatEvicted => _mySeatEvicted;
  bool _mySeatEvicted = false;

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

  /// Sends a GIF chat line: the GIF's https URL, optionally with a caption
  /// (both go over the same 'chat' intent).
  void sendGif(String url, {String caption = ''}) => _spectating
      ? _noop()
      : _send({'type': 'chat', 'text': caption.trim(), 'gif': url});

  /// Uploads a recorded voice note to the server and announces it as a
  /// chat line. Two steps on purpose: the recording's bytes travel by
  /// HTTP (the socket only carries small JSON), and the announcement is a
  /// regular chat broadcast so unread counts, chimes and history all
  /// treat it like any other line. False when there is no room, the
  /// upload was refused, or the network had other plans — the caller
  /// says so instead of the composer silently swallowing a recording.
  Future<bool> sendVoiceNote({
    required List<int> bytes,
    required String mime,
    required int durMs,
    http.Client? httpClient,
  }) async {
    final code = roomCode;
    if (code == null || _spectating) return false;
    // An id the store's policy will accept: [a-z0-9-], unique enough that
    // two notes recorded in the same millisecond stay distinct.
    final id =
        '${DateTime.now().microsecondsSinceEpoch.toRadixString(36)}'
        '${Random().nextInt(1 << 24).toRadixString(36)}';
    final client = httpClient ?? http.Client();
    try {
      final res = await client.post(
        _httpOriginOf(
          serverUrl,
          '/media/voice',
        ).replace(queryParameters: {'room': code, 'id': id}),
        headers: {'content-type': mime, 'x-voice-duration': '$durMs'},
        body: bytes,
      );
      if (res.statusCode != 200) return false;
      _send({'type': 'chat', 'text': '', 'note': id});
      return true;
    } catch (_) {
      return false;
    } finally {
      if (httpClient == null) client.close();
    }
  }

  /// Uploads a keyboard-inserted GIF (Gboard, Samsung Keyboard — the
  /// IME's `commitContent` bytes) and announces it as a normal GIF chat
  /// line. Same two-step shape as [sendVoiceNote]: the bytes travel by
  /// HTTP because the socket only carries small JSON, and the
  /// announcement is an ordinary `'gif'` line so every client renders it
  /// through the same bubble it already knows. False when there is no
  /// room, the upload was refused, or the network had other plans — the
  /// composer owes the player a spoken failure, not silence.
  Future<bool> sendKeyboardGif({
    required List<int> bytes,
    required String mime,
    String caption = '',
    http.Client? httpClient,
  }) async {
    final code = roomCode;
    if (code == null || _spectating) return false;
    // An id the store's policy will accept: [a-z0-9-], unique enough that
    // two pastes in the same millisecond stay distinct.
    final id =
        '${DateTime.now().microsecondsSinceEpoch.toRadixString(36)}'
        '${Random().nextInt(1 << 24).toRadixString(36)}';
    final client = httpClient ?? http.Client();
    try {
      final res = await client.post(
        _httpOriginOf(
          serverUrl,
          '/media/image',
        ).replace(queryParameters: {'room': code, 'id': id}),
        headers: {'content-type': mime},
        body: bytes,
      );
      if (res.statusCode != 200) return false;
      final body = jsonDecode(res.body) as Map<String, dynamic>;
      final urlPath = body['url'] as String?;
      if (urlPath == null) return false;
      // The broadcast gate requires an absolute https URL, and the
      // relative serve path composes to one same-origin as this client.
      sendGif(_httpOriginOf(serverUrl, urlPath).toString(), caption: caption);
      return true;
    } catch (_) {
      return false;
    } finally {
      if (httpClient == null) client.close();
    }
  }

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
    _coldStartTimer?.cancel();
    waitingForColdStart = false;
    _reconnectTimer = null;
    // A deliberate leave: tell the peers we are going, then drop them —
    // the receivers stop playing instead of draining silence for a while.
    _teardownVoice();
    // Reflect the leave immediately so the UI doesn't flash a spinner
    // while the socket cleanup below settles.
    status = OnlineStatus.idle;
    notifyListeners();
    // Cancel rides detached: detaching the reader is synchronous-local
    // hygiene, and its future's completion is event-loop luggage the screen
    // (and anything awaiting a deliberate leave) should never hang on.
    unawaited(_sub?.cancel());
    _sub = null;
    await _channel?.sink.close();
    _channel = null;
  }

  @override
  void dispose() {
    _userClosed = true;
    _reconnectTimer?.cancel();
    _coldStartTimer?.cancel();
    _reconnectTimer = null;
    _teardownVoice();
    _sub?.cancel();
    _channel?.sink.close();
    super.dispose();
  }
}
