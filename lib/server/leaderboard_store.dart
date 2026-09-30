/// Leaderboard persistence for the game server.
///
/// The server records every finished online game — one row per player with
/// their finishing rank — and answers HTTP leaderboard queries from it.
/// Two backends implement [LeaderboardStore]:
///
/// * [SqliteLeaderboardStore] — a local SQLite file (the default). Storage
///   uses the `sqlite3` package directly (the process runs on the same host
///   as the DB file), so there is no ORM and no native plugin machinery on
///   the client side.
/// * [TursoLeaderboardStore] (`turso_leaderboard_store.dart`) — a hosted
///   Turso/libSQL database over its HTTP pipeline API, so the leaderboard
///   survives even when the server runs on an ephemeral free host.
library;

import 'package:sqlite3/sqlite3.dart';

/// One ranked result for a player in a finished game.
class GameResult {
  GameResult({
    required this.seatId,
    required this.name,
    required this.color,
    required this.rank,
    this.game = 'ludo',
  });

  final String seatId; // stable player id across games
  final String name; // display name at the time of the game
  final String color; // corner color name, e.g. 'red'
  final int rank; // 1 = first to finish

  /// Which game this result came from: 'ludo' or 'snakes'. Stored per row so
  /// a career can be reported per game — one merged table made every Snakes
  /// result indistinguishable from a Ludo one, which is why the online
  /// leaderboard had no Snakes board to show. Defaults to 'ludo' so callers
  /// that predate the field keep recording Ludo results.
  final String game;
}

/// An aggregated leaderboard row: a player's career stats.
class LeaderboardEntry {
  LeaderboardEntry({
    required this.seatId,
    required this.name,
    required this.wins,
    required this.games,
    required this.avgRank,
  });

  final String seatId;
  final String name; // most recent display name
  final int wins; // games finished first
  final int games; // total games played
  final double avgRank; // lower is better (1.0 = always first)

  Map<String, dynamic> toJson() => {
    'seatId': seatId,
    'name': name,
    'wins': wins,
    'games': games,
    'avgRank': avgRank,
  };
}

/// Reads and writes finished-game results.
///
/// All methods are async so a remote backend (Turso over HTTP) can slot in
/// behind the same interface; the local SQLite implementation does its work
/// synchronously and returns completed futures.
abstract interface class LeaderboardStore {
  /// Records the full result of one game. Safe to call twice for the same
  /// [gameId] — replays are ignored row by row, so a crash between the
  /// broadcast and the write can be recovered on the next completion.
  Future<void> recordResults({
    required String gameId,
    required List<GameResult> results,
  });

  /// Career stats, best first: most wins, then better average rank, then
  /// more games played. Pass [game] to report one game's board only ('ludo'
  /// or 'snakes'); omit it for the combined board.
  Future<List<LeaderboardEntry>> topPlayers({int limit = 10, String? game});

  /// Number of distinct finished games on record, or just those of [game].
  Future<int> totalGames({String? game});

  /// Releases backend resources (database handles, HTTP clients).
  void close();
}

/// SQLite-backed implementation: open with a file path for persistence or
/// [SqliteLeaderboardStore.inMemory] for tests.
class SqliteLeaderboardStore implements LeaderboardStore {
  SqliteLeaderboardStore._(this._db, {required bool owns}) : _ownsDb = owns {
    _migrate();
  }

  /// Opens (or creates) the database at [path]. Parent directories must
  /// already exist.
  factory SqliteLeaderboardStore(String path) =>
      SqliteLeaderboardStore._(sqlite3.open(path), owns: true);

  /// A throwaway store that vanishes with the process — used by tests.
  factory SqliteLeaderboardStore.inMemory() =>
      SqliteLeaderboardStore._(sqlite3.openInMemory(), owns: true);

  /// Wraps an existing [Database] (the caller keeps ownership) — for tests
  /// that pre-populate or share a database.
  factory SqliteLeaderboardStore.fromDb(Database db) =>
      SqliteLeaderboardStore._(db, owns: false);

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
    ''');
    // A database created before per-game boards existed has no `game` column,
    // and CREATE TABLE IF NOT EXISTS above leaves an existing table untouched.
    // Adding it here is what makes an upgrade a no-op for fresh databases and
    // a repair for deployed ones. DEFAULT '' keeps the rows already there: they
    // predate the column, so their game is genuinely unknown, and counting them
    // as Ludo would invent history. They simply appear on the combined board
    // and on neither per-game board.
    final columns = _db
        .select('PRAGMA table_info(results)')
        .map((r) => r['name'] as String);
    if (!columns.contains('game')) {
      _db.execute(
        "ALTER TABLE results ADD COLUMN game TEXT NOT NULL DEFAULT ''",
      );
    }
  }

  @override
  Future<void> recordResults({
    required String gameId,
    required List<GameResult> results,
  }) {
    // Committed synchronously — the future only smooths the interface.
    _record(gameId, results);
    return Future.value();
  }

  void _record(String gameId, List<GameResult> results) {
    final now = DateTime.now().millisecondsSinceEpoch;
    _db.execute('BEGIN');
    try {
      final stmt = _db.prepare(
        'INSERT OR IGNORE INTO results '
        '(game_id, seat_id, name, color, rank, played_at, game) '
        'VALUES (?, ?, ?, ?, ?, ?, ?)',
      );
      final upsert = _db.prepare(
        'INSERT INTO players (seat_id, name) VALUES (?, ?) '
        'ON CONFLICT(seat_id) DO UPDATE SET name = excluded.name',
      );
      try {
        for (final r in results) {
          stmt.execute([
            gameId,
            r.seatId,
            r.name,
            r.color,
            r.rank,
            now,
            r.game,
          ]);
          upsert.execute([r.seatId, r.name]);
        }
      } finally {
        stmt.close();
        upsert.close();
      }
      _db.execute('COMMIT');
    } on SqliteException {
      _db.execute('ROLLBACK');
      rethrow;
    }
  }

  @override
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
      ${game != null ? "WHERE r.game = ?" : ''}
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

  @override
  Future<int> totalGames({String? game}) async =>
      _db.select(
            'SELECT COUNT(DISTINCT game_id) AS n FROM results'
            '${game != null ? ' WHERE game = ?' : ''}',
            [?game],
          ).first['n']
          as int;

  @override
  void close() {
    if (_ownsDb) _db.close();
  }
}
