# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project is maintained with [git-cliff](https://git-cliff.org).

## Unreleased
### Fixed
- Fix(ui): align title bars to the content column and pull the dice in
- Fix(online): spend the cold-start budget on refused first connections
- Fix(extension): grant wss:// so online play can reach the game server
### Other
- Stop running the full suite on PRs into dev
- Ci: make release prep open a PR and run before the changelog check
## [v1.2.1] - 2026-10-02
### Fixed
- Fix three things that each blocked the Firefox release on their own
### Other
- Regenerate the changelog for the v1.2.1 release
- Give the Firefox add-on a licence AMO will accept
## [v1.2.0] - 2026-10-02
### Added
- Add the changelog guard fix to the v1.2.0 notes
- Feat(deploy): split the web client onto Vercel, and survive a cold start
- Feat(online): a reusable player identity, in-game chat, and a dice that signals
- Feat(leaderboard): per-game boards for Ludo and Snakes
- Feat(online): seat hand-over, walk-outs and autoplay across the online tables
- Feat: Render deploy — .env support, single-service web+server image
- Feat: horizontal scaling — room registry, /stats, sticky LB config
- Feat: persistent leaderboard via Turso (libSQL HTTP API)
### Fixed
- Fix the three real review findings, and correct the one I got wrong
- Fix the git-cliff install path, which failed on its first real run
- Fix the AMO upload: `sign`, not `publish`, and do not wait for approval
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
- Install Flutter in publish-firefox, which had no toolchain
- Let the changelog guard tolerate the section a tag promotes
- Read the AMO credentials under the names the repo actually has
- Point packaged extension pages at the hosted game server
- Open the game in a new tab, not a dedicated window
- Restore the launcher popup; open the game in a window
- Review fixes: an over-broad assertion, and CSS that worked by accident
- Split CI by event, and give the version one owner
- Make the release path reachable, and give the changelog one writer
- Popup goes straight to the main screen, no launcher in front of it
- Keep the game iframe laid out, instead of revealing it from display:none
- Refuse to package a stale web build, and stamp what was packaged
- Scope CI to release PRs, add store publishing, give the add-on an id
- Play the game inside the extension popup, and compact the leaderboard cards
- Give the extension a toolbar popup instead of opening straight into a tab
- Autosave local games so a player can resume where they left off
- Fail the Netlify build on a GAME_SERVER_URL that could never work
- Restructure the README and correct what had drifted out of date
- Bundle Roboto so the extension renders its own text
- Ship the extension to Firefox as well as Chrome
- Regenerate CHANGELOG.md for the merged leaderboard work
- Explain the leaderboard's wait instead of showing a bare spinner
- Name the wrong-server case, and answer preflights that ask for headers
- Replace the autoplay text with a spinning loop beside the name
- Make the message notification a pitch no other sound uses
- Wait out a Render cold start on the leaderboard, and stop blaming your laptop
- Drop the lobby title bar in-game, fix the missing message chime, one-line home row
- Generate random usernames for local seats
- Require a 1 to enter the Snakes board, and badge the board's chat icon
- Label the home leaderboard button 'Leaderboard' with a trophy
- Remove the local leaderboard; add an unread dot for chat
- Distinguish the two leaderboards on the home screen
- Name both leaderboard quantities, and fail the Netlify build without a server URL
- Run the quality gate locally, since CI is over its runner quota
- Host the web client on Netlify instead of Vercel
- Give every player a unique name and an avatar
- Ci: render each changelog entry once
- Ci: delete merged PR head branches automatically
- Ci: generate CHANGELOG.md on the promotion PR and commit it onto the PR branch
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
