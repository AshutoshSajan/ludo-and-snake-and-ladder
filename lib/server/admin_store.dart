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

import 'dart:isolate';

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

/// A freshly minted session: the raw token goes to the client once and
/// is never stored; only its hash lives in the DB.
class SessionToken {
  SessionToken({required this.token, required this.expiresAt});

  final String token;
  final int expiresAt;
}

/// Verifies [password] against a stored PBKDF2 [hash]. Injectable so a
/// test can prove which hash a lookup verifies without paying the KDF.
typedef PasswordVerifier = bool Function(String password, String hash);

/// Whether [verifier] is the production KDF rather than an injected test
/// seam. Only the production verifier understands the `pbkdf2$…` format, so
/// only it gets the worker-isolate treatment and the current work factor;
/// an injected closure is often cheap on purpose and may capture plain test
/// state, so it stays inline.
bool _isProductionVerifier(PasswordVerifier verifier) =>
    identical(verifier, verifyPassword);

/// The production verify, off the event loop. A [defaultPbkdf2Iterations]
/// PBKDF2 runs ~4s on this hardware; on the run loop that would freeze
/// every socket the server holds mid-handshake, so each spend moves to a
/// short-lived worker isolate. The parameters are copied across, not a
/// closure over wider state — `password` and `hash` are Strings, and
/// `verifier` is the library's own top-level function the worker can
/// reference directly.
Future<bool> _verifyOffLoop(String password, String hash) =>
    Isolate.run(() => verifyPassword(password, hash));

/// The production hash, off the event loop, for the same reason.
Future<String> _hashOffLoop(String password, int iterations) =>
    Isolate.run(() => hashPassword(password, iterations: iterations));

/// The iteration count recorded inside a stored hash
/// (`pbkdf2$<iters>$<salt>$<hash>`), or null when the string does not
/// declare one cleanly. Malformed rows get `null` and are simply never
/// upgraded.
int? _storedIterations(String stored) {
  final parts = stored.split(r'$');
  if (parts.length != 4 || parts[0] != 'pbkdf2') return null;
  return int.tryParse(parts[1]);
}


class AdminStore {
  AdminStore._(
    this._backend,
    this._ownsBackend, {
    PasswordVerifier? verifier,
    int? kdfIterations,
  }) : _verifier = verifier ?? verifyPassword,
       kdfIterations = kdfIterations ?? defaultPbkdf2Iterations;

  factory AdminStore.inMemory({
    PasswordVerifier? verifier,
    int? kdfIterations,
  }) => AdminStore._(SqliteBackend.inMemory(), true, verifier: verifier, kdfIterations: kdfIterations);

  factory AdminStore(String path, {PasswordVerifier? verifier, int? kdfIterations}) =>
      AdminStore._(
        SqliteBackend.open(path),
        true,
        verifier: verifier,
        kdfIterations: kdfIterations,
      );

  factory AdminStore.fromDb(
    Database db, {
    PasswordVerifier? verifier,
    int? kdfIterations,
  }) => AdminStore._(
    SqliteBackend.fromDb(db),
    false,
    verifier: verifier,
    kdfIterations: kdfIterations,
  );

  /// Wraps any [SqlBackend] (the caller keeps ownership) — this is how a
  /// Turso-backed deployment gets the same admin surface as SQLite.
  factory AdminStore.fromBackend(
    SqlBackend backend, {
    PasswordVerifier? verifier,
    int? kdfIterations,
  }) => AdminStore._(backend, false, verifier: verifier, kdfIterations: kdfIterations);

  final SqlBackend _backend;
  final bool _ownsBackend;
  final PasswordVerifier _verifier;

  /// This store's password work factor: [defaultPbkdf2Iterations] unless a
  /// test threads a small value — the same explicit-threading rule the KDF
  /// itself follows. Three consumers draw from it so one store costs one
  /// number everywhere: new-user hashes (when a createUser call site passes
  /// no explicit `iterations`), the absent-email decoy (see [_absentHash]),
  /// and the rehash-on-login upgrade target.
  ///
  /// Production never passes this; tests that flip [adminStore] or use
  /// `inMemory()` with the real verifier do — the suite otherwise pays a
  /// full second-scale PBKDF2 per login attempt.
  final int kdfIterations;

  String? _absentHashCache;
  Future<String>? _absentHashMinting;

