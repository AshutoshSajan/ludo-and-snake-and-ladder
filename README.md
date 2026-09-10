# Game Club 🎲

A production-ready, cross-platform **Game Club** app built with Flutter —
containing **Ludo (2–4 players)** and **Snakes & Ladders (2–10 players)**.
Local-first: hot-seat multiplayer with friends on one device plus AI bots —
**plus online Ludo multiplayer** via a self-hosted authoritative Dart server.

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

### CI & changelog

`.github/workflows/ci.yml` runs on **every PR** (analyze + full test suite +
release web build — PRs must be green to merge) and on **every merge to
`main`** (same checks, so the app build is verified on main).

`CHANGELOG.md` is **maintained by [git-cliff](https://git-cliff.org)** from the
commit history using `cliff.toml` (Keep a Changelog format):

- Regenerate locally after commits: `git-cliff -o CHANGELOG.md`
- CI regenerates it on every push to `main` and auto-commits when it changed.
- Write commit subjects as `feat: …`, `fix: …`, `docs: …`, `chore: …` etc.
  (Conventional Commits) so entries land in the right *Added / Fixed / …*
  group; anything else falls into the history-matching rules in `cliff.toml`.

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

## Roadmap

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
- [x] Phase 9 — mid-game reconnect: auto-reconnect with backoff, seat reclaim
      on the server, and a grace period for abandoned-but-started rooms.
- [x] Phase 10 — online leaderboards: the server records every finished game
      into SQLite (`lib/server/leaderboard_store.dart`, `--db FILE` to choose
      the path, default `ludo_leaderboard.db`) and serves career stats
      (wins / games / average placement) at `GET /leaderboard`. The home
      screen's *Online Leaderboard* button shows the top players with a
      medal podium — requires the server to be running.
- [x] Phase 11 — spectating: anyone can watch a running or waiting room via
      the lobby's *Spectate* option. Watchers receive every state broadcast,
      claim no seat, and their intents are ignored by the server (and the
      client). Seated players see who is watching in the roster.
