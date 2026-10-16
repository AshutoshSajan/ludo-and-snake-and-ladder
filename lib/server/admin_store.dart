/// Admin persistence: presence, growth, bans, audit, leaderboard edits,
/// and room lifecycle history — all in the same SQLite database file as
/// the leaderboard when pointed at it, so one DB holds everything the
/// dashboard shows.
///
/// The server keeps live rooms in memory ([GameAuthority.rooms]); this
/// store is the durable history beside it: every created/started/closed
/// room is appended here, so stats survive restarts.
library;

import 'package:sqlite3/sqlite3.dart';

import 'auth.dart';
import 'leaderboard_store.dart';

/// One known player: first/last seen drive growth stats.
class AdminPlayer {
  AdminPlayer({
    required this.seatId,
    required this.name,
    required this.firstSeen,
    required this.lastSeen,
  });

  final String seatId;
  final String name;
  final int firstSeen;
  final int lastSeen;
}

/// New-player count for one UTC day bucket.
class NewPlayersDay {
  NewPlayersDay({required this.day, required this.newPlayers});

  /// Day index since epoch (atMs ~/ 86400000).
  final int day;
  final int newPlayers;
}

/// One audit row for moderation actions.
class AuditEntry {
  AuditEntry({
    required this.action,
    required this.seatId,
    required this.by,
    required this.at,
    this.detail,
  });

  final String action;
  final String seatId;
  final String by;
  final int at;
  final String? detail;
}

/// One room lifecycle row.
class AdminRoom {
  AdminRoom({
    required this.code,
    required this.game,
    required this.instance,
    required this.createdAt,
    this.startedAt,
    this.closedAt,
    required this.status,
    this.playerCount = 0,
    this.winnerSeat,
  });

  final String code;
  final String game;
  final String instance;
  final int createdAt;
  final int? startedAt;
  final int? closedAt;
  final String status;
  final int playerCount;
  final String? winnerSeat;

  Map<String, dynamic> toJson() => {
    'code': code,
    'game': game,
    'instance': instance,
    'createdAt': createdAt,
    if (startedAt != null) 'startedAt': startedAt,
    if (closedAt != null) 'closedAt': closedAt,
    'status': status,
    'playerCount': playerCount,
    if (winnerSeat != null) 'winnerSeat': winnerSeat,
  };
}

/// Aggregate counts for the dashboard overview.
class AdminOverview {
  AdminOverview({
    required this.totalPlayers,
    required this.totalGames,
    required this.totalRooms,
    required this.bannedPlayers,
  });

  final int totalPlayers;
  final int totalGames;
  final int totalRooms;
  final int bannedPlayers;

  Map<String, dynamic> toJson() => {
    'totalPlayers': totalPlayers,
    'totalGames': totalGames,
    'totalRooms': totalRooms,
    'bannedPlayers': bannedPlayers,
  };
}

/// One account. Roles today: 'admin'. Reserved for players later:
/// 'moderator', 'user' — [seatId] links a player account to its game
/// identity when that lane is built, and is null for pure admins.
class AuthUser {
  AuthUser({
    required this.id,
    required this.email,
    required this.name,
    required this.role,
    required this.createdAt,
    this.seatId,
  });

  final int id;
  final String email;
  final String name;
  final String role;
  final int createdAt;
  final String? seatId;

  bool get isAdmin => role == 'admin';

  Map<String, dynamic> toJson() => {
    'id': id,
    'email': email,
    'name': name,
    'role': role,
    'createdAt': createdAt,
    if (seatId != null) 'seatId': seatId,
  };
}

/// A freshly minted session: the raw token goes to the client once and
/// is never stored; only its hash lives in the DB.
class SessionToken {
  SessionToken({required this.token, required this.expiresAt});

  final String token;
  final int expiresAt;
}

class AdminStore {
  AdminStore._(this._db, {required bool owns}) : _ownsDb = owns {
    _migrate();
  }

  factory AdminStore.inMemory() =>
      AdminStore._(sqlite3.openInMemory(), owns: true);

