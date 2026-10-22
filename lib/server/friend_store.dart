/// Friend system persistence: mutual friend requests, the friend list,
/// one-to-one DMs (with likes and reply quotes), and play invites.
///
/// Identity is the player's seat id — the same stable value the WS hello,
/// the leaderboards and the admin Players tab already key on — carried by
/// every device's persisted online player id. Friend *discovery* runs on
/// generated friend codes: a short uppercase string minted once per
/// profile and shown in the Friends screen, because display names are not
/// unique but every profile owns exactly one code.
///
/// Trust model, stated plainly: a friends call asserts the caller's seat
/// id, exactly as the WebSocket `hello` does when a player claims a seat.
/// There is no account system to authenticate against, so these calls are
/// as "authenticated" as playing a game as yourself — the shared,
/// pre-existing identity plane. Abuse is bounded by the handler's per-IP
/// throttles, the store's per-seat caps, and admin bans (banned players
/// are refused on every friends endpoint). If accounts arrive, the right
/// fix is authenticating these handlers and keying the tables on user ids.
library;

import 'package:sqlite3/sqlite3.dart';

/// Games an invitation can point at — the two room types the authority
/// already seats.
const friendInviteGames = {'ludo', 'snakes'};

/// A player on the friends channel: their seat id, freshest display name,
/// and the friend code others use to find them.
class FriendProfile {
  FriendProfile({
    required this.seatId,
    required this.name,
    required this.code,
    required this.seenMs,
  });

  /// Builds a profile from a store row. Public for the remote backend,
  /// which decodes a pipeline row into a plain map before mapping it.
  FriendProfile.fromRow(Map<String, Object?> r)
    : this(
        seatId: r['seat_id'] as String,
        name: r['name'] as String,
        code: r['code'] as String,
        seenMs: r['seen_ms'] as int,
      );

  final String seatId;
  final String name;

  /// Unique, per-profile discovery code. Uppercase, no I/L/O/0/1.
  final String code;
  final int seenMs;

  Map<String, dynamic> toJson() => {
    'seatId': seatId,
    'name': name,
    'code': code,
    'lastSeen': seenMs,
  };
}

/// One accepted friendship, as seen from [seatId]'s side.
class FriendEntry {
  FriendEntry({
    required this.seatId,
    required this.name,
    required this.code,
    required this.sinceMs,
  });

  /// Builds an entry from a store row (remote backend row maps included).
  FriendEntry.fromRow(Map<String, Object?> r)
    : seatId = r['seat_id'] as String,
      name = r['name'] as String,
      code = r['code'] as String,
      sinceMs = r['since_ms'] as int;

  final String seatId;
  final String name;
  final String code;
  final int sinceMs;

  Map<String, dynamic> toJson() => {
    'seatId': seatId,
    'name': name,
    'code': code,
    'since': sinceMs,
  };
}

/// A pending friend request — incoming when [fromSeat] wants [toSeat]'s
/// friendship, outgoing when [fromSeat] asked and [toSeat] has not
/// answered. Names and codes are snapshotted at send time so the request
/// stays readable even if the sender never registers again.
class FriendRequest {
  FriendRequest({
    required this.id,
    required this.fromSeat,
    required this.fromName,
    required this.fromCode,
    required this.toSeat,
    required this.toName,
    required this.toCode,
    required this.createdAtMs,
  });

  /// Builds a request from a store row (remote backend row maps included).
  FriendRequest.fromRow(Map<String, Object?> r)
    : this(
        id: r['id'] as int,
        fromSeat: r['from_seat'] as String,
        fromName: r['from_name'] as String,
        fromCode: r['from_code'] as String,
        toSeat: r['to_seat'] as String,
        toName: r['to_name'] as String,
        toCode: r['to_code'] as String,
        createdAtMs: r['created_ms'] as int,
      );

  final int id;
  final String fromSeat;
  final String fromName;
  final String fromCode;
  final String toSeat;
  final String toName;
  final String toCode;
  final int createdAtMs;

  Map<String, dynamic> toJson() => {
    'id': id,
    'from': {'seatId': fromSeat, 'name': fromName, 'code': fromCode},
    'to': {'seatId': toSeat, 'name': toName, 'code': toCode},
    'createdAt': createdAtMs,
  };
}

/// One DM. [replyToId] (with the cached [replyFrom] / [replyBody] quote)
/// marks a reply to an earlier message; the quote is a snapshot rather
/// than a live join so it stays readable even after the quoted row is
/// moderated away.
class FriendMessage {
  FriendMessage({
    required this.id,
    required this.fromSeat,
    required this.toSeat,
    required this.body,
    required this.liked,
    required this.createdAtMs,
    this.replyToId,
    this.replyFrom = '',
    this.replyBody = '',
  });

  /// Builds a message from a store row (remote backend row maps included).
  FriendMessage.fromRow(Map<String, Object?> r)
    : this(
        id: r['id'] as int,
        fromSeat: r['from_seat'] as String,
        toSeat: r['to_seat'] as String,
        body: r['body'] as String,
        liked: (r['liked'] as int?) == 1,
        createdAtMs: r['created_ms'] as int,
        replyToId: r['reply_to'] as int?,
        replyFrom: r['reply_from'] as String? ?? '',
        replyBody: r['reply_body'] as String? ?? '',
      );

  final int id;
  final String fromSeat;

  /// The other side of the pair (for any participant's perspective).
  final String toSeat;
  final String body;
  final bool liked;
  final int createdAtMs;

  final int? replyToId;

  /// Quote snapshot as of send time: the quoted message's author and body.
  final String replyFrom;
  final String replyBody;

  /// True when [participant] sent this message.
  bool fromIs(String participant) => fromSeat == participant;

