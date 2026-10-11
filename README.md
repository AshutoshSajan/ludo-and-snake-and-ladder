# Game Club 🎲

<p align="center">
  <img src="https://img.shields.io/badge/Flutter-3.47.2-02569B?logo=flutter&logoColor=white" alt="Flutter">
  <img src="https://img.shields.io/badge/Dart-3.13.2-0175C2?logo=dart&logoColor=white" alt="Dart">
  <img src="https://img.shields.io/badge/Platform-Web%20%7C%20Android%20%7C%20iOS%20%7C%20macOS%20%7C%20Linux%20%7C%20Windows-4285F4?logo=flutter&logoColor=white" alt="Platforms">
  <img src="https://img.shields.io/badge/Extension-Chrome%20%7C%20Firefox-FF7139?logo=googlechrome&logoColor=white" alt="Browser Extension">
  <img src="https://img.shields.io/badge/License-MIT-green" alt="License">
</p>

<p align="center">
  <img src="assets/screenshots/banner.png" alt="Game Club — Ludo & Snakes and Ladders" width="1200"/>
</p>

---

A **Flutter** app with two classic board games — **Ludo** and **Snakes & Ladders** — playable **locally** (hot-seat, AI) or **online** (authoritative Dart server, WebSockets, reconnect, spectate, leaderboards). Also ships as a **browser extension** (Manifest V3, Chrome & Firefox).

| | Ludo | Snakes & Ladders |
|---|---|---|
| Players | 2–4 | 2–10 |
| Board | 52 cells, 4 tokens each | 100 squares, 9 ladders, 10 snakes |
| Start | roll a **6** to leave base | roll a **1** to enter |
| Bots | easy / medium / hard | auto-play |
| Online | ✅ rooms, chat, autoplay | ✅ rooms, chat, autoplay |

Runs on **web, Linux, macOS, Windows, Android and iOS**, and ships as a
**browser extension** for Chrome and Firefox.