  factory AdminStore(String path) =>
      AdminStore._(sqlite3.open(path), owns: true);

  factory AdminStore.fromDb(Database db) =>
      AdminStore._(db, owns: false);

  final Database _db;
  final bool _ownsDb;

  void _migrate() {
    _db.execute('''
      CREATE TABLE IF NOT EXISTS results (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        game_id TEXT NOT NULL,
        seat_id TEXT NOT NULL,
        name TEXT NOT NULL,
        color TEXT NOT NULL,
        rank INTEGER NOT NULL,
        played_at INTEGER NOT NULL
      );
      CREATE INDEX IF NOT EXISTS idx_results_seat ON results(seat_id);
      CREATE UNIQUE INDEX IF NOT EXISTS idx_results_game_seat
          ON results(game_id, seat_id);
      CREATE TABLE IF NOT EXISTS players (
        seat_id TEXT PRIMARY KEY,
        name TEXT NOT NULL
      );
      CREATE TABLE IF NOT EXISTS admin_players (
        seat_id TEXT PRIMARY KEY,
        name TEXT NOT NULL,
        first_seen INTEGER NOT NULL,
        last_seen INTEGER NOT NULL
      );
      CREATE TABLE IF NOT EXISTS admin_bans (
        seat_id TEXT PRIMARY KEY,
        reason TEXT NOT NULL,
        banned_by TEXT NOT NULL,
        banned_at INTEGER NOT NULL,
        until_ms INTEGER
      );
      CREATE TABLE IF NOT EXISTS admin_audit (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        action TEXT NOT NULL,
        seat_id TEXT NOT NULL,
        by_name TEXT NOT NULL,
        detail TEXT,
        at_ms INTEGER NOT NULL
      );
      CREATE TABLE IF NOT EXISTS admin_rooms (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        code TEXT NOT NULL,
        game TEXT NOT NULL,
        instance TEXT NOT NULL,
        created_at INTEGER NOT NULL,
        started_at INTEGER,
        closed_at INTEGER,
        status TEXT NOT NULL,
        player_count INTEGER NOT NULL DEFAULT 0,
        winner_seat TEXT
      );
      CREATE INDEX IF NOT EXISTS idx_admin_rooms_code ON admin_rooms(code);
      CREATE INDEX IF NOT EXISTS idx_admin_rooms_created
          ON admin_rooms(created_at);
      CREATE TABLE IF NOT EXISTS auth_users (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        email TEXT NOT NULL UNIQUE,
        name TEXT NOT NULL,
        password_hash TEXT NOT NULL,
        role TEXT NOT NULL DEFAULT 'user',
        seat_id TEXT,
        created_at INTEGER NOT NULL
      );
      CREATE TABLE IF NOT EXISTS auth_sessions (
        token_hash TEXT PRIMARY KEY,
        user_id INTEGER NOT NULL REFERENCES auth_users(id) ON DELETE CASCADE,
        created_at INTEGER NOT NULL,
        expires_at INTEGER NOT NULL
      );
      CREATE INDEX IF NOT EXISTS idx_auth_sessions_user
          ON auth_sessions(user_id);
    ''');
    final cols = _db
        .select('PRAGMA table_info(results)')
        .map((r) => r['name'] as String);
    if (!cols.contains('game')) {
      _db.execute(
        "ALTER TABLE results ADD COLUMN game TEXT NOT NULL DEFAULT ''",
      );
    }
  }

  // ---------------------------------------------------------- presence

  Future<void> recordPresence({
    required String seatId,
    required String name,
  }) async {
    await recordPresenceAt(
      seatId: seatId,
      name: name,
      atMs: DateTime.now().millisecondsSinceEpoch,
    );
  }

