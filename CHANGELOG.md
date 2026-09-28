# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project is maintained with [git-cliff](https://git-cliff.org).

## Unreleased
### Added
- Feat: Render deploy — .env support, single-service web+server image

- bin/server.dart: .env loader (real env wins), PORT support, serves the
  compiled Flutter web build when present (WEB_DIR, default build/web)
- Dockerfile: flutter SDK build stage (pub get, flutter build web, dart
  compile exe) + debian-slim runtime with libsqlite3 fallback
- render.yaml: one-service blueprint (web UI + WS + /stats + leaderboard,
  health check /stats, sync:false Turso env vars)
- client: defaultServerUrl prefers GAME_SERVER_URL dart-define, then
  same-origin wss on https (Render), keeps dev defaults
- .env.example (committed) + local .env (gitignored) +
  deploy/turso_schema.sql for explicit Turso provisioning
- README: 'Deploy on Render' section
- Feat: horizontal scaling — room registry, /stats, sticky LB config

- lib/server/room_registry.dart: cross-instance room registry; in-memory
  default, Turso TTL-backed table when TURSO_DATABASE_URL is set
- bin/server.dart: --instance-id/INSTANCE_ID, GET /stats capacity gauges,
  GET /rooms/lookup?code= routing hook, 30s registry TTL sweep, per-join
  registration
- deploy/nginx.conf: consistent-hash (room-affinity) LB for N replicas
- tests: TursoRoomRegistry wire format via mock HTTP, InMemory registry,
  stats/lookup production handlers; README Phase 12
- Feat: persistent leaderboard via Turso (libSQL HTTP API)

LeaderboardStore is now an abstract interface with two backends: the local SQLite file (renamed SqliteLeaderboardStore, unchanged behavior) and a new TursoLeaderboardStore that speaks Turso SQL-over-HTTP (POST /v2/pipeline, Bearer auth) via package:http — no native driver. Selected from TURSO_DATABASE_URL + TURSO_AUTH_TOKEN in bin/server.dart, falling back to the SQLite file. Store methods are async; GameAuthority fire-and-forgets idempotent writes and lets a failed write retry on the next room action. Wire format, row decoding (integers as strings), error surfacing and env selection are covered by 10 new tests.
### Fixed
- Fix(server): unregister closed rooms from the registry immediately
- Fix(docker): pin Flutter 3.47.2 from official tarball; dart build cli bundle
- Fix(server): normalize /rooms/lookup codes like the join path
### Other
- Memoize the duplicate-column upgrade as done

A fresh table answers ALTER TABLE ... ADD COLUMN owner with "duplicate column name: owner". The previous handler cleared _upgrades on every error, so that expected answer resent the doomed ALTER (a full extra round trip) on every register, lookup, and unregister. Treat only the duplicate-column answer as done; other failures stay pending and are retried by the next call.
- Never leave a route pointing at a closed room

A registration is a slow round trip, and a room can close while one is in
flight: the close callback's scoped unregister removes the row first, and
the registration that lands afterwards restores it — or creates it —
pointing at a room that no longer exists. /rooms/lookup then keeps
sending joins to a dead room until the entry expires.

All route upkeep now funnels through advertiseRoom, which re-checks the
room once the round trip finishes and withdraws the route again when it
is gone. That covers the join/reconnect refresh, the periodic sweep, and
the hand-back that returns an expired-claim code to the local room that
won it. The withdrawal is scoped to the room's own token, so a recycled
code's newer room is never touched.
- Migrate room_registry tables that predate the owner column

CREATE TABLE IF NOT EXISTS cannot add a column to a table that already
exists, so a Turso database created by an earlier revision of this branch
kept a room_registry without `owner`. Every register, unregister, and
lookup then failed with "no such column: owner" — and because the create
path treats a registry error as an outage, rooms were hosted locally,
where no other replica could find them.

