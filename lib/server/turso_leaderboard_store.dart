/// Turso (libSQL) leaderboard persistence over the hosted HTTP API.
///
/// Speaks the "SQL over HTTP" protocol (Hrana over HTTP v2): every operation
/// is a `POST {db}/v2/pipeline` carrying `execute` statements and a trailing
/// `close`, authenticated with a Bearer token. Plain HTTP means no native
/// driver — the store reuses the `package:http` the app already ships.
///
/// Configure with two environment variables (Turso CLI naming):
///
///     TURSO_DATABASE_URL   e.g. libsql://my-db-myorg.turso.io
///     TURSO_AUTH_TOKEN     a database token (`turso db tokens create`)
///
/// Because the data lives off-host, the game server itself can run on an
/// ephemeral free host without losing the leaderboard.
library;

import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import 'leaderboard_store.dart';

/// A failed Turso HTTP request or a failed statement inside a pipeline.
class TursoLeaderboardException implements Exception {
  TursoLeaderboardException(this.message);

  final String message;

  @override
  String toString() => 'TursoLeaderboardException: $message';
}

/// [LeaderboardStore] backed by a remote Turso database.
class TursoLeaderboardStore implements LeaderboardStore {
  TursoLeaderboardStore({
    required Uri url,
    required this.authToken,
    http.Client? client,
  })  : _baseUrl = _normalizeBaseUrl(url),
        _client = client ?? http.Client(),
        _ownsClient = client == null;

