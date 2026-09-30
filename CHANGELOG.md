# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project is maintained with [git-cliff](https://git-cliff.org).

## Unreleased
### Added
- Feat(online): seat hand-over, walk-outs and autoplay across the online tables

- lib/server/game_server.dart: seats feed — every join/leave/autoplay change
  broadcasts seatsJson(), so a table always knows who is where, including the
  seats that are quiet (connected: false) and the ones that walked out
- lib/server/game_server.dart: autoplay intents — a seat can hand its turns to
  the table, the server rolls on its own clock, and a human taking the seat
  back stops it mid-thought instead of letting a pending roll land
- lib/server/game_server.dart: walk-outs — leaving gives the chair up for
  good (no rejoin, no reuse); two players decide the table by forfeit, three
  or four play on without the empty corner, and a dropped socket is not a
  walk-out: the seat waits and the same profile can reclaim it
- lib/server/game_server.dart: chat relay accepts the 'text' field; a
  two-player ludo table seats the pair opposite each other
- bin/server.dart: /health fails open — a scoreboard store that is down is
  reported in the body (store, storeError) instead of turning the game server
  into a 500 that a load balancer would read as a dead instance
- lib/services/online_client.dart: seats/left events, sendAutoplay and
  sendLeave, and a chat payload field the server actually reads
- lib/ui/shared/seat_status_strip.dart: one strip for both boards — autoplay
  outranks a dropped socket ("playing for you" beats "connection lost"), and
  it stays hidden while every seat is present and live
- lib/ui/ludo/ludo_view.dart, lib/ui/snakes/online_snakes_view.dart: autoplay
  toggle, leave confirmation, and a notice when a seat walks out
- lib/screens/online_lobby_screen.dart: the roster keeps seats that walked out
  apart from seats that went quiet, and an explicit Leave says so before the
  socket is dropped
- lib/controllers/ludo_session.dart: the session forwards the autoplay and
  leave intents to the client
- test/online_server_test.dart: authority coverage — lobby chat and autoplay,
  a handed-over seat played by the table, the human taking it back, 2P and 3P
  walk-outs, and a dropped link that is not a walk-out
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
- Ci: render each changelog entry once

A commit and its cherry-pick are two commits with a byte-identical message, so the same change printed twice: the changelog-job change landed on staging via #68 and #70 cherry-picked it into dev, which after the staging back-merge left dev with the entry at two places in the file.

Pipe the grouped commits through unique(attribute=message). Verified with git-cliff 2.14.1 against both trunks: dev drops from 505 to 489 lines with exactly one 16-line duplicate block removed and nothing added, and main is regenerated byte-for-byte unchanged, so branches without duplicates are untouched.
- Ci: generate CHANGELOG.md on the promotion PR and commit it onto the PR branch

The changelog job used to run on pushes to main and open a follow-up pull
request against staging, so main always shipped a CHANGELOG.md one promotion
behind the code it described, and closing that gap needed an extra bot PR.

Move the job to pull requests whose base is staging or main, and have it commit
the regenerated file onto that PR's head branch instead: the changelog now
travels with the code it documents and reaches main inside the same merge
commit. Add a guard that fails the job when the regenerated file would drop an
existing release section, which is the stale-head-branch case the old comment
warned about.

Branch protection is unavailable on this plan, so guard-main stays the only
thing that can stop a direct push to main; this job only ever pushes to a PR
head branch.
- Ci: delete merged PR head branches automatically

The repo setting delete_branch_on_merge cannot simply be switched on: it deletes the head branch of every merged PR, and this repo promotes with dev -> staging -> main, so the next promotion would delete dev and then staging.

prune-branch runs on the pull_request closed event and is guarded three ways: a trunk is never deleted, names outside this repo prefixes are never touched, and a branch holding commits absent from the base is kept rather than discarded.

Also pin pull_request to four activity types so editing PR labels stops triggering a full test run.
- Move the app providers onto Riverpod 3 notifiers

Riverpod 3 moved StateNotifierProvider/StateNotifier out of the main import, and all four app notifiers were built on them, so flutter_riverpod 2.6.1 -> 3.4.3 needed a migration rather than a version bump.

The setup that used to sit in each constructor now lives in build(), which is where 3.x expects it: return the default synchronously, apply the persisted value when storage answers. Ref is no longer passed through the constructor - a Notifier owns one as the protected `ref` - so the constructors and the injected `_ref` fields are gone. Every async callback checks `ref.mounted` first, because 3.x refuses to let a disposed Ref be touched and these loads can outlive the provider; the services used after the await are captured before it.

