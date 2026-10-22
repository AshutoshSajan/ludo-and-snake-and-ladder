/// Turso (libSQL) friend persistence over the hosted HTTP API.
///
/// Speaks the same "SQL over HTTP" protocol (Hrana over HTTP v2) as
/// [TursoLeaderboardStore] and [TursoRoomRegistry]: every operation is a
/// `POST {db}/v2/pipeline` carrying `execute` statements and a trailing
/// `close`, authenticated with a Bearer token. That keeps friendships,
/// requests, blocks, DMs, and invites off the ephemeral game host, so a
/// redeploy no longer wipes who your friends are.
///
/// Configure with the same two environment variables the other durable
/// stores use:
///
///     TURSO_DATABASE_URL   e.g. libsql://my-db-myorg.turso.io
///     TURSO_AUTH_TOKEN     a database token (`turso db tokens create`)
///
/// Schema is strictly additive (`CREATE ... IF NOT EXISTS` plus guarded
/// `ALTER TABLE ... ADD COLUMN`) and every multi-write operation runs in one
/// explicit transaction inside one pipeline, so a failure cannot leave half
/// a friendship behind.
library;

import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import 'friend_store.dart';

/// A failed Turso HTTP request or a failed statement inside a pipeline.
class TursoFriendStoreException implements Exception {
  TursoFriendStoreException(this.message);

  final String message;

  @override
  String toString() => 'TursoFriendStoreException: $message';
}

/// [FriendStore] backed by a remote Turso database.
class TursoFriendStore implements FriendStore {
  TursoFriendStore({
    required Uri url,
    required this.authToken,
    http.Client? client,
    DateTime Function()? clock,
  }) : _baseUrl = _normalizeBaseUrl(url),
       _client = client ?? http.Client(),
       _ownsClient = client == null,
       _now = clock ?? DateTime.now;

  /// Reads `TURSO_DATABASE_URL` + `TURSO_AUTH_TOKEN`. Returns null when
  /// either is missing so callers can fall back to the local store.
  static TursoFriendStore? fromEnvironment(
    Map<String, String> env, {
    http.Client? client,
    DateTime Function()? clock,
  }) {
    final url = env['TURSO_DATABASE_URL']?.trim();
    final token = env['TURSO_AUTH_TOKEN']?.trim();
    if (url == null || url.isEmpty || token == null || token.isEmpty) {
      return null;
    }
    return TursoFriendStore(
      url: Uri.parse(url),
      authToken: token,
      client: client,
      clock: clock,
    );
  }

  /// `turso://` and `libsql://` URLs are https URLs in disguise.
  static Uri _normalizeBaseUrl(Uri url) {
    var text = url.toString();
    if (text.startsWith('libsql://')) {
      text = 'https://${text.substring('libsql://'.length)}';
    }
    if (text.startsWith('turso://')) {
      text = 'https://${text.substring('turso://'.length)}';
    }
    while (text.endsWith('/')) {
      text = text.substring(0, text.length - 1);
    }
    return Uri.parse(text);
  }

  final Uri _baseUrl;
  final String authToken;
  final http.Client _client;
  final bool _ownsClient;

  /// Injectable clock, matching the SQLite store's `withClock` test path.
  final DateTime Function() _now;

  int get _nowMs => _now().millisecondsSinceEpoch;

  static const _timeout = Duration(seconds: 10);

