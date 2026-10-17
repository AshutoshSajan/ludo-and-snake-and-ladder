/// Registry of the tables the admin dashboard's Data tab may read and
/// write, with per-table capabilities. Everything the admin CRUD API
/// touches is named HERE and nowhere else: table and column names come
/// only from these specs (never from request bodies — those are values,
/// always bound as SQL parameters), so a crafted request cannot reach a
/// table the registry does not list.
///
/// Lines drawn on purpose:
/// - `admin_audit` is read-only — the moderation log must not be editable
///   by the tool it records for.
/// - `auth_users` never reads or writes `password_hash` (only through the
///   dedicated /admin/users endpoint, which hashes) and never inserts
///   rows outside that endpoint.
/// - `auth_sessions` allows delete (force sign-out) but no insert.
library;

/// Capabilities for one table.
class AdminTableSpec {
  const AdminTableSpec({
    required this.name,
    required this.pk,
    required this.pkIsText,
    required this.columns,
    this.editable = const {},
    this.insertable = false,
    this.deletable = false,
    this.orderBy = 'rowid DESC',
  });

  final String name;

  /// Primary key column. Text pks (seat_id, token_hash) and integer
  /// autoincrement pks (id) both exist across the schema.
  final String pk;
  final bool pkIsText;

  /// Readable columns, in display order. Secrets stay out of this list.
  final List<String> columns;

  /// Columns a row edit may set. Empty = read-only table.
  final Set<String> editable;

  /// Whether the API may insert rows at all.
  final bool insertable;

  /// Whether the API may delete rows.
  final bool deletable;

  /// Default listing order (identifier-safe: literal SQL from here only).
  final String orderBy;
}

const AdminTableSpec _feedbackSpec = AdminTableSpec(
  name: 'feedback',
  pk: 'id',
  pkIsText: false,
  columns: [
    'id',
    'category',
    'source',
    'title',
    'message',
    'contact',
    'seat_id',
    'game_id',
    'app_version',
    'status',
    'priority',
    'admin_notes',
    'created_at',
    'updated_at',
  ],
  editable: {
    'category',
    'source',
    'title',
    'message',
    'contact',
    'seat_id',
    'game_id',
    'app_version',
    'status',
    'priority',
    'admin_notes',
  },
  insertable: true,
  deletable: true,
  orderBy: 'id DESC',
);

const AdminTableSpec _resultsSpec = AdminTableSpec(
  name: 'results',
  pk: 'id',
  pkIsText: false,
  columns: ['id', 'game_id', 'seat_id', 'name', 'game', 'color', 'rank', 'played_at'],
  editable: {
    'game_id',
    'seat_id',
    'name',
    'game',
    'color',
    'rank',
    'played_at',
  },
  insertable: true,
  deletable: true,
  orderBy: 'id DESC',
);

const AdminTableSpec _playersSpec = AdminTableSpec(
  name: 'players',
  pk: 'seat_id',
  pkIsText: true,
  columns: ['seat_id', 'name'],
  editable: {'name'},
  insertable: true,
  deletable: true,
  orderBy: 'seat_id ASC',
);

const AdminTableSpec _adminPlayersSpec = AdminTableSpec(
  name: 'admin_players',
  pk: 'seat_id',
  pkIsText: true,
  columns: ['seat_id', 'name', 'first_seen', 'last_seen'],
  editable: {'name', 'first_seen', 'last_seen'},
  insertable: true,
  deletable: true,
  orderBy: 'last_seen DESC',
);

const AdminTableSpec _bansSpec = AdminTableSpec(
  name: 'admin_bans',
  pk: 'seat_id',
  pkIsText: true,
  columns: ['seat_id', 'reason', 'banned_by', 'banned_at', 'until_ms'],
  editable: {'reason', 'banned_by', 'banned_at', 'until_ms'},
  insertable: true,
  deletable: true,
  orderBy: 'banned_at DESC',
);

const AdminTableSpec _roomsSpec = AdminTableSpec(
  name: 'admin_rooms',
  pk: 'id',
  pkIsText: false,
  columns: [
    'id',
    'code',
    'game',
    'instance',
    'status',
    'created_at',
    'started_at',
    'closed_at',
    'player_count',
    'winner_seat',
  ],
  editable: {
    'code',
    'game',
    'instance',
    'status',
    'started_at',
    'closed_at',
    'player_count',
    'winner_seat',
  },
  insertable: true,
  deletable: true,
  orderBy: 'id DESC',
);

const AdminTableSpec _auditSpec = AdminTableSpec(
  name: 'admin_audit',
  pk: 'id',
  pkIsText: false,
  columns: ['id', 'action', 'seat_id', 'by_name', 'detail', 'at_ms'],
  // Read-only: the audit log records the tool's own actions.
  orderBy: 'id DESC',
);

const AdminTableSpec _usersSpec = AdminTableSpec(
  name: 'auth_users',
  pk: 'id',
  pkIsText: false,
  // password_hash deliberately unreadable here; inserts go through
  // /admin/users so passwords are hashed, never posted raw.
  columns: ['id', 'email', 'name', 'role', 'seat_id', 'created_at'],
  editable: {'email', 'name', 'role', 'seat_id'},
  deletable: true,
  orderBy: 'id ASC',
);

const AdminTableSpec _sessionsSpec = AdminTableSpec(
  name: 'auth_sessions',
  pk: 'token_hash',
  pkIsText: true,
  columns: ['token_hash', 'user_id', 'created_at', 'expires_at'],
  editable: {'expires_at'},
  // Delete = force sign-out; inserts only via login.
  deletable: true,
  orderBy: 'created_at DESC',
);

const Map<String, AdminTableSpec> adminTableSpecs = {
  'feedback': _feedbackSpec,
  'results': _resultsSpec,
  'players': _playersSpec,
  'admin_players': _adminPlayersSpec,
  'admin_bans': _bansSpec,
  'admin_rooms': _roomsSpec,
  'admin_audit': _auditSpec,
  'auth_users': _usersSpec,
  'auth_sessions': _sessionsSpec,
};

AdminTableSpec? tableSpec(String name) => adminTableSpecs[name];