  Future<void> recordPresenceAt({
    required String seatId,
    required String name,
    required int atMs,
  }) async {
    final existing = _db.select(
      'SELECT first_seen FROM admin_players WHERE seat_id = ?',
      [seatId],
    );
    if (existing.isEmpty) {
      _db.execute(
        'INSERT INTO admin_players (seat_id, name, first_seen, last_seen) '
        'VALUES (?, ?, ?, ?)',
        [seatId, name, atMs, atMs],
      );
    } else {
      _db.execute(
        'UPDATE admin_players SET name = ?, last_seen = ? '
        'WHERE seat_id = ?',
        [name, atMs, seatId],
      );
    }
  }

  Future<AdminPlayer?> player(String seatId) async {
    final rows = _db.select(
      'SELECT seat_id, name, first_seen, last_seen FROM admin_players '
      'WHERE seat_id = ?',
      [seatId],
    );
    if (rows.isEmpty) return null;
    final r = rows.first;
    return AdminPlayer(
      seatId: r['seat_id'] as String,
      name: r['name'] as String,
      firstSeen: r['first_seen'] as int,
      lastSeen: r['last_seen'] as int,
    );
  }

  Future<List<AdminPlayer>> allPlayers({int limit = 100}) async {
    final rows = _db.select(
      'SELECT seat_id, name, first_seen, last_seen FROM admin_players '
      'ORDER BY last_seen DESC LIMIT ?',
      [limit],
    );
    return [
      for (final r in rows)
        AdminPlayer(
          seatId: r['seat_id'] as String,
          name: r['name'] as String,
          firstSeen: r['first_seen'] as int,
          lastSeen: r['last_seen'] as int,
        ),
    ];
  }

  Future<List<NewPlayersDay>> newPlayersPerDay({int days = 7}) async {
    final nowDay = DateTime.now().millisecondsSinceEpoch ~/ 86400000;
    final out = <NewPlayersDay>[];
    for (var i = days - 1; i >= 0; i--) {
      final day = nowDay - i;
      final start = day * 86400000;
      final end = (day + 1) * 86400000;
      final rows = _db.select(
        'SELECT COUNT(*) AS n FROM admin_players '
        'WHERE first_seen >= ? AND first_seen < ?',
        [start, end],
      );
      out.add(NewPlayersDay(day: day, newPlayers: rows.first['n'] as int));
    }
    return out;
  }

  // --------------------------------------------------------- moderation

  Future<bool> isBanned(String seatId) async {
    final rows = _db.select(
      'SELECT until_ms FROM admin_bans WHERE seat_id = ?',
      [seatId],
    );
    if (rows.isEmpty) return false;
    final until = rows.first['until_ms'] as int?;
    if (until == null) return true;
    return until > DateTime.now().millisecondsSinceEpoch;
  }

  Future<void> ban({
    required String seatId,
    required String reason,
    required String by,
    int? untilMs,
  }) async {
    final now = DateTime.now().millisecondsSinceEpoch;
    _db.execute(
      'INSERT INTO admin_bans (seat_id, reason, banned_by, banned_at, '
      'until_ms) VALUES (?, ?, ?, ?, ?) '
      'ON CONFLICT(seat_id) DO UPDATE SET reason = excluded.reason, '
      'banned_by = excluded.banned_by, banned_at = excluded.banned_at, '
      'until_ms = excluded.until_ms',
      [seatId, reason, by, now, untilMs],
    );
    await _audit(action: 'ban', seatId: seatId, by: by, detail: reason);
  }

  Future<void> unban(String seatId, {String by = 'admin'}) async {
    _db.execute('DELETE FROM admin_bans WHERE seat_id = ?', [seatId]);
    await _audit(action: 'unban', seatId: seatId, by: by);
  }

  Future<List<AuditEntry>> auditLog({int limit = 50}) async {
    final rows = _db.select(
      'SELECT action, seat_id, by_name, detail, at_ms FROM admin_audit '
      'ORDER BY id DESC LIMIT ?',
      [limit],
    );
    return [
      for (final r in rows)
        AuditEntry(
          action: r['action'] as String,
          seatId: r['seat_id'] as String,
          by: r['by_name'] as String,
          at: r['at_ms'] as int,
          detail: r['detail'] as String?,
        ),
    ];
  }