  /// Same schema as the SQLite implementation. Every statement is
  /// idempotent; running the block again on an existing database changes
  /// nothing.
  static const _schemaSql = <String>[
    'CREATE TABLE IF NOT EXISTS friend_profiles ('
        'seat_id TEXT PRIMARY KEY, '
        'name TEXT NOT NULL, '
        'code TEXT NOT NULL UNIQUE, '
        'seen_ms INTEGER NOT NULL)',
    'CREATE TABLE IF NOT EXISTS friendships ('
        'id INTEGER PRIMARY KEY AUTOINCREMENT, '
        'seat_a TEXT NOT NULL, '
        'seat_b TEXT NOT NULL, '
        'since_ms INTEGER NOT NULL, '
        'UNIQUE(seat_a, seat_b))',
    'CREATE INDEX IF NOT EXISTS idx_friendships_a ON friendships(seat_a)',
    'CREATE INDEX IF NOT EXISTS idx_friendships_b ON friendships(seat_b)',
    'CREATE TABLE IF NOT EXISTS friend_requests ('
        'id INTEGER PRIMARY KEY AUTOINCREMENT, '
        'from_seat TEXT NOT NULL, '
        'from_name TEXT NOT NULL, '
        'from_code TEXT NOT NULL, '
        'to_seat TEXT NOT NULL, '
        'to_name TEXT NOT NULL, '
        'to_code TEXT NOT NULL, '
        'created_ms INTEGER NOT NULL, '
        'UNIQUE(from_seat, to_seat))',
    'CREATE INDEX IF NOT EXISTS idx_friend_requests_to '
        'ON friend_requests(to_seat)',
    'CREATE TABLE IF NOT EXISTS friend_messages ('
        'id INTEGER PRIMARY KEY AUTOINCREMENT, '
        'from_seat TEXT NOT NULL, '
        'to_seat TEXT NOT NULL, '
        'body TEXT NOT NULL, '
        'liked INTEGER NOT NULL DEFAULT 0, '
        'reply_to INTEGER, '
        "reply_from TEXT NOT NULL DEFAULT '', "
        "reply_body TEXT NOT NULL DEFAULT '', "
        'created_ms INTEGER NOT NULL)',
    'CREATE INDEX IF NOT EXISTS idx_friend_messages_pair '
        'ON friend_messages(from_seat, to_seat)',
    'CREATE INDEX IF NOT EXISTS idx_friend_messages_rev '
        'ON friend_messages(to_seat, from_seat)',
    'CREATE TABLE IF NOT EXISTS friend_invites ('
        'id INTEGER PRIMARY KEY AUTOINCREMENT, '
        'from_seat TEXT NOT NULL, '
        'from_name TEXT NOT NULL, '
        'to_seat TEXT NOT NULL, '
        'game TEXT NOT NULL, '
        'code TEXT, '
        "status TEXT NOT NULL DEFAULT 'pending', "
        'created_ms INTEGER NOT NULL, '
        'updated_ms INTEGER NOT NULL)',
    'CREATE INDEX IF NOT EXISTS idx_friend_invites_to '
        'ON friend_invites(to_seat)',
    'CREATE TABLE IF NOT EXISTS friend_blocks ('
        'id INTEGER PRIMARY KEY AUTOINCREMENT, '
        'blocker TEXT NOT NULL, '
        'blocked TEXT NOT NULL, '
        "blocked_name TEXT NOT NULL DEFAULT '', "
        'created_ms INTEGER NOT NULL, '
        'UNIQUE(blocker, blocked))',
    'CREATE INDEX IF NOT EXISTS idx_friend_blocks_blocker '
        'ON friend_blocks(blocker)',
  ];

  /// Columns added after the first remote databases were created. SQLite
  /// has no `ADD COLUMN IF NOT EXISTS`, so the column list is checked first
  /// and each ALTER runs only when its column is absent. Nothing is dropped
  /// or rewritten.
  static const _addReplyFromSql =
      "ALTER TABLE friend_messages ADD COLUMN reply_from TEXT NOT NULL "
      "DEFAULT ''";
  static const _addReplyBodySql =
      "ALTER TABLE friend_messages ADD COLUMN reply_body TEXT NOT NULL "
      "DEFAULT ''";
  static const _messageColumnProbeSql = 'SELECT name FROM pragma_table_info(?)';

  // ----------------------------------------------------------------- SQL

  static const _selectProfileSql =
      'SELECT seat_id, name, code, seen_ms FROM friend_profiles '
      'WHERE seat_id = ?';
  static const _selectProfileByCodeSql =
      'SELECT seat_id, name, code, seen_ms FROM friend_profiles WHERE code = ?';
  static const _upsertProfileSql =
      'INSERT INTO friend_profiles (seat_id, name, code, seen_ms) '
      'VALUES (?, ?, ?, ?) '
      'ON CONFLICT(seat_id) DO UPDATE SET '
      'name = excluded.name, seen_ms = excluded.seen_ms';

  static const _friendshipSql =
      'SELECT id FROM friendships WHERE seat_a = ? AND seat_b = ?';
  static const _friendCountSql =
      'SELECT COUNT(*) AS n FROM friendships '
      'WHERE seat_a = ? OR seat_b = ?';

  static const _mineRequestSql =
      'SELECT id FROM friend_requests WHERE from_seat = ? AND to_seat = ?';
  static const _pendingCountSql =
      'SELECT COUNT(*) AS n FROM friend_requests '
      'WHERE from_seat = ? OR to_seat = ?';
  static const _insertRequestIfNotFriendsSql =
      'INSERT OR IGNORE INTO friend_requests '
      '(from_seat, from_name, from_code, to_seat, to_name, to_code, created_ms) '
      'SELECT ?, ?, ?, ?, ?, ?, ? '
      'WHERE NOT EXISTS ('
      'SELECT 1 FROM friendships WHERE seat_a = ? AND seat_b = ?)';
  static const _acceptReverseFriendshipSql =
      'INSERT OR IGNORE INTO friendships (seat_a, seat_b, since_ms) '
      'SELECT ?, ?, ? WHERE EXISTS ('
      'SELECT 1 FROM friend_requests WHERE from_seat = ? AND to_seat = ?)';
  static const _clearPairRequestsIfReverseSql =
      'DELETE FROM friend_requests '
      'WHERE ((from_seat = ? AND to_seat = ?) '
      'OR (from_seat = ? AND to_seat = ?)) '
      'AND EXISTS ('
      'SELECT 1 FROM friend_requests WHERE from_seat = ? AND to_seat = ?)';
  static const _friendshipExistsSql =
      'SELECT CASE WHEN EXISTS ('
      'SELECT 1 FROM friendships WHERE seat_a = ? AND seat_b = ?) '
      'THEN 1 ELSE 0 END AS friends';