  /// The absent-email decoy hash that [checkCredentials] verifies against
  /// when no account exists — the countershape of CWE-208: an unregistered
  /// address must cost the same PBKDF2 work as a wrong password on a real
  /// one, so the decoy is a hash of a random token nobody stores.
  ///
  /// Minted once per store, lazily, inside a worker isolate: before the
  /// isolate move this was an eagerly-computed top-level final, which
  /// charged the server boot (and every test that imported the file) the
  /// full KDF whether or not anyone ever missed an email. With a test
  /// verifier injected the format is unreadable anyway, so the mint runs at
  /// one iteration and stays instant.
  Future<String> get _absentHash {
    final cached = _absentHashCache;
    if (cached != null) return Future.value(cached);
    return _absentHashMinting ??= _hashOffLoop(
      randomToken(),
      _isProductionVerifier(_verifier) ? kdfIterations : 1,
    ).then((hash) {
      _absentHashCache = hash;
      return hash;
    });
  }

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
    int? iterations,
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
          // Off the event loop: with no explicit call-site value this is
          // [kdfIterations] (the OWASP-floor default in production), a
          // multi-second spend the server cannot afford on its run loop.
          await _hashOffLoop(password, iterations ?? kdfIterations),
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

  /// The stored hash for one account, or null when unknown. A test seam —
  /// [AuthUser] deliberately carries no hash, and production sees hashes
  /// only through the verifier — but the work-factor upgrade tests must
  /// observe what landed in the row: the old rehash-contract bug class
  /// (password rewritten, format regressions) hides behind a passing
  /// login otherwise.
  Future<String?> debugPasswordHash(int userId) async {
    await ensureSchema();
    final results = await _backend.run([
      SqlStatement('SELECT password_hash FROM auth_users WHERE id = ?', [
        userId,
      ]),
    ]);
    final row = results.first.firstRow;
    return row?['password_hash'] as String?;
  }

  /// The absent-email decoy used by [checkCredentials] (test seam, same
  /// rationale as [debugPasswordHash]): a mint is invisible until a miss
  /// happens, and the CWE-208 contract — the decoy carries the store's
  /// work factor — must be observable, not trusted.
  Future<String> debugAbsentHash() => _absentHash;

  /// Null on unknown email OR wrong password — callers must not
  /// distinguish the two (no account enumeration), and the two paths must
  /// not be distinguishable by *timing* either: an absent email still
  /// runs the password KDF against [_absentHash], so a probe of an
  /// unregistered address costs the same PBKDF2 work as a wrong password
  /// on a real one (CWE-208).
  ///
  /// Both verification spends run inside a worker isolate when the store
  /// has the production verifier — a ~4s KDF on the run loop starves every
  /// live socket the server serves. A successful login against a hash built
  /// at a lower work factor is opportunistically upgraded (rehashed) to
  /// [kdfIterations], so legacy rows from the 100k era (and anything the
  /// store's factor has since risen above) earn the current floor the next
  /// time the right operator signs in.
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
      if (_isProductionVerifier(_verifier)) {
        await _verifyOffLoop(password, await _absentHash);
      } else {
        _verifier(password, await _absentHash);
      }
      return null;
    }
    final hash = row['password_hash'] as String;
    final ok = _isProductionVerifier(_verifier)
        ? await _verifyOffLoop(password, hash)
        : _verifier(password, hash);
    if (!ok) return null;
    final user = _userFromRow(row);
    final stored = _storedIterations(hash);
    if (_isProductionVerifier(_verifier) &&
        stored != null &&
        stored < kdfIterations) {
      // One background-grade spend per operator, the first time they sign
      // in after a work-factor bump. Awaited, not fire-and-forget: the
      // login's rate-limit slot is already held for the KDF, and an
      // unawaited write to auth_users on a busy loop is heads-down the
      // same failure mode the isolate move exists to avoid.
      final upgraded = await _hashOffLoop(password, kdfIterations);
      await _backend.run([
        SqlStatement(
          'UPDATE auth_users SET password_hash = ? WHERE id = ?',
          [upgraded, user.id],
        ),
      ]);
      await _audit(
        action: 'passwordRehash',
        seatId: user.email,
        by: 'login',
        detail: '$stored -> $kdfIterations',
      );
    }
    return user;
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

  /// A fixed 12-hour window measured from session creation: no sliding
  /// renewal on activity, so an unattended browser loses access within half
  /// a day at most. The client persists the expiry alongside the token
  /// (services/admin_session_store.dart) and drops its own copy at the same
  /// moment; the server stays the source of truth through the lazy expiry
  /// delete below.
  static const defaultSessionTtl = Duration(hours: 12);

  Future<SessionToken> createSession(
    int userId, {
    Duration ttl = defaultSessionTtl,
  }) async {
    await ensureSchema();
    final token = randomToken();
    final now = DateTime.now().millisecondsSinceEpoch;
    await _backend.run([
      SqlStatement(
        'INSERT INTO auth_sessions '
        '(token_hash, user_id, created_at, expires_at) VALUES (?, ?, ?, ?)',
        [hashToken(token), userId, now, now + ttl.inMilliseconds],
      ),
    ]);
    return SessionToken(token: token, expiresAt: now + ttl.inMilliseconds);
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
