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
  expires_at INTEGER NOT NULL
);