  Map<String, dynamic> toJson() => {
    'id': id,
    'from': fromSeat,
    'to': toSeat,
    'body': body,
    'liked': liked,
    'createdAt': createdAtMs,
    if (replyToId != null) 'replyTo': replyToId,
    if (replyToId != null) 'replyFrom': replyFrom,
    if (replyToId != null) 'replyBody': replyBody,
  };
}

/// One play invite. [status]: 'pending' until the invitee answers (or it
/// expires), then 'accepted', 'declined' or 'expired'.
class FriendInvite {
  FriendInvite({
    required this.id,
    required this.fromSeat,
    required this.fromName,
    required this.toSeat,
    required this.game,
    required this.status,
    required this.createdAtMs,
    this.code,
  });

  /// Builds an invite from a store row (remote backend row maps included).
  FriendInvite.fromRow(Map<String, Object?> r)
    : this(
        id: r['id'] as int,
        fromSeat: r['from_seat'] as String,
        fromName: r['from_name'] as String,
        toSeat: r['to_seat'] as String,
        game: r['game'] as String,
        status: r['status'] as String,
        createdAtMs: r['created_ms'] as int,
        code: r['code'] as String?,
      );

  final int id;
  final String fromSeat;
  final String fromName;
  final String toSeat;
  final String game;

  /// The room code the invitee should join, null while the inviter's room
  /// is still being claimed on the game server.
  final String? code;
  final String status;
  final int createdAtMs;

  bool get isPending => status == 'pending';

  Map<String, dynamic> toJson() => {
    'id': id,
    'from': {'seatId': fromSeat, 'name': fromName},
    'game': game,
    if (code != null) 'code': code,
    'status': status,
    'createdAt': createdAtMs,
  };
}

/// A page of DM history: the messages in send order plus the pair's
/// highest message id — the value a client stores as its read marker.
class FriendChatPage {
  FriendChatPage({required this.messages, required this.latestId});

  final List<FriendMessage> messages;

  /// 0 when the pair has no messages; the client's first ever read then
  /// marks "everything up to here" cleanly.
  final int latestId;
}

/// Row caps the store enforces (and the Friends screen quotes).
class FriendCaps {
  static const friendsPerSeat = 200;
  static const pendingPerSeat = 50;
  static const invitesPerSeat = 20;

  /// Blocks one seat may hold.
  static const blocksPerSeat = 200;

  /// Identity caps: a trimmed, non-empty seat id and display name are
  /// required; a too-long display name is clamped, not rejected.
  static const maxNameLength = 60;
  static const maxMessageLength = 1000;

  /// DM history kept per pair; older rows are trimmed on every send.
  static const chatHistoryPerPair = 200;

  /// An invite older than this is expired on read — an invite is a table
  /// held for you, not a permanent letter.
  static const inviteLifetime = Duration(hours: 2);
}

/// A pair-affecting hold the store itself may place on existent rows.
class FriendBlock {
  FriendBlock({
    required this.blocker,
    required this.blocked,
    required this.blockedName,
    required this.createdAtMs,
  });

  /// Builds a block from a store row (remote backend row maps included).
  FriendBlock.fromRow(Map<String, Object?> r)
    : blocker = r['blocker'] as String,
      blocked = r['blocked'] as String,
      blockedName = r['blocked_name'] as String? ?? '',
      createdAtMs = r['created_ms'] as int;

  final String blocker;
  final String blocked;

  /// The blocked profile's name as of the block — the row survives a
  /// profile-less world and reads well in the "blocked" list.
  final String blockedName;
  final int createdAtMs;

  Map<String, dynamic> toJson() => {
    'seatId': blocked,
    'name': blockedName,
    'blockedAt': createdAtMs,
  };
}

/// The friends persistence contract.
///
/// Two backends implement it:
///
/// * [SqliteFriendStore] — the local SQLite file (the default), also used
///   by tests and by local development with no Turso configured.
/// * [TursoFriendStore] (`turso_friend_store.dart`) — a hosted Turso/libSQL
///   database over its HTTP pipeline API, so friendships survive a redeploy
///   on an ephemeral host. It reads the same `TURSO_DATABASE_URL` +
///   `TURSO_AUTH_TOKEN` variables the leaderboard and room registry use.
///
/// All identity, caps, ordering, and error semantics live here: a backend
/// must preserve them exactly so the HTTP handlers stay wire-compatible.
abstract interface class FriendStore {
  /// Blocks one seat may hold (also quoted by the admin panel).
  static const blocksPerSeat = FriendCaps.blocksPerSeat;

  /// Registers (or refreshes) the caller's profile and returns it. The
  /// friend code is minted on first sight and never re-issued.
  Future<FriendProfile> serve(String seatId, String name);

  /// The profile for [seatId], if that player ever registered.
  Future<FriendProfile?> profile(String seatId);

  /// The profile owning [code] (case-insensitive), if any.
  Future<FriendProfile?> profileByCode(String code);

  /// Resolves a 6-char uppercase friend code or a bare seat id.
  Future<FriendProfile?> resolveTarget(String target);

  /// True when the pair has an accepted friendship.
  Future<bool> areFriends(String a, String b);

  /// Number of accepted friends [seatId] has.
  Future<int> friendCount(String seatId);

  /// Sends a request, or returns `'accepted'` when the reverse pending
  /// request already exists. Returns `'pending'` otherwise.
  Future<String> sendRequest(
    String fromSeat,
    String fromName,
    String target, {
    String? targetName,
  });

  /// Accepts or declines a pending request addressed to [seatId].
  Future<bool> respond(String seatId, int requestId, {required bool accept});