TursoRoomRegistry now runs ALTER TABLE ... ADD COLUMN owner TEXT once per
process before the first statement that needs it. Its failure is
tolerated because "duplicate column name" is the expected answer once the
column exists (fresh tables are created with it, and replicas migrating
concurrently race the same way); a genuine problem still surfaces from
the caller's own statement immediately after. A failed attempt (registry
unreachable) is retried by the next call instead of being memoized.
- Refuse claims that would steal a live room's route

Two concurrent creations on one replica can draw the same 4-letter code.
register was a CAS only against other instances, so the second claim
replaced the first row's owner token and BOTH reported success. The
second creation then failed the local code-collision check, and its
cleanup — the unregister of the token it believed it had claimed —
deleted the first room's live route: lookups answered 404 and another
replica could claim the code before a sweep refresh restored it.

register now refreshes a live row only for the same instance AND the
same room token; foreign claims and competing same-instance claims alike
leave the row untouched. The Turso CAS re-reads the owner column too, so
a refused competing claim can never masquerade as a success. The create
path's collision-race cleanup additionally hands the route straight back
to the winning local room instead of leaving it dark until its next
sweep refresh.
- Retry joins on the replica that owns the room code

A room is created on whichever replica the code-less first connection
landed on, so hashing by `?code=` alone can pin a later join or
reconnect to a replica that never saw the room. The landing replica now
answers with the owning instance (from the registry) and the client
retries the join as `?owner=<instance>`, which nginx's new map pins to
the owning upstream directly — a closed set of known instances, so it
cannot be abused as an open proxy.

Room codes are canonicalized to uppercase when connect stores the code
and again when the URI is built, so the hash and the room's stored code
never disagree.
- Claim a room code before the room exists

Code uniqueness is checked locally only, so two replicas could generate
the same code. The old create-then-claim flow could hand the host a code
whose registry row pointed at another replica, and when the claim was
refused it abandoned a room that quick-matchers had already joined,
leaving them attached to a room the server no longer tracked.

Creation now reserves a generated code in the registry first and only
then opens the room under it (createRoom takes an explicit code and
token): a refusal retries with a fresh code and nothing to abandon,
three refusals fail the hello with an error instead of handing out an
unroutable room, and a registry outage still hosts locally as before.
Quick match uses the same claimed path (`matchExisting` plus claimed
creation) so the code a matched player receives always routes back here.
If the socket dies while a claim is in flight, the seating is undone:
the empty room closes and its freshly claimed row is released.

Also fixed while touching the join paths: honor WEB_DIR from .env
(assign the loaded environment to serverEnv in main), look up the
foreign owner with the uppercase code, and omit the `owner` key from
error frames when no foreign owner is known.
- Scope registry deletes to the closing room's token

A room code is recycled the moment its room closes, so a slow Turso
DELETE could erase the row a newer room (same code) had already claimed
— routing joins to an instance that no longer holds the room. Both
registries now store an opaque per-room token (`owner` column for Turso,
a parallel map in memory) and the scoped delete (`owner IS ?`) skips rows
that changed hands; a token-less unregister still deletes unconditionally.
- Ci: unpin deprecating runner label and Node 20 actions

