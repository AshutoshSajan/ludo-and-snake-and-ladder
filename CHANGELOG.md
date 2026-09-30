# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project is maintained with [git-cliff](https://git-cliff.org).

## Unreleased
### Added
- Feat(deploy): split the web client onto Vercel, and survive a cold start

Lets the web client be hosted on Vercel while the authoritative game
server stays on Render, and makes the first connect of a session wait
for a sleeping host instead of reporting a failure.

The split itself needs no code: `defaultServerUrl()` already prefers a
build-time `--dart-define=GAME_SERVER_URL`, so once the client is on its
own domain the dart-define wins and `sameOriginServerUrl` is never used
for online play. The two hosts need not share a name, and the
leaderboard's HTTP origin is derived from that same URL, so it follows
automatically. `vercel.json` carries the build command, the output
directory, and the same no-cache policy the server now applies, so a
Vercel deploy is not stale-cached either.

Cold starts are the part that actually needed fixing. Render's free
plan sleeps after ~15 idle minutes, and until the process is listening
the proxy refuses connections — so pressing "Play" after a pause
reported "Could not reach server" to someone who had done nothing
wrong. A refused socket is now re-probed with backoff for up to ~22s
while the UI says "Starting the game server…" and explains why, and only
then reports failure, pointing at cold start rather than at the player.
The leaderboard fetch got the same patience (5 attempts, 10s each) for
the same reason.

Tests: a refused socket is retried rather than reported, and a server
that is genuinely unreachable still gives up with a useful message. The
backoff is not final so the give-up path is provable in a second
instead of in the 22s a real user would wait.

Documented in the README, including the practical catch that Vercel has
no Flutter runtime and the build therefore has to happen in GitHub
Actions (or a custom builder image).
- Feat(online): a reusable player identity, in-game chat, and a dice that signals

Three things the online tables were missing, plus one that had gone
missing on a screen where it had shipped.

A reusable player identity. The connect form asked for a name every
time, and the seat id was generated per session:

  final String _seatId = 'u${DateTime.now()...}';

The server keys every recorded result by seat id, so that made each
session a *different player* to the server: no career carried across
games, and a new leaderboard row every time. Saving the name alone would
not have fixed it — you would have been the same name under a fresh id
each session, filling the board with duplicate rows of you.

The id is now created once and persisted, the name is remembered and
prefilled, and the name stays freely editable. The id is shown
read-only rather than hidden, because it is what wins attach to, and
it is deliberately not editable: changing it would orphan the career
already recorded under it. There is a test for exactly that.

In-game chat. Chat was reachable only from the lobby — the one screen
where you are not mid-game — so a running table could not talk to
itself. Both online boards now open a chat sheet over the board, with
history and an input that lifts above the keyboard.

The server was never the problem: chat is handled ahead of the "no game
yet" guard and already worked in every phase. Two tests pin that, so
moving the chat case behind the guard later cannot quietly break
in-game chat while the lobby keeps working.

A dice that signals. Snakes' die was hardcoded gold for every seat and
never pulsed; it now takes the current player's corner colour and
breathes on your turn. Ludo already wore the corner colour, so it only
gained the pulse — driven by `isCurrent` rather than "is my turn",
because Ludo shows a die per corner and an AI or remote seat's corner
needs the cue too.

Also fixes the per-game leaderboard tabs, which were present but
invisible: three labelled segments with icons do not fit a phone, and a
SegmentedButton that overflows clips its *last* segment, so "Snakes"
was cut off rather than squashed. Now iconless and horizontally
scrollable, so a longer label cannot hide a tab again.
- Feat(leaderboard): per-game boards for Ludo and Snakes

The online leaderboard had no game dimension at all. Every finished game
wrote into one merged table with no record of which game it was, so a
Snakes win was indistinguishable from a Ludo one and there was no Snakes
board to show — the local leaderboard splits the two, the online one
could not.

GameResult now carries the game, the row stores it, and both stores can
report one game or all of them:

  topPlayers(game: 'snakes')   totalGames(game: 'snakes')