  /// Reads `TURSO_DATABASE_URL` + `TURSO_AUTH_TOKEN`. Returns null when
  /// either is missing so callers can fall back to a local store.
  static TursoLeaderboardStore? fromEnvironment(
    Map<String, String> env, {
    http.Client? client,
  }) {
    final url = env['TURSO_DATABASE_URL']?.trim();
    final token = env['TURSO_AUTH_TOKEN']?.trim();
    if (url == null || url.isEmpty || token == null || token.isEmpty) {
      return null;
    }
    return TursoLeaderboardStore(
        url: Uri.parse(url), authToken: token, client: client);
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

  // Same schema as the SQLite implementation (see leaderboard_store.dart).
  static const _schemaSql = <String>[
    'CREATE TABLE IF NOT EXISTS results ('
        'id INTEGER PRIMARY KEY AUTOINCREMENT, '
        'game_id TEXT NOT NULL, '
        'seat_id TEXT NOT NULL, '
        'name TEXT NOT NULL, '
        'color TEXT NOT NULL, '
        'rank INTEGER NOT NULL, '
        'played_at INTEGER NOT NULL)',
    'CREATE INDEX IF NOT EXISTS idx_results_seat ON results(seat_id)',
    'CREATE UNIQUE INDEX IF NOT EXISTS idx_results_game_seat '
        'ON results(game_id, seat_id)',
    'CREATE TABLE IF NOT EXISTS players '
        '(seat_id TEXT PRIMARY KEY, name TEXT NOT NULL)',
  ];

  static const _insertSql = 'INSERT OR IGNORE INTO results '
      '(game_id, seat_id, name, color, rank, played_at) '
      'VALUES (?, ?, ?, ?, ?, ?)';
  static const _upsertPlayerSql = 'INSERT INTO players (seat_id, name) '
      'VALUES (?, ?) '
      'ON CONFLICT(seat_id) DO UPDATE SET name = excluded.name';
  static const _topPlayersSql = '''
      SELECT r.seat_id AS seat_id,
             p.name AS name,
             SUM(CASE WHEN r.rank = 1 THEN 1 ELSE 0 END) AS wins,
             COUNT(*) AS games,
             AVG(r.rank) AS avg_rank
      FROM results r
      JOIN players p ON p.seat_id = r.seat_id
      GROUP BY r.seat_id
      ORDER BY wins DESC, avg_rank ASC, games DESC
      LIMIT ?
''';
  static const _totalGamesSql =
      'SELECT COUNT(DISTINCT game_id) AS n FROM results';

  static const _timeout = Duration(seconds: 10);

  final Uri _baseUrl;
  final String authToken;
  final http.Client _client;
  final bool _ownsClient;

  /// Completes once the schema pipeline has succeeded; a failed attempt is
  /// cleared so the next call retries (all statements are IF NOT EXISTS).
  Future<void>? _schemaReady;

  Uri get _pipelineUrl => Uri.parse('$_baseUrl/v2/pipeline');

  @override
  Future<void> recordResults({
    required String gameId,
    required List<GameResult> results,
  }) async {
    if (results.isEmpty) return;
    await _ensureSchema();
    final now = DateTime.now().millisecondsSinceEpoch;
    final requests = <Map<String, dynamic>>[
      for (final r in results) ...[
        _execute(_insertSql, [gameId, r.seatId, r.name, r.color, r.rank, now]),
        _execute(_upsertPlayerSql, [r.seatId, r.name]),
      ],
      _close(),
    ];
    await _runPipeline(requests);
  }

  @override
  Future<List<LeaderboardEntry>> topPlayers({int limit = 10}) async {
    await _ensureSchema();
    final results =
        await _runPipeline([_execute(_topPlayersSql, [limit]), _close()]);
    final table = _ResultTable(_executeResult(results, 0));
    return [
      for (final row in table.rows)
        LeaderboardEntry(
          seatId: table.cell(row, 'seat_id') as String,
          name: table.cell(row, 'name') as String,
          wins: table.cell(row, 'wins') as int,
          games: table.cell(row, 'games') as int,
          avgRank: (table.cell(row, 'avg_rank') as num).toDouble(),
        ),
    ];
  }

  @override
  Future<int> totalGames() async {
    await _ensureSchema();
    final results = await _runPipeline([_execute(_totalGamesSql), _close()]);
    final table = _ResultTable(_executeResult(results, 0));
    return table.cell(table.rows.single, 'n') as int;
  }

  @override
  void close() {
    if (_ownsClient) _client.close();
  }

  Future<void> _ensureSchema() {
    return _schemaReady ??= _createSchema();
  }

  Future<void> _createSchema() async {
    try {
      await _runPipeline([..._schemaSql.map(_execute), _close()]);
    } catch (_) {
      _schemaReady = null; // let the next call retry
      rethrow;
    }
  }

  /// Sends one pipeline (one HTTP request, one fresh server-side stream)
  /// and returns its results, throwing [TursoLeaderboardException] on any
  /// transport, HTTP, or statement failure.
  Future<List<dynamic>> _runPipeline(
      List<Map<String, dynamic>> requests) async {
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
      throw TursoLeaderboardException(
          'Turso request timed out after ${_timeout.inSeconds}s');
    }
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw TursoLeaderboardException('Turso pipeline failed '
          '(HTTP ${response.statusCode}): ${_snippet(response.body)}');
    }
    final Object? decoded;
    try {
      decoded = jsonDecode(response.body);
    } on FormatException catch (e) {
      throw TursoLeaderboardException(
          'Turso returned invalid JSON: ${e.message}');
    }
    final results = (decoded as Map?)?['results'];
    if (results is! List) {
      throw TursoLeaderboardException('Turso response has no results array: '
          '${_snippet(response.body)}');
    }
    for (var i = 0; i < results.length; i++) {
      final entry = results[i];
      if (entry is Map && entry['type'] == 'error') {
        throw TursoLeaderboardException(
            'Turso pipeline step $i failed: ${_errorMessage(entry)}');
      }
    }
    return results;
  }

  /// Unwraps the result of the [index]-th execute request.
  Map<String, dynamic> _executeResult(List<dynamic> results, int index) {
    final entry = results[index] as Map?;
    if (entry == null || entry['type'] != 'ok') {
      throw TursoLeaderboardException(
          'Turso pipeline step $index failed: ${_errorMessage(entry)}');
    }
    final result = (entry['response'] as Map?)?['result'] as Map?;
    if (result == null) {
      throw TursoLeaderboardException(
          'Turso pipeline step $index has no result');
    }
    return Map<String, dynamic>.from(result);
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
          if (args != null)
            'args': [for (final arg in args) _encodeArg(arg)],
        },
      };

  static Map<String, dynamic> _close() => const {'type': 'close'};

  /// Encodes a Dart value as a pipeline argument. Integers are serialized
  /// as strings per the API docs (JSON numbers cannot hold all 64-bit ints).
  static Map<String, dynamic> _encodeArg(Object? value) => switch (value) {
        null => const {'type': 'null', 'value': null},
        int i => {'type': 'integer', 'value': '$i'},
        double d => {'type': 'float', 'value': d},
        String s => {'type': 'text', 'value': s},
        _ => throw ArgumentError(
            'unsupported Turso arg type: ${value.runtimeType}'),
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

  Object? cell(List<Object?> row, String column) =>
      row[columns.indexOf(column)];

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
    throw TursoLeaderboardException('Turso returned a non-integer: $value');
  }

  static double _toDouble(Object? value) {
    if (value is num) return value.toDouble();
    if (value is String) return double.parse(value);
    throw TursoLeaderboardException('Turso returned a non-number: $value');
  }
}
