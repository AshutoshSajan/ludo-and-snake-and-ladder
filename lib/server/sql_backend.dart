/// One async SQL seam for every durable store.
///
/// The server has always been able to run against either the local
/// `sqlite3` file or a hosted Turso (libSQL) database, but only the
/// leaderboard/friends/room-registry stores spoke both. Admin history,
/// accounts, sessions and feedback were SQLite-only, so a Turso deployment
/// kept half its state on the ephemeral host and half in the cloud.
///
/// [SqlBackend] gives every store the same two implementations:
///
/// * [SqliteBackend] — the local file (or an in-memory database for tests),
///   using `package:sqlite3` directly. Calls complete immediately, but the
///   API is async so a remote backend slots in unchanged.
/// * [TursoBackend] — the hosted HTTP pipeline API (`POST /v2/pipeline`).
///
/// A [run] batch is atomic when it contains more than one statement: the
/// backend opens `BEGIN IMMEDIATE`, executes the statements in order, and
/// commits only when all of them succeed. Both implementations therefore
/// preserve the "ban + audit" / "result + player upsert" write pairs that
/// the SQLite stores used to get from synchronous local transactions.
library;

import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:sqlite3/sqlite3.dart';

/// A failed statement, transport, or HTTP request.
class SqlException implements Exception {
  SqlException(this.message, {this.cause});

  final String message;
  final Object? cause;

  @override
  String toString() => 'SqlException: $message';
}

/// One SQL statement and its bound arguments. Values only — table and
/// column identifiers come from the stores' own whitelists.
class SqlStatement {
  const SqlStatement(this.sql, [this.args = const []]);

  final String sql;
  final List<Object?> args;
}

/// What one statement returned.
class SqlResult {
  const SqlResult({
    this.rows = const [],
    this.affected = 0,
    this.lastInsertId = 0,
  });

  /// Rows for a SELECT (empty for writes).
  final List<Map<String, Object?>> rows;

  /// Rows inserted/updated/deleted by this statement (writes only).
  final int affected;

  /// `last_insert_rowid()` after an INSERT, or 0 when unavailable.
  final int lastInsertId;

  Map<String, Object?>? get firstRow => rows.isEmpty ? null : rows.first;
}

/// The storage contract every durable store speaks.
abstract interface class SqlBackend {
  /// Runs [statements] in order. With [atomic] true and more than one
  /// statement, the whole batch is one transaction: any failure rolls all
  /// of it back. A single statement is atomic on its own.
  Future<List<SqlResult>> run(
    List<SqlStatement> statements, {
    bool atomic = true,
  });

  /// Releases the database handle or HTTP client this backend owns.
  void close();
}

/// [SqlBackend] over a local SQLite database.
class SqliteBackend implements SqlBackend {
  SqliteBackend._(this._db, {required bool owns}) : _ownsDb = owns;

  /// A throwaway database that vanishes with the process — used by tests.
  factory SqliteBackend.inMemory() =>
      SqliteBackend._(sqlite3.openInMemory(), owns: true);

  /// Opens (or creates) the database at [path].
  factory SqliteBackend.open(String path) =>
      SqliteBackend._(sqlite3.open(path), owns: true);

  /// Wraps an existing connection (the caller keeps ownership), so several
  /// stores can share one file the way `main()` does.
  factory SqliteBackend.fromDb(Database db) => SqliteBackend._(db, owns: false);

  final Database _db;
  final bool _ownsDb;

  /// The raw handle, for stores that still own their own schema helpers.
  Database get database => _db;

  @override
  Future<List<SqlResult>> run(
    List<SqlStatement> statements, {
    bool atomic = true,
  }) async {
    if (statements.isEmpty) return const [];
    final useTransaction = atomic && statements.length > 1;
    if (useTransaction) _db.execute('BEGIN IMMEDIATE');
    try {
      final results = <SqlResult>[];
      for (final statement in statements) {
        final rows = _db.select(statement.sql, statement.args);
        final write = _isWrite(statement.sql);
        results.add(
          SqlResult(
            rows: [for (final row in rows) Map<String, Object?>.of(row)],
            affected: write ? _db.updatedRows : 0,
            lastInsertId: write ? _db.lastInsertRowId : 0,
          ),
        );
      }
      if (useTransaction) _db.execute('COMMIT');
      return results;
    } catch (error) {
      if (useTransaction) {
        try {
          _db.execute('ROLLBACK');
        } on SqliteException {
          // SQLite already rolled the transaction back.
        }
      }
      throw SqlException('SQLite statement failed: $error', cause: error);
    }
  }

  @override
  void close() {
    if (_ownsDb) _db.close();
  }
}

/// [SqlBackend] over the hosted Turso (libSQL) HTTP pipeline API.
///
/// Every [run] is one `POST {db}/v2/pipeline` carrying the statements and a
/// trailing `close`, authenticated with a Bearer token. Multi-statement
/// batches add `BEGIN IMMEDIATE`/`COMMIT`, matching the transaction pattern
/// the leaderboard/friends stores already use.
class TursoBackend implements SqlBackend {
  TursoBackend({
    required Uri url,
    required this.authToken,
    http.Client? client,
    this.timeout = const Duration(seconds: 10),
  }) : _baseUrl = _normalizeBaseUrl(url),
       _client = client ?? http.Client(),
       _ownsClient = client == null;

