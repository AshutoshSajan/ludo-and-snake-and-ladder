/// Admin persistence: presence, growth, bans, audit, leaderboard edits,
/// room lifecycle history, accounts and sessions — all in the same
/// database as the leaderboard, whether that database is the local SQLite
/// file or a hosted Turso instance, so one store holds everything the
/// dashboard shows.
///
/// The server keeps live rooms in memory ([GameAuthority.rooms]); this
/// store is the durable history beside it: every created/started/closed
/// room is appended here, so stats survive restarts.
library;

import 'package:sqlite3/sqlite3.dart';

import 'admin_tables.dart';
import 'auth.dart';
import 'leaderboard_store.dart';
import 'sql_backend.dart';

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

/// A freshly minted session: the raw token goes to the browser once,
/// inside the HttpOnly session cookie, and is never stored in the
/// database; only its hash lives there.
class SessionToken {
  SessionToken({required this.token, required this.expiresAt});

  final String token;
  final int expiresAt;
}

/// Verifies [password] against a stored bcrypt [hash]. Injectable so a
/// test can prove which hash a lookup verifies without paying the KDF.
/// Legacy PBKDF2 rows take [verifyPasswordOffLoop] instead — they predate
/// this seam and are upgraded in place on success.
typedef PasswordVerifier = bool Function(String password, String hash);

class AdminStore {
  AdminStore._(
    this._backend,
    this._ownsBackend, {
    PasswordVerifier? verifier,
    int? bcryptRounds,
    Duration? sessionTtl,
  }) : _verifier = verifier ?? verifyPassword,
       bcryptRounds = bcryptRounds ?? defaultBcryptRounds,
       sessionTtl = sessionTtl ?? defaultSessionTtl;

  factory AdminStore.inMemory({
    PasswordVerifier? verifier,
    int? bcryptRounds,
    Duration? sessionTtl,
  }) => AdminStore._(
    SqliteBackend.inMemory(),
    true,
    verifier: verifier,
    bcryptRounds: bcryptRounds,
    sessionTtl: sessionTtl,
  );

  factory AdminStore(
    String path, {
    PasswordVerifier? verifier,
    int? bcryptRounds,
    Duration? sessionTtl,
  }) => AdminStore._(
    SqliteBackend.open(path),
    true,
    verifier: verifier,
    bcryptRounds: bcryptRounds,
    sessionTtl: sessionTtl,
  );

  factory AdminStore.fromDb(
    Database db, {
    PasswordVerifier? verifier,
    int? bcryptRounds,
    Duration? sessionTtl,
  }) => AdminStore._(
    SqliteBackend.fromDb(db),
    false,
    verifier: verifier,
    bcryptRounds: bcryptRounds,
    sessionTtl: sessionTtl,
  );

  /// Wraps any [SqlBackend] (the caller keeps ownership) — this is how a
  /// Turso-backed deployment gets the same admin surface as SQLite.
  factory AdminStore.fromBackend(
    SqlBackend backend, {
    PasswordVerifier? verifier,
    int? bcryptRounds,
    Duration? sessionTtl,
  }) => AdminStore._(
    backend,
    false,
    verifier: verifier,
    bcryptRounds: bcryptRounds,
    sessionTtl: sessionTtl,
  );

  final SqlBackend _backend;
  final bool _ownsBackend;
  final PasswordVerifier _verifier;

  /// This store's bcrypt cost for digesting NEW passwords: [defaultBcryptRounds]
  /// unless a test threads a small value — the same explicit-threading rule
  /// the hash itself follows. One number for every consumer. A legacy
  /// PBKDF2 row is re-hashed at this cost on its first successful login,
  /// which is the migration path — there is no separate "reset password"
  /// endpoint to lean on.
  ///
  /// Production never passes this; tests that flip [adminStore] or use
  /// `inMemory()` with the real verifier do — the suite otherwise pays a
  /// ~370ms bcrypt per password the store hashes.
  final int bcryptRounds;

  /// The one session clock this store serves. [createSession] stamps row
  /// expiries from it and the login/setup handlers read it back to set the
  /// cookie's Max-Age, so a response can never advertise a lifetime that
  /// disagrees with what the row actually got. Set from
  /// ADMIN_SESSION_TTL_HOURS at boot (see [adminSessionTtlFromEnv]); tests
  /// thread small values directly.
  final Duration sessionTtl;