  /// Withdraws an outgoing request (the "Sent" side cancels).
  Future<bool> cancel(String fromSeat, int requestId);

  /// Deletes the friendship between [a] and [b], whichever side breaks it.
  Future<bool> remove(String a, String b);

  /// All accepted friends of [seatId] (alphabetical by name).
  Future<List<FriendEntry>> friends(String seatId);

  /// True when [blocker] has blocked [about].
  Future<bool> isBlocked(String blocker, String about);

  /// Blocks [about] for [blocker]: severs the friendship, drops pending
  /// requests/invites between them, and denies future contact. Idempotent.
  Future<bool> block(String blocker, String about, {String? targetName});

  /// Lifts a block. True when one actually existed.
  Future<bool> unblock(String blocker, String about);

  /// Who [seatId] has blocked (newest block first).
  Future<List<FriendBlock>> blocks(String seatId);

  /// Requests addressed TO [seatId], oldest first.
  Future<List<FriendRequest>> incoming(String seatId);

  /// Requests [seatId] sent which have not been answered.
  Future<List<FriendRequest>> outgoing(String seatId);

  /// One DM by id, if it still exists.
  Future<FriendMessage?> message(int id);

  /// Sends a DM between friends, optionally quoting an earlier message.
  Future<FriendMessage> send(
    String fromSeat,
    String toSeat,
    String body, {
    int? replyTo,
  });

  /// History for the pair in send order, newest page when [since] is null.
  Future<FriendChatPage> chat(
    String seatId,
    String peer, {
    int? since,
    int limit = 50,
  });

  /// The highest message id on the pair (0 when they have no messages).
  Future<int> latestMessageId(String seatId, String peer);

  /// The highest message id with every peer [seatId] has a DM with, keyed
  /// by the peer seat id. One read for the whole friend list: a remote
  /// backend must not need one round trip per friend.
  Future<Map<String, int>> latestMessageIds(String seatId);

  /// Sets (or clears) the like on a message; null when the caller is not a
  /// participant (or the message is gone).
  Future<FriendMessage?> like(
    String seatId,
    int messageId, {
    required bool liked,
  });

  /// Records a play invite, superseding any earlier pending invite between
  /// the same pair.
  Future<FriendInvite> sendInvite(
    String fromSeat,
    String fromName,
    String toSeat,
    String game, {
    String? code,
  });

  /// The invitee answers. Accept returns the room code (null when none).
  Future<String?> respondInvite(
    String seatId,
    int inviteId, {
    required bool accept,
  });

  /// Invites addressed to [seatId] (pending first, newest first), expiring
  /// stale pendings in place on read.
  Future<List<FriendInvite>> invites(String seatId);

  /// Releases backend resources (database handles, HTTP clients).
  void close();
}

/// SQLite-backed [FriendStore]: open with a file path for persistence,
/// [SqliteFriendStore.inMemory] for tests, or [SqliteFriendStore.withClock]
/// when a test needs deterministic invite expiry.
class SqliteFriendStore implements FriendStore {
  SqliteFriendStore._(
    this._db, {
    required bool owns,
    DateTime Function()? clock,
  }) : _ownsDb = owns,
       _now = clock ?? DateTime.now {
    _migrate();
  }

  factory SqliteFriendStore.inMemory() =>
      SqliteFriendStore._(sqlite3.openInMemory(), owns: true);

  factory SqliteFriendStore(String path) =>
      SqliteFriendStore._(sqlite3.open(path), owns: true);

  factory SqliteFriendStore.withClock(DateTime Function() clock) =>
      SqliteFriendStore._(sqlite3.openInMemory(), owns: true, clock: clock);

  /// Shares the production connection: one SQLite file for everything the
  /// dashboard shows, exactly like the report store.
  factory SqliteFriendStore.fromDb(Database db, {DateTime Function()? clock}) =>
      SqliteFriendStore._(db, owns: false, clock: clock);

  final Database _db;
  final bool _ownsDb;

  /// Injectable!
  final DateTime Function() _now;

  int get _nowMs => _now().millisecondsSinceEpoch;

  void _migrate() {
    _db.execute('''
      CREATE TABLE IF NOT EXISTS friend_profiles (
        seat_id TEXT PRIMARY KEY,
        name TEXT NOT NULL,
        code TEXT NOT NULL UNIQUE,
        seen_ms INTEGER NOT NULL
      );
      CREATE TABLE IF NOT EXISTS friendships (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        seat_a TEXT NOT NULL,
        seat_b TEXT NOT NULL,
        since_ms INTEGER NOT NULL,
        UNIQUE(seat_a, seat_b)
      );
      CREATE INDEX IF NOT EXISTS idx_friendships_a ON friendships(seat_a);
      CREATE INDEX IF NOT EXISTS idx_friendships_b ON friendships(seat_b);
      CREATE TABLE IF NOT EXISTS friend_requests (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        from_seat TEXT NOT NULL,
        from_name TEXT NOT NULL,
        from_code TEXT NOT NULL,
        to_seat TEXT NOT NULL,
        to_name TEXT NOT NULL,
        to_code TEXT NOT NULL,
        created_ms INTEGER NOT NULL,
        UNIQUE(from_seat, to_seat)
      );
      CREATE INDEX IF NOT EXISTS idx_friend_requests_to
          ON friend_requests(to_seat);
      CREATE TABLE IF NOT EXISTS friend_messages (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        from_seat TEXT NOT NULL,
        to_seat TEXT NOT NULL,
        body TEXT NOT NULL,
        liked INTEGER NOT NULL DEFAULT 0,
        reply_to INTEGER,
        reply_from TEXT NOT NULL DEFAULT '',
        reply_body TEXT NOT NULL DEFAULT '',
        created_ms INTEGER NOT NULL
      );
      CREATE INDEX IF NOT EXISTS idx_friend_messages_pair
          ON friend_messages(from_seat, to_seat);
      CREATE INDEX IF NOT EXISTS idx_friend_messages_rev
          ON friend_messages(to_seat, from_seat);
      CREATE TABLE IF NOT EXISTS friend_invites (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        from_seat TEXT NOT NULL,
        from_name TEXT NOT NULL,
        to_seat TEXT NOT NULL,
        game TEXT NOT NULL,
        code TEXT,
        status TEXT NOT NULL DEFAULT 'pending',
        created_ms INTEGER NOT NULL,
        updated_ms INTEGER NOT NULL
      );
      CREATE INDEX IF NOT EXISTS idx_friend_invites_to
          ON friend_invites(to_seat);
      CREATE TABLE IF NOT EXISTS friend_blocks (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        blocker TEXT NOT NULL,
        blocked TEXT NOT NULL,
        blocked_name TEXT NOT NULL DEFAULT '',
        created_ms INTEGER NOT NULL,
        UNIQUE(blocker, blocked)
      );
      CREATE INDEX IF NOT EXISTS idx_friend_blocks_blocker
          ON friend_blocks(blocker);
    ''');
  }