GET /leaderboard takes ?game=snakes and always reports gamesByGame, so
the client can label its tabs without a request per tab. The client grew
Ludo / Snakes / All tabs, each showing its own finished count, and an
empty tab names its game instead of reading as a broken leaderboard.

Both stores migrate a database that predates the column. This is not
hypothetical: the deployed database is one, and CREATE TABLE IF NOT
EXISTS leaves an existing table alone, so without the ALTER every insert
naming `game` would fail and the leaderboard would 500. SQLite has no
ADD COLUMN IF NOT EXISTS, so the column list is checked first.

Rows that predate the column keep an empty game rather than being
back-dated as Ludo: their game is genuinely unknown, and inventing it
would put fake history on a board. They show on the combined board and
on neither per-game board, and a test says exactly that.
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
- Fix(deploy): revalidate the app shell, and give new players a name

Flutter's web files are not content-hashed — `main.dart.js` is always
that name — so a browser that cached it went on running the previous
deploy. "Fixed on the server" and "fixed in your browser" were two
different things, and this cost a debugging session more than once: a
report that a shipped feature was missing turned out to be a stale tab,
then a stale bundle.

The shell (index.html, main.dart.js, the bootstrap and service worker)
now revalidates on every load — a cheap 304 when nothing changed, never
a stale body — while fonts, canvaskit and icons are held for a year,
since those *are* versioned by name and are most of the payload.

`/` is handled explicitly. The static handler answers it with
index.html, but the *request* path has no file name, so keying off the
name alone quietly gave the home page a year-long immutable cache. That
was caught by checking the headers a real server actually returned,
not by reading the policy.

A new player is also given a default name instead of an empty field.
Derived from their id, so it is *stable*: the same player is always the
same "Swift Otter" rather than a new name each visit. An unstable
default would be worse than none, scattering one player's career across
the leaderboard.

Built from two small word lists rather than a package. A name generator
is a dozen lines; a dependency is a permanent supply-chain surface and a
pubspec.lock entry for something used once. The `names` package is also
the wrong shape — it has no notion of being reproducible, which is the
one property that matters here.
- Fix(snakes): home area, dice tumble, sound, leave dialog, and a pulse

Six defects in the Snakes & Ladders boards, online and offline.

The home area was missing online only. The offline view has always had a
home lane under the board; the online view had none, and the board
numbers 1..100, so square 0 has no cell and squareCenter(0) fell through
the boustrophedon maths onto square 10's cell. Every pawn still waiting
to enter was drawn on top of a numbered square. The offline panel is now
ported across, and home pawns are excluded from the board layer so
nothing is drawn twice.

The die never tumbled online: the view passed a hardcoded
`rolling: false`, so it snapped to the new face while the offline one
rolled. It is now driven off the awaitingRoll -> awaitingMove transition
for 600ms, matching the online Ludo view and fitting inside the 700ms
beat before the forced move.

Online Snakes played in silence. Ludo gets its dice sound through
LudoSession; this view has no session, so nothing was ever wired to the
client's onRoll and a whole game played silent.

"Back to lobby" stranded the player. The game-over dialog is not
barrier-dismissible and its button called onLeave without popping the
dialog first, so the route underneath was torn down while the dialog
stayed on top with no way to dismiss it.

Autoplay lived in the row under the board, packed in with the die and
ROLL — the row that overflows on a narrow layout, which is why it read
as missing. It now sits in the app bar beside sound and pause, where
Ludo already keeps it.

The row of player chips above the board is gone; it duplicated what the
pawns already show. Whose turn it is is now said by the piece itself,
pulsing gently, on the board or waiting in the home strip. The pulse
respects the "Board animations" preference and stops its ticker when
nobody is on turn. The online SeatStatusStrip stays: it carries
autoplay, walk-out and connection state the board cannot show.

Sound gained a mute button on all four boards (both games, online and
offline) reading the same persisted provider as Settings, so the two
cannot disagree.
- Fix(server): prove the store is reachable at startup, and name TLS failures

The deployed leaderboard answered 500 with a HandshakeException because
the runtime image had no CA certificates, and the debugging went after
the Turso token for a long time because the failure looks exactly like a
revoked credential. Nothing at boot said otherwise: the server started,
logged "leaderboard: Turso", and served games perfectly, so the only
symptom was a certificate error buried in a 500 on some later request.