  /// Schema is created lazily and memoized: a Turso deployment cannot run
  /// migrations in a constructor. A failed attempt is cleared so the next
  /// call retries (every statement is idempotent).
  Future<void>? _schemaReady;

  /// Creates every table this store owns, including the additive `game`
  /// column upgrade for databases created before per-game boards existed.
  Future<void> ensureSchema() => _schemaReady ??= _createSchema();

  Future<void> _createSchema() async {
    try {
      await _backend.run([
        for (final sql in _schemaSql) SqlStatement(sql),
      ], atomic: false);
      final probe = await _backend.run(const [
        SqlStatement(_hasGameColumnSql, ['results', 'game']),
      ]);
      final present = (probe.first.rows.first['n'] as int) > 0;
      if (!present) {
        await _backend.run(const [SqlStatement(_addGameColumnSql)]);
      }
    } catch (_) {
      _schemaReady = null; // let the next call retry
      rethrow;
    }
  }

  static const _hasGameColumnSql =
      'SELECT COUNT(*) AS n FROM pragma_table_info(?) WHERE name = ?';
  static const _addGameColumnSql =
      "ALTER TABLE results ADD COLUMN game TEXT NOT NULL DEFAULT ''";

  static const _schemaSql = <String>[
    'CREATE TABLE IF NOT EXISTS results ('
        'id INTEGER PRIMARY KEY AUTOINCREMENT, '
        'game_id TEXT NOT NULL, '
        'seat_id TEXT NOT NULL, '
        'name TEXT NOT NULL, '
        'color TEXT NOT NULL, '
        'rank INTEGER NOT NULL, '
        'played_at INTEGER NOT NULL, '
        "game TEXT NOT NULL DEFAULT '')",
    'CREATE INDEX IF NOT EXISTS idx_results_seat ON results(seat_id)',
    'CREATE UNIQUE INDEX IF NOT EXISTS idx_results_game_seat '
        'ON results(game_id, seat_id)',
    'CREATE TABLE IF NOT EXISTS players ('
        'seat_id TEXT PRIMARY KEY, '
        'name TEXT NOT NULL)',
    'CREATE TABLE IF NOT EXISTS admin_players ('
        'seat_id TEXT PRIMARY KEY, '
        'name TEXT NOT NULL, '
        'first_seen INTEGER NOT NULL, '
        'last_seen INTEGER NOT NULL)',
    'CREATE TABLE IF NOT EXISTS admin_bans ('
        'seat_id TEXT PRIMARY KEY, '
        'reason TEXT NOT NULL, '
        'banned_by TEXT NOT NULL, '
        'banned_at INTEGER NOT NULL, '
        'until_ms INTEGER)',
    'CREATE TABLE IF NOT EXISTS admin_audit ('
        'id INTEGER PRIMARY KEY AUTOINCREMENT, '
        'action TEXT NOT NULL, '
        'seat_id TEXT NOT NULL, '
        'by_name TEXT NOT NULL, '
        'detail TEXT, '
        'at_ms INTEGER NOT NULL)',
    'CREATE TABLE IF NOT EXISTS admin_rooms ('
        'id INTEGER PRIMARY KEY AUTOINCREMENT, '
        'code TEXT NOT NULL, '
        'game TEXT NOT NULL, '
        'instance TEXT NOT NULL, '
        'created_at INTEGER NOT NULL, '
        'started_at INTEGER, '
        'closed_at INTEGER, '
        'status TEXT NOT NULL, '
        'player_count INTEGER NOT NULL DEFAULT 0, '
        'winner_seat TEXT)',
    'CREATE INDEX IF NOT EXISTS idx_admin_rooms_code ON admin_rooms(code)',
    'CREATE INDEX IF NOT EXISTS idx_admin_rooms_created '
        'ON admin_rooms(created_at)',
    'CREATE TABLE IF NOT EXISTS auth_users ('
        'id INTEGER PRIMARY KEY AUTOINCREMENT, '
        'email TEXT NOT NULL UNIQUE, '
        'name TEXT NOT NULL, '
        'password_hash TEXT NOT NULL, '
        "role TEXT NOT NULL DEFAULT 'user', "
        'seat_id TEXT, '
        'created_at INTEGER NOT NULL)',
    'CREATE TABLE IF NOT EXISTS auth_sessions ('
        'token_hash TEXT PRIMARY KEY, '
        'user_id INTEGER NOT NULL REFERENCES auth_users(id) ON DELETE CASCADE, '
        'created_at INTEGER NOT NULL, '
        'expires_at INTEGER NOT NULL)',
    'CREATE INDEX IF NOT EXISTS idx_auth_sessions_user '
        'ON auth_sessions(user_id)',
  ];

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
    await ensureSchema();
    await _backend.run([
      SqlStatement(
        'INSERT INTO admin_players (seat_id, name, first_seen, last_seen) '
        'VALUES (?, ?, ?, ?) '
        'ON CONFLICT(seat_id) DO UPDATE SET name = excluded.name, '
        'last_seen = excluded.last_seen',
        [seatId, name, atMs, atMs],
      ),
    ]);
  }

  Future<AdminPlayer?> player(String seatId) async {
    await ensureSchema();
    final results = await _backend.run([
      SqlStatement(
        'SELECT seat_id, name, first_seen, last_seen FROM admin_players '
        'WHERE seat_id = ?',
        [seatId],
      ),
    ]);
    final row = results.first.firstRow;
    if (row == null) return null;
    return AdminPlayer(
      seatId: row['seat_id'] as String,
      name: row['name'] as String,
      firstSeen: row['first_seen'] as int,
      lastSeen: row['last_seen'] as int,
    );
  }

  Future<List<AdminPlayer>> allPlayers({int limit = 100}) async {
    await ensureSchema();
    final results = await _backend.run([
      SqlStatement(
        'SELECT seat_id, name, first_seen, last_seen FROM admin_players '
        'ORDER BY last_seen DESC LIMIT ?',
        [limit],
      ),
    ]);
    return [
      for (final r in results.first.rows)
        AdminPlayer(
          seatId: r['seat_id'] as String,
          name: r['name'] as String,
          firstSeen: r['first_seen'] as int,
          lastSeen: r['last_seen'] as int,
        ),
    ];
  }

  Future<List<NewPlayersDay>> newPlayersPerDay({int days = 7}) async {
    await ensureSchema();
    final nowDay = DateTime.now().millisecondsSinceEpoch ~/ 86400000;
    final firstDay = nowDay - days + 1;
    final results = await _backend.run([
      SqlStatement(
        'SELECT first_seen / 86400000 AS day, COUNT(*) AS n '
        'FROM admin_players '
        'WHERE first_seen >= ? AND first_seen < ? '
        'GROUP BY day',
        [firstDay * 86400000, (nowDay + 1) * 86400000],
      ),
    ]);
    final counts = <int, int>{
      for (final row in results.first.rows) row['day'] as int: row['n'] as int,
    };
    return [
      for (var day = firstDay; day <= nowDay; day++)
        NewPlayersDay(day: day, newPlayers: counts[day] ?? 0),
    ];
  }

  // --------------------------------------------------------- moderation

  Future<bool> isBanned(String seatId) async {
    await ensureSchema();
    final results = await _backend.run([
      SqlStatement('SELECT until_ms FROM admin_bans WHERE seat_id = ?', [
        seatId,
      ]),
    ]);
    final row = results.first.firstRow;
    if (row == null) return false;
    final until = row['until_ms'] as int?;
    if (until == null) return true;
    return until > DateTime.now().millisecondsSinceEpoch;
  }

  Future<void> ban({
    required String seatId,
    required String reason,
    required String by,
    int? untilMs,
  }) async {
    await ensureSchema();
    final now = DateTime.now().millisecondsSinceEpoch;
    await _backend.run([
      SqlStatement(
        'INSERT INTO admin_bans (seat_id, reason, banned_by, banned_at, '
        'until_ms) VALUES (?, ?, ?, ?, ?) '
        'ON CONFLICT(seat_id) DO UPDATE SET reason = excluded.reason, '
        'banned_by = excluded.banned_by, banned_at = excluded.banned_at, '
        'until_ms = excluded.until_ms',
        [seatId, reason, by, now, untilMs],
      ),
      _auditStatement(action: 'ban', seatId: seatId, by: by, detail: reason),
    ]);
  }

  Future<void> unban(String seatId, {String by = 'admin'}) async {
    await ensureSchema();
    await _backend.run([
      SqlStatement('DELETE FROM admin_bans WHERE seat_id = ?', [seatId]),
      _auditStatement(action: 'unban', seatId: seatId, by: by),
    ]);
  }

  Future<List<AuditEntry>> auditLog({int limit = 50}) async {
    await ensureSchema();
    final results = await _backend.run([
      SqlStatement(
        'SELECT action, seat_id, by_name, detail, at_ms FROM admin_audit '
        'ORDER BY id DESC LIMIT ?',
        [limit],
      ),
    ]);
    return [
      for (final r in results.first.rows)
        AuditEntry(
          action: r['action'] as String,
          seatId: r['seat_id'] as String,
          by: r['by_name'] as String,
          at: r['at_ms'] as int,
          detail: r['detail'] as String?,
        ),
    ];
  }

  static SqlStatement _auditStatement({
    required String action,
    required String seatId,
    required String by,
    String? detail,
  }) => SqlStatement(
    'INSERT INTO admin_audit (action, seat_id, by_name, detail, at_ms) '
    'VALUES (?, ?, ?, ?, ?)',
    [action, seatId, by, detail, DateTime.now().millisecondsSinceEpoch],
  );

  Future<void> _audit({
    required String action,
    required String seatId,
    required String by,
    String? detail,
  }) async {
    await _backend.run([
      _auditStatement(action: action, seatId: seatId, by: by, detail: detail),
    ]);
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
    await ensureSchema();
    final now = DateTime.now().millisecondsSinceEpoch;
    await _backend.run([
      SqlStatement(
        'INSERT OR IGNORE INTO results '
        '(game_id, seat_id, name, color, rank, played_at, game) '
        'VALUES (?, ?, ?, ?, ?, ?, ?)',
        [gameId, seatId, name, color, rank, now, game],
      ),
      SqlStatement(
        'INSERT INTO players (seat_id, name) VALUES (?, ?) '
        'ON CONFLICT(seat_id) DO UPDATE SET name = excluded.name',
        [seatId, name],
      ),
    ]);
  }

  Future<List<LeaderboardEntry>> topPlayers({
    int limit = 10,
    String? game,
  }) async {
    await ensureSchema();
    final results = await _backend.run([
      SqlStatement(
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
      ),
    ]);
    return [
      for (final row in results.first.rows)
        LeaderboardEntry(
          seatId: row['seat_id'] as String,
          name: row['name'] as String,
          wins: row['wins'] as int,
          games: row['games'] as int,
          avgRank: (row['avg_rank'] as num).toDouble(),
        ),
    ];
  }

  Future<int> totalGames({String? game}) async {
    await ensureSchema();
    final results = await _backend.run([
      SqlStatement(
        'SELECT COUNT(DISTINCT game_id) AS n FROM results'
        '${game != null ? ' WHERE game = ?' : ''}',
        [?game],
      ),
    ]);
    return results.first.rows.first['n'] as int;
  }

  Future<void> renamePlayer({
    required String seatId,
    required String name,
    required String by,
  }) async {
    await ensureSchema();
    await _backend.run([
      SqlStatement('UPDATE players SET name = ? WHERE seat_id = ?', [
        name,
        seatId,
      ]),
      SqlStatement('UPDATE admin_players SET name = ? WHERE seat_id = ?', [
        name,
        seatId,
      ]),
      _auditStatement(action: 'rename', seatId: seatId, by: by, detail: name),
    ]);
  }

  Future<void> deleteGame(String gameId, {String by = 'admin'}) async {
    await ensureSchema();
    await _backend.run([
      SqlStatement('DELETE FROM results WHERE game_id = ?', [gameId]),
      _auditStatement(action: 'deleteGame', seatId: gameId, by: by),
    ]);
  }

  // -------------------------------------------------------------- rooms

  Future<void> recordRoomCreated({
    required String code,
    required String game,
    required String instance,
  }) async {
    await ensureSchema();
    await _backend.run([
      SqlStatement(
        'INSERT INTO admin_rooms '
        '(code, game, instance, created_at, status, player_count) '
        'VALUES (?, ?, ?, ?, ?, ?)',
        [
          code,
          game,
          instance,
          DateTime.now().millisecondsSinceEpoch,
          'lobby',
          1,
        ],
      ),
    ]);
  }

  Future<void> recordRoomStarted(String code) async {
    await ensureSchema();
    await _backend.run([
      SqlStatement(
        'UPDATE admin_rooms SET status = ?, started_at = ? '
        'WHERE id = (SELECT id FROM admin_rooms WHERE code = ? '
        'ORDER BY id DESC LIMIT 1)',
        ['live', DateTime.now().millisecondsSinceEpoch, code],
      ),
    ]);
  }

  Future<void> recordRoomClosed(
    String code, {
    String? winnerSeat,
    int playerCount = 0,
  }) async {
    await ensureSchema();
    await _backend.run([
      SqlStatement(
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
      ),
    ]);
  }

  Future<List<AdminRoom>> recentRooms({int limit = 50}) async {
    await ensureSchema();
    final results = await _backend.run([
      SqlStatement(
        'SELECT code, game, instance, created_at, started_at, closed_at, '
        'status, player_count, winner_seat FROM admin_rooms '
        'ORDER BY id DESC LIMIT ?',
        [limit],
      ),
    ]);
    return [
      for (final r in results.first.rows)
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

  Future<int> totalRooms() async {
    await ensureSchema();
    final results = await _backend.run(const [
      SqlStatement('SELECT COUNT(*) AS n FROM admin_rooms'),
    ]);
    return results.first.rows.first['n'] as int;
  }

  Future<AdminOverview> overview() async {
    await ensureSchema();
    final now = DateTime.now().millisecondsSinceEpoch;
    final results = await _backend.run([
      const SqlStatement('SELECT COUNT(*) AS n FROM admin_players'),
      const SqlStatement('SELECT COUNT(DISTINCT game_id) AS n FROM results'),
      const SqlStatement('SELECT COUNT(*) AS n FROM admin_rooms'),
      SqlStatement(
        'SELECT COUNT(*) AS n FROM admin_bans '
        'WHERE until_ms IS NULL OR until_ms > ?',
        [now],
      ),
    ]);
    return AdminOverview(
      totalPlayers: results[0].rows.first['n'] as int,
      totalGames: results[1].rows.first['n'] as int,
      totalRooms: results[2].rows.first['n'] as int,
      bannedPlayers: results[3].rows.first['n'] as int,
    );
  }

  // -------------------------------------------------- users & sessions
  //
  // Shared by admins today and players tomorrow: one accounts table with
  // roles, one sessions table with hashed opaque tokens. The player lane
  // later adds self-registration (role 'user' + seat_id link) and reuses
  // createSession/validateSession unchanged.

  static const _userRoles = {'admin', 'moderator', 'user'};

  Future<int> userCount() async {
    await ensureSchema();
    final results = await _backend.run(const [
      SqlStatement('SELECT COUNT(*) AS n FROM auth_users'),
    ]);
    return results.first.rows.first['n'] as int;
  }

  Future<bool> get needsSetup async => await userCount() == 0;

  AuthUser _userFromRow(Map<String, Object?> row) => AuthUser(
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
    String by = 'system',
  }) async {
    await ensureSchema();
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
    final existing = await _backend.run([
      SqlStatement('SELECT id FROM auth_users WHERE email = ?', [normalized]),
    ]);
    if (existing.first.rows.isNotEmpty) {
      throw StateError('email already registered');
    }
    final now = DateTime.now().millisecondsSinceEpoch;
    final results = await _backend.run([
      SqlStatement(
        'INSERT INTO auth_users '
        '(email, name, password_hash, role, seat_id, created_at) '
        'VALUES (?, ?, ?, ?, ?, ?)',
        [
          normalized,
          name.trim().isEmpty ? normalized : name.trim(),
          // Bcrypt is deliberately slow and this store hashes at
          // [bcryptRounds] — ~370ms per password in production, paid inline
          // on the login/create path itself.
          hashPassword(password, rounds: bcryptRounds),
          role,
          seatId,
          now,
        ],
      ),
      _auditStatement(action: 'userCreate', seatId: normalized, by: by),
      SqlStatement('SELECT * FROM auth_users WHERE email = ?', [normalized]),
    ]);
    return _userFromRow(results.last.rows.first);
  }

  Future<AuthUser?> findUserByEmail(String email) async {
    await ensureSchema();
    final results = await _backend.run([
      SqlStatement('SELECT * FROM auth_users WHERE email = ?', [
        normalizeEmail(email),
      ]),
    ]);
    final row = results.first.firstRow;
    return row == null ? null : _userFromRow(row);
  }

  Future<AuthUser?> findUserById(int id) async {
    await ensureSchema();
    final results = await _backend.run([
      SqlStatement('SELECT * FROM auth_users WHERE id = ?', [id]),
    ]);
    final row = results.first.firstRow;
    return row == null ? null : _userFromRow(row);
  }

  /// Null on unknown email OR wrong password — callers must not
  /// distinguish the two (no account enumeration), and the two paths must
  /// not be distinguishable by *timing* either: an absent email still runs
  /// a full bcrypt verification against [absentEmailHash] — a cost-12 hash
  /// of a preimage nobody has — so a probe of an unregistered address
  /// costs the same work as a wrong password on a real one (CWE-208).
  /// The decoy verify rides the production bcrypt path directly rather than
  /// [_verifier], so a test's cheap injected verifier cannot quietly make
  /// the absent branch instantaneous while the real one pays.
  ///
  /// A row still holding the pre-bcrypt PBKDF2 form is verified off the
  /// event loop and, on success, rewritten with a bcrypt digest at
  /// [bcryptRounds]. That one-time upgrade is what lets an account created
  /// before the bcrypt release log in at all; the legacy window is a single
  /// successful login per row. Its wrong-password path costs the row's
  /// stored PBKDF2 work rather than the bcrypt decoy, so legacy rows are not
  /// timing-identical until upgraded — a bounded exception for accounts that
  /// already existed, not the steady state. A failed upgrade write does not
  /// deny the login (the password was already correct): the row stays
  /// legacy and the next login retries.
  Future<AuthUser?> checkCredentials(String email, String password) async {
    await ensureSchema();
    final results = await _backend.run([
      SqlStatement('SELECT * FROM auth_users WHERE email = ?', [
        normalizeEmail(email),
      ]),
    ]);
    final row = results.first.firstRow;
    if (row == null) {
      // Spend the verification work anyway; its result is discarded
      // because there is no account to admit.
      verifyPassword(password, absentEmailHash);
      return null;
    }
    final stored = row['password_hash'] as String;
    final legacy = isLegacyPasswordHash(stored);
    final ok = legacy
        ? await verifyPasswordOffLoop(password, stored)
        : _verifier(password, stored);
    if (!ok) return null;
    if (legacy) {
      try {
        await _backend.run([
          SqlStatement('UPDATE auth_users SET password_hash = ? WHERE id = ?', [
            hashPassword(password, rounds: bcryptRounds),
            row['id'],
          ]),
        ]);
      } catch (_) {
        // Correct password, failed upgrade: admit the operator and retry
        // the rewrite on the next login rather than turning a credential
        // that just verified into a 500.
      }
    }
    return _userFromRow(row);
  }

  Future<List<AuthUser>> listUsers({int limit = 100}) async {
    await ensureSchema();
    final results = await _backend.run([
      SqlStatement('SELECT * FROM auth_users ORDER BY id ASC LIMIT ?', [limit]),
    ]);
    return [for (final r in results.first.rows) _userFromRow(r)];
  }

  Future<void> setUserRole({
    required int userId,
    required String role,
    required String by,
  }) async {
    await ensureSchema();
    if (!_userRoles.contains(role)) throw ArgumentError('unknown role $role');
    await _backend.run([
      SqlStatement('UPDATE auth_users SET role = ? WHERE id = ?', [
        role,
        userId,
      ]),
    ]);
    final user = await findUserById(userId);
    await _audit(
      action: 'roleChange',
      seatId: user?.email ?? '$userId',
      by: by,
      detail: role,
    );
  }

  /// A two-hour window measured from session creation: the operator's whole
  /// shift fits, and an unattended tab is stale within half an afternoon.
  /// The window is this store's [sessionTtl] — ADMIN_SESSION_TTL_HOURS may
  /// raise or lower it at boot, but every stamp comes from that one clock
  /// and every cookie lifetime mirrors the row, so there is nowhere for
  static const defaultSessionTtl = Duration(hours: 2);

  /// Parses the boot knob. Unset or empty = [defaultSessionTtl]; a positive
  /// integer is hours; anything else (zero, negative, decimal, text) is
  /// invalid and the caller must refuse to start — a typo in the
  /// environment must not silently shorten or stretch every admin's
  /// session. Returns null exactly when the value is garbage so `main()`'s
  /// boot check and this parser stay a single readable contract.
  static Duration? adminSessionTtlFromEnv(String? raw) {
    final text = raw?.trim() ?? '';
    if (text.isEmpty) return defaultSessionTtl;
    final hours = int.tryParse(text);
    if (hours == null || hours <= 0) return null;
    return Duration(hours: hours);
  }

  Future<SessionToken> createSession(int userId) => createSessionAt(
    userId,
    DateTime.now().millisecondsSinceEpoch,
  );

  /// [atMs] is injectable so tests can pin the instant the row is stamped.
  Future<SessionToken> createSessionAt(int userId, int atMs) async {
    await ensureSchema();
    final token = randomToken();
    await _backend.run([
      SqlStatement(
        'INSERT INTO auth_sessions '
        '(token_hash, user_id, created_at, expires_at) VALUES (?, ?, ?, ?)',
        [
          hashToken(token),
          userId,
          atMs,
          atMs + sessionTtl.inMilliseconds,
        ],
      ),
    ]);
    return SessionToken(token: token, expiresAt: atMs + sessionTtl.inMilliseconds);
  }

  /// The session's user, or null when unknown/expired. Expired rows are
  /// deleted lazily on sight.
  Future<AuthUser?> validateSession(String token) async {
    await ensureSchema();
    final digest = hashToken(token);
    final results = await _backend.run([
      SqlStatement(
        'SELECT u.*, s.expires_at AS session_expires_at FROM auth_users u '
        'JOIN auth_sessions s ON s.user_id = u.id '
        'WHERE s.token_hash = ?',
        [digest],
      ),
    ]);
    final row = results.first.firstRow;
    if (row == null) return null;
    final expiry = row['session_expires_at'] as int;
    if (expiry <= DateTime.now().millisecondsSinceEpoch) {
      await _backend.run([
        SqlStatement('DELETE FROM auth_sessions WHERE token_hash = ?', [
          digest,
        ]),
      ]);
      return null;
    }
    return _userFromRow(row);
  }

  Future<void> revokeSession(String token) async {
    await ensureSchema();
    await _backend.run([
      SqlStatement('DELETE FROM auth_sessions WHERE token_hash = ?', [
        hashToken(token),
      ]),
    ]);
  }

  Future<void> revokeUserSessions(int userId) async {
    await ensureSchema();
    await _backend.run([
      SqlStatement('DELETE FROM auth_sessions WHERE user_id = ?', [userId]),
    ]);
  }

  // ------------------------------------------------- generic table CRUD
  //
  // Powers the dashboard's Data tab: list/insert/update/delete on the
  // whitelisted tables from [adminTableSpecs]. Identifiers come only from
  // the specs; request values are always bound parameters, so no request
  // input ever becomes SQL structure.

  /// One page of rows. [q] is a naive substring match across every
  /// column (text-cast) — enough for a triage/lookup tool.
  Future<List<Map<String, dynamic>>> tableRows(
    AdminTableSpec spec, {
    int limit = 100,
    int offset = 0,
    String? q,
  }) async {
    await ensureSchema();
    final where = <String>[];
    final args = <dynamic>[];
    if (q != null && q.trim().isNotEmpty) {
      final needle = '%${q.trim()}%';
      where.add(
        [for (final c in spec.columns) "CAST($c AS TEXT) LIKE ?"].join(' OR '),
      );
      args.addAll([for (final _ in spec.columns) needle]);
    }
    final results = await _backend.run([
      SqlStatement(
        'SELECT ${spec.columns.join(', ')} FROM ${spec.name} '
        '${where.isEmpty ? '' : 'WHERE (${where.first}) '}'
        'ORDER BY ${spec.orderBy} LIMIT ? OFFSET ?',
        [...args, limit, offset],
      ),
    ]);
    return [for (final r in results.first.rows) Map<String, dynamic>.of(r)];
  }

  Future<int> tableCount(AdminTableSpec spec, {String? q}) async {
    await ensureSchema();
    final where = <String>[];
    final args = <dynamic>[];
    if (q != null && q.trim().isNotEmpty) {
      final needle = '%${q.trim()}%';
      where.add(
        [for (final c in spec.columns) "CAST($c AS TEXT) LIKE ?"].join(' OR '),
      );
      args.addAll([for (final _ in spec.columns) needle]);
    }
    final results = await _backend.run([
      SqlStatement(
        'SELECT COUNT(*) AS n FROM ${spec.name} '
        '${where.isEmpty ? '' : 'WHERE (${where.first})'}',
        args,
      ),
    ]);
    return results.first.rows.first['n'] as int;
  }

  /// Only [AdminTableSpec.editable] columns are accepted; text primary
  /// keys may also be set ON INSERT (a row needs its identity) but never
  /// RENAMED by a later edit — editing pks breaks the cross-table seat
  /// references. DB defaults fill the rest (status/priority/timestamps);
  /// values are bound, never inlined. Throws [ArgumentError] on an
  /// unknown column.
  Future<void> insertTableRow(
    AdminTableSpec spec,
    Map<String, dynamic> values,
  ) async {
    await ensureSchema();
    if (!spec.insertable) {
      throw ArgumentError("table '${spec.name}' does not allow inserts");
    }
    final writable = {...spec.editable, spec.pk};
    final cols = <String>[];
    final args = <dynamic>[];
    for (final e in values.entries) {
      if (!writable.contains(e.key)) {
        throw ArgumentError("column '${e.key}' is not writable");
      }
      cols.add(e.key);
      args.add(_boundValue(e.value));
    }
    if (cols.isEmpty) throw ArgumentError('no values to insert');
    await _backend.run([
      SqlStatement(
        'INSERT INTO ${spec.name} (${cols.join(', ')}) '
        'VALUES (${cols.map((_) => '?').join(', ')})',
        args,
      ),
    ]);
  }

  /// Updates one row by primary key. Returns false when no row matched.
  Future<bool> updateTableRow(
    AdminTableSpec spec,
    String pkValue,
    Map<String, dynamic> values,
  ) async {
    await ensureSchema();
    final sets = <String>[];
    final args = <dynamic>[];
    for (final e in values.entries) {
      if (!spec.editable.contains(e.key)) {
        throw ArgumentError("column '${e.key}' is not writable");
      }
      sets.add('${e.key} = ?');
      args.add(_boundValue(e.value));
    }
    if (sets.isEmpty) return true;
    args.add(_coercePk(spec, pkValue));
    final results = await _backend.run([
      SqlStatement(
        'UPDATE ${spec.name} SET ${sets.join(', ')} '
        'WHERE ${spec.pk} = ?',
        args,
      ),
    ]);
    return results.first.affected > 0;
  }

  /// Deletes one row by primary key. Returns false when no row matched.
  Future<bool> deleteTableRow(AdminTableSpec spec, String pkValue) async {
    await ensureSchema();
    final results = await _backend.run([
      SqlStatement('DELETE FROM ${spec.name} WHERE ${spec.pk} = ?', [
        _coercePk(spec, pkValue),
      ]),
    ]);
    return results.first.affected > 0;
  }

  dynamic _coercePk(AdminTableSpec spec, String raw) =>
      spec.pkIsText ? raw : (int.tryParse(raw) ?? -1);

  /// JSON values arrive as String/num/bool/null; booleans become ints so
  /// the database stores 0/1 rather than failing to bind.
  dynamic _boundValue(dynamic v) => switch (v) {
    final bool b => b ? 1 : 0,
    final num n => n.toInt() == n ? n.toInt() : n.toDouble(),
    _ => v,
  };

  /// Public audit hook for actions outside this store (the feedback
  /// triage lives in [ReportStore] and still belongs in the log).
  Future<void> recordAdminAction({
    required String action,
    required String subject,
    required String by,
    String? detail,
  }) async {
    await ensureSchema();
    await _audit(action: action, seatId: subject, by: by, detail: detail);
  }

  void close() {
    if (_ownsBackend) _backend.close();
  }
}