  /// Test-only: drops every friend row, so tests can start from a blank
  /// record. Not part of the deployment surface — the stores are created
  /// fresh there.
  void clearAll() {
    for (final t in [
      'friend_profiles',
      'friendships',
      'friend_requests',
      'friend_messages',
      'friend_invites',
      'friend_blocks',
    ]) {
      _db.execute('DELETE FROM $t');
    }
  }

  // ------------------------------------------------------------- identity

  /// The per-call identity: a trimmed, non-empty seat id and display name,
  /// the name clamped rather than rejected (a too-long display name is a
  /// trimming job, not an error).
  (String, String) _checkCaller(String seatId, String name) {
    final id = seatId.trim();
    final nm = name.trim();
    if (id.isEmpty) throw ArgumentError('seatId required');
    if (nm.isEmpty) throw ArgumentError('name required');
    return (id, nm.substring(0, nm.length.clamp(0, FriendCaps.maxNameLength)));
  }

  /// Registers (or refreshes) the caller's profile and returns it. The
  /// friend code is minted on first sight and never re-issued — everyone
  /// who has ever seen the code must keep finding the same profile.
  @override
  Future<FriendProfile> serve(String seatId, String name) async {
    final (id, nm) = _checkCaller(seatId, name);
    final now = _nowMs;
    final existing = await profile(id);
    if (existing != null) {
      if (existing.name != nm) {
        _db.execute(
          'UPDATE friend_profiles SET name = ?, seen_ms = ? WHERE seat_id = ?',
          [nm, now, id],
        );
      } else {
        _db.execute(
          'UPDATE friend_profiles SET seen_ms = ? WHERE seat_id = ?',
          [now, id],
        );
      }
      return (await profile(id))!;
    }
    for (var attempt = 0; attempt < 8; attempt++) {
      final code = _generateCode(attempt);
      try {
        _db.execute(
          'INSERT INTO friend_profiles (seat_id, name, code, seen_ms) '
          'VALUES (?, ?, ?, ?)',
          [id, nm, code, now],
        );
        return (await profile(id))!;
      } on SqliteException {
        // Unique clash on `code` — rare among ~500M possibilities, but a
        // retry is four lines. A concurrent registration of the same seat
        // has inserted the seat_id row already: the re-read then wins.
        final raced = await profile(id);
        if (raced != null && raced.seatId == id) return raced;
      }
    }
    throw StateError('could not mint a unique friend code');
  }

  @override
  Future<FriendProfile?> profile(String seatId) async {
    final rows = _db.select(
      'SELECT seat_id, name, code, seen_ms FROM friend_profiles '
      'WHERE seat_id = ?',
      [seatId.trim()],
    );
    return rows.isEmpty ? null : FriendProfile.fromRow(rows.first);
  }

  @override
  Future<FriendProfile?> profileByCode(String code) async {
    final c = code.trim().toUpperCase();
    if (c.length != 6) return null;
    final rows = _db.select(
      'SELECT seat_id, name, code, seen_ms FROM friend_profiles '
      'WHERE code = ?',
      [c],
    );
    return rows.isEmpty ? null : FriendProfile.fromRow(rows.first);
  }

  /// Resolves an add-friend target: a 6-char uppercase token (the code
  /// alphabet only) is a friend code, anything else is a seat id.
  @override
  Future<FriendProfile?> resolveTarget(String target) async {
    final t = target.trim();
    if (t.isEmpty) return null;
    final looksLikeCode =
        t.length == 6 && RegExp(r'^[2-9A-HJ-NP-Z]+$').hasMatch(t);
    return looksLikeCode ? profileByCode(t) : profile(t);
  }

  static const _codeChars =
      '23456789ABCDEFGHJKMNPQRSTUVWXYZ'; // reads aloud cleanly

  String _generateCode([int attempt = 0]) {
    var seed = DateTime.now().microsecondsSinceEpoch ^ (attempt * 7919);
    final out = StringBuffer();
    for (var i = 0; i < 6; i++) {
      seed = (seed * 1103515245 + 12345) & 0x7fffffff;
      out.write(_codeChars[seed % _codeChars.length]);
    }
    return out.toString();
  }

  // -------------------------------------------------------- relationships

  Future<FriendProfile> _requireProfile(String seatId) async =>
      (await profile(seatId)) ??
      (throw ArgumentError('unknown player $seatId'));

  (String lo, String hi) _pairOf(String a, String b) =>
      a.compareTo(b) <= 0 ? (a, b) : (b, a);

