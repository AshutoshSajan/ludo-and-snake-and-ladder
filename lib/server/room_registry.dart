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
  /// code): the claim is refused so routing stays stable instead of
  /// flip-flopping between owners. Expired entries of other instances are
  /// fair game. A false return means the caller must pick another code.
  Future<bool> register(String code, String instanceId);

  /// The owning instance id, or null when the room is unknown (or its
  /// entry has expired).
  Future<String?> lookup(String code);

  /// Drops the mapping (e.g. the room closed cleanly).
  Future<void> unregister(String code);
}

/// Single-process registry: every lookup in this process succeeds. Used
/// when the server runs as one instance (the common case today) and in
/// tests.
class InMemoryRoomRegistry implements RoomRegistry {
  final Map<String, String> _owners = {};

  @override
  Future<bool> register(String code, String instanceId) async {
    final current = _owners[code];
    if (current != null && current != instanceId) return false;
    _owners[code] = instanceId;
    return true;
  }

  @override
  Future<String?> lookup(String code) async => _owners[code];

  @override
  Future<void> unregister(String code) async {
    _owners.remove(code);
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
        'expires_at INTEGER NOT NULL)'),
  ];

  static const _upsertSql = 'INSERT INTO room_registry (code, instance, '
      'expires_at) VALUES (?, ?, ?) '
      'ON CONFLICT(code) DO UPDATE SET instance = excluded.instance, '
      'expires_at = excluded.expires_at '
      'WHERE room_registry.instance = excluded.instance '
      'OR room_registry.expires_at <= ?';
  static const _gcSql = 'DELETE FROM room_registry WHERE expires_at < ?';
  static const _selectSql =
      'SELECT instance FROM room_registry WHERE code = ?';
  static const _deleteSql = 'DELETE FROM room_registry WHERE code = ?';

  /// Like the leaderboard pipelines, every pipeline ends with an explicit
  /// `close` so the server-side statement stream is released immediately
  /// instead of lingering until the server times it out.
  static const _close = {'type': 'close'};

  /// A CAS upsert: rows the pipeline already own (same instance) or that
  /// no live entry holds (the GC has just removed expired rows; `<=`
  /// covers the clock edge) may be claimed. A live foreign claim is left
  /// untouched, and the trailing [_selectSql] reports who actually owns
  /// the code afterwards.
  @override
  Future<bool> register(String code, String instanceId) async {
    final table = await _pipeline([
      ..._schema,
      _execStmt(_gcSql, [_nowMs()]),
      _execStmt(_upsertSql, [code, instanceId, _expiryMs(), _nowMs()]),
      _execStmt(_selectSql, [code]),
      _close,
    ]);
    return table.rows.isNotEmpty && '${table.rows.first.first}' == instanceId;
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
  Future<void> unregister(String code) =>
      _pipeline([..._schema, _execStmt(_deleteSql, [code]), _close]);

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
