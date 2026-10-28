/// Player feedback persistence: bug reports, feature requests, questions
/// and the contact-page inbox land in one queue (`feedback` table) that
/// the admin dashboard triages — priority sorting, status workflow, and
/// full row CRUD from the Data tab.
///
/// Lives in the same database as the admin history — local SQLite or
/// Turso, whichever the deployment configured — so one store holds
/// everything the dashboard shows. Categories are the automation hook:
/// bug/feature/question route to different follow-up workflows, 'other'
/// is the catch-all for anything else.
library;

import 'package:sqlite3/sqlite3.dart';

import 'sql_backend.dart';

/// What kind of issue this is. The admin tooling filters and automates on
/// these, so the set is deliberately small and closed.
const feedbackCategories = {'bug', 'feature', 'question', 'other', 'player'};

/// Where a report came from: the in-game/settings report sheet, the
/// contact page, or somewhere else.
const feedbackSources = {'report', 'contact', 'other'};

/// Triage workflow: open → in_progress → resolved (→ closed). Any
/// transition is allowed; the dashboard offers them all.
const feedbackStatuses = {'open', 'in_progress', 'resolved', 'closed'};

/// Lowest to highest. The list view sorts critical-first automatically.
const feedbackPriorities = {'low', 'medium', 'high', 'critical'};

/// One feedback row.
class FeedbackEntry {
  FeedbackEntry({
    required this.id,
    required this.category,
    required this.source,
    required this.title,
    required this.message,
    required this.status,
    required this.priority,
    required this.createdAt,
    required this.updatedAt,
    this.contact,
    this.seatId,
    this.gameId,
    this.appVersion,
    this.adminNotes = '',
  });

  final int id;
  final String category;
  final String source;

  /// Optional one-line summary; the message is the required part.
  final String title;
  final String message;

  /// How to reach the reporter back — optional, self-declared.
  final String? contact;

  /// Game identity of the reporter when known (online play).
  final String? seatId;
  final String? gameId;
  final String? appVersion;

  final String status;
  final String priority;
  final String adminNotes;
  final int createdAt;
  final int updatedAt;

  Map<String, dynamic> toJson() => {
    'id': id,
    'category': category,
    'source': source,
    if (title.isNotEmpty) 'title': title,
    'message': message,
    if (contact != null && contact!.isNotEmpty) 'contact': contact,
    if (seatId != null && seatId!.isNotEmpty) 'seatId': seatId,
    if (gameId != null && gameId!.isNotEmpty) 'gameId': gameId,
    if (appVersion != null && appVersion!.isNotEmpty) 'appVersion': appVersion,
    'status': status,
    'priority': priority,
    if (adminNotes.isNotEmpty) 'adminNotes': adminNotes,
    'createdAt': createdAt,
    'updatedAt': updatedAt,
  };
}

class ReportStore {
  ReportStore._(this._backend, this._ownsBackend);

  factory ReportStore.inMemory() =>
      ReportStore._(SqliteBackend.inMemory(), true);

  factory ReportStore(String path) =>
      ReportStore._(SqliteBackend.open(path), true);

  factory ReportStore.fromDb(Database db) =>
      ReportStore._(SqliteBackend.fromDb(db), false);

  /// Wraps any [SqlBackend] (the caller keeps ownership) — this is how a
  /// Turso-backed deployment gets the same feedback queue as SQLite.
  factory ReportStore.fromBackend(SqlBackend backend) =>
      ReportStore._(backend, false);

  final SqlBackend _backend;
  final bool _ownsBackend;

  /// Schema is created lazily and memoized: a Turso deployment cannot run
  /// migrations in a constructor. A failed attempt is cleared so the next
  /// call retries (every statement is idempotent).
  Future<void>? _schemaReady;

  Future<void> ensureSchema() => _schemaReady ??= _createSchema();

  Future<void> _createSchema() async {
    try {
      await _backend.run([
        for (final sql in _schemaSql) SqlStatement(sql),
      ], atomic: false);
    } catch (_) {
      _schemaReady = null; // let the next call retry
      rethrow;
    }
  }

  static const _schemaSql = <String>[
    'CREATE TABLE IF NOT EXISTS feedback ('
        'id INTEGER PRIMARY KEY AUTOINCREMENT, '
        'category TEXT NOT NULL, '
        "source TEXT NOT NULL DEFAULT 'report', "
        "title TEXT NOT NULL DEFAULT '', "
        'message TEXT NOT NULL, '
        'contact TEXT, '
        'seat_id TEXT, '
        'game_id TEXT, '
        'app_version TEXT, '
        "status TEXT NOT NULL DEFAULT 'open', "
        "priority TEXT NOT NULL DEFAULT 'medium', "
        "admin_notes TEXT NOT NULL DEFAULT '', "
        'created_at INTEGER NOT NULL, '
        'updated_at INTEGER NOT NULL)',
    'CREATE INDEX IF NOT EXISTS idx_feedback_status ON feedback(status)',
    'CREATE INDEX IF NOT EXISTS idx_feedback_created '
        'ON feedback(created_at)',
  ];