  @override
  Future<bool> areFriends(String a, String b) async {
    final (lo, hi) = _pairOf(a.trim(), b.trim());
    return _db.select(
      'SELECT id FROM friendships WHERE seat_a = ? AND seat_b = ?',
      [lo, hi],
    ).isNotEmpty;
  }

  @override
  Future<int> friendCount(String seatId) async {
    final s = seatId.trim();
    return _db.select(
          'SELECT COUNT(*) AS n FROM friendships WHERE seat_a = ? OR seat_b = ?',
          [s, s],
        ).first['n']
        as int;
  }

  /// Sends a request, or returns 'accepted' when the reverse pending
  /// request already exists: two players who both pressed add are friends
  /// the moment they match, which is what players read as intent.
  ///
  /// A target shaped like a friend code must resolve to a minted profile.
  /// A bare seat id resolves the same way — unless that player has never
  /// opened the friends surface and has no profile yet, which is the
  /// normal case for a tablemate met mid-game: with [targetName] supplied
  /// (the roster name the room already shows), their profile mints here
  /// instead of failing, and heals the moment their own friends call
  /// re-registers them under their own name. Without it, the miss is an
  /// answer ("no player matches"), as before.
  ///
  /// Throws [ArgumentError] for malformed/unknown targets and [StateError]
  /// with a user-presentable reason for relationship states (self, already
  /// friends, blocked, list full, caps) — the handler maps both to 400s.
  @override
  Future<String> sendRequest(
    String fromSeat,
    String fromName,
    String target, {
    String? targetName,
  }) async {
    final (from, nm) = _checkCaller(fromSeat, fromName);
    var to = await resolveTarget(target);
    if (to == null) {
      final mintName = (targetName ?? '').trim();
      final looksLikeCode =
          target.trim().length == 6 &&
          RegExp(r'^[2-9A-HJ-NP-Z]+$').hasMatch(target.trim());
      // Codes must be minted by their owner (a code is proof the player
      // shared it); a seat id plus roster name mints the tablemate.
      if (mintName.isNotEmpty && !looksLikeCode) {
        to = await serve(target, mintName);
      }
    }
    if (to == null) {
      throw ArgumentError('no player matches "$target"');
    }
    if (from == to.seatId) throw StateError('you cannot friend yourself');
    if (await isBlocked(from, to.seatId)) {
      throw StateError('you blocked this player — unblock to add them');
    }
    if (await isBlocked(to.seatId, from)) {
      throw ArgumentError('that player is not accepting friend requests');
    }
    if (await areFriends(from, to.seatId)) throw StateError('already friends');
    if (await friendCount(from) >= FriendCaps.friendsPerSeat) {
      throw StateError(
        'your friend list is full (max ${FriendCaps.friendsPerSeat})',
      );
    }
    if (await friendCount(to.seatId) >= FriendCaps.friendsPerSeat) {
      throw StateError('${to.name} can accept no more friends');
    }
    final mine = _db.select(
      'SELECT id FROM friend_requests WHERE from_seat = ? AND to_seat = ?',
      [from, to.seatId],
    ).isNotEmpty;
    if (mine) return 'pending';
    final reverse = _db.select(
      'SELECT id FROM friend_requests WHERE from_seat = ? AND to_seat = ?',
      [to.seatId, from],
    );
    if (reverse.isNotEmpty) {
      return _acceptRequest(from, reverse.first['id'] as int)
          ? 'accepted'
          : 'pending';
    }
    void pendingCap(String seat) {
      final n =
          _db.select(
                'SELECT COUNT(*) AS n FROM friend_requests '
                'WHERE from_seat = ? OR to_seat = ?',
                [seat, seat],
              ).first['n']
              as int;
      if (n >= FriendCaps.pendingPerSeat) {
        throw StateError('too many pending requests — wait for replies');
      }
    }

    pendingCap(from);
    pendingCap(to.seatId);
    final now = _nowMs;
    _db.execute(
      'INSERT INTO friend_requests '
      '(from_seat, from_name, from_code, to_seat, to_name, to_code, created_ms) '
      'VALUES (?, ?, ?, ?, ?, ?, ?)',
      [from, nm, (await profile(from))!.code, to.seatId, to.name, to.code, now],
    );
    return 'pending';
  }

  /// Accepts a request addressed to [seatId], creating the friendship and
  /// clearing any mirror row the pair had already sent. Idempotent.
  bool _acceptRequest(String seatId, int requestId) {
    final rows = _db.select(
      'SELECT from_seat, to_seat FROM friend_requests '
      'WHERE id = ? AND to_seat = ?',
      [requestId, seatId.trim()],
    );
    if (rows.isEmpty) return false;
    final from = rows.first['from_seat'] as String;
    final to = rows.first['to_seat'] as String;
    _db.execute('DELETE FROM friend_requests WHERE id = ?', [requestId]);
    _db.execute(
      'DELETE FROM friend_requests WHERE from_seat = ? AND to_seat = ?',
      [to, from],
    );
    final (lo, hi) = _pairOf(from, to);
    _db.execute(
      'INSERT OR IGNORE INTO friendships (seat_a, seat_b, since_ms) '
      'VALUES (?, ?, ?)',
      [lo, hi, _nowMs],
    );
    return true;
  }

  /// Accepts or declines a pending request addressed to [seatId].
  @override
  Future<bool> respond(
    String seatId,
    int requestId, {
    required bool accept,
  }) async {
    if (accept) return _acceptRequest(seatId, requestId);
    _db.execute('DELETE FROM friend_requests WHERE id = ? AND to_seat = ?', [
      requestId,
      seatId.trim(),
    ]);
    return true;
  }

