/// Cross-instance room registry — the piece that lets several game-server
/// instances live behind a load balancer without sharing memory.
///
/// Each instance owns its rooms in process memory (`GameAuthority.rooms`).
/// When a player's WebSocket upgrade lands on the "wrong" instance (the LB
/// cannot always route by room code — e.g. a reconnect that carries a code
/// created on another box, or quick-match where the code does not exist yet),
/// the edge can ask this registry which instance owns the room and forward
/// or redirect there:
///
///     GET /rooms/lookup?code=ABCD   ->  {"ok": true, "code": "ABCD",
///                                       "instance": "game-2"}
///
/// Two implementations ship:
///
/// * [InMemoryRoomRegistry] — single-instance mode and tests. `lookup`
///   answers for every room of the current process.
/// * [TursoRoomRegistry] — a TTL map in a Turso (libSQL) database over the
///   same SQL-over-HTTP pipeline API the leaderboard store uses. Entries
///   expire automatically, so a crashed instance leaves no stale routes;
///   each surviving instance refreshes its rooms on a short sweep.
///
/// Configure Turso with the same env vars as the leaderboard store
/// (`TURSO_DATABASE_URL` + `TURSO_AUTH_TOKEN`), plus optional
/// `ROOM_TTL_SECONDS` (default 120).
library;

import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

/// Where clients should be routed for a room code.
abstract class RoomRegistry {
  /// Claims or refreshes `code -> instanceId`. Returns false when a live
  /// entry owned by a DIFFERENT instance exists (a cross-replica duplicate
  /// code) — or when the same instance owns it under a DIFFERENT [owner]
  /// token (two concurrent creations on one replica drawing the same code):
  /// a live route belongs to exactly one room, so the claim must not
  /// replace the row's owner. Were both claims answered with true, the
  /// loser's cleanup would [unregister] the winner's live route. The claim
  /// is refused so routing stays stable instead of flip-flopping between
  /// owners. Expired entries are fair game. A false return means the caller
  /// must pick another code. [owner] is an opaque per-room token: codes are
  /// recycled the moment a room closes, so two rooms can briefly share one
  /// code and the token is what later lets [unregister] tell them apart.
  Future<bool> register(String code, String instanceId, {String? owner});

  /// The owning instance id, or null when the room is unknown (or its
  /// entry has expired).
  Future<String?> lookup(String code);

  /// Drops the mapping (e.g. the room closed cleanly). When [owner] is
  /// given, only the row still owned by THAT room is deleted: a close's
  /// delete is asynchronous, and a newer room may already have claimed the
  /// same code by the time it lands — deleting unconditionally would erase
  /// the live room's route. A null [owner] drops unconditionally.
  Future<void> unregister(String code, {String? owner});
}

/// Single-process registry: every lookup in this process succeeds. Used
/// when the server runs as one instance (the common case today) and in
/// tests.
class InMemoryRoomRegistry implements RoomRegistry {
  final Map<String, String> _owners = {};
  final Map<String, String?> _rowOwners = {};

  @override
  Future<bool> register(String code, String instanceId,
      {String? owner}) async {
    final current = _owners[code];
    if (current != null && current != instanceId) return false;
    // A live row is refreshable only by the room that owns it: a competing
    // claim (same instance, different token) must not take over the owner,
    // or the refused creation's cleanup would delete the live route when it
    // unregisters the token it thought it had claimed.
    if (current != null && _rowOwners[code] != owner) return false;
    _owners[code] = instanceId;
    _rowOwners[code] = owner;
    return true;
  }

  @override
  Future<String?> lookup(String code) async => _owners[code];

  @override
  Future<void> unregister(String code, {String? owner}) async {
    // A stale close (one whose room's code has already been recycled) must
    // not drop the newer room's row — same protection as the Turso delete.
    if (owner != null && _rowOwners[code] != owner) return;
    _owners.remove(code);
    _rowOwners.remove(code);
  }
}

/// [RoomRegistry] backed by a Turso table with a TTL column. Reads the
/// standard env vars; returns null from [fromEnvironment] when they are
/// missing so callers can fall back to the in-memory registry.
class TursoRoomRegistry implements RoomRegistry {
  TursoRoomRegistry({
    required Uri url,
    required this.authToken,
    http.Client? client,
    this.ttl = const Duration(seconds: 120),
  })  : _baseUrl = normalizeBaseUrl(url),
        _client = client ?? http.Client(),
        _ownsClient = client == null;