  static const _acceptFriendshipFromRequestSql =
      'INSERT OR IGNORE INTO friendships (seat_a, seat_b, since_ms) '
      'SELECT CASE WHEN from_seat <= to_seat THEN from_seat ELSE to_seat END, '
      'CASE WHEN from_seat <= to_seat THEN to_seat ELSE from_seat END, ? '
      'FROM friend_requests WHERE id = ? AND to_seat = ?';
  static const _deleteMirrorRequestSql =
      'DELETE FROM friend_requests '
      'WHERE from_seat = ('
      'SELECT to_seat FROM friend_requests WHERE id = ? AND to_seat = ?) '
      'AND to_seat = ('
      'SELECT from_seat FROM friend_requests WHERE id = ? AND to_seat = ?)';
  static const _deleteRequestSql =
      'DELETE FROM friend_requests WHERE id = ? AND to_seat = ?';

  static const _friendsSql =
      'SELECT f.seat_id AS seat_id, f.name AS name, f.code AS code, '
      's.since_ms AS since_ms FROM friendships s '
      'JOIN friend_profiles f ON f.seat_id = s.seat_a WHERE s.seat_b = ?'
      ' UNION ALL '
      'SELECT f.seat_id AS seat_id, f.name AS name, f.code AS code, '
      's.since_ms AS since_ms FROM friendships s '
      'JOIN friend_profiles f ON f.seat_id = s.seat_b WHERE s.seat_a = ?';

  static const _blockSql =
      'SELECT id FROM friend_blocks WHERE blocker = ? AND blocked = ?';
  static const _blockCountSql =
      'SELECT COUNT(*) AS n FROM friend_blocks WHERE blocker = ?';
  static const _insertBlockSql =
      'INSERT OR IGNORE INTO friend_blocks '
      '(blocker, blocked, blocked_name, created_ms) '
      'SELECT ?, ?, COALESCE((SELECT name FROM friend_profiles '
      "WHERE seat_id = ?), ''), ?";
  static const _blocksSql =
      'SELECT blocker, blocked, blocked_name, created_ms FROM friend_blocks '
      'WHERE blocker = ? ORDER BY created_ms DESC';

  static const _requestColumns =
      'SELECT id, from_seat, from_name, from_code, to_seat, to_name, '
      'to_code, created_ms FROM friend_requests';

  static const _messageColumns =
      'SELECT id, from_seat, to_seat, body, liked, reply_to, reply_from, '
      'reply_body, created_ms FROM friend_messages';
  static const _selectMessageSql = '$_messageColumns WHERE id = ?';
  static const _selectLastMessageSql =
      '$_messageColumns WHERE id = last_insert_rowid()';
  static const _insertMessageSql =
      'INSERT INTO friend_messages '
      '(from_seat, to_seat, body, liked, reply_to, reply_from, reply_body, '
      'created_ms) VALUES (?, ?, ?, 0, ?, ?, ?, ?)';
  static const _trimChatSql =
      'DELETE FROM friend_messages WHERE id IN ('
      'SELECT id FROM friend_messages '
      'WHERE (from_seat = ? AND to_seat = ?) '
      'OR (from_seat = ? AND to_seat = ?) '
      'ORDER BY id DESC LIMIT -1 OFFSET ?)';
  static const _latestMessageSql =
      'SELECT id FROM friend_messages WHERE '
      '((from_seat = ?1 AND to_seat = ?2) '
      'OR (from_seat = ?2 AND to_seat = ?1)) '
      'ORDER BY id DESC LIMIT 1';
  static const _latestMessageIdsSql =
      'SELECT CASE WHEN from_seat = ?1 THEN to_seat ELSE from_seat END '
      'AS peer, MAX(id) AS latest FROM friend_messages '
      'WHERE from_seat = ?1 OR to_seat = ?1 GROUP BY peer';

  static const _inviteColumns =
      'SELECT id, from_seat, from_name, to_seat, game, code, status, '
      'created_ms FROM friend_invites';
  static const _invitePendingCountSql =
      "SELECT COUNT(*) AS n FROM friend_invites "
      "WHERE to_seat = ? AND status = 'pending'";
  static const _deletePendingInviteSql =
      "DELETE FROM friend_invites "
      "WHERE from_seat = ? AND to_seat = ? AND status = 'pending'";
  static const _insertInviteSql =
      'INSERT INTO friend_invites '
      '(from_seat, from_name, to_seat, game, code, status, created_ms, '
      'updated_ms) VALUES (?, ?, ?, ?, ?, ?, ?, ?)';
  static const _pendingInviteSql =
      "SELECT code FROM friend_invites "
      "WHERE id = ? AND to_seat = ? AND status = 'pending'";
  static const _answerInviteSql =
      'UPDATE friend_invites SET status = ?, updated_ms = ? '
      "WHERE id = ? AND to_seat = ? AND status = 'pending'";
  static const _expireInvitesSql =
      "UPDATE friend_invites SET status = 'expired' "
      "WHERE to_seat = ? AND status = 'pending' AND created_ms < ?";
  static const _invitesSql =
      'SELECT id, from_seat, from_name, to_seat, game, code, status, '
      'created_ms FROM friend_invites WHERE to_seat = ?1 ORDER BY '
      'CASE status WHEN ?2 THEN 0 ELSE 1 END ASC, id DESC LIMIT ?3';