  /// Withdraws an outgoing request (the "Sent" side cancels).
  @override
  Future<bool> cancel(String fromSeat, int requestId) {
    _db.execute('DELETE FROM friend_requests WHERE id = ? AND from_seat = ?', [
      requestId,
      fromSeat.trim(),
    ]);
    return Future.value(true);
  }

  /// Releases the database handle when this store owns it (in-memory and
  /// path-backed constructors); a shared-production connection is left to
  /// its owner, mirroring the report store.
  @override
  void close() {
    if (_ownsDb) _db.close();
  }

  /// Deletes the friendship between [a] and [b], whichever side breaks it.
  @override
  Future<bool> remove(String a, String b) {
    final (lo, hi) = _pairOf(a.trim(), b.trim());
    _db.execute('DELETE FROM friendships WHERE seat_a = ? AND seat_b = ?', [
      lo,
      hi,
    ]);
    return Future.value(true);
  }

  /// All accepted friends of [seatId] (alphabetical by name).
  @override
  Future<List<FriendEntry>> friends(String seatId) async {
    final s = seatId.trim();
    final mine = _db.select(
      'SELECT f.seat_id AS seat_id, f.name AS name, f.code AS code, '
      's.since_ms AS since_ms FROM friendships s '
      'JOIN friend_profiles f ON f.seat_id = s.seat_a WHERE s.seat_b = ?'
      ' UNION ALL '
      'SELECT f.seat_id AS seat_id, f.name AS name, f.code AS code, '
      's.since_ms AS since_ms FROM friendships s '
      'JOIN friend_profiles f ON f.seat_id = s.seat_b WHERE s.seat_a = ?',
      [s, s],
    );
    final list = [for (final r in mine) FriendEntry.fromRow(r)]
      ..sort((x, y) => x.name.toLowerCase().compareTo(y.name.toLowerCase()));
    return list;
  }

  // -------------------------------------------------------------- blocking

  /// True when [blocker] has blocked [about].
  @override
  Future<bool> isBlocked(String blocker, String about) async => _db.select(
    'SELECT id FROM friend_blocks WHERE blocker = ? AND blocked = ?',
    [blocker.trim(), about.trim()],
  ).isNotEmpty;

  /// True when EITHER side has blocked the other — both directions deny
  /// contact; being blocked by someone you never blocked reads identical
  /// to being blocked by someone you did, by design (the other side's
  /// action is never angled for).
  Future<bool> _blockedBetween(String a, String b) async =>
      await isBlocked(a, b) || await isBlocked(b, a);

  /// Blocks [about] for [blocker]: severs the friendship (if any), drops
  /// every pending request or invite between them, and denies all future
  /// contact until unblocked. Idempotent.
  ///
  /// [targetName] mints a profile for a seat id that never produced one
  /// (a tablemate who has never opened the friends screen) with the roster
  /// name the room shows — the block must not depend on the target having
  /// visited a menu. Codes still stay unmintable: only the owner mints a
  /// code. The minted name self-heals on the target's own next friends call.
  @override
  Future<bool> block(String blocker, String about, {String? targetName}) async {
    final by = blocker.trim();
    final them = about.trim();
    if (by.isEmpty || them.isEmpty) {
      throw ArgumentError('seat and target required');
    }
    if (by == them) throw StateError('you cannot block yourself');
    await _requireProfile(by);
    if (await profile(them) == null) {
      final mintName = (targetName ?? '').trim();
      final looksLikeCode =
          them.length == 6 && RegExp(r'^[2-9A-HJ-NP-Z]+$').hasMatch(them);
      if (mintName.isNotEmpty && !looksLikeCode) {
        await serve(them, mintName);
      }
    }
    await _requireProfile(them);
    final n =
        _db.select(
              'SELECT COUNT(*) AS n FROM friend_blocks WHERE blocker = ?',
              [by],
            ).first['n']
            as int;
    if (!await isBlocked(by, them) && n >= FriendCaps.blocksPerSeat) {
      throw StateError('too many blocked players');
    }
    final (lo, hi) = _pairOf(by, them);
    _db.execute('DELETE FROM friendships WHERE seat_a = ? AND seat_b = ?', [
      lo,
      hi,
    ]);
    _db.execute(
      'DELETE FROM friend_requests WHERE (from_seat = ?1 AND to_seat = ?2) '
      'OR (from_seat = ?2 AND to_seat = ?1)',
      [by, them],
    );
    _db.execute(
      "DELETE FROM friend_invites WHERE status = 'pending' AND "
      '((from_seat = ?1 AND to_seat = ?2) OR (from_seat = ?2 AND to_seat = ?1))',
      [by, them],
    );
    if (!await isBlocked(by, them)) {
      final name = (await profile(them))?.name ?? '';
      _db.execute(
        'INSERT INTO friend_blocks (blocker, blocked, blocked_name, created_ms) '
        'VALUES (?, ?, ?, ?)',
        [by, them, name, _nowMs],
      );
    }
    return true;
  }

  /// Lifts a block. True when one actually existed.
  @override
  Future<bool> unblock(String blocker, String about) async {
    _db.execute('DELETE FROM friend_blocks WHERE blocker = ? AND blocked = ?', [
      blocker.trim(),
      about.trim(),
    ]);
    return _db.updatedRows > 0;
  }

  /// Who [seatId] has blocked (with names as of the block moment).
  @override
  Future<List<FriendBlock>> blocks(String seatId) async {
    final rows = _db.select(
      'SELECT blocker, blocked, blocked_name, created_ms FROM friend_blocks '
      'WHERE blocker = ? ORDER BY created_ms DESC',
      [seatId.trim()],
    );
    return [for (final r in rows) FriendBlock.fromRow(r)];
  }

