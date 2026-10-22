/// An in-memory stand-in for Turso's SQL-over-HTTP pipeline API.
///
/// The real backend is a libSQL database behind `POST /v2/pipeline`. Rather
/// than answering with canned rows (which cannot prove that a store's SQL
/// actually preserves the SQLite contract), this fake executes each pipeline
/// statement against a real [sqlite3] in-memory database and re-encodes the
/// result in the same typed wire format Turso uses. Tests then exercise the
/// exact SQL, transactions, and conditional writes the remote store ships,
/// with no network and no Turso account.
library;

import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:sqlite3/sqlite3.dart';

/// A fake Turso pipeline endpoint backed by one in-memory SQLite database.
class FakeTursoPipeline {
  FakeTursoPipeline({Database? db}) : db = db ?? sqlite3.openInMemory();

  /// The backing database. Keep this handle across "redeploys" to prove rows
  /// outlive a store instance.
  final Database db;

  /// How many HTTP pipeline requests have been served.
  int calls = 0;

  /// Every request received, in order (for wire-format assertions).
  final List<http.Request> requests = [];

  /// Overrides the HTTP response when set (auth failures, outages).
  http.Response? failure;

  /// When non-null, a statement whose SQL contains this fragment fails
  /// without executing. Lets a test prove that one failed step rolls back
  /// the whole transaction instead of leaving half a write behind.
  String? failOnSql;

  /// An [http.Client] that speaks the pipeline protocol against [db].
  http.Client get client => MockClient((request) async {
    calls++;
    requests.add(request);
    final override = failure;
    if (override != null) return override;
    return _handle(request);
  });

  void dispose() => db.close();

  Future<http.Response> _handle(http.Request request) async {
    final decoded = jsonDecode(request.body) as Map<String, dynamic>;
    final requests = decoded['requests'] as List<dynamic>;
    final results = <Map<String, dynamic>>[];

    for (final entry in requests) {
      if (entry is! Map) continue;
      if (entry['type'] == 'close') {
        results.add({
          'type': 'ok',
          'response': {'type': 'close'},
        });
        continue;
      }
      if (entry['type'] != 'execute') {
        results.add({
          'type': 'error',
          'error': {'message': 'unsupported request type ${entry['type']}'},
        });
        break;
      }

      final stmt = entry['stmt'] as Map<String, dynamic>;
      final sql = stmt['sql'] as String;
      final args = [
        for (final arg in stmt['args'] as List<dynamic>? ?? const [])
          _decodeArg(arg as Map<String, dynamic>),
      ];

      final failOn = failOnSql;
      if (failOn != null && sql.contains(failOn)) {
        _rollback();
        results.add({
          'type': 'error',
          'error': {'message': 'injected failure on: $failOn'},
        });
        break;
      }

      try {
        final prepared = db.prepare(sql);
        try {
          final result = prepared.select(args);
          results.add({
            'type': 'ok',
            'response': {
              'type': 'execute',
              'result': {
                'cols': [
                  for (final name in result.columnNames)
                    {'name': name, 'decltype': null},
                ],
                'rows': [
                  for (final row in result.rows)
                    [for (final cell in row) _encodeCell(cell)],
                ],
                'affected_row_count': db.updatedRows,
                'last_insert_rowid': db.lastInsertRowId,
              },
            },
          });
        } finally {
          prepared.close();
        }
      } on SqliteException catch (e) {
        _rollback();
        results.add({
          'type': 'error',
          'error': {'message': e.message},
        });
        break;
      }
    }

    return http.Response(
      jsonEncode({'baton': null, 'base_url': null, 'results': results}),
      200,
      headers: {'content-type': 'application/json'},
    );
  }

  /// A failed statement must not leave the fake connection stuck inside a
  /// transaction: real Turso rolls the whole pipeline back, and the next
  /// call needs a clean connection.
  void _rollback() {
    if (db.autocommit) return;
    try {
      db.execute('ROLLBACK');
    } on SqliteException {
      // Already rolled back by SQLite; nothing left to do.
    }
  }

  static Object? _decodeArg(Map<String, dynamic> arg) => switch (arg['type']) {
    'null' || null => null,
    'integer' || 'number' => int.parse('${arg['value']}'),
    'float' => (arg['value'] as num).toDouble(),
    'text' => '${arg['value']}',
    _ => arg['value'],
  };

  static Map<String, dynamic> _encodeCell(Object? cell) => switch (cell) {
    null => {'type': 'null', 'value': null},
    int i => {'type': 'integer', 'value': '$i'},
    double d => {'type': 'float', 'value': d},
    String s => {'type': 'text', 'value': s},
    _ => {'type': 'text', 'value': '$cell'},
  };
}