  static const _close = {'type': 'close'};

  Future<void>? _schemaReady;

  Uri get _pipelineUrl => Uri.parse('$_baseUrl/v2/pipeline');

  Future<void> _ensureSchema() => _schemaReady ??= _createSchema();

  Future<void> _createSchema() async {
    try {
      await _pipeline([..._schemaSql.map(_execute), _close]);
      await _addReplyColumnsIfMissing();
    } catch (_) {
      _schemaReady = null; // let the next call retry
      rethrow;
    }
  }

  Future<void> _addReplyColumnsIfMissing() async {
    final tables = await _pipeline([
      _execute(_messageColumnProbeSql, ['friend_messages']),
      _close,
    ]);
    final present = {for (final row in tables.first.rows) '${row.first ?? ''}'};
    final missing = <String>[
      if (!present.contains('reply_from')) _addReplyFromSql,
      if (!present.contains('reply_body')) _addReplyBodySql,
    ];
    if (missing.isEmpty) return;
    await _pipeline([...missing.map(_execute), _close]);
  }

  // ------------------------------------------------------------- identity

  (String, String) _checkCaller(String seatId, String name) {
    final id = seatId.trim();
    final nm = name.trim();
    if (id.isEmpty) throw ArgumentError('seatId required');
    if (nm.isEmpty) throw ArgumentError('name required');
    return (id, nm.substring(0, nm.length.clamp(0, FriendCaps.maxNameLength)));
  }

  @override
  Future<FriendProfile> serve(String seatId, String name) async {
    final (id, nm) = _checkCaller(seatId, name);
    await _ensureSchema();
    final now = _nowMs;
    for (var attempt = 0; attempt < 8; attempt++) {
      final code = _generateCode(attempt);
      try {
        final tables = await _pipeline([
          _execute(_upsertProfileSql, [id, nm, code, now]),
          _execute(_selectProfileSql, [id]),
          _close,
        ]);
        final table = tables[1];
        if (table.rows.isNotEmpty) {
          return FriendProfile.fromRow(table.rowMap(table.rows.first));
        }
      } on TursoFriendStoreException catch (e) {
        // A unique clash on `code` is retryable; a transport/auth failure
        // is not, and must surface instead of burning eight silent retries.
        if (!_isUniqueViolation(e)) rethrow;
        final raced = await profile(id);
        if (raced != null) return raced;
      }
    }
    throw StateError('could not mint a unique friend code');
  }

  @override
  Future<FriendProfile?> profile(String seatId) async {
    await _ensureSchema();
    return _singleProfile(_selectProfileSql, [seatId.trim()]);
  }

  @override
  Future<FriendProfile?> profileByCode(String code) async {
    final c = code.trim().toUpperCase();
    if (c.length != 6) return null;
    await _ensureSchema();
    return _singleProfile(_selectProfileByCodeSql, [c]);
  }

  @override
  Future<FriendProfile?> resolveTarget(String target) async {
    final t = target.trim();
    if (t.isEmpty) return null;
    final looksLikeCode =
        t.length == 6 && RegExp(r'^[2-9A-HJ-NP-Z]+$').hasMatch(t);
    return looksLikeCode ? profileByCode(t) : profile(t);
  }