  /// Requests addressed TO [seatId], oldest first.
  @override
  Future<List<FriendRequest>> incoming(String seatId) async => [
    for (final r in _requests('to_seat', seatId.trim())) r,
  ];

  /// Requests [seatId] sent which have not been answered.
  @override
  Future<List<FriendRequest>> outgoing(String seatId) async => [
    for (final r in _requests('from_seat', seatId.trim())) r,
  ];

  Iterable<FriendRequest> _requests(String column, String seatId) {
    assert(column == 'to_seat' || column == 'from_seat');
    final rows = _db.select(
      'SELECT id, from_seat, from_name, from_code, to_seat, to_name, '
      'to_code, created_ms FROM friend_requests WHERE $column = ? '
      'ORDER BY created_ms ASC',
      [seatId],
    );
    return [for (final r in rows) FriendRequest.fromRow(r)];
  }

  // ------------------------------------------------------------------ chat

  @override
  Future<FriendMessage?> message(int id) async {
    final rows = _db.select(
      'SELECT id, from_seat, to_seat, body, liked, reply_to, reply_from, '
      'reply_body, created_ms FROM friend_messages WHERE id = ?',
      [id],
    );
    return rows.isEmpty ? null : FriendMessage.fromRow(rows.first);
  }

  Future<FriendMessage> _messageOrThrow(int id) async =>
      (await message(id)) ?? (throw StateError("message '$id' vanished"));

  /// Sends a DM. Both parties must be friends; [replyTo], when present,
  /// must belong to the same pair and is quoted as a snapshot.
  @override
  Future<FriendMessage> send(
    String fromSeat,
    String toSeat,
    String body, {
    int? replyTo,
  }) async {
    final from = fromSeat.trim();
    final to = toSeat.trim();
    final text = body.trim();
    if (to.isEmpty) throw ArgumentError('recipient required');
    if (text.isEmpty) throw ArgumentError('message empty');
    if (text.length > FriendCaps.maxMessageLength) {
      throw ArgumentError(
        'message too long (max ${FriendCaps.maxMessageLength})',
      );
    }
    if (!await areFriends(from, to)) {
      throw StateError('you can message friends only');
    }
    if (await _blockedBetween(from, to)) {
      throw StateError('you can no longer message this player');
    }
    int? replyId;
    String replyAuthor = '';
    String replyText = '';
    if (replyTo != null) {
      final quoted = await message(replyTo);
      if (quoted == null) throw ArgumentError('quoted message not found');
      final pair = {quoted.fromSeat, quoted.toSeat};
      if (!pair.contains(from) || !pair.contains(to)) {
        throw ArgumentError('that message is not part of your chat');
      }
      replyId = quoted.id;
      replyAuthor = quoted.fromSeat;
      replyText = quoted.body;
    }
    _db.execute(
      'INSERT INTO friend_messages '
      '(from_seat, to_seat, body, liked, reply_to, reply_from, reply_body, '
      'created_ms) VALUES (?, ?, ?, 0, ?, ?, ?, ?)',
      [from, to, text, replyId, replyAuthor, replyText, _nowMs],
    );
    final id = _db.lastInsertRowId;
    _trimChat(from, to);
    return _messageOrThrow(id);
  }

  /// Keeps [FriendCaps.chatHistoryPerPair] newest rows for the pair,
  /// whichever side wrote them. Runs on every send so the pair's history
  /// stays bounded — a chat is a conversation, not a ledger.
  void _trimChat(String a, String b) {
    _db.execute(
      '''
      DELETE FROM friend_messages WHERE id IN (
        SELECT id FROM friend_messages
        WHERE (from_seat = ?1 AND to_seat = ?2)
           OR (from_seat = ?2 AND to_seat = ?1)
        ORDER BY id DESC LIMIT -1 OFFSET ?3
      )''',
      [a, b, FriendCaps.chatHistoryPerPair],
    );
  }

  /// History for the pair in send order. With [since] (a message id)
  /// only newer pages — polling clients pay bytes for the gap, nothing
  /// for the known past.
  @override
  Future<FriendChatPage> chat(
    String seatId,
    String peer, {
    int? since,
    int limit = 50,
  }) async {
    final me = seatId.trim();
    final them = peer.trim();
    if (them.isEmpty) throw ArgumentError('peer required');
    const pair =
        '((from_seat = ?1 AND to_seat = ?2) OR (from_seat = ?2 AND to_seat = ?1))';
    final cap = limit.clamp(1, FriendCaps.chatHistoryPerPair).toString();
    if (since != null) {
      final rows = _db.select(
        'SELECT * FROM friend_messages WHERE $pair AND id > ?3 '
        'ORDER BY id ASC LIMIT $cap',
        [me, them, since],
      );
      return FriendChatPage(
        messages: [for (final r in rows) FriendMessage.fromRow(r)],
        latestId: await latestMessageId(me, them),
      );
    }
    final rows = _db.select(
      'SELECT * FROM friend_messages WHERE $pair ORDER BY id DESC LIMIT $cap',
      [me, them],
    );
    // Newest-first from SQL; callers read and the UI renders oldest-first.
    final list = [for (final r in rows) FriendMessage.fromRow(r)].reversed
        .toList();
    return FriendChatPage(
      messages: list,
      latestId: list.isEmpty ? 0 : list.last.id,
    );
  }

  /// Every peer's highest message id in one pass — the unread-marker
  /// baseline for the whole friend list.
  @override
  Future<Map<String, int>> latestMessageIds(String seatId) async {
    final s = seatId.trim();
    final rows = _db.select(
      'SELECT CASE WHEN from_seat = ?1 THEN to_seat ELSE from_seat END '
      'AS peer, MAX(id) AS latest FROM friend_messages '
      'WHERE from_seat = ?1 OR to_seat = ?1 GROUP BY peer',
      [s],
    );
    return {for (final r in rows) r['peer'] as String: r['latest'] as int};
  }