- Bump actions/checkout v4 -> v6 (v4 targets Node 20, now forced to 24)
- Bump peter-evans/create-pull-request v7 -> v8 (same Node 20 issue)
- Pin runs-on to ubuntu-24.04: ubuntu-latest migrates to Ubuntu 26 on
  Oct 19, 2026 (actions/runner-images#14748), which would silently
  change the toolchain underneath the build
- Make registry code claims CAS and bound/close registry pipelines

Cross-replica duplicate codes could silently overwrite another replica's
routing entry (unconditional upsert; code generation is per-instance only).
RoomRegistry.register now returns whether the claim stuck: the Turso upsert
only takes rows that are ours or already expired, a trailing SELECT verifies
the resulting owner, and InMemoryRoomRegistry mirrors the same semantics.
wsHandler claims freshly created codes in the registry and, on a refusal,
quietly drops the duplicate room (GameAuthority.abandonRoom - no unregister,
the row is the other replica's) and regenerates, so joins can never be routed
to the wrong replica.

Registry pipelines now also end with an explicit close request (matching the
leaderboard transport) and every HTTP pipeline is bounded to 10s, so a hung
Turso connection cannot pile up pending refreshes. Wire-format tests updated
accordingly; new tests cover the CAS outcomes, the close request, the 10s
timeout, and the duplicate-code regeneration.
- Derive registry sweep cadence from the room TTL

The sweep that re-registers live rooms ran on a fixed 30 s period. With
ROOM_TTL_SECONDS below 30 — say 10 — a live room's registry entry
expired before the next sweep, so /rooms/lookup 404ed for ~20 s per
cycle for rooms that still existed; even a 35 s TTL left only ~5 s of
margin against sweep jitter or a failed request.

The sweep now runs at a third of the configured TTL, truncated to whole
seconds and clamped to [1 s, 30 s]: the 120 s default keeps the
historical 30 s cadence, and short TTLs get proportionally shorter
sweeps that leave margin for two missed rounds. Extracted into a
testable registryRefreshInterval() with regression tests.
- Keep the page port in the same-origin server URL

The same-origin default built the WebSocket URL from Uri.base.host only,
dropping an explicit nonstandard port. A page served over HTTPS on
e.g. :8443 then connected to the default port 443, and the leaderboard
— derived from the same URL — hit the wrong origin too, so neither
worked even though the page loaded.

Use the page URI's authority (host plus explicit port) for the wss
branch; plain http keeps the :8080 local dev default. The derivation
is extracted into a testable sameOriginServerUrl() with regression
tests for nonstandard port, standard port, and the http dev case.
- Carry the room code in the WebSocket URL for room affinity

nginx hashes the ?code= query parameter consistently to pin a room's
players to the replica that owns the room, but the client connected to
the bare /ws URL and sent the code only in the hello frame — so the
affinity key was always empty. A join (or reconnect) could land on the
wrong replica; the server rejects it and the client deliberately stops
retrying, so the join never succeeds.

The client now appends ?code= to the WebSocket URL whenever the room
code is known: on join-by-code from the first connection, and on every
reconnect using the code learned from 'joined' (also covering
quick-match reconnects). The hello frame still carries the code — the
server treats it as authoritative, so plain sockets are unaffected.
First connects without a code (room creation, quick match) may still
land anywhere; that is the documented design, and every later open is
sticky.

nginx.conf's header now documents that the shipped client supplies the
parameter. Regression tests assert the URL on join, on reconnect, and
on quick-match reconnect.
- Serve the documented health JSON at /health; honor WEB_DIR from .env

Review follow-ups on PR #50:

- GET / previously documented as the JSON health check now serves the
  Flutter web build when one ships. Add a dedicated GET /health that
  always returns the JSON health payload (stable URL for probes in every
  deployment mode); keep the JSON response at / only when no web build
  exists, for API-only deployments.
- The webDir getter read WEB_DIR only from the process environment,
  ignoring values supplied via .env. Capture the merged environment at
  startup (serverEnv) and consult it, so a build configured solely in
  .env is still served. Real environment wins, matching the loader.
- Document both in the server header and README.
### Testing
- Test: cover the /stats connection gauge with a live socket

The stats test only checked that `connections` was an int — it passed
even if the gauge always read zero or never decremented after a
disconnect. Add a loopback test that opens a raw WebSocket, verifies
the count increments (before any hello), closes the socket, and polls
until the gauge returns to its baseline.

flutter_test's global HttpOverrides stubs plain HTTP clients with empty
400 responses, so the test opts out via a zone-local no-op
HttpOverrides subclass (base createHttpClient builds the real client).
## [v1.1.0] - 2026-09-20
### Added
- Feat: quick match — auto-pair waiting players and auto-start at two
### Documentation
- Docs: fold the quick-match doc entry into the v1.1.0 release section
- Docs: fold quick-match entry into v1.1.0 release section
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
### Documentation
- Docs: add v1.0.0 release section to changelog
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
- Ci: generate changelog on main pushes only
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
