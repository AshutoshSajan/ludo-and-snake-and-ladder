/// One place decides where every durable server store lives.
///
/// Before this module, `bin/server.dart` wired each store by hand. That is
/// how the admin/auth/feedback tables ended up on the host's SQLite file
/// while leaderboard/friends/room-routing lived in Turso: each new store
/// re-made the "local or remote?" decision in its own few lines, and one
/// of them eventually made it differently.
///
/// [openPersistence] makes the decision exactly once:
///
/// * `TURSO_DATABASE_URL` + `TURSO_AUTH_TOKEN` set → **every** store is
///   Turso-backed and no local SQLite handle is opened. Turso is the single
///   store of record.
/// * Otherwise → **every** store runs on one local SQLite file. That mode
///   exists for development and tests only; it is never a second copy
///   beside a Turso deployment.
///
/// The guard is mechanical, not a convention: `test/persistence_test.dart`
/// opens the factory with Turso credentials, proves every store writes to
/// the fake remote database, and proves the local file was never created.
/// A source ratchet in the same test fails if `bin/server.dart` starts
/// constructing a store directly again.
library;

import 'package:http/http.dart' as http;
import 'package:sqlite3/sqlite3.dart';

import 'admin_store.dart';
import 'friend_store.dart';
import 'leaderboard_store.dart';
import 'report_store.dart';
import 'room_registry.dart';
import 'sql_backend.dart';
import 'turso_friend_store.dart';
import 'turso_leaderboard_store.dart';

/// The server's durable stores, opened as one unit from one environment.
///
/// Fields are typed at the shared interfaces, so callers cannot depend on
/// a particular backend. [usesTurso] is the mode this instance chose;
/// [registryTtl] is the room-registry TTL the refresh timer must use (null
/// for the in-memory registry).
class ServerPersistence {
  ServerPersistence._({
    required this.usesTurso,
    required this.leaderboard,
    required this.admin,
    required this.reports,
    required this.friends,
    required this.rooms,
    required this.registryTtl,
    required this._onClose,
  });

  /// True when every store below is backed by Turso.
  final bool usesTurso;

  final LeaderboardStore leaderboard;
  final AdminStore admin;
  final ReportStore reports;
  final FriendStore friends;
  final RoomRegistry rooms;

  /// TTL of the Turso room registry; null when rooms are process-local.
  final Duration? registryTtl;

  final void Function() _onClose;
  var _closed = false;

  /// Creates every schema up front so a misconfigured deployment fails at
  /// boot instead of on the first request. Every statement is idempotent.
  Future<void> ensureSchema() async {
    await admin.ensureSchema();
    await reports.ensureSchema();
    final friendStore = friends;
    if (friendStore is TursoFriendStore) await friendStore.ensureSchema();
  }

  /// Releases the connections this instance owns. Idempotent.
  void close() {
    if (_closed) return;
    _closed = true;
    _onClose();
  }
}

/// Opens every durable store for [env], using [dbPath] only when Turso is
/// not configured.
///
/// [tursoClient] lets tests point every remote store at one fake pipeline;
/// production leaves it null and the factory owns (and closes) a real
/// HTTP client.
ServerPersistence openPersistence({
  required Map<String, String> env,
  required String dbPath,
  http.Client? tursoClient,
  Duration? sessionTtl,
}) {
  // Presence of the leaderboard credentials is the single mode switch:
  // every other Turso store reads the same two variables, so this one
  // check cannot disagree with them.
  final leaderboard = TursoLeaderboardStore.fromEnvironment(
    env,
    client: tursoClient,
  );
  if (leaderboard != null) {
    return _openTurso(env, leaderboard, tursoClient, sessionTtl);
  }
  return _openLocal(dbPath, sessionTtl);
}

ServerPersistence _openTurso(
  Map<String, String> env,
  LeaderboardStore leaderboard,
  http.Client? tursoClient,
  Duration? sessionTtl,
) {
  final client = tursoClient ?? http.Client();
  final ownsClient = tursoClient == null;

  try {
    // One backend and one client for admin history, accounts, sessions and
    // feedback. The stores below deliberately do NOT own the backend.
    final backend = TursoBackend.fromEnvironment(env, client: client);
    final friends = TursoFriendStore.fromEnvironment(env, client: client);
    final rooms = TursoRoomRegistry.fromEnvironment(env, client: client);
    if (backend == null || friends == null || rooms == null) {
      throw StateError(
        'Turso credentials produced a partial persistence configuration',
      );
    }

    return ServerPersistence._(
      usesTurso: true,
      leaderboard: leaderboard,
      admin: AdminStore.fromBackend(backend, sessionTtl: sessionTtl),
      reports: ReportStore.fromBackend(backend),
      friends: friends,
      rooms: rooms,
      registryTtl: rooms.ttl,
      onClose: () {
        leaderboard.close();
        friends.close();
        rooms.close();
        backend.close();
        if (ownsClient) client.close();
      },
    );
  } catch (_) {
    if (ownsClient) client.close();
    rethrow;
  }
}

ServerPersistence _openLocal(String dbPath, Duration? sessionTtl) {
  // One connection for admin, feedback and friends; the leaderboard store
  // keeps its own handle exactly as it did before the factory existed.
  final db = sqlite3.open(dbPath);
  try {
    final leaderboard = SqliteLeaderboardStore(dbPath);
    return ServerPersistence._(
      usesTurso: false,
      leaderboard: leaderboard,
      admin: AdminStore.fromDb(db, sessionTtl: sessionTtl),
      reports: ReportStore.fromDb(db),
      friends: SqliteFriendStore.fromDb(db),
      rooms: InMemoryRoomRegistry(),
      registryTtl: null,
      onClose: () {
        leaderboard.close();
        db.close();
      },
    );
  } catch (_) {
    db.close();
    rethrow;
  }
}
