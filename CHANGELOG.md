# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project is maintained with [git-cliff](https://git-cliff.org).

## Unreleased
### Added
- Feat(friends): the players seated at your table list themselves
- Feat(lobby): one-tap friend requests on each room seat row
- Feat(friends): a players directory with one-tap friend requests
- Feat(voice): the speaking beam carries the animation — a brighter trio of rings
- Feat(online): legible turn state, mic-borne speaking beam, evicted-seat exit
- Feat(friends): add, block, and report players from the table
- Feat(game): enforce a 30-second online turn timer with five-miss ejection
- Feat(voice): show who is talking as gold chips on lobby and boards
- Feat(chat): share GIFs straight from mobile keyboards
- Feat(chat): GIF search over a provider-neutral proxy — Klipy by default
- Feat(friends): friends tray and 1:1 chat with like, reply and invite handoff
- Feat(friends): friend codes, requests, DMs, play invites and blocks on the server
- Feat(feedback): player reports, contact page, admin triage + table CRUD
- Feat(chat): voice notes in table chat, and a chat worth looking at
- Feat(voice): table voice chat over WebRTC with seat-addressed signalling
- Feat(chat): GIF support in table chat
- Feat(online): host-picked table size and one-tap room code copy
- Feat(admin): restrict admin UI to the hosted web app
- Feat(admin): custom dashboard with DB-backed rooms, auth and stats
- Add CodeQL analysis workflow configuration
### Documentation
- Docs(roadmap): graduate shipped in-flight items
- Docs(ux): make the player experience part of every feature
- Docs: redesign banner and restructure README
- Docs: add Play Online, room, leaderboard & settings screenshots
- Docs: replace placeholder screenshots with real Playwright captures
- Docs: replace duplicate screenshots with distinct labeled placeholders
### Fixed
- Fix(ui): the home cards sit in the column every screen uses
- Fix(web): revalidate the build-derived assets so new icons ship
- Fix(lobby): the room code card, its toast and the chat order match the header
- Fix(ui): the in-game chat and GIF sheets read in the header column
- Fix(online): the evicted seat hears its own removal; corner strikes read the seats feed
- Fix(ui): the friends tray and the DM screen read in the same column as their headers
- Fix(online,board): a table that already ended ends the screen too; strikes and the turn clock move outside the board
- Fix(ui): compact friend rows; create-room talk rides the mic button
- Fix(online): miss toasts talk to their seat; the removal ends the board
- Fix(board): center the pawn tap box on its cell at every board size
- Fix(chat): keep the chat sheet under the board, not on it
- Fix(online): back press walks out through the confirm dialog
- Fix(voice): let the web probe reach the never-speaking fallback
- Fix(ui): say why a roll spent the turn without moving a piece
- Fix(dice): cap identical-face streaks at three on every roll stream
- Fix(notes): keep echo cancel and noise suppression on for voice notes
- Fix(dice): one documented, uniform roll shared by every seat
- Fix(voice): rebuild pre-mic peers and reinvite so staggered joins converge
- Fix(voice): the far end of the table call is actually audible
- Fix(chat): the idle voice-note composer stops halving the chat row
- Fix(chat): the waiting GIF reserves its full card, not a bar
- Fix(voice): web recording never needed a filesystem path
- Fix(chat): the pre-first-chunk GIF phase shows the placeholder, not emptiness
- Fix(chat): the pre-first-chunk GIF phase shows the placeholder, not emptiness
- Fix(ludo): mute mic appears only once table voice is joined
- Fix(chat): GIF bubbles hold a fixed frame from loading to loaded
- Fix(hooks): pull no longer leaves CHANGELOG.md dirty in the tree
- Fix(chat): GIF bubbles stop hiding the loaded image behind a spinner
- Fix(chat): voice notes record on Chromium — probe the browser codec
- Fix(hooks): unset git plumbing in pre-push so children's own git describes their repos
- Fix(online): hint and undo are local-table conveniences only
- Fix(admin): unify badge styling and align app bar to content column
- Fix(admin): keep setup fail-closed, guarantee Paste menu, align tests/docs
- Fix(ci): codeql only scans actions and c-cpp with pinned runner
- Fix: add fetch-depth and sparse-checkout to all checkout actions in release.yaml
- Fix: remove ext-v* tag trigger from CI workflow to avoid duplicate runs
- Fix: fix duplicate CI runs and Firefox publishing on ext-v* tags
- Fix(ci): give release-prep pull-requests write so its PR can be opened
- Fix(ui): align title bars to the content column and pull the dice in
- Fix(online): spend the cold-start budget on refused first connections
- Fix(extension): grant wss:// so online play can reach the game server
### Other
- Ci(deploy): only main deploys to Netlify, and superseded action runs cancel
- Refactor(friends): the room's own rows replace the all-users directory
- Ci(web): build web on every push, not only before main
- Ci(guard-dev): count merge parents from git instead of the push payload
- Potential fix for pull request finding
- Ci: add automated screenshot capture + local script
- Ci: add automated screenshot capture workflow
- Stop running the full suite on PRs into dev
- Ci: make release prep open a PR and run before the changelog check
### Performance
- Perf(board): smooth mobile web play and reachable pawn taps
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