ProfilesNotifier.load() disappeared: reading the provider runs build(), which starts the load, and nothing else called it. The two tests that hand-built a ProfilesNotifier with a Ref from a throwaway Provider<Ref> now read profilesProvider.notifier from a container overriding storageProvider with an inert storage whose load never completes, which keeps the old "never load(), never touch SharedPreferences" guarantee.

Checked rather than assumed: NotifierProvider defaults to isAutoDispose false, and the repo uses no ref.listen, StateProvider, ChangeNotifierProvider, .autoDispose or ProviderObserver, so none of the 3.x lifecycle changes reach anything here.

Analyze clean with --fatal-infos, 190 tests pass, web release build succeeds.
- Refresh the locked dependency versions and CI action pins

pub upgrade moved sqlite3 3.5.2 -> 3.6.0, meta 1.18.3 -> 1.19.0, vector_math 2.4.0 -> 2.4.3, platform 3.1.6 -> 3.2.0, synchronized 3.4.1+2 -> 3.4.2, objective_c 9.5.0 -> 9.6.0 and the sqlite3 build-hook chain (hooks, code_assets, native_toolchain_c, record_use, process). No pubspec constraint changed: every bump was already allowed by the existing carets, the lock had only drifted. flutter_riverpod 2.6.1 stays put on purpose - 3.x is a major release with provider lifecycle changes and needs its own migration.

CI: actions/checkout v6 -> v7, git-cliff 2.14.1 -> 2.14.2. Checked against each repo release API: checkout v7.0.1 is current, flutter-action is at v2.23.0 so the v2 pin is current, create-pull-request is at v8.1.1 so the v8 pin is current.

Analyze clean with --fatal-infos, 190 tests pass, web release build succeeds.
- Say which part of the leaderboard path is broken

The screen had one message for every failure, so a server that answered 500 --
up, reachable, its own store broken -- told the player to check whether
'dart run bin/server.dart' is running. That is the wrong errand, and it is what
the deployed app does today.

fetchLeaderboard now throws LeaderboardServerException when the server answers
with a non-200 status, which is the point where 'reachable' and 'unreachable'
actually split, and the screen words the two apart. A third state was already
right and is now pinned by tests: zero finished games is an empty board, not an
outage. The loader is injectable so the widget tests can show each state
without a live server.
- Answer a failing route as JSON, not as a bare shelf 500

/leaderboard calls its store unguarded, so a revoked Turso token throws out of
the handler. shelf then writes its own error page -- plain text, and from
*outside* the middleware chain, which means no CORS headers either. A browser
cannot read that response at all, so it reports a cross-origin block and the
app blames the connection, while the fault is the server's own database.

jsonErrorMiddleware now sits inside corsMiddleware and turns any throw into a
500 JSON body with the CORS headers still applied, so the client sees a status
it can name. The cause is logged rather than sent: the route is public and a
store failure can quote the database URL. The log line names the method and
path, because the deployed log previously showed a lone 500 with nothing to
trace.

Tested through the real middleware chain with a store whose reads fail, and
live against a server pointed at an unreachable Turso host: JSON 500 carrying
access-control-allow-origin, and '!! 500 on GET /leaderboard: ...' logged.
- Let the browser read the JSON API: CORS on the server