  static TursoRoomRegistry? fromEnvironment(
    Map<String, String> env, {
    http.Client? client,
    Duration? ttl,
  }) {
    final url = env['TURSO_DATABASE_URL']?.trim();
    final token = env['TURSO_AUTH_TOKEN']?.trim();
    if (url == null || url.isEmpty || token == null || token.isEmpty) {
      return null;
    }
    final ttlSeconds = int.tryParse(env['ROOM_TTL_SECONDS'] ?? '');
    return TursoRoomRegistry(
      url: Uri.parse(url),
      authToken: token,
      client: client,
      ttl: ttl ?? Duration(seconds: ttlSeconds ?? 120),
    );
  }

  /// `turso://` and `libsql://` URLs are https URLs in disguise.
  static Uri normalizeBaseUrl(Uri url) {
    var text = url.toString();
    for (final scheme in const ['libsql://', 'turso://']) {
      if (text.startsWith(scheme)) {
        text = 'https://${text.substring(scheme.length)}';
      }
    }
    while (text.endsWith('/')) {
      text = text.substring(0, text.length - 1);
    }
    return Uri.parse(text);
  }

  final String authToken;
  final Duration ttl;

  final Uri _baseUrl;
  final http.Client _client;
  final bool _ownsClient;

  // Idempotent schema, replayed on every call so a fresh database works
  // without a migration step (same approach as the leaderboard store).
  static final _schema = <Map<String, dynamic>>[
    _execStmt('CREATE TABLE IF NOT EXISTS room_registry ('
        'code TEXT PRIMARY KEY, '
        'instance TEXT NOT NULL, '
        'owner TEXT, '
        'expires_at INTEGER NOT NULL)'),
  ];

  static const _upsertSql = 'INSERT INTO room_registry (code, instance, '
      'owner, expires_at) VALUES (?, ?, ?, ?) '
      'ON CONFLICT(code) DO UPDATE SET instance = excluded.instance, '
      'owner = excluded.owner, expires_at = excluded.expires_at '
      'WHERE (room_registry.instance = excluded.instance '
      'AND room_registry.owner IS excluded.owner) '
      'OR room_registry.expires_at <= ?';
  static const _gcSql = 'DELETE FROM room_registry WHERE expires_at < ?';
  static const _selectSql =
      'SELECT instance, owner FROM room_registry WHERE code = ?';

  /// Scoped to the closing room's [owner] token: a code is recycled the
  /// moment its room closes, so by the time this slow delete lands a newer
  /// room may own the code — this must not erase the live room's route.
  /// `owner IS ?` (not `= ?`) also matches rows with a NULL owner.
  static const _deleteSql =
      'DELETE FROM room_registry WHERE code = ? AND owner IS ?';

  /// Like the leaderboard pipelines, every pipeline ends with an explicit
  /// `close` so the server-side statement stream is released immediately
  /// instead of lingering until the server times it out.
  static const _close = {'type': 'close'};

  /// A CAS upsert: only the row's current owner — the same instance AND the
  /// same room token — may refresh it, or a row nobody live holds (the GC
  /// has just removed expired rows; `<=` covers the clock edge). A live
  /// foreign claim AND a live claim of another local room are left
  /// untouched, and the trailing [_selectSql] reports who actually owns the
  /// code afterwards — including which token, so a refused competing claim
  /// can never masquerade as a success.
  @override
  Future<bool> register(String code, String instanceId,
      {String? owner}) async {
    final table = await _pipeline([
      ..._schema,
      _execStmt(_gcSql, [_nowMs()]),
      _execStmt(_upsertSql, [code, instanceId, owner, _expiryMs(), _nowMs()]),
      _execStmt(_selectSql, [code]),
      _close,
    ]);
    if (table.rows.isEmpty) return false;
    final row = table.rows.first;
    return row.length > 1 &&
        '${row.first}' == instanceId &&
        row[1] == owner;
  }

  @override
  Future<String?> lookup(String code) async {
    final table = await _pipeline([
      ..._schema,
      _execStmt(_gcSql, [_nowMs()]),
      _execStmt(_selectSql, [code]),
      _close,
    ]);
    return table.rows.isEmpty ? null : '${table.rows.first.first}';
  }

