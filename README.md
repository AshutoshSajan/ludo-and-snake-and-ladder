# Game Club 🎲

A production-ready, cross-platform **Game Club** app built with Flutter —
containing **Ludo (2–4 players)** and **Snakes & Ladders (2–10 players)**.
Local-first: hot-seat multiplayer with friends on one device plus AI bots —
**plus online multiplayer for both games** (Ludo and Snakes & Ladders) via a
self-hosted authoritative Dart server.

## Games & rules

### Ludo (classic)
- 2–4 players (red / green / yellow / blue), 4 tokens each, 52-cell track.
- Roll a **6** to leave the base; 6 grants an **extra roll**.
- **Three consecutive 6s** forfeit the turn.
- **Safe cells**: every start cell + the four star cells. No captures there.
- **Blocks**: two tokens of one color form a block — opponents can neither
  land on nor pass it.
- **Exact home entry**: overshooting the home triangle is not allowed.
- Extra roll also on a capture or bringing a token home.
- Captured tokens return to base.
- Rankings recorded when players finish; the game ends when fewer than two
  players remain.

### Snakes & Ladders
- 100 squares, **2–10 players**, coexisting pawns.
- Classic jump map (9 ladders, 10 snakes).
- **Exact landing on 100** — overshoot bounces back.
- Game ends when the first player reaches 100; everyone is ranked by square.

## Architecture

```
lib/
├── engine/            # PURE Dart, zero Flutter imports (unit-testable,
│   │                  # reusable by a future authoritative server)
│   ├── core/          #   player profiles & local stats
│   ├── ludo/          #   models, board geometry, rules, AI
│   └── snakes/        #   models, rules (single deterministic engine)
├── controllers/       # session orchestration: turns, AI timing,
│                      # animations, sounds, mid-game seat management
├── providers/         # Riverpod state: profiles, settings, sound
├── services/          # sound (audioplayers) + haptics, storage
├── ui/
│   ├── ludo/          # CustomPainter board, animated token layer, view
│   ├── snakes/        # CustomPainter board (snakes/ladders drawn), view
│   ├── shared/        # dice widget, victory dialog, seat manager sheet
│   └── theme.dart     # "tabletop club" design tokens
└── screens/           # home, setup (user selection), leaderboard

assets/sounds/         # 8 procedurally synthesized WAV effects
tools/gen_sounds.dart  # regenerates them: dart run tools/gen_sounds.dart
tools/gen_app_icons.py # favicon + Android/iOS/macOS/Windows launcher icons
test/                  # 26 engine rule tests + 2 widget smoke tests
```

### Design highlights
- **Board rendering** with `CustomPainter` (resolution-independent; the same
  painters draw the home-screen thumbnails).
- **Token animations**: moves hop cell-by-cell along the real path; ladder
  climbs, snake slides, captures and dice rolls each have distinct sounds
  and haptics.
- **Mid-game seat management**: from the pause menu you can add players,
  remove players, and swap any seat between human and AI bot instantly —
  board position is always preserved.
- **AI difficulty**: easy (random), medium (greedy), hard (positional
  heuristic: captures, safety, danger, blocks).

## Getting started

Requires Flutter 3.47+ (stable).

```bash
flutter pub get
flutter run                 # pick a device (Chrome or Linux desktop)
```

### Run tests & analyze

```bash
flutter test               # 28 tests: full Ludo + Snakes rule coverage
flutter analyze
```

### Branches, PRs & CI

All development follows a **branch-and-PR workflow** — nothing is ever pushed
directly to `main`. The repo has four permanent tiers:

| Branch | Role | PRs into it come from | Merge gate |
|---|---|---|---|
| `sandbox` | free experiments / spikes / prototypes | anything, no ceremony | none — break it freely |
| `dev` | **day-to-day development integration** | `feat/…` `fix/…` `chore/…` task branches (and `sandbox` when a spike graduates) | analyze + full tests + build (CI) |
| `staging` | release preparation / integration testing | `dev` | analyze + full tests + build (CI) |
| `main` | production | `staging` **only** | merged by the maintainer |

**The rules:**

- **Every feature, bugfix, task or experiment gets its own branch**, named
  `feat/…`, `fix/…`, `chore/…`, `spike/…` etc., cut from the branch it will
  be merged into (normally `dev`).
- **PRs always target the immediate parent branch — `feat/…` → `dev`,
  `dev` → `staging`, `staging` → `main`.** Task branches never target
  `staging`/`main` directly, and nothing is ever pushed to `main`.
- Tests must pass (analyze + full suite + release build) before a PR merges;
  CI runs on every PR and every merge to `dev`/`staging`/`main`.