  // ---------------------------------------------------------- validation

  static const maxTitleLength = 120;
  static const maxMessageLength = 4000;
  static const maxContactLength = 200;
  static const maxTagLength = 100;

  /// Guards one write path for every creator of rows — the public POST
  /// /feedback endpoint and admin inserts alike. Throws [ArgumentError]
  /// with a user-presentable message on bad input.
  void _validate({
    required String category,
    required String source,
    required String message,
  }) {
    if (!feedbackCategories.contains(category)) {
      throw ArgumentError(
        'category must be one of ${feedbackCategories.join(', ')}',
      );
    }
    if (!feedbackSources.contains(source)) {
      throw ArgumentError(
        'source must be one of ${feedbackSources.join(', ')}',
      );
    }
    if (message.trim().isEmpty) {
      throw ArgumentError('message required');
    }
    if (message.length > maxMessageLength) {
      throw ArgumentError(
        'message too long (max $maxMessageLength characters)',
      );
    }
  }

  FeedbackEntry _fromRow(Map<String, Object?> r) => FeedbackEntry(
    id: r['id'] as int,
    category: r['category'] as String,
    source: r['source'] as String,
    title: r['title'] as String? ?? '',
    message: r['message'] as String,
    contact: r['contact'] as String?,
    seatId: r['seat_id'] as String?,
    gameId: r['game_id'] as String?,
    appVersion: r['app_version'] as String?,
    status: r['status'] as String,
    priority: r['priority'] as String,
    adminNotes: r['admin_notes'] as String? ?? '',
    createdAt: r['created_at'] as int,
    updatedAt: r['updated_at'] as int,
  );

  // ------------------------------------------------------------ writing

  /// Inserts a row. Optional strings are clamped to their caps rather than
  /// rejected — a 130-character title is a trimming job, not an error.
  Future<FeedbackEntry> create({
    required String category,
    required String message,
    String source = 'report',
    String? title,
    String? contact,
    String? seatId,
    String? gameId,
    String? appVersion,
  }) async {
    await ensureSchema();
    _validate(category: category, source: source, message: message);
    final now = DateTime.now().millisecondsSinceEpoch;
    final results = await _backend.run([
      SqlStatement(
        'INSERT INTO feedback '
        '(category, source, title, message, contact, seat_id, game_id, '
        'app_version, status, priority, admin_notes, created_at, updated_at) '
        'VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)',
        [
          category,
          source,
          (title ?? '').trim().substring(
            0,
            (title ?? '').trim().length.clamp(0, maxTitleLength),
          ),
          message.trim(),
          _clamp(contact, maxContactLength),
          _clamp(seatId, maxTagLength),
          _clamp(gameId, maxTagLength),
          _clamp(appVersion, maxTagLength),
          'open',
          'medium',
          '',
          now,
          now,
        ],
      ),
      const SqlStatement(
        'SELECT * FROM feedback WHERE id = last_insert_rowid()',
      ),
    ]);
    return _fromRow(results.last.rows.first);
  }