  @override
  Future<void> unregister(String code, {String? owner}) =>
      _pipeline([..._schema, _execStmt(_deleteSql, [code, owner]), _close]);

  int _nowMs() => DateTime.now().millisecondsSinceEpoch;
  int _expiryMs() => _nowMs() + ttl.inMilliseconds;

  /// Releases the underlying HTTP client if this registry owns it.
  void close() {
    if (_ownsClient) _client.close();
  }

  // ------------------------------------------------------- HTTP pipeline

  /// Same bound as the leaderboard transport: a pipeline that never
  /// finishes is abandoned after ten seconds instead of hanging forever
  /// (periodic refreshes would otherwise pile up pending requests).
  static const _timeout = Duration(seconds: 10);

  Future<_RegistryTable> _pipeline(List<Map<String, dynamic>> stmts) async {
    http.Response response;
    try {
      response = await _client
          .post(
            _baseUrl.replace(path: '${_baseUrl.path}/v2/pipeline'),
            headers: {
              'authorization': 'Bearer $authToken',
              'content-type': 'application/json',
            },
            body: jsonEncode({'requests': stmts}),
          )
          .timeout(_timeout);
    } on TimeoutException {
      throw RoomRegistryException(
          'Turso request timed out after ${_timeout.inSeconds}s');
    } catch (e) {
      throw RoomRegistryException('Turso request failed: $e');
    }
    if (response.statusCode != 200) {
      throw RoomRegistryException(
          'Turso returned ${response.statusCode}: ${_snippet(response.body)}');
    }
    final Map<String, dynamic> body;
    try {
      body = jsonDecode(response.body) as Map<String, dynamic>;
    } catch (_) {
      throw RoomRegistryException('Turso returned non-JSON body');
    }
    final results = body['results'] as List<dynamic>? ?? const [];
    for (var i = 0; i < results.length; i++) {
      final entry = results[i];
      if (entry is Map && entry['type'] != 'ok') {
        throw RoomRegistryException(
            'Turso pipeline step $i failed: ${entry['error']}');
      }
    }
    final okResults = [
      for (final entry in results)
        if (entry is Map) (entry['response'] as Map?)?['result'],
    ];
    return _RegistryTable(okResults);
  }

  static String _snippet(String body) {
    final flat = body.replaceAll('\n', ' ').trim();
    return flat.length > 200 ? flat.substring(0, 200) : flat;
  }

  static Map<String, dynamic> _execStmt(String sql,
          [List<Object?>? args]) =>
      {
        'type': 'execute',
        'stmt': {
          'sql': sql,
          if (args != null)
            'args': [
              for (final arg in args) _encodeArg(arg),
            ],
        },
      };

  /// Integers are serialized as strings per the API docs (JSON numbers
  /// cannot hold all 64-bit ints).
  static Map<String, dynamic> _encodeArg(Object? value) => switch (value) {
        null => {'type': 'null', 'value': null},
        int i => {'type': 'integer', 'value': '$i'},
        String s => {'type': 'text', 'value': s},
        _ => throw ArgumentError(
            'unsupported registry arg type: ${value.runtimeType}'),
      };
}

/// A failed registry HTTP request or statement.
class RoomRegistryException implements Exception {
  RoomRegistryException(this.message);

  final String message;

  @override
  String toString() => 'RoomRegistryException: $message';
}

/// Decoded pipeline result: rows of plain Dart values across all execute
/// steps. Only the final SELECT's rows matter for lookup.
class _RegistryTable {
  _RegistryTable(List<dynamic> results) {
    for (final result in results) {
      if (result is! Map) continue;
      final rows = result['rows'] as List<dynamic>? ?? const [];
      for (final row in rows) {
        this.rows.add([for (final cell in row as List<dynamic>) _decode(cell)]);
      }
    }
  }

  final rows = <List<Object?>>[];

  static Object? _decode(Object? cell) {
    if (cell is! Map) return cell;
    final value = cell['value'];
    return switch (cell['type']) {
      'null' || null => null,
      'integer' => value is int ? value : int.parse('$value'),
      'text' => value is String ? value : '$value',
      _ => value,
    };
  }
}