  Future<void> _audit({
    required String action,
    required String seatId,
    required String by,
    String? detail,
  }) async {
    _db.execute(
      'INSERT INTO admin_audit (action, seat_id, by_name, detail, at_ms) '
      'VALUES (?, ?, ?, ?, ?)',
      [action, seatId, by, detail, DateTime.now().millisecondsSinceEpoch],
    );
  }

  // --------------------------------------------------- leaderboard edits

  Future<void> recordResult({
    required String gameId,
    required String seatId,
    required String name,
    required String game,
    required int rank,
    String color = 'red',
  }) async {
    final now = DateTime.now().millisecondsSinceEpoch;
    _db.execute(
      'INSERT OR IGNORE INTO results '
      '(game_id, seat_id, name, color, rank, played_at, game) '
      'VALUES (?, ?, ?, ?, ?, ?, ?)',
      [gameId, seatId, name, color, rank, now, game],
    );
    _db.execute(
      'INSERT INTO players (seat_id, name) VALUES (?, ?) '
      'ON CONFLICT(seat_id) DO UPDATE SET name = excluded.name',
      [seatId, name],
    );
  }

  Future<List<LeaderboardEntry>> topPlayers({
    int limit = 10,
    String? game,
  }) async {
    final rows = _db.select(
      '''
      SELECT r.seat_id AS seat_id,
             p.name AS name,
             SUM(CASE WHEN r.rank = 1 THEN 1 ELSE 0 END) AS wins,
             COUNT(*) AS games,
             AVG(r.rank) AS avg_rank
      FROM results r
      JOIN players p ON p.seat_id = r.seat_id
      ${game != null ? 'WHERE r.game = ?' : ''}
      GROUP BY r.seat_id
      ORDER BY wins DESC, avg_rank ASC, games DESC
      LIMIT ?
    ''',
      [?game, limit],
    );
    return [
      for (final row in rows)
        LeaderboardEntry(
          seatId: row['seat_id'] as String,
          name: row['name'] as String,
          wins: row['wins'] as int,
          games: row['games'] as int,
          avgRank: (row['avg_rank'] as num).toDouble(),
        ),
    ];
  }

  Future<int> totalGames({String? game}) async => _db
      .select(
        'SELECT COUNT(DISTINCT game_id) AS n FROM results'
        '${game != null ? ' WHERE game = ?' : ''}',
        [?game],
      )
      .first['n'] as int;

  Future<void> renamePlayer({
    required String seatId,
    required String name,
    required String by,
  }) async {
    _db.execute('UPDATE players SET name = ? WHERE seat_id = ?', [
      name,
      seatId,
    ]);
    _db.execute('UPDATE admin_players SET name = ? WHERE seat_id = ?', [
      name,
      seatId,
    ]);
    await _audit(
      action: 'rename',
      seatId: seatId,
      by: by,
      detail: name,
    );
  }

  Future<void> deleteGame(String gameId, {String by = 'admin'}) async {
    _db.execute('DELETE FROM results WHERE game_id = ?', [gameId]);
    await _audit(action: 'deleteGame', seatId: gameId, by: by);
  }

  // -------------------------------------------------------------- rooms

  Future<void> recordRoomCreated({
    required String code,
    required String game,
    required String instance,
  }) async {
    _db.execute(
      'INSERT INTO admin_rooms '
      '(code, game, instance, created_at, status, player_count) '
      'VALUES (?, ?, ?, ?, ?, ?)',
      [code, game, instance, DateTime.now().millisecondsSinceEpoch, 'lobby', 1],
    );
  }

  Future<void> recordRoomStarted(String code) async {
    _db.execute(
      'UPDATE admin_rooms SET status = ?, started_at = ? '
      'WHERE id = (SELECT id FROM admin_rooms WHERE code = ? '
      'ORDER BY id DESC LIMIT 1)',
      ['live', DateTime.now().millisecondsSinceEpoch, code],
    );
  }

