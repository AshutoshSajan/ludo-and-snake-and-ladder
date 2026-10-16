-- Game Club — admin tables (auto-created on first use).
--
-- These live in the SAME SQLite file as the leaderboard (`ludo_leaderboard.db`
-- by default, `--db` to change) so one DB holds everything the dashboard
-- shows: presence, bans, audit and room lifecycle beside `results`/`players`.
-- No action needed: AdminStore runs CREATE TABLE IF NOT EXISTS at open.
-- This file exists for review and explicit provisioning.
--
-- `admin_players`  presence: first_seen drives new-players-per-day.
-- `admin_bans`     bans: NULL until_ms = permanent.
-- `admin_audit`    append-only moderation log.
-- `admin_rooms`    one row per created room; status lobby -> live -> closed.

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

-- Accounts + sessions (auth_users/auth_sessions). One table for admins
-- today and players tomorrow: role is 'admin' | 'moderator' | 'user',
-- seat_id links a future player account to its game identity.
-- Passwords are PBKDF2-HMAC-SHA256 (per-user salt); sessions store only
-- the SHA-256 hash of an opaque 256-bit token.
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
CREATE INDEX IF NOT EXISTS idx_auth_sessions_user
    ON auth_sessions(user_id);
