# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project is maintained with [git-cliff](https://git-cliff.org).

## Unreleased
### Documentation
- Docs: add v1.0.0 release section to changelog
## [v1.0.0] - 2026-09-17
### Added
- Feat: online Snakes & Ladders multiplayer

Rooms are now game-typed: the host picks Snakes & Ladders at creation and everyone joins via the same 4-letter code flow. The server rolls and resolves the single forced move with the pure engine (same intent protocol); the client auto-sends its move after a beat, renders board/pawns with the shared painter, and handles game-over, spectating, and mid-game reconnects. Leaderboard results map pawn slots back to corner seats.
- Phase 10+11: online leaderboards (SQLite store + /leaderboard + scoreboard UI) and spectating (read-only watchers, spectator lobby UI, intent no-ops)
- Online leaderboards: SQLite-backed career stats (Phase 10)

- LeaderboardStore (lib/server/leaderboard_store.dart): records one row per seated player per finished game, idempotent per game id; aggregates wins/games/avg placement; in-memory, file, or borrowed-database mode for tests

- GameAuthority takes an optional store and records results exactly when a game reaches gameOver (ranks straight from state.rankings); no-op when absent

- Server: GET /leaderboard JSON endpoint, --db FILE flag, game count merged into /health

- Client: OnlineClient.fetchLeaderboard HTTP fetch; new ScoreboardScreen with medal podium, per-rank rows, pull-to-refresh and server-down state; home screen entry point

- Tests: 8 store tests (aggregation, idempotency, name updates, avg-rank ordering, file persistence), 2 authority recording tests on a forced endgame, 1 HTTP handler test — 99 total, analyze clean, web release build OK
- Online Ludo multiplayer: authoritative shelf/WebSocket server, client session, lobby UI, tests
- Polish & hardening: settings screen (sound/haptics/animations), move undo + hints, streak stats, screen-reader semantics, CI workflow; Haptics swallow platform errors; injectable session RNG; tests for all features
- Add offline Chrome extension packaging (MV3): manifest, toolbar action, local-CanvasKit bootstrap pin, icon generator, build script, docs
- Add regression tests for all bug fixes; lazy AudioPlayer; addPlayer token alignment
- Autoplay mode, glossy black rounded dice, roll animation on every roll
- Finished pieces rest on their own color triangle in the center finish square
- Add per-step hop tick sound synced to token movement
- Finished tokens in own yard, champion fanfare + confetti, per-corner dice with 3D tumble, remove top strip
### Fixed
- Fix(changelog): skip merge-commit subjects in git-cliff
- Fix(dice): stop tumble carrying across turns; settle spin-down ends after settle duration

Semantics wrapper for the GestureDetector (accessibility label) with explicit
textDirection; regression tests for spin-down stop and value settle.
- Fix turn order to run clockwise around the board (red-blue-yellow-green)
- Fix Ludo track direction and color-to-corner mapping

Track now runs counter-clockwise with each color's start cell adjacent to its own yard (red (8,1), green (1,6), yellow (6,13), blue (13,8)), so a rolled six spawns the token beside the player's own corner instead of the opposite one. Updated geometry expectations in rule tests.
- Fix blue home column misalignment (col 6 -> col 7) so all home runs connect to their matching center triangle
- Fix Ludo center home triangles spanning the 3x3 block; draw ladder rails as parallel tracks
### Other
- Mid-game reconnect: seat reclaim, auto-reconnect, grace period

Server: persistent seatRegistry per room; rejoinRoom reclaims the original corner mid-game and evicts stale connections; started rooms with no members survive an emptyRoomGrace (default 5 min) before removal, emptied lobbies are dropped immediately; transport routes hello-through-rejoin and sends the current snapshot to a rejoining client. Client: OnlineClient auto-reconnects with exponential backoff (500ms..8s, 5 attempts) after an unplanned drop, reuses the join code/identity, and surfaces a reconnecting status; definitive server errors stop the loop; disconnect() reflects idle immediately. UI: reconnecting banner over the board and lobby spinner. Tests: 10 new (authority rejoin/grace, loopback mid-game rejoin, client backoff/give-up/rejection/disconnect via fake channels in fakeAsync). analyze clean; 91/91 tests; web release build OK.
- Dice pips painted in face plane, larger cube
- Finishing pawns walk into their own yard slot instead of the board center
- Dice: true 3D cube render — 8 projected vertices, depth-sorted shaded faces, perspective tumble
- Ludo: corner picker per seat; 2-player default is diagonal seating (red vs yellow)
- Ludo: move per-player dice into outer margin corners, outside yard boxes
- Ludo: horizontal name plates (bottom for bottom yards, top for top yards) + safe-cell chime
- Ludo: highlight only movable pawns, center yard pawns, plain entrance arrows, full-color home columns
- Ludo board polish: stars at start+8, square yards, arm-edge name plates, taller pawns, matching center triangles, entrance arrows
- Ludo: run main track clockwise; start cells beside own yards
- Restyle Ludo board & tokens: rounded baseplates with corner name plates, pulsing glow on active corner, pawn-shaped tokens with rotating turn ring and per-step hop bounce
- Game Club v1: Ludo + Snakes & Ladders — local hot-seat + AI, all 6 platforms scaffolded<!-- generated by git-cliff -->