- **`main` is CI-guarded**: a push to `main` fails CI unless its head is a
  merge commit (direct pushes are rejected; squash-merges into `main` are
  rejected too — use merge commits). Branch protection itself is unavailable
  on this private repo (free plan), so the guard job stands in for it.

```bash
git checkout dev && git pull                # latest development state
git checkout -b feat/my-feature dev         # new branch per task
# …work (TDD: failing test first, then the fix)…
git push -u origin feat/my-feature
gh pr create --base dev                     # PR to the parent, never main
# spike?            → cut from sandbox, PR back to sandbox
# spike graduated?  → branch feat/… from sandbox, PR to dev
```

### CI & changelog

`.github/workflows/ci.yml` runs on **every PR** (analyze + full test suite +
release web build — PRs must be green to merge) and on **every merge to
`dev`/`staging`/`main`** (same checks, so the app build is verified on
every tier).

`CHANGELOG.md` is **maintained by [git-cliff](https://git-cliff.org)** from the
commit history using `cliff.toml` (Keep a Changelog format):

- Regenerate locally after commits: `git-cliff -o CHANGELOG.md`
- The CI changelog job runs on integration pushes (`dev`, `staging`, `main`)
  and **opens a PR into `staging`** with the regenerated file (it never
  pushes to `main`).
- Write commit subjects as `feat: …`, `fix: …`, `docs: …`, `chore: …` etc.
  (Conventional Commits) so entries land in the right *Added / Fixed / …*
  group; anything else falls into the history-matching rules in `cliff.toml`.

### Code review (Greptile)

[Greptile](https://www.greptile.com) reviews pull requests through the
committed `.greptile/config.json`:

```json
{
  "includeBranches": ["main"]
}
```

**Only PRs targeting `main` are reviewed.** With this repo's tiers that is the
`staging` → `main` release PR — the one change that is about to ship — while
PRs into `dev`/`staging` are left to CI. Notes:

- The filter is inclusive, so widening it is a one-word edit:
  `"includeBranches": ["main", "staging"]`. Use `excludeBranches` instead to
  review everything *except* listed tiers.
- Both lists take globs (`release/*`, `dependabot/**`), matched
  case-insensitively against the PR's **base** branch.
- Draft PRs are skipped by default (`triggerOnDrafts: false`), so a release PR
  is first reviewed when it is marked ready.
- A skipped PR can still be reviewed on demand by commenting
  `@greptileai review`.
- The same filters live in the dashboard (**Code Review Settings → When
  Greptile Reviews → Filters**); the committed file overrides dashboard
  settings. Greptile reads it from the PR's *source* branch, so a branch only
  obeys the filter once it contains this file (i.e. once it has merged `dev`).

### Platform notes

| Target | Status |
|---|---|
| Web (Chrome) | ✅ verified: `flutter build web --release` boots in Chrome |
| Linux desktop | ✅ code complete — needs `libgstreamer1.0-dev libgstreamer-plugins-base1.0-dev` installed via apt to compile (not available in this dev container, no root) |
| Android / iOS | ✅ configured (`flutter create` scaffolding in `android/`, `ios/`) — toolchains absent on this machine; build in Android Studio / Xcode |
| macOS / Windows | ✅ configured — build on the respective OS |

Install Linux desktop prerequisites (Debian/Ubuntu):

```bash
sudo apt-get install -y libgstreamer1.0-dev libgstreamer-plugins-base1.0-dev
flutter build linux --release
```

Android/iOS: open in Android Studio / Xcode and run normally, or
`flutter build apk --release` / `flutter build ios --release` with the
toolchains installed.

### App icon

The mark — a gold-rimmed ivory die on the felt table — is drawn in code, so
every size and every platform comes out of one place:

```bash
python3 tools/gen_app_icons.py   # no third-party deps
```

That writes the web favicon and manifest icons (rounded and maskable), the
Android launcher PNGs plus an adaptive-icon foreground layer, the opaque iOS
set (iOS rejects alpha), the rounded macOS set and the multi-size Windows
`.ico`. `web/manifest.json` carries the app's felt-green theme colour and
name, so an installed PWA matches the icon.

### Chrome extension

The game also ships as an **offline Chrome extension** (Manifest V3).

Build & load:

```bash
flutter build web --release      # once, or when the game changed
./tools/build_extension.sh       # -> build/extension/
./tools/build_extension.sh --zip # also -> build/game-club-extension.zip (Web Store)
```

Then in Chrome: `chrome://extensions` → enable **Developer mode** →
**Load unpacked** → select `build/extension/`. A die icon appears in the
toolbar; clicking it opens the game in a new tab. It works fully offline.

How it works: the extension bundles the whole Flutter web payload. MV3's
CSP forbids remote scripts, so `tools/build_extension.sh` pins the
bootstrap to the **local** `canvaskit/` engine copy
(`useLocalCanvasKit:true`) and verifies no remote `.js/.wasm` references
remain. Icons are generated by `tools/gen_extension_icons.py` (no
third-party deps). Clicking the toolbar icon (`extension/background.js`)
opens `index.html` in a tab.

## Local checks (the free stand-in for CI)

GitHub-hosted runner minutes are a metered resource and this repo exhausted
them, so the important checks run on your machine instead — same commands, no
queue, no quota.

Enable the hooks **once per clone**:

```bash
git config core.hooksPath .githooks
```

That installs a `pre-push` hook which:

1. Verifies `CHANGELOG.md` matches commit history — on `staging`/`main` pushes
   only, so ordinary branch work pays nothing for it.
2. Runs `flutter analyze --fatal-infos` and `flutter test` before any push.

Both run standalone too:

```bash
tool/ci.sh              # analyze + test              (~30s)
tool/ci.sh --web        # also build web release     (~90s)
tool/changelog.sh       # rewrite CHANGELOG.md
tool/changelog.sh --check   # fail if out of date, change nothing
```

`CHANGELOG.md` is generated by `git-cliff` from commit history (rules in
`cliff.toml`) and should never be hand-edited. `tool/changelog.sh` keeps the
guard the CI job had: a regeneration that would *drop* a released section fails
loudly instead of erasing history, which is what happens when a branch is
missing commits its base has.

**Bypassing, and what it costs.** `git push --no-verify` skips all of it, and so
does `SKIP_LOCAL_CI=1 git push` for just the slow half. Be deliberate about it:
while CI is over quota, a skipped hook means nothing verified the push.

**This is a fast path, not enforcement.** A hook lives in your clone, is skipped
by `--no-verify`, and does not run at all for a merge made from the GitHub UI or
from another machine. The `test` and `guard-main` jobs in
`.github/workflows/ci.yml` are therefore still there and should be restored the
moment quota allows — they are the only checks that apply to everyone. The
`changelog` job was removed from the workflow on purpose: it regenerated the
same file as the hook, so the two raced, and whichever ran second produced a
commit the other had not verified.

**If you want CI back without using hosted minutes**, a
[self-hosted runner](https://docs.github.com/en/actions/hosting-your-own-runners)
does not consume GitHub-hosted minutes at all. That is the only option that
restores enforcement for a private repo at zero cost — free CI tiers elsewhere
(Cirrus, CircleCI) generally require a public repository, and this one is
private.

## Split deploy: web client on Netlify, game server on Render

The single-service Render deploy above is the simplest thing that works. You can
also host **only the web client on Netlify** and leave the authoritative game
server on Render — the server needs a long-lived process and a WebSocket
upgrade, neither of which a static CDN provides.

`netlify.toml` configures the whole build; there is nothing to click except one
environment variable. Point the site at this repo and Netlify reads the rest.

**Set `GAME_SERVER_URL`** in **Site settings → Environment variables**:

```
wss://ludo-1zpb.onrender.com/ws
```

That is the one required setting, and it is how the client learns where the game
server is — baked in at build time via `--dart-define`, which
`defaultServerUrl()` prefers over same-origin. Without it the build still
succeeds and the client falls back to its own origin, where there is no game
server; the lobby's server field would then need the URL typed in by hand.

Everything else is in the file: `build/web` as the publish directory, an SPA
rewrite, and the same cache policy `lib/server/web_cache.dart` applies, so the
Netlify origin and the Render fallback agree exactly.

Once the client has its own domain, `sameOriginServerUrl` is never used for
online play (the dart-define wins), so the two hosts need not share a name. The
leaderboard's HTTP origin is derived from that same URL, so it follows
automatically. CORS is already handled server-side: `corsMiddleware` echoes the
request origin, and browsers do not apply CORS to WebSockets at all.

**Cold starts.** Render's free plan sleeps after ~15 idle minutes, and the
proxy refuses connections until the process is listening again. That is a wait,
not a failure, so the client now re-probes for up to ~22s and shows
*"Starting the game server…"* with an explanation, rather than reporting an
error to someone who merely pressed Play a moment early. The leaderboard fetch
is patient for the same reason (5 attempts, 10s each).

**Practical catch — Netlify's stock image has no Flutter**, so `netlify.toml`
installs the SDK itself. Note it deliberately does *not* use the cirruslabs
Flutter images: those froze at 3.44.0 / Dart 3.12 and cannot resolve this
project, which requires Dart ^3.13.2. It pulls the official 3.47.2 tarball and
unpacks it inside the repo so Netlify's build cache keeps it between builds.
A test asserts that version matches the `Dockerfile`, so the two cannot drift.

If you would rather not add a second host at all, the single-service Render
deploy already serves the web client from the same origin and needs no extra
moving parts.

## Deploy on Render

The repo ships a one-click blueprint (`render.yaml`) that deploys the **full
multiplayer app as a single service**: the Docker image contains the compiled
Flutter web client *and* the Dart server, so the game UI, the WebSocket
transport, `/stats`, `/rooms/lookup`, and `/leaderboard` all live on the same
origin — the web client's `wss://<your-app>.onrender.com/ws` default just
works, no configuration needed.

1. Push a branch with `render.yaml`/`Dockerfile`, then in Render: **New →
   Blueprint**, select this repo, accept.
2. Fill the two prompts from Turso:
   `turso db create game-club && turso db tokens create game-club`
   (schema is created lazily by the stores; to provision explicitly see
   `deploy/turso_schema.sql`).
3. Health checks hit `GET /stats`; local env vars come from `.env`
   (see `.env.example`) or the service dashboard — the dashboard always wins.

Free-plan caveat: the service sleeps after ~15 idle minutes; first
connection cold-starts the instance.


- [x] Phase 1 — scaffold, theme, routing, home screen
- [x] Phase 2 — core engine (profiles, turn order, seats)
- [x] Phase 3 — Ludo engine + full rule tests
- [x] Phase 4 — Snakes & Ladders engine + tests
- [x] Phase 5 — Ludo UI (hot-seat + AI, animations, sounds)
- [x] Phase 6 — Snakes & Ladders UI
- [x] Phase 7 — mid-game player management (add / remove / human↔AI swap)
- [x] Phase 8 — **online Ludo multiplayer**: authoritative Dart shelf +
      WebSocket server (`bin/server.dart`) that reuses the pure-Dart `engine/`
      for dice, rules, and validation. Run `dart run bin/server.dart`
      (listens on `:8080`), then use the *Online Ludo* button on the home
      screen — create a room, share the 4-letter code, and play remotely.
      Clients send only *intents*; the server broadcasts snapshots, so the
      game cannot be cheated from the client side.
- [x] Phase 8b — **online Snakes & Ladders**: rooms are game-typed — the host
      picks Snakes & Ladders at room creation and everyone joins the same
      flow (code, lobby, spectate, reconnect). The server rolls and resolves
      the single forced move with the pure engine; the client auto-sends the
      move intent after a beat so the roll stays visible.
- [x] Phase 8c — **quick match**: the online lobby's *Quick match* button
      pairs you with the first waiting room of the chosen game type (or opens
      one) and the game auto-starts as soon as two players are seated — no
      room-code sharing needed. Reconnects still reclaim the matched seat.
- [x] Phase 9 — mid-game reconnect: auto-reconnect with backoff, seat reclaim
      on the server, and a grace period for abandoned-but-started rooms.
- [x] Phase 10 — online leaderboards: the server records every finished game
      and serves career stats (wins / games / average placement) at
      `GET /leaderboard`. The home screen's *Online Leaderboard* button shows
      the top players with a medal podium — requires the server to be running.
      Storage is pluggable (`lib/server/leaderboard_store.dart`): a local
      SQLite file by default (`--db FILE`, default `ludo_leaderboard.db`), or
      a hosted **Turso** (libSQL) database when `TURSO_DATABASE_URL` and
      `TURSO_AUTH_TOKEN` are set — the leaderboard then survives on ephemeral
      free hosts since the data lives off-server (no native driver needed;
      the store speaks Turso's SQL-over-HTTP API via `package:http`).
      Setup: `turso db create <name>` then `turso db tokens create <name>`
      (`lib/server/turso_leaderboard_store.dart`).
- [x] Phase 11 — spectating: anyone can watch a running or waiting room via
      the lobby's *Spectate* option. Watchers receive every state broadcast,
      claim no seat, and their intents are ignored by the server (and the
      client). Seated players see who is watching in the roster.
- [x] Phase 12 — **horizontal scaling**: the server is ready to run as N
      replicas behind a load balancer (`deploy/nginx.conf` routes
      `/ws?code=XXXX` with consistent hashing so a room's players always
      reach the same replica). Each replica identifies itself via
      `--instance-id` / `INSTANCE_ID`, advertises its rooms in a room
      registry (`lib/server/room_registry.dart` — in-memory for single
      instance, a TTL map in Turso when `TURSO_DATABASE_URL` is set), and
      exposes `GET /stats` (connections / rooms / spectators) plus
      `GET /rooms/lookup?code=XXXX` (the owning instance) so an edge can
      forward a WS join that landed on the wrong replica. Code claims are
      compare-and-set: a replica never overwrites a live claim of another
      replica — a rare cross-replica duplicate code is dropped and
      regenerated instead of stealing the routing. Entries expire
      automatically, so a crashed replica leaves no stale routes.
      `GET /health` is the JSON health check; with a web build shipped,
      `GET /` serves the game UI instead.
