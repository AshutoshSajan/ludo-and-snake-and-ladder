-- Game Club — Turso database schema.
--
-- The stores create these tables on first use (idempotent), so this file
-- exists for explicit provisioning and review. Apply with:
--
--     turso db shell <database-name> < deploy/turso_schema.sql
--
-- `results`/`players` are the leaderboard (lib/server/turso_leaderboard_store.dart),
-- `room_registry` is the cross-instance routing map with a TTL column
-- (lib/server/room_registry.dart) — expired rows are GC'd on every call.
-- `owner` is the per-room token that scopes a close's delete so a recycled
-- code's newer room is never erased by a stale unregister. The `friend_*`
-- tables are the durable friends state (lib/server/turso_friend_store.dart):
-- profiles with immutable friend codes, accepted friendships, pending
-- requests, DMs, play invites and blocks. Databases created by an earlier
-- revision of the server are upgraded in place on first use (the stores run
-- guarded ALTER TABLE ... ADD COLUMN), so this file is only needed for a
-- brand-new database.

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
CREATE UNIQUE INDEX IF NOT EXISTS idx_results_game_seat ON results(game_id, seat_id);

CREATE TABLE IF NOT EXISTS players (
  seat_id TEXT PRIMARY KEY,
  name TEXT NOT NULL
);

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