  /// Partial update. Only the fields present in [patch] change. Unknown
  /// or out-of-whitelist values throw [ArgumentError]; the handler turns
  /// that into a 400.
  Future<FeedbackEntry?> update(int id, Map<String, dynamic> patch) async {
    final existing = await byId(id);
    if (existing == null) return null;
    final sets = <String>[];
    final args = <dynamic>[];
    void set(String column, String allowed, String value) {
      if (!allowed.contains(value)) {
        throw ArgumentError('value must be one of: $allowed');
      }
      sets.add('$column = ?');
      args.add(value);
    }

    for (final e in patch.entries) {
      switch (e.key) {
        case 'category':
          set('category', feedbackCategories.join('|'), e.value as String);
        case 'status':
          set('status', feedbackStatuses.join('|'), e.value as String);
        case 'priority':
          set('priority', feedbackPriorities.join('|'), e.value as String);
        case 'source':
          set('source', feedbackSources.join('|'), e.value as String);
        case 'title':
          sets.add('title = ?');
          args.add(
            (e.value as String?)?.trim().substring(
                  0,
                  (e.value as String?)?.trim().length.clamp(
                        0,
                        maxTitleLength,
                      ) ??
                      0,
                ) ??
                '',
          );
        case 'message':
          final m = e.value as String? ?? '';
          _validate(
            category: patch['category'] as String? ?? existing.category,
            source: patch['source'] as String? ?? existing.source,
            message: m,
          );
          sets.add('message = ?');
          args.add(m.trim());
        case 'contact':
          sets.add('contact = ?');
          args.add(_clamp(e.value as String?, maxContactLength));
        case 'seatId':
          sets.add('seat_id = ?');
          args.add(_clamp(e.value as String?, maxTagLength));
        case 'gameId':
          sets.add('game_id = ?');
          args.add(_clamp(e.value as String?, maxTagLength));
        case 'appVersion':
          sets.add('app_version = ?');
          args.add(_clamp(e.value as String?, maxTagLength));
        case 'adminNotes':
          sets.add('admin_notes = ?');
          args.add(
            (e.value as String? ?? '').trim().substring(
              0,
              (e.value as String? ?? '').trim().length.clamp(
                0,
                maxMessageLength,
              ),
            ),
          );
        default:
          throw ArgumentError('unknown field ${e.key}');
      }
    }
    if (sets.isEmpty) return existing;
    sets.add('updated_at = ?');
    args
      ..add(DateTime.now().millisecondsSinceEpoch)
      ..add(id);
    await _backend.run([
      SqlStatement('UPDATE feedback SET ${sets.join(', ')} WHERE id = ?', args),
    ]);
    return byId(id);
  }

  /// True when a row was deleted.
  Future<bool> delete(int id) async {
    await ensureSchema();
    final results = await _backend.run([
      SqlStatement('DELETE FROM feedback WHERE id = ?', [id]),
    ]);
    return results.first.affected > 0;
  }

  // ----------------------------------------------------------- reading

  Future<FeedbackEntry?> byId(int id) async {
    await ensureSchema();
    final results = await _backend.run([
      SqlStatement('SELECT * FROM feedback WHERE id = ?', [id]),
    ]);
    final row = results.first.firstRow;
    return row == null ? null : _fromRow(row);
  }

  /// The triage queue. Default order: actionable first (open before
  /// closed), then priority critical-first, then newest — so the top of
  /// the list is always "what should a human look at next".
  Future<List<FeedbackEntry>> list({
    String? category,
    String? status,
    String sort = 'priority',
    int limit = 100,
    int offset = 0,
  }) async {
    await ensureSchema();
    final where = <String>[];
    final args = <dynamic>[];
    if (category != null && category.isNotEmpty) {
      where.add('category = ?');
      args.add(category);
    }
    if (status != null && status.isNotEmpty) {
      where.add('status = ?');
      args.add(status);
    }
    final order = sort == 'newest'
        ? 'created_at DESC, id DESC'
        // Actionable-first, priority-ranked, newest tiebreak.
        : "CASE status WHEN 'open' THEN 0 WHEN 'in_progress' THEN 1 "
              "WHEN 'resolved' THEN 2 ELSE 3 END, "
              "CASE priority WHEN 'critical' THEN 0 WHEN 'high' THEN 1 "
              "WHEN 'medium' THEN 2 ELSE 3 END, "
              'created_at DESC, id DESC';
    final results = await _backend.run([
      SqlStatement(
        'SELECT * FROM feedback '
        '${where.isEmpty ? '' : 'WHERE ${where.join(' AND ')} '}'
        'ORDER BY $order LIMIT ? OFFSET ?',
        [...args, limit, offset],
      ),
    ]);
    return [for (final r in results.first.rows) _fromRow(r)];
  }

  Future<int> count({String? status}) async {
    await ensureSchema();
    final results = await _backend.run([
      if (status == null || status.isEmpty)
        const SqlStatement('SELECT COUNT(*) AS n FROM feedback')
      else
        SqlStatement('SELECT COUNT(*) AS n FROM feedback WHERE status = ?', [
          status,
        ]),
    ]);
    return results.first.rows.first['n'] as int;
  }

  /// Per-category open counts — the automation hook for the dashboard.
  Future<Map<String, int>> openByCategory() async {
    await ensureSchema();
    final results = await _backend.run(const [
      SqlStatement(
        "SELECT category, COUNT(*) AS n FROM feedback "
        "WHERE status IN ('open', 'in_progress') GROUP BY category",
      ),
    ]);
    return {
      for (final r in results.first.rows)
        r['category'] as String: r['n'] as int,
    };
  }

  static String? _clamp(String? raw, int max) {
    final v = raw?.trim() ?? '';
    if (v.isEmpty) return null;
    return v.substring(0, v.length.clamp(0, max));
  }

  void close() {
    if (_ownsBackend) _backend.close();
  }
}