  Future<void> recordRoomClosed(
    String code, {
    String? winnerSeat,
    int playerCount = 0,
  }) async {
    _db.execute(
      'UPDATE admin_rooms SET status = ?, closed_at = ?, winner_seat = ?, '
      'player_count = ? '
      'WHERE id = (SELECT id FROM admin_rooms WHERE code = ? '
      'ORDER BY id DESC LIMIT 1)',
      [
        'closed',
        DateTime.now().millisecondsSinceEpoch,
        winnerSeat,
        playerCount,
        code,
      ],
    );
  }

  Future<List<AdminRoom>> recentRooms({int limit = 50}) async {
    final rows = _db.select(
      'SELECT code, game, instance, created_at, started_at, closed_at, '
      'status, player_count, winner_seat FROM admin_rooms '
      'ORDER BY id DESC LIMIT ?',
      [limit],
    );
    return [
      for (final r in rows)
        AdminRoom(
          code: r['code'] as String,
          game: r['game'] as String,
          instance: r['instance'] as String,
          createdAt: r['created_at'] as int,
          startedAt: r['started_at'] as int?,
          closedAt: r['closed_at'] as int?,
          status: r['status'] as String,
          playerCount: (r['player_count'] as int?) ?? 0,
          winnerSeat: r['winner_seat'] as String?,
        ),
    ];
  }

  Future<int> totalRooms() async =>
      _db.select('SELECT COUNT(*) AS n FROM admin_rooms').first['n'] as int;

  Future<AdminOverview> overview() async {
    final players =
        _db.select('SELECT COUNT(*) AS n FROM admin_players').first['n']
            as int;
    final gamesRow = _db
        .select('SELECT COUNT(DISTINCT game_id) AS n FROM results')
        .first['n'];
    final rooms = await totalRooms();
    final now = DateTime.now().millisecondsSinceEpoch;
    final banned =
        _db
            .select(
              'SELECT COUNT(*) AS n FROM admin_bans '
              'WHERE until_ms IS NULL OR until_ms > ?',
              [now],
            )
            .first['n']
            as int;
    return AdminOverview(
      totalPlayers: players,
      totalGames: (gamesRow as int?) ?? 0,
      totalRooms: rooms,
      bannedPlayers: banned,
    );
  }

  // -------------------------------------------------- users & sessions
  //
  // Shared by admins today and players tomorrow: one accounts table with
  // roles, one sessions table with hashed opaque tokens. The player lane
  // later adds self-registration (role 'user' + seat_id link) and reuses
  // createSession/validateSession unchanged.

  static const _userRoles = {'admin', 'moderator', 'user'};

  Future<int> userCount() async =>
      _db.select('SELECT COUNT(*) AS n FROM auth_users').first['n'] as int;

  Future<bool> get needsSetup async => await userCount() == 0;

  AuthUser _userFromRow(Row row) => AuthUser(
    id: row['id'] as int,
    email: row['email'] as String,
    name: row['name'] as String,
    role: row['role'] as String,
    createdAt: row['created_at'] as int,
    seatId: row['seat_id'] as String?,
  );

  /// Creates an account. Throws [ArgumentError] on short passwords or
  /// unknown roles, [StateError] on duplicate email.
  Future<AuthUser> createUser({
    required String email,
    required String name,
    required String password,
    String role = 'user',
    String? seatId,
    int iterations = defaultPbkdf2Iterations,
    String by = 'system',
  }) async {
    final normalized = normalizeEmail(email);
    if (normalized.isEmpty || !normalized.contains('@')) {
      throw ArgumentError('valid email required');
    }
    if (password.length < minPasswordLength) {
      throw ArgumentError(
        'password must be at least $minPasswordLength characters',
      );
    }
    if (!_userRoles.contains(role)) throw ArgumentError('unknown role $role');
    final exists = _db.select('SELECT id FROM auth_users WHERE email = ?', [
      normalized,
    ]);
    if (exists.isNotEmpty) throw StateError('email already registered');
    final now = DateTime.now().millisecondsSinceEpoch;
    _db.execute(
      'INSERT INTO auth_users '
      '(email, name, password_hash, role, seat_id, created_at) '
      'VALUES (?, ?, ?, ?, ?, ?)',
      [
        normalized,
        name.trim().isEmpty ? normalized : name.trim(),
        hashPassword(password, iterations: iterations),
        role,
        seatId,
        now,
      ],
    );
    final id = _db.lastInsertRowId;
    await _audit(action: 'userCreate', seatId: normalized, by: by);
    return (await findUserById(id))!;
  }