  Future<FriendProfile?> _singleProfile(String sql, List<Object?> args) async {
    final tables = await _pipeline([_execute(sql, args), _close]);
    final table = tables.first;
    return table.rows.isEmpty
        ? null
        : FriendProfile.fromRow(table.rowMap(table.rows.first));
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

  static bool _isUniqueViolation(TursoFriendStoreException e) {
    final message = e.message.toLowerCase();
    return message.contains('unique') && message.contains('constraint');
  }

  // -------------------------------------------------------- relationships

  @override
  Future<bool> areFriends(String a, String b) async {
    await _ensureSchema();
    final (lo, hi) = _pairOf(a.trim(), b.trim());
    return _exists(_friendshipSql, [lo, hi]);
  }

  @override
  Future<int> friendCount(String seatId) async {
    await _ensureSchema();
    final s = seatId.trim();
    final tables = await _pipeline([
      _execute(_friendCountSql, [s, s]),
      _close,
    ]);
    return _intCell(tables.first, 'n');
  }

  Future<FriendProfile> _requireProfile(String seatId) async =>
      (await profile(seatId)) ??
      (throw ArgumentError('unknown player $seatId'));

  (String lo, String hi) _pairOf(String a, String b) =>
      a.compareTo(b) <= 0 ? (a, b) : (b, a);

  @override
  Future<String> sendRequest(
    String fromSeat,
    String fromName,
    String target, {
    String? targetName,
  }) async {
    final (from, nm) = _checkCaller(fromSeat, fromName);
    await _ensureSchema();
    var to = await resolveTarget(target);
    if (to == null) {
      final mintName = (targetName ?? '').trim();
      final looksLikeCode =
          target.trim().length == 6 &&
          RegExp(r'^[2-9A-HJ-NP-Z]+$').hasMatch(target.trim());
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
    if (await _exists(_mineRequestSql, [from, to.seatId])) {
      return 'pending';
    }

    final reverseTables = await _pipeline([
      _execute(_mineRequestSql, [to.seatId, from]),
      _close,
    ]);
    if (reverseTables.first.rows.isNotEmpty) {
      final id = reverseTables.first.cell(reverseTables.first.rows.first, 'id');
      final accepted = await _acceptRequest(from, id as int);
      return accepted ? 'accepted' : 'pending';
    }

    await _pendingCap(from);
    await _pendingCap(to.seatId);

    final now = _nowMs;
    final (lo, hi) = _pairOf(from, to.seatId);
    final sender = (await profile(from))!;
    final tables = await _pipeline([
      _execute('BEGIN IMMEDIATE'),
      _execute(_acceptReverseFriendshipSql, [lo, hi, now, to.seatId, from]),
      _execute(_clearPairRequestsIfReverseSql, [
        from,
        to.seatId,
        to.seatId,
        from,
        to.seatId,
        from,
      ]),
      _execute(_insertRequestIfNotFriendsSql, [
        from,
        nm,
        sender.code,
        to.seatId,
        to.name,
        to.code,
        now,
        lo,
        hi,
      ]),
      _execute(_friendshipExistsSql, [lo, hi]),
      _execute('COMMIT'),
      _close,
    ]);
    return _intCell(tables[4], 'friends') == 1 ? 'accepted' : 'pending';
  }

  Future<void> _pendingCap(String seat) async {
    final tables = await _pipeline([
      _execute(_pendingCountSql, [seat, seat]),
      _close,
    ]);
    final n = _intCell(tables.first, 'n');
    if (n >= FriendCaps.pendingPerSeat) {
      throw StateError('too many pending requests — wait for replies');
    }
  }

  /// Accepts a request addressed to [seatId], creating the friendship and
  /// clearing any mirror row the pair had already sent. Idempotent.
  Future<bool> _acceptRequest(String seatId, int requestId) async {
    final tables = await _pipeline([
      _execute('BEGIN IMMEDIATE'),
      _execute(_acceptFriendshipFromRequestSql, [
        _nowMs,
        requestId,
        seatId.trim(),
      ]),
      _execute(_deleteMirrorRequestSql, [
        requestId,
        seatId.trim(),
        requestId,
        seatId.trim(),
      ]),
      _execute(_deleteRequestSql, [requestId, seatId.trim()]),
      _execute('SELECT changes() AS n'),
      _execute('COMMIT'),
      _close,
    ]);
    return _intCell(tables[4], 'n') > 0;
  }

  @override
  Future<bool> respond(
    String seatId,
    int requestId, {
    required bool accept,
  }) async {
    await _ensureSchema();
    if (accept) return _acceptRequest(seatId, requestId);
    await _pipeline([
      _execute(_deleteRequestSql, [requestId, seatId.trim()]),
      _close,
    ]);
    return true;
  }

  @override
  Future<bool> cancel(String fromSeat, int requestId) async {
    await _ensureSchema();
    await _pipeline([
      _execute('DELETE FROM friend_requests WHERE id = ? AND from_seat = ?', [
        requestId,
        fromSeat.trim(),
      ]),
      _close,
    ]);
    return true;
  }

  @override
  Future<bool> remove(String a, String b) async {
    await _ensureSchema();
    final (lo, hi) = _pairOf(a.trim(), b.trim());
    await _pipeline([
      _execute('DELETE FROM friendships WHERE seat_a = ? AND seat_b = ?', [
        lo,
        hi,
      ]),
      _close,
    ]);
    return true;
  }

  @override
  Future<List<FriendEntry>> friends(String seatId) async {
    await _ensureSchema();
    final s = seatId.trim();
    final tables = await _pipeline([
      _execute(_friendsSql, [s, s]),
      _close,
    ]);
    final list = [
      for (final row in tables.first.rows)
        FriendEntry.fromRow(tables.first.rowMap(row)),
    ]..sort((x, y) => x.name.toLowerCase().compareTo(y.name.toLowerCase()));
    return list;
  }

  // -------------------------------------------------------------- blocking

  @override
  Future<bool> isBlocked(String blocker, String about) async {
    await _ensureSchema();
    return _exists(_blockSql, [blocker.trim(), about.trim()]);
  }

  Future<bool> _blockedBetween(String a, String b) async =>
      await isBlocked(a, b) || await isBlocked(b, a);

  @override
  Future<bool> block(String blocker, String about, {String? targetName}) async {
    final by = blocker.trim();
    final them = about.trim();
    if (by.isEmpty || them.isEmpty) {
      throw ArgumentError('seat and target required');
    }
    if (by == them) throw StateError('you cannot block yourself');
    await _ensureSchema();
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

    final counts = await _pipeline([
      _execute(_blockCountSql, [by]),
      _close,
    ]);
    final n = _intCell(counts.first, 'n');
    if (!await isBlocked(by, them) && n >= FriendCaps.blocksPerSeat) {
      throw StateError('too many blocked players');
    }

    final (lo, hi) = _pairOf(by, them);
    await _pipeline([
      _execute('BEGIN IMMEDIATE'),
      _execute('DELETE FROM friendships WHERE seat_a = ? AND seat_b = ?', [
        lo,
        hi,
      ]),
      _execute(
        'DELETE FROM friend_requests WHERE '
        '(from_seat = ?1 AND to_seat = ?2) '
        'OR (from_seat = ?2 AND to_seat = ?1)',
        [by, them],
      ),
      _execute(
        "DELETE FROM friend_invites WHERE status = 'pending' AND "
        '((from_seat = ?1 AND to_seat = ?2) '
        'OR (from_seat = ?2 AND to_seat = ?1))',
        [by, them],
      ),
      _execute(_insertBlockSql, [by, them, them, _nowMs]),
      _execute('COMMIT'),
      _close,
    ]);
    return true;
  }

  @override
  Future<bool> unblock(String blocker, String about) async {
    await _ensureSchema();
    final tables = await _pipeline([
      _execute('DELETE FROM friend_blocks WHERE blocker = ? AND blocked = ?', [
        blocker.trim(),
        about.trim(),
      ]),
      _execute('SELECT changes() AS n'),
      _close,
    ]);
    return _intCell(tables[1], 'n') > 0;
  }

  @override
  Future<List<FriendBlock>> blocks(String seatId) async {
    await _ensureSchema();
    final tables = await _pipeline([
      _execute(_blocksSql, [seatId.trim()]),
      _close,
    ]);
    return [
      for (final row in tables.first.rows)
        FriendBlock.fromRow(tables.first.rowMap(row)),
    ];
  }

  @override
  Future<List<FriendRequest>> incoming(String seatId) async {
    await _ensureSchema();
    final tables = await _pipeline([
      _execute('$_requestColumns WHERE to_seat = ? ORDER BY created_ms ASC', [
        seatId.trim(),
      ]),
      _close,
    ]);
    return [
      for (final row in tables.first.rows)
        FriendRequest.fromRow(tables.first.rowMap(row)),
    ];
  }

  @override
  Future<List<FriendRequest>> outgoing(String seatId) async {
    await _ensureSchema();
    final tables = await _pipeline([
      _execute('$_requestColumns WHERE from_seat = ? ORDER BY created_ms ASC', [
        seatId.trim(),
      ]),
      _close,
    ]);
    return [
      for (final row in tables.first.rows)
        FriendRequest.fromRow(tables.first.rowMap(row)),
    ];
  }

  // ------------------------------------------------------------------ chat

  @override
  Future<FriendMessage?> message(int id) async {
    await _ensureSchema();
    final tables = await _pipeline([
      _execute(_selectMessageSql, [id]),
      _close,
    ]);
    final table = tables.first;
    return table.rows.isEmpty
        ? null
        : FriendMessage.fromRow(table.rowMap(table.rows.first));
  }

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
    await _ensureSchema();
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
    final tables = await _pipeline([
      _execute('BEGIN IMMEDIATE'),
      _execute(_insertMessageSql, [
        from,
        to,
        text,
        replyId,
        replyAuthor,
        replyText,
        _nowMs,
      ]),
      _execute(_selectLastMessageSql),
      _execute(_trimChatSql, [
        from,
        to,
        to,
        from,
        FriendCaps.chatHistoryPerPair,
      ]),
      _execute('COMMIT'),
      _close,
    ]);
    final table = tables[2];
    if (table.rows.isEmpty) {
      throw StateError('message vanished immediately after insert');
    }
    return FriendMessage.fromRow(table.rowMap(table.rows.first));
  }

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
    await _ensureSchema();
    const pair =
        '((from_seat = ?1 AND to_seat = ?2) '
        'OR (from_seat = ?2 AND to_seat = ?1))';
    final cap = limit.clamp(1, FriendCaps.chatHistoryPerPair);
    final tables = await _pipeline([
      if (since == null)
        _execute(
          'SELECT * FROM friend_messages WHERE $pair '
          'ORDER BY id DESC LIMIT ?3',
          [me, them, cap],
        )
      else
        _execute(
          'SELECT * FROM friend_messages WHERE $pair AND id > ?3 '
          'ORDER BY id ASC LIMIT ?4',
          [me, them, since, cap],
        ),
      _execute(_latestMessageSql, [me, them]),
      _close,
    ]);
    final page = tables.first;
    final latest = _intCell(tables[1], 'id', orElse: 0);
    if (since != null) {
      return FriendChatPage(
        messages: [
          for (final row in page.rows) FriendMessage.fromRow(page.rowMap(row)),
        ],
        latestId: latest,
      );
    }
    final list = [
      for (final row in page.rows) FriendMessage.fromRow(page.rowMap(row)),
    ].reversed.toList();
    return FriendChatPage(messages: list, latestId: latest);
  }

