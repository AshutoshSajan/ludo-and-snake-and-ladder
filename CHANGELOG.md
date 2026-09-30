# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project is maintained with [git-cliff](https://git-cliff.org).

## Unreleased
### Added
- Feat(deploy): split the web client onto Vercel, and survive a cold start
- Feat(online): a reusable player identity, in-game chat, and a dice that signals
- Feat(leaderboard): per-game boards for Ludo and Snakes
- Feat(online): seat hand-over, walk-outs and autoplay across the online tables
- Feat: Render deploy — .env support, single-service web+server image
- Feat: horizontal scaling — room registry, /stats, sticky LB config
- Feat: persistent leaderboard via Turso (libSQL HTTP API)
### Fixed
- Fix the leaderboard tab counts and refuse a Netlify build with no game server
- Fix cliff.toml rendering whole commit bodies as changelog entries
- Fix(deploy): revalidate the app shell, and give new players a name
- Fix(snakes): home area, dice tumble, sound, leave dialog, and a pulse
- Fix(server): prove the store is reachable at startup, and name TLS failures
- Fix(ui): stop labelling the online screens "Ludo" only
- Fix(deploy): install ca-certificates in the runtime image
- Fix(server): let a WebSocket upgrade through the JSON error middleware
- Fix(online): stop the table playing itself once a room has nobody in it
- Fix(server): unregister closed rooms from the registry immediately
- Fix(docker): pin Flutter 3.47.2 from official tarball; dart build cli bundle
- Fix(server): normalize /rooms/lookup codes like the join path
### Other
- Name both leaderboard quantities, and fail the Netlify build without a server URL
- Run the quality gate locally, since CI is over its runner quota
- Host the web client on Netlify instead of Vercel
- Give every player a unique name and an avatar
- Ci: render each changelog entry once
- Ci: generate CHANGELOG.md on the promotion PR and commit it onto the PR branch
- Ci: delete merged PR head branches automatically
- Move the app providers onto Riverpod 3 notifiers
- Refresh the locked dependency versions and CI action pins
- Say which part of the leaderboard path is broken
- Answer a failing route as JSON, not as a bare shelf 500
- Let the browser read the JSON API: CORS on the server
- Write the changelog's escaped newlines as line breaks
- Give the snakes game one home area, not one per player
- Review only the PRs that target main
- Give the home garages a house and every platform an icon
- Show the dice on every roll and park starting pawns in home
- Memoize the duplicate-column upgrade as done
- Never leave a route pointing at a closed room
- Migrate room_registry tables that predate the owner column
- Refuse claims that would steal a live room's route
- Retry joins on the replica that owns the room code
- Claim a room code before the room exists
- Scope registry deletes to the closing room's token
- Ci: unpin deprecating runner label and Node 20 actions
- Make registry code claims CAS and bound/close registry pipelines
- Derive registry sweep cadence from the room TTL
- Keep the page port in the same-origin server URL
- Carry the room code in the WebSocket URL for room affinity
- Serve the documented health JSON at /health; honor WEB_DIR from .env
### Testing
- Test: cover the /stats connection gauge with a live socket
## [v1.1.0] - 2026-09-20
### Added
- Feat: quick match — auto-pair waiting players and auto-start at two
### Documentation
- Docs: fold the quick-match doc entry into the v1.1.0 release section
- Docs: fold quick-match entry into v1.1.0 release section
## [v1.0.0] - 2026-09-17
### Added
- Feat: online Snakes & Ladders multiplayer
- Phase 10+11: online leaderboards (SQLite store + /leaderboard + scoreboard UI) and spectating (read-only watchers, spectator lobby UI, intent no-ops)
- Online leaderboards: SQLite-backed career stats (Phase 10)
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
- Fix turn order to run clockwise around the board (red-blue-yellow-green)
- Fix Ludo track direction and color-to-corner mapping
- Fix blue home column misalignment (col 6 -> col 7) so all home runs connect to their matching center triangle
- Fix Ludo center home triangles spanning the 3x3 block; draw ladder rails as parallel tracks
### Other
- Ci: generate changelog on main pushes only
- Mid-game reconnect: seat reclaim, auto-reconnect, grace period
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