  Future<AuthUser?> findUserByEmail(String email) async {
    final rows = _db.select('SELECT * FROM auth_users WHERE email = ?', [
      normalizeEmail(email),
    ]);
    if (rows.isEmpty) return null;
    return _userFromRow(rows.first);
  }

  Future<AuthUser?> findUserById(int id) async {
    final rows = _db.select('SELECT * FROM auth_users WHERE id = ?', [id]);
    if (rows.isEmpty) return null;
    return _userFromRow(rows.first);
  }

  /// Null on unknown email OR wrong password — callers must not
  /// distinguish the two (no account enumeration).
  Future<AuthUser?> checkCredentials(String email, String password) async {
    final rows = _db.select(
      'SELECT * FROM auth_users WHERE email = ?',
      [normalizeEmail(email)],
    );
    if (rows.isEmpty) return null;
    final hash = rows.first['password_hash'] as String;
    if (!verifyPassword(password, hash)) return null;
    return _userFromRow(rows.first);
  }

  Future<List<AuthUser>> listUsers({int limit = 100}) async {
    final rows = _db.select(
      'SELECT * FROM auth_users ORDER BY id ASC LIMIT ?',
      [limit],
    );
    return [for (final r in rows) _userFromRow(r)];
  }

  Future<void> setUserRole({
    required int userId,
    required String role,
    required String by,
  }) async {
    if (!_userRoles.contains(role)) throw ArgumentError('unknown role $role');
    _db.execute('UPDATE auth_users SET role = ? WHERE id = ?', [role, userId]);
    final user = await findUserById(userId);
    await _audit(
      action: 'roleChange',
      seatId: user?.email ?? '$userId',
      by: by,
      detail: role,
    );
  }

  static const defaultSessionTtl = Duration(days: 7);

  Future<SessionToken> createSession(
    int userId, {
    Duration ttl = defaultSessionTtl,
  }) async {
    final token = randomToken();
    final now = DateTime.now().millisecondsSinceEpoch;
    _db.execute(
      'INSERT INTO auth_sessions '
      '(token_hash, user_id, created_at, expires_at) VALUES (?, ?, ?, ?)',
      [hashToken(token), userId, now, now + ttl.inMilliseconds],
    );
    return SessionToken(token: token, expiresAt: now + ttl.inMilliseconds);
  }

  /// The session's user, or null when unknown/expired. Expired rows are
  /// deleted lazily on sight.
  Future<AuthUser?> validateSession(String token) async {
    final digest = hashToken(token);
    final rows = _db.select(
      'SELECT u.* FROM auth_users u '
      'JOIN auth_sessions s ON s.user_id = u.id '
      'WHERE s.token_hash = ?',
      [digest],
    );
    if (rows.isEmpty) return null;
    final expiry = _db
        .select('SELECT expires_at FROM auth_sessions WHERE token_hash = ?', [
          digest,
        ])
        .first['expires_at'] as int;
    if (expiry <= DateTime.now().millisecondsSinceEpoch) {
      _db.execute('DELETE FROM auth_sessions WHERE token_hash = ?', [digest]);
      return null;
    }
    return _userFromRow(rows.first);
  }

  Future<void> revokeSession(String token) async {
    _db.execute('DELETE FROM auth_sessions WHERE token_hash = ?', [
      hashToken(token),
    ]);
  }

  Future<void> revokeUserSessions(int userId) async {
    _db.execute('DELETE FROM auth_sessions WHERE user_id = ?', [userId]);
  }

  void close() {
    if (_ownsDb) _db.close();
  }
}