  @override
  Future<Map<String, int>> latestMessageIds(String seatId) async {
    final me = seatId.trim();
    await _ensureSchema();
    final tables = await _pipeline([
      _execute(_latestMessageIdsSql, [me]),
      _close,
    ]);
    final table = tables.first;
    return {
      for (final row in table.rows)
        table.cell(row, 'peer') as String: table.cell(row, 'latest') as int,
    };
  }

  @override
  Future<int> latestMessageId(String seatId, String peer) async {
    final me = seatId.trim();
    final them = peer.trim();
    await _ensureSchema();
    final tables = await _pipeline([
      _execute(_latestMessageSql, [me, them]),
      _close,
    ]);
    return _intCell(tables.first, 'id', orElse: 0);
  }

  @override
  Future<FriendMessage?> like(
    String seatId,
    int messageId, {
    required bool liked,
  }) async {
    final me = seatId.trim();
    final target = await message(messageId);
    if (target == null) return null;
    if (target.fromSeat != me && target.toSeat != me) return null;
    final tables = await _pipeline([
      _execute('UPDATE friend_messages SET liked = ? WHERE id = ?', [
        liked ? 1 : 0,
        messageId,
      ]),
      _execute(_selectMessageSql, [messageId]),
      _close,
    ]);
    final table = tables[1];
    return table.rows.isEmpty
        ? null
        : FriendMessage.fromRow(table.rowMap(table.rows.first));
  }

