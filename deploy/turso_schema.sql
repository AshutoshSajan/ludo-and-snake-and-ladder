-- Game Club — Turso database schema.
--
-- The stores create these tables on first use (idempotent), so this file
-- exists for explicit provisioning and review. Apply with:
--
--     turso db shell <database-name> < deploy/turso_schema.sql
--
-- Turso is the single store of record when the server is configured with
-- TURSO_DATABASE_URL + TURSO_AUTH_TOKEN: the leaderboard, admin history,
-- accounts, sessions, feedback, friends and the cross-instance room
-- registry all live here. Local SQLite is only the no-Turso fallback.
--
-- `results`/`players` are the leaderboard (lib/server/turso_leaderboard_store.dart
-- and lib/server/admin_store.dart), `room_registry` is the cross-instance
-- routing map with a TTL column (lib/server/room_registry.dart) — expired
-- rows are GC'd on every call. `owner` is the per-room token that scopes a
-- close's delete so a recycled code's newer room is never erased by a stale
-- unregister. The `friend_*` tables are the durable friends state
-- (lib/server/turso_friend_store.dart): profiles with immutable friend
-- codes, accepted friendships, pending requests, DMs, play invites and
-- blocks. The `admin_*`, `auth_*` and `feedback` tables are the dashboard's
-- history, accounts and triage queue (lib/server/admin_store.dart,
-- lib/server/report_store.dart). Databases created by an earlier revision
-- of the server are upgraded in place on first use (the stores run guarded
-- ALTER TABLE ... ADD COLUMN), so this file is only needed for a brand-new
-- database.

CREATE TABLE IF NOT EXISTS results (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  game_id TEXT NOT NULL,
  seat_id TEXT NOT NULL,
  name TEXT NOT NULL,
  color TEXT NOT NULL,
  rank INTEGER NOT NULL,
  played_at INTEGER NOT NULL,
  game TEXT NOT NULL DEFAULT ''
);
CREATE INDEX IF NOT EXISTS idx_results_seat ON results(seat_id);
CREATE UNIQUE INDEX IF NOT EXISTS idx_results_game_seat ON results(game_id, seat_id);

CREATE TABLE IF NOT EXISTS players (
  seat_id TEXT PRIMARY KEY,
  name TEXT NOT NULL
);

-- Admin history: presence/growth, moderation bans, the audit trail and
-- every room lifecycle transition.
CREATE TABLE IF NOT EXISTS admin_players (
  seat_id TEXT PRIMARY KEY,
  name TEXT NOT NULL,
  first_seen INTEGER NOT NULL,
  last_seen INTEGER NOT NULL
);

CREATE TABLE IF NOT EXISTS admin_bans (
  seat_id TEXT PRIMARY KEY,
  reason TEXT NOT NULL,
  banned_by TEXT NOT NULL,
  banned_at INTEGER NOT NULL,
  until_ms INTEGER
);

CREATE TABLE IF NOT EXISTS admin_audit (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  action TEXT NOT NULL,
  seat_id TEXT NOT NULL,
  by_name TEXT NOT NULL,
  detail TEXT,
  at_ms INTEGER NOT NULL
);

CREATE TABLE IF NOT EXISTS admin_rooms (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  code TEXT NOT NULL,
  game TEXT NOT NULL,
  instance TEXT NOT NULL,
  created_at INTEGER NOT NULL,
  started_at INTEGER,
  closed_at INTEGER,
  status TEXT NOT NULL,
  player_count INTEGER NOT NULL DEFAULT 0,
  winner_seat TEXT
);
CREATE INDEX IF NOT EXISTS idx_admin_rooms_code ON admin_rooms(code);
CREATE INDEX IF NOT EXISTS idx_admin_rooms_created ON admin_rooms(created_at);

-- Admin accounts and sessions. Only the SHA-256 hash of a session token is
-- stored; password hashes are PBKDF2 and never leave the server.
CREATE TABLE IF NOT EXISTS auth_users (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  email TEXT NOT NULL UNIQUE,
  name TEXT NOT NULL,
  password_hash TEXT NOT NULL,
  role TEXT NOT NULL DEFAULT 'user',
  seat_id TEXT,
  created_at INTEGER NOT NULL
);