So the store is now contacted once at startup and the result logged:

  Turso reachable: 8 game(s) recorded.

and on failure the log names the likely cause instead of leaving it to be
inferred from a stack trace:

  !! Turso is NOT reachable: HandshakeException: ...
     If this says CERTIFICATE_VERIFY_FAILED, the runtime image is missing
     ca-certificates (debian:bookworm-slim ships no /etc/ssl/certs) —
     fix the Dockerfile, not the token.

A store that cannot be reached is still logged and the server still
starts: liveness does not depend on the leaderboard, and an instance
serving games perfectly should not refuse to boot over a scoreboard.
The line is diagnostic, not a gate.

Both branches verified against a real server: reachable prints the game
count, and pointing TURSO_DATABASE_URL at a host with an untrusted
certificate reproduces the exact failure and prints the guidance.
- Fix(ui): stop labelling the online screens "Ludo" only

Online Snakes & Ladders has worked since it shipped, but every label
on the way into it said Ludo: the home screen's button read "Online
Ludo", the lobby's app bar read "Online Ludo", and the tagline under
the wifi icon read "Play Ludo online against friends" regardless of
which game the Ludo/Snakes toggle had selected.

So the feature existed and was reachable, but nothing on screen ever
said so. Someone looking for online Snakes landed on a screen that
identified as a Ludo screen, which is indistinguishable from the
feature not existing -- the same reason the earlier report read as
"online snake game not working".