> **Contents** — [Games](#games--rules) · [Architecture](#architecture) ·
> [Getting started](#getting-started) · [Local checks](#local-checks-the-free-stand-in-for-ci) ·
> [Deploy](#deploy) · [Browser extension](#browser-extension) ·
> [Contributing](#branches-prs--ci)

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

---

## 🎮 Gameplay Previews

### 🎲 Ludo
<p align="center">
  <img src="assets/screenshots/ludo-gameplay.png" alt="Ludo Gameplay" width="700"/>
  <br/>
  <em>Ludo gameplay with animated dice rolls, token movements, and captures</em>
</p>

<p align="center">
  <img src="assets/screenshots/ludo-board.png" alt="Ludo Board" width="700"/>
  <br/>
  <em>Classic Ludo board with 4 players, safe cells, and home columns</em>
</p>

### 🐍 Snakes & Ladders
<p align="center">
  <img src="assets/screenshots/snakes-gameplay.png" alt="Snakes & Ladders Gameplay" width="700"/>
  <br/>
  <em>Snakes & Ladders with animated pawn movements, ladder climbs, and snake slides</em>
</p>

<p align="center">
  <img src="assets/screenshots/snakes-board.png" alt="Snakes & Ladders Board" width="700"/>
  <br/>
  <em>Classic 100-square board with 9 ladders and 10 snakes</em>
</p>

---

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

assets/sounds/         # 12 procedurally synthesized WAV effects
tools/gen_sounds.dart  # regenerates them: dart run tools/gen_sounds.dart
tools/gen_app_icons.py # favicon + Android/iOS/macOS/Windows launcher icons
test/                  # 307 tests: engine rules, online server, UI, deploy config
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
flutter test               # 307 tests: engine rules, online server, UI, deploy config
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

`.github/workflows/ci.yml` runs on **PRs targeting `main`** and on **pushes to
`main`**, plus `v*` tags.

> **Which event runs what.** `pull_request` (into `main`) runs the `test` job and
> nothing else — analyze, the full suite, and a release web build.
>
> A **push to `main`** runs the release path, in this order:
>
> 1. `release-prep` regenerates `CHANGELOG.md` and bumps the declared version,
>    then **opens a pull request** with both in one commit. It cannot push to
>    `main` directly: `guard-main` requires the head of `main` to be a merge
>    commit, and a bot commit is not one.
> 2. You merge that `chore: release prep` PR. That merge re-runs the workflow.
> 3. `verify-release` runs analyze + the full suite — the only test gate on a push
>    path, since `test` is pull-request-scoped.
> 4. `publish-firefox` builds the add-on and uploads it to addons.mozilla.org.
>
> So a release is: land your PR → merge the bot's `chore: release prep` PR → the
> add-on is uploaded. No tagging and nothing typed by hand. A `v*` tag runs the
> same path, for cutting a release without merging anything new.
>
> **Why only `main`.** Hosted runner minutes are metered and this repo exhausted
> them once already, so a full run happens where a change is about to ship rather
> than at every hop. Scoping is a trigger filter (`on.pull_request.branches:
> [main]`) rather than an `if:` inside the job, because an `if` still starts the
> runner and every job only to skip them. A PR into the integration branch has no
> hosted CI — run `tool/ci.sh` locally, which is the same gate and what the
> `pre-push` hook does. `prune-branch` only fires for PRs into `main`, so inner
> branches need deleting by hand.

### Publishing the add-ons

Both store jobs are in the workflow, triggered on a `v*` tag so a release is a
deliberate act. The **Chrome job is commented out** — the Web Store needs a paid
developer account that is not set up, and a publish job failing on every tag is
worse than no job. The steps are kept so enabling it is a review, not a rewrite.

Credentials go in repository secrets and are **not** in the repo:
`AMO_API_KEY` and `AMO_API_SECRET` for Firefox, plus
`CHROME_CLIENT_ID`, `CHROME_CLIENT_SECRET` and `CHROME_REFRESH_TOKEN` when
Chrome is enabled.

Before uploading, check the package the way AMO will:

```bash
npx web-ext lint --source-dir build/extension-firefox --self-hosted
```

That is what caught the missing `gecko.id`, which AMO rejects a listed add-on
without, and the missing `data_collection_permissions`. Note that lint reports
the latter only as a **warning**, among 11 warnings that are genuine noise.

**The license lives in `extension/amo.metadata.json`, not the manifest**, and AMO
rejects a listed version without it — saying so only after the upload:

```
WebExtError: Submission failed (2): Bad Request
  "version": { "license": [
    "This field, or custom_license, is required for listed versions." ] }
```

Three things about that file are easy to get wrong, and each one produces the
same opaque 400, because `web-ext` does not validate it — it forwards whatever
it read:

- **`license` goes under `version`, not at the top level.** `web-ext` sends
  `{...metadata, version: {upload, ...metadata.version}}`, so a top-level
  `license` never reaches `version.license`.
- **`categories` must be an AMO slug.** There are 32; `games` is not one of
  them. The games category is `games-entertainment`.
- **The value is an AMO license slug** — `GPL-3.0-only`, not bare `GPL-3.0`,
  which SPDX has deprecated in favour of the `-only` / `-or-later` forms.

And `--amo-metadata extension/amo.metadata.json` must be passed to `web-ext
sign`. `web-ext` does **not** discover the file by convention: it reads it only
when that flag names a path. Without the flag the upload succeeds and AMO
rejects it with a 400 about a field nothing in the repository mentions. The file
is therefore *not* packaged into the add-on; `tools/build_extension.sh` validates
it instead, so a malformed shape fails in seconds on a laptop rather than after a
runner build.

GPL section 4 also requires the licence text to travel with the covered work, so
`LICENSE` is packaged into the add-on rather than living only in the repository.

**`data_collection_permissions` is mandatory.** Since 2025-11-03, AMO blocks an
upload for a *new* add-on that omits
`browser_specific_settings.gecko.data_collection_permissions`. A first release is
exactly the case that rule targets. Offline play needs nothing, so `required` is
`["none"]`; online play does transmit a chosen display name and chat to the game
server, so those are declared `optional`. Because the built-in consent UI only
exists from Firefox 140, `strict_min_version` is `140.0` — otherwise installs on
older Firefox would collect data with no visible consent.

Licensed under **GPL-3.0-only** — see [LICENSE](LICENSE).

`CHANGELOG.md` is **generated** by [git-cliff](https://git-cliff.org) from the
commit history using `cliff.toml` (Keep a Changelog format) — never hand-edit
it.

```bash
tool/changelog.sh           # rewrite it
tool/changelog.sh --check   # fail if out of date, change nothing
```

The pre-push hook runs `--check` on `staging`/`main` pushes, so the file cannot
drift from history at the moment it matters. Write commit subjects as
`feat: …`, `fix: …`, `docs: …`, `chore: …` (Conventional Commits) so entries
land in the right *Added / Fixed / …* group.

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

### Browser extension

The game also ships as a **browser extension** (Manifest V3), for **both
Chrome and Firefox**.

Build & load:

```bash
flutter build web --release            # once, or when the game changed

./tools/build_extension.sh             # Chrome    -> build/extension-chrome/
./tools/build_extension.sh --firefox   # Firefox   -> build/extension-firefox/

./tools/build_extension.sh --firefox --zip   # -> build/game-club-firefox.xpi
./tools/build_extension.sh --zip             # -> build/game-club-chrome.zip
```

**Chrome:** `chrome://extensions` → **Developer mode** → **Load unpacked** →
select `build/extension-chrome/`.

**Firefox:** `about:debugging#/runtime/this-firefox` → **Load Temporary
Add-on** → pick `build/extension-firefox/manifest.json`.

Clicking the die in the toolbar opens a small **launcher popup**, and the game
opens in a **new tab**. The popup is 300px wide on purpose: a browser popup is
capped at 800x600 and closes the moment you click outside it, so playing inside
one gives a board too small to read in a window that vanishes mid-move.
Interim versions played inside the popup and in a dedicated window; this is the
launcher with the game in a tab.

Each click opens a fresh tab. Focusing an already-open game tab is deliberately
**not** attempted: finding a tab by URL needs the `tabs` permission, Chrome
presents that to users as "read your browsing history", and that is not a fair
trade for saving one tab. The original launcher did query by URL without
declaring the permission, so its reuse silently never worked. `chrome.tabs.create`
needs no permission at all. Local play works fully offline.

**Why two manifests.** MV3 split the background model and the browsers did not
follow each other. Chrome runs the toolbar handler as a **service worker**;
Firefox has no service workers and requires an **event page**
(`background.scripts`). A manifest carrying `service_worker` is rejected by
Firefox, and one carrying `scripts` is ignored by Chrome — so the target
selects the manifest, not the build. The build script asserts the right one
was packaged, because a wrong manifest installs and then does nothing when
clicked, which is a poor way to find out.

Both manifests declare a `connect-src` naming the hosted game server. Offline
play needs no network at all, but online play is a cross-origin socket from an
add-on page, and without that directive the browser blocks it in a way that
looks like a dead server.

**Online play points at the hosted server, not the page.** A packaged add-on
serves the game from `chrome-extension://<id>/` or `moz-extension://<uuid>/`,
which is same-origin with nothing playable — and, worse, its "host" is the
extension id, so the client's same-origin fallback once produced
`ws://<extension-id>:8080/ws`, a URL that can never dial. Online play in the
packaged add-ons failed while the Netlify build worked, for exactly that
reason: same client, different default URL. `sameOriginServerUrl` now sends
every non-`http(s)` scheme to the hosted game server, and the value is a
constant in `lib/screens/online_lobby_screen.dart` rather than a build-time
`--dart-define`, because one packaged build is installed everywhere and cannot
carry a per-deployment setting. `GAME_SERVER_URL` still overrides it wherever
it is set.

**Publishing.** Firefox: upload the `.xpi` (or `.zip`) at
[addons.mozilla.org](https://addons.mozilla.org/developers/addon/submit/distribution);
Mozilla signs it there and rejects an unsigned upload, so the artifact in
`build/` is upload-ready but not signed. Chrome: the Web Store takes the
`.zip`.

How it works: the extension bundles the whole Flutter web payload. MV3's CSP
forbids remote scripts, so `tools/build_extension.sh` pins the bootstrap to the
**local** `canvaskit/` engine copy (`useLocalCanvasKit:true`) and verifies no
remote `.js/.wasm` references remain. Flutter's service worker is stripped —
there is no service-worker context in an extension page, so shipping one only
buys a failed registration. Icons are generated by
`tools/gen_extension_icons.py` (no third-party deps). Clicking the toolbar icon
(`extension/background.js`) opens `index.html` in a tab



## Deploy

The backend is one Dart server. It can serve the whole app on its own, or the
web client can be hosted separately.

| Setup | Frontend | Backend | When |
|---|---|---|---|
| **Single service** (simplest) | same Render service | same | no second host to manage |
| **Split** | Netlify | Render | cleaner URL; client can be cached at the edge |

### Single service (Render)


#### Full Render walkthrough

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
### Split: web client on Netlify, game server on Render

Host **only the web client on Netlify** and leave the authoritative game
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

---
## Browser extension

The extension ships both games in one package. Open `chrome://extensions`,
enable **Developer mode**, and **Load unpacked** pointing at
`build/extension-chrome/` (or `build/extension-firefox/`).

- **Chrome/Edge/Opera**: `./tools/build_extension.sh --chrome` →
  `build/game-club-chrome.zip` for Chrome Web Store.
- **Firefox**: `./tools/build_extension.sh --firefox` →
  `build/game-club-firefox.xpi` for Firefox Add-ons (AMO).

### Features

- **Launcher**: 300px felt-green panel with die icon, **Open Game Club** button.
- **One click → new tab** at `wss://ludo-1zpb.onrender.com/ws` (or your
  `--dart-define=GAME_SERVER_URL`). Reuses an existing tab if already open.
- **Offline-first**: local Ludo & Snakes play fully offline; online button is
  only a navigation affordance.
- **Tab button**: `🖥 Tab` in the corner for users who want a full window.

---
## Local checks (the free stand-in for CI)

The `tool/ci.sh` script runs the same checks as CI — no runner queue wait.

```bash
# Full local gate
./tool/ci.sh              # analyze + test
./tool/ci.sh --web       # + web release build
```

### Pre-push hook

```bash
git config core.hooksPath .githooks   # one-time setup
```

The hook runs `flutter analyze --fatal-infos` + `flutter test` on every push
to `main`/`staging`/`dev`. Skip with `git push --no-verify`.

---
## Branches, PRs & CI

```
sandbox  →  dev  →  staging  →  main
```

| Branch | Purpose | PRs target | Gate |
|---|---|---|---|
| `sandbox` | spikes, prototypes | `dev` (optional) | none |
| `dev` | **day-to-day integration** | `feat/…` `fix/…` `chore/…` | analyze + tests + build |
| `staging` | release preparation | `dev` | analyze + tests + build |
| `main` | production | `staging` **only** | you merge |

**Flow:** `sandbox` → `dev` → `staging` → `main`. Task branches cut from and PR to
their immediate parent — normally `dev`; `staging`/`main` are never direct PR
targets from task branches; nothing is ever pushed to `main`.

**CI gates** run on every PR and push:
- `dev`/`staging`/`main` push → full CI (analyze + tests + build)
- PR to `staging`/`main` → full CI (required to merge)
- `main` push → `guard-main` requires merge commit

**Rule:** task branches → `dev` → `staging` → `main`. No direct pushes to `main`;
`staging`→`main` and `dev`→`staging` are PRs with green CI. Your rule is
 enforced by the `guard-main` job.

### CI & changelog

`.github/workflows/ci.yml` runs on **PRs targeting `main`** and on **pushes to
`main`**, plus `v*` tags.

> **Which event runs what.** `pull_request` (into `main`) runs the `test` job and
> nothing else — analyze, the full suite, and a release web build.
>
> A **push to `main`** runs the release path, in this order:

1. `release-prep` regenerates `CHANGELOG.md` and bumps the declared version,
   then **opens a pull request** with both in one commit. It cannot push to
   `main` directly: `guard-main` requires the head of `main` to be a merge
   commit, and a bot commit is not one.
2. You merge that `chore: release prep` PR. That merge re-runs the workflow.
3. `verify-release` runs analyze + the full suite — the only test gate on a push
   path, since `test` is pull-request-scoped.
4. `publish-firefox` builds the add-on and uploads it to addons.mozilla.org.

### Commit convention

```
feat(ludo): add new power-up
fix(snakes): fix ladder collision at square 42
docs: update leaderboard API docs
chore(deps): upgrade flutter_riverpod to 3.0
```

> **Changelog** is generated by `git-cliff` from commit history.
> Don't edit `CHANGELOG.md` manually — it's regenerated on every `main` push.

## Contributing

Issues and PRs welcome. For anything non-trivial, open an issue first.

**Code style**: `flutter analyze --fatal-infos` + `dart format` (enforced by CI).
**Tests**: New features need tests. Run `flutter test` before pushing.

## License

MIT — see [LICENSE](LICENSE).