  // -------------------------------------------------------------- invites

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
    if (code != null && !RegExp(r'^[a-zA-Z]{4}$').hasMatch(code.trim())) {
      throw ArgumentError('room code must be 4 letters');
    }
    await _ensureSchema();
    if (!await areFriends(from, to)) {
      throw StateError('you can invite friends only');
    }
    if (await _blockedBetween(from, to)) {
      throw StateError('you can no longer invite this player');
    }
    final counts = await _pipeline([
      _execute(_invitePendingCountSql, [to]),
      _close,
    ]);
    if (_intCell(counts.first, 'n') >= FriendCaps.invitesPerSeat) {
      final target = await _requireProfile(to);
      throw StateError('${target.name} has too many invites');
    }
    final now = _nowMs;
    final tables = await _pipeline([
      _execute('BEGIN IMMEDIATE'),
      _execute(_deletePendingInviteSql, [from, to]),
      _execute(_insertInviteSql, [
        from,
        nm,
        to,
        game,
        code?.trim().toUpperCase(),
        'pending',
        now,
        now,
      ]),
      _execute('$_inviteColumns WHERE id = last_insert_rowid()'),
      _execute('COMMIT'),
      _close,
    ]);
    final table = tables[3];
    if (table.rows.isEmpty) {
      throw StateError('invite vanished immediately after insert');
    }
    return FriendInvite.fromRow(table.rowMap(table.rows.first));
  }

  @override
  Future<String?> respondInvite(
    String seatId,
    int inviteId, {
    required bool accept,
  }) async {
    await _ensureSchema();
    final tables = await _pipeline([
      _execute('BEGIN IMMEDIATE'),
      _execute(_pendingInviteSql, [inviteId, seatId.trim()]),
      _execute(_answerInviteSql, [
        accept ? 'accepted' : 'declined',
        _nowMs,
        inviteId,
        seatId.trim(),
      ]),
      _execute('COMMIT'),
      _close,
    ]);
    final pending = tables[1];
    if (pending.rows.isEmpty) return null;
    return accept ? pending.cell(pending.rows.first, 'code') as String? : null;
  }

  @override
  Future<List<FriendInvite>> invites(String seatId) async {
    final me = seatId.trim();
    await _ensureSchema();
    final cutoff = _nowMs - FriendCaps.inviteLifetime.inMilliseconds;
    final tables = await _pipeline([
      _execute('BEGIN IMMEDIATE'),
      _execute(_expireInvitesSql, [me, cutoff]),
      _execute(_invitesSql, [me, 'pending', FriendCaps.invitesPerSeat * 2]),
      _execute('COMMIT'),
      _close,
    ]);
    return [
      for (final row in tables[2].rows)
        FriendInvite.fromRow(tables[2].rowMap(row)),
    ];
  }

  @override
  void close() {
    if (_ownsClient) _client.close();
  }

  // ------------------------------------------------------- HTTP pipeline

  Future<bool> _exists(String sql, List<Object?> args) async {
    final tables = await _pipeline([_execute(sql, args), _close]);
    return tables.first.rows.isNotEmpty;
  }

  int _intCell(_ResultTable table, String column, {int? orElse}) {
    if (table.rows.isEmpty) {
      if (orElse != null) return orElse;
      throw TursoFriendStoreException(
        'expected a "$column" row but the pipeline returned none',
      );
    }
    return table.cell(table.rows.first, column) as int;
  }

  /// Sends one pipeline (one HTTP request, one fresh server-side stream)
  /// and returns the execute results in statement order. Throws
  /// [TursoFriendStoreException] on any transport, HTTP, or statement
  /// failure — a failed write never reports success.
  Future<List<_ResultTable>> _pipeline(
    List<Map<String, dynamic>> requests,
  ) async {
    final http.Response response;
    try {
      response = await _client
          .post(
            _pipelineUrl,
            headers: {
              'authorization': 'Bearer $authToken',
              'content-type': 'application/json',
            },
            body: jsonEncode({'baton': null, 'requests': requests}),
          )
          .timeout(_timeout);
    } on TimeoutException {
      throw TursoFriendStoreException(
        'Turso request timed out after ${_timeout.inSeconds}s',
      );
    } catch (e) {
      throw TursoFriendStoreException('Turso request failed: $e');
    }
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw TursoFriendStoreException(
        'Turso pipeline failed (HTTP ${response.statusCode}): '
        '${_snippet(response.body)}',
      );
    }
    final Object? decoded;
    try {
      decoded = jsonDecode(response.body);
    } on FormatException catch (e) {
      throw TursoFriendStoreException(
        'Turso returned invalid JSON: ${e.message}',
      );
    }
    final results = (decoded as Map?)?['results'];
    if (results is! List) {
      throw TursoFriendStoreException(
        'Turso response has no results array: ${_snippet(response.body)}',
      );
    }
    final tables = <_ResultTable>[];
    for (var i = 0; i < results.length; i++) {
      final entry = results[i];
      if (entry is! Map || entry['type'] != 'ok') {
        throw TursoFriendStoreException(
          'Turso pipeline step $i failed: ${_errorMessage(entry)}',
        );
      }
      final reply = entry['response'];
      if (reply is Map && reply['type'] == 'close') continue;
      final result = (reply as Map?)?['result'] as Map?;
      if (result == null) {
        throw TursoFriendStoreException('Turso pipeline step $i has no result');
      }
      tables.add(_ResultTable(Map<String, dynamic>.from(result)));
    }
    return tables;
  }

  static String _errorMessage(Object? entry) {
    if (entry is Map) {
      final error = entry['error'];
      if (error is Map) return '${error['message']}';
      if (error != null) return '$error';
    }
    return 'unknown error';
  }

  static String _snippet(String body) {
    final flat = body.replaceAll('\n', ' ').trim();
    return flat.length > 200 ? '${flat.substring(0, 200)}…' : flat;
  }

  static Map<String, dynamic> _execute(String sql, [List<Object?>? args]) => {
    'type': 'execute',
    'stmt': {
      'sql': sql,
      if (args != null) 'args': [for (final arg in args) _encodeArg(arg)],
    },
  };

  /// Encodes a Dart value as a pipeline argument. Integers are serialized
  /// as strings per the API docs (JSON numbers cannot hold all 64-bit ints).
  static Map<String, dynamic> _encodeArg(Object? value) => switch (value) {
    null => const {'type': 'null', 'value': null},
    int i => {'type': 'integer', 'value': '$i'},
    double d => {'type': 'float', 'value': d},
    String s => {'type': 'text', 'value': s},
    _ => throw ArgumentError(
      'unsupported Turso arg type: ${value.runtimeType}',
    ),
  };
}