The Leaderboard screen failed on web even with the server up and
answering: the Flutter dev page (http://localhost:<random port>) and
the game server (:8080) are different origins, so the browser fetched
`/leaderboard` fine and then refused to hand the response to the app —
and the app surfaced that as "Could not reach the server".

The production pipeline now wraps its routes in `corsMiddleware`, which
reflects the request Origin plus `Vary: Origin` on the read-only JSON API
(`/health`, `/leaderboard`, `/stats`, `/rooms/lookup`) and answers OPTIONS
preflights with 200. WebSockets need no preflight so `/ws` is untouched,
writes stay rejected with 405, and nothing riding auth or cookies changes:
the only bearer token in the picture is Turso's, server-side.

Covered by two server tests that exercise the real middleware, not the
raw handlers: all four routes carry the headers and answer OPTIONS, and
a POST is still a 405 with the headers present. Verified live too, with a
browser-shaped Origin header against a scratch server.
- Write the changelog's escaped newlines as line breaks

The "Keep the page port in the same-origin server URL" note landed as one
physical line carrying nine literal 
 escapes: its commit body was
written with escaped newlines and git-cliff copies a body verbatim into
the notes, so the paragraph is unreadable in the release notes and in the
release PR (flagged on CHANGELOG.md line 173).

A postprocessor now turns that two-character escape into the line break
it was meant to be, which repairs this entry and any future body written
the same way, and the changelog is regenerated. The rest of the file is
byte-for-byte what CI generates - regenerating before the change
reproduced the committed file exactly, and afterwards the diff is only
those nine escapes.

The commit message itself cannot be rewritten, since it is already on
staging and main; the guard belongs in the generator.
- Give the snakes game one home area, not one per player

Every seat had its own house-marked garage under the board, so "where do
pawns start" had as many answers as there were players, and at ten seats
the strip grew a second row of them. There is now a single home area:
one panel under the board, marked with one house and a count of who is
still waiting, holding a colour chip per pawn that has not entered yet.
Chips shrink to keep all ten in one row rather than growing a second
area, and a pawn that has entered simply leaves the panel.

The panel and the ghost hop still share one coordinate space, so a pawn
departs from the exact spot its chip occupied - one formula places both,
with the panel's own origin accounted for. The moving pawn is drawn only
by the ghost, so it never shows up twice during the walk.
- Review only the PRs that target main

Greptile reviewed every pull request in this repo, so the daily feature
PRs into dev competed for attention with the one change that is actually
about to ship. A committed .greptile/config.json now narrows it:

  "includeBranches": ["main"]

The filter is inclusive and is matched against the PR's base branch, so
with this repo's tiers the only PR Greptile reviews is staging -> main -
the release PR. PRs into dev/sandbox stay CI-gated, drafts are skipped
until they are marked ready, and any PR the filter skips can still be
reviewed on demand with @greptileai.

Widening or inverting it is a one-line edit (includeBranches, or
excludeBranches to review everything but a tier); both take globs. The
new README section records that, the dashboard equivalent, and the one
gotcha worth knowing: Greptile reads the config from the PR's source
branch, so a branch obeys the filter only once it contains the file.
- Give the home garages a house and every platform an icon

Snakes & Ladders: the strip under the board labelled each garage with a
seat number, which reads as a board square rather than as home - square
0 is off-board, so a waiting pawn is not on any square yet. Every garage
now carries a house (dimmed once its pawn has left) and the seat numbers
stay where they belong, on the seat cards above.

The app also had no icon of its own: the web build served Flutter's
default favicon, Android a placeholder launcher PNG, and the PWA a
"game_club" manifest in Flutter blue. One drawing now feeds all of it -
a gold-rimmed ivory die on the felt table, in the palette of
lib/ui/theme.dart - via tools/gen_app_icons.py, a stdlib-only generator
in the spirit of gen_extension_icons.py. It renders one anti-aliased
master per variant and box-filters it down to every required size:

  web/favicon.png                     rounded corners, 32 px
  web/icons/Icon-192|512.png          full bleed, no alpha
  web/icons/Icon-maskable-*.png       full bleed, content inside the mask
  android/.../ic_launcher.png         one per density
  android/.../ic_launcher_foreground  adaptive layer + anydpi-v26 wiring
  ios/.../AppIcon.appiconset          opaque: iOS rejects alpha
  macos/.../app_icon_*.png            rounded
  windows/.../app_icon.ico            16/32/48 DIB + 256 PNG entries

Re-running the generator is a byte-for-byte no-op, so the set can be
rebuilt whenever the mark changes.

The names those icons sit under are aligned too: the PWA manifest and
page title become "Game Club" with the icon's felt-green theme colour,
and Android's launcher label stops saying "game_club".
- Show the dice on every roll and park starting pawns in home

Three bugs from playing the games, all with a test each:

Ludo: a roll that ends the turn on the spot — nothing legal to move, or
the triple-six forfeit — nulls lastRoll inside rollDice, before the view
is ever notified. The dice keyed its tumble and its face off lastRoll,
so exactly the rolls a player most wants to see came up dead still.
Record the face and the seat in lastRolledValue/lastRolledBy, which no
rule reads, and drive the tumble off the roll sequence instead.

Snakes: pawns start at square 0, which has no cell on a 1..100 board, so
the whole starting lineup was drawn outside the board and clipped away.
Hang a strip of numbered garages under the board inside the same Stack
and coordinate space, so a pawn leaving home is one continuous hop from
its garage onto square 1.

Snakes: a move took 260ms per hop plus a 150ms tail — slow enough that
players tapped ahead. One hop is now 120ms with a 260ms tail, shared as
constants between the session and the view so the dice tumble window
cannot drift from the walk it opens.

Also: autoplay for human seats (the pause-menu "go for a break" beat),
and scheduleNext no longer cancels the timer that lands an in-flight
move — toggling autoplay mid-walk used to strand the pawn mid-board
with the session permanently busy.
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