CREATE TABLE IF NOT EXISTS auth_sessions (
  token_hash TEXT PRIMARY KEY,
  user_id INTEGER NOT NULL REFERENCES auth_users(id) ON DELETE CASCADE,
  created_at INTEGER NOT NULL,
  expires_at INTEGER NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_auth_sessions_user ON auth_sessions(user_id);

-- Feedback triage queue (bug reports, feature requests, questions).
CREATE TABLE IF NOT EXISTS feedback (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  category TEXT NOT NULL,
  source TEXT NOT NULL DEFAULT 'report',
  title TEXT NOT NULL DEFAULT '',
  message TEXT NOT NULL,
  contact TEXT,
  seat_id TEXT,
  game_id TEXT,
  app_version TEXT,
  status TEXT NOT NULL DEFAULT 'open',
  priority TEXT NOT NULL DEFAULT 'medium',
  admin_notes TEXT NOT NULL DEFAULT '',
  created_at INTEGER NOT NULL,
  updated_at INTEGER NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_feedback_status ON feedback(status);
CREATE INDEX IF NOT EXISTS idx_feedback_created ON feedback(created_at);

CREATE TABLE IF NOT EXISTS room_registry (
  code TEXT PRIMARY KEY,
  instance TEXT NOT NULL,
  owner TEXT,
  expires_at INTEGER NOT NULL
);

-- Friends: the same tables [TursoFriendStore] creates lazily.
CREATE TABLE IF NOT EXISTS friend_profiles (
  seat_id TEXT PRIMARY KEY,
  name TEXT NOT NULL,
  code TEXT NOT NULL UNIQUE,
  seen_ms INTEGER NOT NULL
);

CREATE TABLE IF NOT EXISTS friendships (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  seat_a TEXT NOT NULL,
  seat_b TEXT NOT NULL,
  since_ms INTEGER NOT NULL,
  UNIQUE(seat_a, seat_b)
);
CREATE INDEX IF NOT EXISTS idx_friendships_a ON friendships(seat_a);
CREATE INDEX IF NOT EXISTS idx_friendships_b ON friendships(seat_b);

CREATE TABLE IF NOT EXISTS friend_requests (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  from_seat TEXT NOT NULL,
  from_name TEXT NOT NULL,
  from_code TEXT NOT NULL,
  to_seat TEXT NOT NULL,
  to_name TEXT NOT NULL,
  to_code TEXT NOT NULL,
  created_ms INTEGER NOT NULL,
  UNIQUE(from_seat, to_seat)
);
CREATE INDEX IF NOT EXISTS idx_friend_requests_to ON friend_requests(to_seat);

CREATE TABLE IF NOT EXISTS friend_messages (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  from_seat TEXT NOT NULL,
  to_seat TEXT NOT NULL,
  body TEXT NOT NULL,
  liked INTEGER NOT NULL DEFAULT 0,
  reply_to INTEGER,
  reply_from TEXT NOT NULL DEFAULT '',
  reply_body TEXT NOT NULL DEFAULT '',
  created_ms INTEGER NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_friend_messages_pair
  ON friend_messages(from_seat, to_seat);
CREATE INDEX IF NOT EXISTS idx_friend_messages_rev
  ON friend_messages(to_seat, from_seat);

CREATE TABLE IF NOT EXISTS friend_invites (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  from_seat TEXT NOT NULL,
  from_name TEXT NOT NULL,
  to_seat TEXT NOT NULL,
  game TEXT NOT NULL,
  code TEXT,
  status TEXT NOT NULL DEFAULT 'pending',
  created_ms INTEGER NOT NULL,
  updated_ms INTEGER NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_friend_invites_to ON friend_invites(to_seat);

CREATE TABLE IF NOT EXISTS friend_blocks (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  blocker TEXT NOT NULL,
  blocked TEXT NOT NULL,
  blocked_name TEXT NOT NULL DEFAULT '',
  created_ms INTEGER NOT NULL,
  UNIQUE(blocker, blocked)
);
CREATE INDEX IF NOT EXISTS idx_friend_blocks_blocker ON friend_blocks(blocker);

-- The device credential: only the SHA-256 hash of the device's secret is
-- stored (never the token). First bind of a seat wins; every friends
-- endpoint derives the acting seat from the hash instead of trusting a
-- request's public seat id.
CREATE TABLE IF NOT EXISTS friend_credentials (
  seat_id TEXT PRIMARY KEY,
  token_hash TEXT NOT NULL UNIQUE,
  created_ms INTEGER NOT NULL
);