/// A decoded `execute` result: column names plus rows of plain Dart values.
class _ResultTable {
  _ResultTable(Map<String, dynamic> result)
    : columns = [
        for (final col in result['cols'] as List<dynamic>? ?? const [])
          (col is Map ? col['name'] : col) as String? ?? '',
      ],
      rows = [
        for (final row in result['rows'] as List<dynamic>? ?? const [])
          [for (final cell in row as List<dynamic>) _decodeValue(cell)],
      ];

  final List<String> columns;
  final List<List<Object?>> rows;

  Object? cell(List<Object?> row, String column) {
    final index = columns.indexOf(column);
    if (index < 0) {
      throw TursoFriendStoreException(
        'Turso result has no "$column" column ($columns)',
      );
    }
    return row[index];
  }

  Map<String, Object?> rowMap(List<Object?> row) => {
    for (var i = 0; i < columns.length; i++) columns[i]: row[i],
  };

  /// Decodes a wire cell into a plain Dart value. The pipeline API wraps
  /// every cell in a typed object; integers arrive as strings so 64-bit
  /// values survive JSON. Raw (untyped) JSON values are accepted too.
  static Object? _decodeValue(Object? cell) {
    if (cell is! Map) return cell;
    final value = cell['value'];
    return switch (cell['type']) {
      'null' || null => null,
      'integer' || 'number' => _toInt(value),
      'float' => _toDouble(value),
      'text' => value is String ? value : '$value',
      _ => value,
    };
  }

  static int _toInt(Object? value) {
    if (value is int) return value;
    if (value is num) return value.toInt();
    if (value is String) return int.parse(value);
    throw TursoFriendStoreException('Turso returned a non-integer: $value');
  }

  static double _toDouble(Object? value) {
    if (value is num) return value.toDouble();
    if (value is String) return double.parse(value);
    throw TursoFriendStoreException('Turso returned a non-number: $value');
  }
}