  /// Reads `TURSO_DATABASE_URL` + `TURSO_AUTH_TOKEN`. Returns null when
  /// either is missing, so callers can fall back to local SQLite.
  static TursoBackend? fromEnvironment(
    Map<String, String> env, {
    http.Client? client,
  }) {
    final url = env['TURSO_DATABASE_URL']?.trim();
    final token = env['TURSO_AUTH_TOKEN']?.trim();
    if (url == null || url.isEmpty || token == null || token.isEmpty) {
      return null;
    }
    return TursoBackend(url: Uri.parse(url), authToken: token, client: client);
  }

  /// `turso://` and `libsql://` URLs are https URLs in disguise.
  static Uri _normalizeBaseUrl(Uri url) {
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

  final Uri _baseUrl;
  final String authToken;
  final http.Client _client;
  final bool _ownsClient;

  /// Per-request timeout. Exposed for tests that want a shorter bound.
  final Duration timeout;

  Uri get _pipelineUrl => Uri.parse('$_baseUrl/v2/pipeline');

  @override
  Future<List<SqlResult>> run(
    List<SqlStatement> statements, {
    bool atomic = true,
  }) async {
    if (statements.isEmpty) return const [];
    final useTransaction = atomic && statements.length > 1;
    final requests = <Map<String, dynamic>>[
      if (useTransaction) _execute('BEGIN IMMEDIATE'),
      for (final statement in statements)
        _execute(statement.sql, statement.args),
      if (useTransaction) _execute('COMMIT'),
      _close(),
    ];
    final results = await _runPipeline(requests);
    final offset = useTransaction ? 1 : 0;
    if (results.length < offset + statements.length) {
      throw SqlException(
        'Turso returned ${results.length} results for '
        '${statements.length} statement(s)',
      );
    }
    return [
      for (var i = 0; i < statements.length; i++)
        _decodeResult(_executeResult(results, offset + i)),
    ];
  }

  @override
  void close() {
    if (_ownsClient) _client.close();
  }

  Future<List<dynamic>> _runPipeline(
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
          .timeout(timeout);
    } on TimeoutException {
      throw SqlException('Turso request timed out after ${timeout.inSeconds}s');
    } on http.ClientException catch (error) {
      throw SqlException('Turso request failed: $error', cause: error);
    }
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw SqlException(
        'Turso pipeline failed '
        '(HTTP ${response.statusCode}): ${_snippet(response.body)}',
      );
    }
    final Object? decoded;
    try {
      decoded = jsonDecode(response.body);
    } on FormatException catch (error) {
      throw SqlException(
        'Turso returned invalid JSON: ${error.message}',
        cause: error,
      );
    }
    final results = (decoded as Map?)?['results'];
    if (results is! List) {
      throw SqlException(
        'Turso response has no results array: ${_snippet(response.body)}',
      );
    }
    for (var i = 0; i < results.length; i++) {
      final entry = results[i];
      if (entry is Map && entry['type'] == 'error') {
        throw SqlException(
          'Turso pipeline step $i failed: ${_errorMessage(entry)}',
        );
      }
    }
    return results;
  }

  Map<String, dynamic> _executeResult(List<dynamic> results, int index) {
    final entry = results[index] as Map?;
    if (entry == null || entry['type'] != 'ok') {
      throw SqlException(
        'Turso pipeline step $index failed: ${_errorMessage(entry)}',
      );
    }
    final result = (entry['response'] as Map?)?['result'] as Map?;
    if (result == null) {
      throw SqlException('Turso pipeline step $index has no result');
    }
    return Map<String, dynamic>.from(result);
  }

  static SqlResult _decodeResult(Map<String, dynamic> result) {
    final columns = [
      for (final col in result['cols'] as List<dynamic>? ?? const [])
        (col is Map ? col['name'] : col) as String? ?? '',
    ];
    final rows = <Map<String, Object?>>[];
    for (final raw in result['rows'] as List<dynamic>? ?? const []) {
      final cells = raw as List<dynamic>;
      final row = <String, Object?>{};
      for (var i = 0; i < columns.length && i < cells.length; i++) {
        row[columns[i]] = _decodeCell(cells[i]);
      }
      rows.add(row);
    }
    return SqlResult(
      rows: rows,
      affected:
          (result['affected_row_count'] as num?)?.toInt() ??
          int.tryParse('${result['affected_row_count']}') ??
          0,
      lastInsertId: _toIntOrZero(result['last_insert_rowid']),
    );
  }

  static int _toIntOrZero(Object? value) {
    if (value is int) return value;
    if (value is num) return value.toInt();
    if (value is String) return int.tryParse(value) ?? 0;
    return 0;
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

  static Map<String, dynamic> _close() => const {'type': 'close'};

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

  /// Decodes a wire cell into a plain Dart value. The pipeline API wraps
  /// every cell in a typed object; integers arrive as strings so 64-bit
  /// values survive JSON.
  static Object? _decodeCell(Object? cell) {
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
    throw SqlException('Turso returned a non-integer: $value');
  }

  static double _toDouble(Object? value) {
    if (value is num) return value.toDouble();
    if (value is String) return double.parse(value);
    throw SqlException('Turso returned a non-number: $value');
  }
}

final RegExp _writeStatement = RegExp(
  r'^\s*(insert|update|delete|replace)\b',
  caseSensitive: false,
);

bool _isWrite(String sql) => _writeStatement.hasMatch(sql);