  /// The highest message id on the pair — the unread-marker baseline.
  @override
  Future<int> latestMessageId(String seatId, String peer) async {
    final me = seatId.trim();
    final them = peer.trim();
    const pair =
        '((from_seat = ?1 AND to_seat = ?2) OR (from_seat = ?2 AND to_seat = ?1))';
    final rows = _db.select(
      'SELECT id FROM friend_messages WHERE $pair ORDER BY id DESC LIMIT 1',
      [me, them],
    );
    return rows.isEmpty ? 0 : rows.first['id'] as int;
  }

  /// Sets (or clears) the like on a message. Both the sender and the
  /// recipient may toggle it — in a pair, a like needs no identity.
  @override
  Future<FriendMessage?> like(
    String seatId,
    int messageId, {
    required bool liked,
  }) async {
    final me = seatId.trim();
    final rows = _db.select('SELECT id FROM friend_messages WHERE id = ?', [
      messageId,
    ]);
    if (rows.isEmpty) return null;
    final target = (await message(messageId))!;
    if (target.fromSeat != me && target.toSeat != me) return null;
    _db.execute('UPDATE friend_messages SET liked = ? WHERE id = ?', [
      liked ? 1 : 0,
      messageId,
    ]);
    return message(messageId);
  }

  // -------------------------------------------------------------- invites

  /// Records that [fromSeat] asked [toSeat] to join a [game] room whose
  /// code [code] (null while still being claimed) is waiting. Any earlier
  /// pending invite between the same pair is superseded — one live
  /// invitation per pair.
  @override
  Future<FriendInvite> sendInvite(
    String fromSeat,
    String fromName,
    String toSeat,
    String game, {
    String? code,
  }) async {
    final (from, nm) = _checkCaller(fromSeat, fromName);
    final to = toSeat.trim();
    if (to.isEmpty) throw ArgumentError('recipient required');
    if (from == to) throw StateError('you cannot invite yourself');
    if (!friendInviteGames.contains(game)) {
      throw ArgumentError(
        'game must be one of ${friendInviteGames.join(', ')}',
      );
    }
    // Room codes are generated from letters *and digits* (see
    // GameServer's alphabet), so an invite must accept the same shape.
    // A letters-only check rejected every table whose code happened to
    // contain a digit — the invite never reached the friend.
    if (code != null && !RegExp(r'^[a-zA-Z0-9]{4}$').hasMatch(code.trim())) {
      throw ArgumentError('room code must be 4 letters or digits');
    }
    if (!await areFriends(from, to)) {
      throw StateError('you can invite friends only');
    }
    if (await _blockedBetween(from, to)) {
      throw StateError('you can no longer invite this player');
    }
    final now = _nowMs;
    final invitedNow =
        _db.select(
              "SELECT COUNT(*) AS n FROM friend_invites WHERE to_seat = ? "
              "AND status = 'pending'",
              [to],
            ).first['n']
            as int;
    if (invitedNow >= FriendCaps.invitesPerSeat) {
      final target = await _requireProfile(to);
      throw StateError('${target.name} has too many invites');
    }
    _db.execute(
      "DELETE FROM friend_invites WHERE from_seat = ? AND to_seat = ? "
      "AND status = 'pending'",
      [from, to],
    );
    _db.execute(
      'INSERT INTO friend_invites '
      '(from_seat, from_name, to_seat, game, code, status, created_ms, '
      'updated_ms) VALUES (?, ?, ?, ?, ?, ?, ?, ?)',
      [from, nm, to, game, code?.trim().toUpperCase(), 'pending', now, now],
    );
    return _invite(_db.lastInsertRowId)!;
  }

  FriendInvite? _invite(int id) {
    final rows = _db.select('SELECT * FROM friend_invites WHERE id = ?', [id]);
    return rows.isEmpty ? null : FriendInvite.fromRow(rows.first);
  }

  /// The invitee answers. An accepted invite returns the room code to
  /// join (null while none was attached); a decline just closes the row.
  @override
  Future<String?> respondInvite(
    String seatId,
    int inviteId, {
    required bool accept,
  }) async {
    final rows = _db.select(
      "SELECT code FROM friend_invites WHERE id = ? AND to_seat = ? "
      "AND status = 'pending'",
      [inviteId, seatId.trim()],
    );
    if (rows.isEmpty) return null;
    final now = _nowMs;
    _db.execute(
      "UPDATE friend_invites SET status = ?, updated_ms = ? WHERE id = ?",
      [accept ? 'accepted' : 'declined', now, inviteId],
    );
    return accept ? rows.first['code'] as String? : null;
  }

  /// Invites addressed to [seatId] (newest first), expiring stale pendings
  /// in place on read.
  @override
  Future<List<FriendInvite>> invites(String seatId) async {
    final me = seatId.trim();
    final cutoff = _nowMs - FriendCaps.inviteLifetime.inMilliseconds;
    _db.execute(
      "UPDATE friend_invites SET status = 'expired' WHERE to_seat = ? "
      "AND status = 'pending' AND created_ms < ?",
      [me, cutoff],
    );
    final rows = _db.select(
      'SELECT * FROM friend_invites WHERE to_seat = ?1 ORDER BY '
      'CASE status WHEN ?2 THEN 0 ELSE 1 END ASC, id DESC LIMIT ?3',
      [me, 'pending', FriendCaps.invitesPerSeat * 2],
    );
    return [for (final r in rows) FriendInvite.fromRow(r)];
  }
}