The button and app bar now read "Play Online", and the tagline names
the game the toggle has selected ("Play Snakes & Ladders online
against friends" once Snakes is picked, and back again when it isn't).

Verified against the deployed instance: a 3-player online Snakes game
played to gameOver over wss://ludo-1zpb.onrender.com/ws, 695 intents,
all three clients receiving 153 identical state broadcasts each, and
the result written to Turso (games 4 -> 5, S1 1W/1G).

Two widget tests now drive the real lobby and toggle the game; the
label test fails on the old strings.
- Fix(deploy): install ca-certificates in the runtime image

The deployed leaderboard answered HTTP 500 on every request. The cause
was not Turso and not the token: the runtime stage of the Dockerfile
installed libsqlite3-0 but not ca-certificates, and debian:bookworm-slim
ships no /etc/ssl/certs directory at all. Dart verifies TLS against the
system trust store, so every HTTPS call to Turso failed with

    HandshakeException: CERTIFICATE_VERIFY_FAILED:
    unable to get local issuer certificate

That reads exactly like a revoked token, which is where the debugging
went first. /health had been reporting it faithfully all along, as
storeError data rather than a failed probe, so the instance stayed up
and served games perfectly -- but the scoreboard could never load, and
the room registry could never register a route, so matchmaking and
join-by-code could not find rooms across instances.

The build stage already installed ca-certificates; the stage that
actually talks to Turso is the one that needed it.

Verified by building the image and running the real server from it
against the real database:

  /health        {"games":null,"storeError":"...CERTIFICATE_VERIFY_FAILED..."}
                 -> {"games":3,"store":"turso"}
  /leaderboard   500 -> 200 with rows
  /rooms/lookup  500 -> 404 "room 'ZZZZ' unknown to the cluster" (correct)

A full online Snakes game played to gameOver inside that container and
its result was written to Turso (games 3 -> 4, ImgA 1W/1G).

A test now asserts the runtime stage installs ca-certificates: it
fails on the old Dockerfile and passes on this one, so the invariant
cannot be lost by editing the build stage alone.
- Fix(server): let a WebSocket upgrade through the JSON error middleware

/ws tells shelf_io a connection is now a WebSocket by throwing
HijackException, which is control flow rather than a failure. The
jsonErrorMiddleware added to make a dead Turso store readable as JSON
caught it anyway and answered 500, so every single connection logged
a bogus "!! 500 on GET /ws" and shelf_io then complained it had been
handed a response for a request it had already hijacked.

The upgrade itself always worked and the client was never affected --
only the log lied, which is its own kind of misleading: a server whose
log fills with 500s on /ws looks broken in a way that sends you
debugging the WebSocket transport instead of reading the health route.

Shelf's own guidance is that middleware capturing exceptions must
rethrow this one, so it now passes straight through. Verified against a
live server: 3 connections, 0 spurious 500s (was 4 connections,
4 spurious 500s).
- Fix(online): stop the table playing itself once a room has nobody in it

A seat handed over to the table keeps playing after that player's tab closes —
that is the point of keeping the flag on the server. But the driver had no idea
whether anyone was still there at all, so a room where both players closed
their tabs kept rolling on its own to the end. A game nobody is connected to
can even finish and write a leaderboard row for people who were not there to
play it.

- lib/server/game_server.dart: _armAutoTimer refuses to arm while the room has
  no connections at all (players or watchers), and every roster change
  re-evaluates it: a dropped link or a walk-out cancels a pending step, and a
  join, rejoin or arriving spectator re-arms it so the paused turn resumes
  exactly where it stopped instead of having moved on unseen
- lib/server/game_server.dart: a walk-out arms the driver for the seat that
  inherits the turn — it used to move the turn onto an autoplay seat and leave
  it sitting there until somebody happened to send another intent
- test/online_server_test.dart: new group "the autoplay driver" — a room with
  nobody in it freezes and picks its turn back up when someone returns, a
  hand-over still plays while somebody is watching, and a walk-out hands the
  turn to an autoplay seat with the driver picking it up
- Fix(server): unregister closed rooms from the registry immediately
- Fix(docker): pin Flutter 3.47.2 from official tarball; dart build cli bundle
- Fix(server): normalize /rooms/lookup codes like the join path
### Other
- Host the web client on Netlify instead of Vercel

Adds netlify.toml and removes vercel.json, so the Flutter web client deploys
to Netlify while the WebSocket game server stays on Render.

The build installs Flutter itself: Netlify's stock image has none, and the
cirruslabs images cannot be used because they froze at 3.44.0 / Dart 3.12 and
cannot resolve this project (Dart ^3.13.2). It pulls the official 3.47.2
tarball, matching the Dockerfile, and unpacks it inside the repo so Netlify's
build cache keeps it between builds.

Two cache bugs found by simulating Netlify's header resolution rather than
reading the config, both of which would have shipped:

- The site root has no filename, so it matched the catch-all and would have
  been served immutable for a year. This is the same trap already fixed in
  web_cache.dart, recurring on a new origin.
- A catch-all cache rule is worse still. A deep link like /ludo/abc is
  answered by index.html, but Netlify picks the header from the path the
  browser requested, so every shared game URL and refresh would have served a
  year-old app shell.

So there is no blanket cache rule: the shell files are listed explicitly and
/assets, /canvaskit and /fonts are named as the versioned directories.
Anything unrecognised falls through to Netlify's own revalidating default,
which is the safe direction.

deploy_config_test.dart pins all of it, including that the Flutter version
matches the Dockerfile and that the policy still agrees with
web_cache.dart, so the two origins cannot drift. Removing the '/' rule makes
it fail, so it is a real assertion and not a tautology.

255/255 tests pass; dart analyze lib bin test clean.
- Give every player a unique name and an avatar

Two players on the leaderboard could be indistinguishable: the default name
pool was 16x16, so 256 names for unlimited players, and a chosen name was
stored verbatim.

DefaultNames.unique() appends a short tag derived from the player id, so a
name identifies exactly one player and stays stable across games and
sessions. The server also disambiguates on join: if two people in one room
pick the same name, the later one is tagged from the seat id, which is what
the leaderboard already groups by. Nobody is rejected and no identity is
rewritten.

PlayerAvatar renders a deterministic identicon from the same id - nothing to
upload, nothing to store, no new dependency, and it cannot drift from the
player because it is derived from the player's identity. Shown on every
online leaderboard row and podium card. Custom uploaded photos are not
implemented yet; the identicon is the default they would override.

LeaderboardRow now carries the seatId the server already sent, so a row's
avatar is tied to the player rather than to a display name two players may
share.

245/245 tests pass; dart analyze lib bin test clean.
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
