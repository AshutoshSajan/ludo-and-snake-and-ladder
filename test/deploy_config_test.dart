import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:game_club/server/web_cache.dart';

/// The two deploy targets must agree on caching, and neither may be left
/// without a config.
///
/// This is a real failure mode, not a hypothetical one: a stale cached app
/// shell is what makes a freshly deployed build look like it did not ship, and
/// the shell filenames are not content-hashed, so the browser cannot tell a
/// new one from an old one on its own. `web_cache.dart` is the policy the Dart
/// server applies when it serves the client; `netlify.toml` applies the same
/// policy when Netlify serves it. If only one is updated, the bug reappears on
/// whichever origin was missed — and only on that origin, which is why it is so
/// easy to misread as a deploy that did not happen.
void main() {
  group('release.yaml — one-tag binary releases (Sudoku-tested pattern)', () {
    late String release;
    setUpAll(() {
      release = File('.github/workflows/release.yaml').readAsStringSync();
    });

    test('only app tags drive a release; ext-v* can never do it', () {
      // Copied from the incident the guard documents: an ext-v tag through
      // the version resolver would cut an app release named after an
      // extension version. The resolver must refuse it, and manual dispatch
      // still needs a way to name the version.
      expect(release, contains("tags: ['v*']"));
      expect(release, contains('ext-v*'));
      expect(
        release,
        contains("Tag {ref_name!r} is not a vX.Y.Z app release tag"),
      );
    });

    test('every artifact the release needs has a build job behind it', () {
      // The publish step's `needs` is the complete list; the job names are
      // what download-artifact's '*-dist' pattern collects. A job here but
      // not in `needs` builds and then discards its output — the shape of
      // the bug this pins.
      for (final job in [
        'build-android',
        'build-linux',
        'build-appimage',
        'build-windows',
        'build-web',
        'build-extension',
        'build-snap',
      ]) {
        expect(release, contains('  $job:'),
            reason: '$job must exist as a job');
      }
      final publish = RegExp(r'  publish:[\s\S]*?(?=\n  [a-z-]+:|$)')
          .firstMatch(release)
          ?.group(0);
      expect(publish, isNotNull, reason: 'the publish job must exist');
      for (final job in [
        'build-android',
        'build-linux',
        'build-appimage',
        'build-windows',
        'build-web',
        'build-extension',
        'build-snap',
      ]) {
        expect(publish, contains(job),
            reason: 'publish must wait on $job, or its artifacts are orphaned');
      }
    });

    test('the Linux jobs carry the audio deps the game needs', () {
      // LUDO-specific, not in the Sudoku original: the game plays sounds
      // through audioplayers, so a runner without the GStreamer headers
      // fails the Flutter build, not just the tests. Both jobs that compile
      // C++ must name them.
      for (final job in ['build-linux:', 'build-appimage:']) {
        final block = release.split(job).elementAtOrNull(1);
        expect(block, isNotNull, reason: '$job must exist');
        expect(block, contains('libgstreamer1.0-dev'),
            reason: '$job compiles the audio plugins and needs the headers');
      }
    });

    test('the desktop artifacts use the real executable names', () {
      // Also LUDO-specific: linuxdeploy is handed an explicit -e path that
      // must match the desktop file's Exec name (`game-club`), so the release
      // workflow stages the real CMake binary (`game_club`) under that name
      // first — both lines have to be present, or packaging succeeds while
      // wrapping nothing. The Inno script has its own Source line and must
      // name `game_club.exe` directly. Checked here because a runner is the
      // only other place it would fail.
      expect(release, contains('cp build/linux/x64/release/bundle/game_club'));
      expect(
        release,
        contains('-e build/linux/x64/release/bundle/game-club'),
      );
      final iss = File('packaging/inno/game-club.iss').readAsStringSync();
      expect(iss, contains(r'build\windows\x64\runner\Release\*'));
      expect(iss, contains('game_club.exe'));
    });

    test('a manual dispatch can only dry-run, never publish', () {
      // workflow_dispatch shares the whole pipeline so a dry run is a real
      // validation. But the publish step must be tag-gated, or a dry run
      // from the Actions tab cuts a public release with a hand-typed
      // version. The `if` is the only thing standing between the two.
      expect(
        release,
        contains("if: startsWith(github.ref, 'refs/tags/v')"),
        reason: 'only a real v* tag may run softprops/action-gh-release',
      );
    });

    test('the release computes checksums over everything it ships', () {
      expect(release, contains('sha256sum -- * > SHA256SUMS.txt'));
      expect(release, contains('files: dist/*'));
    });
  });

  group('netlify.toml', () {
    late String toml;
    setUpAll(() {
      toml = File('netlify.toml').readAsStringSync();
    });

    test('exists — Netlify is the frontend host', () {
      expect(File('netlify.toml').existsSync(), isTrue);
    });

    test('vercel.json is gone, so there is no ambiguous second config', () {
      // Both files declaring a build for the same output directory means the
      // deployed origin depends on which dashboard you happened to open.
      expect(File('vercel.json').existsSync(), isFalse);
    });

    test('publishes the Flutter web output', () {
      expect(toml, contains('publish = "build/web"'));
    });

    test('passes GAME_SERVER_URL through, since the socket is not on Netlify',
        () {
      expect(toml, contains(r'--dart-define=GAME_SERVER_URL=$GAME_SERVER_URL'));
    });

    test('refuses to build without GAME_SERVER_URL', () {
      // Shipping without it is the failure this guards: the client falls back
      // to same-origin and opens wss://<site>.netlify.app/ws, which answers
      // 200 with index.html. A green build plus a healthy-looking site are
      // exactly the signals that read as success while online play is broken.
      expect(toml, contains(r'if [ -z "${GAME_SERVER_URL:-}" ]; then'));
      // The guard must come before the build, or it is decoration.
      //
      // Compared against lastIndexOf, not indexOf: the file's header comment
      // names `flutter build web --release` to explain what the build produces,
      // and the first match sits ~3k characters before the real command. An
      // indexOf assertion here passes for the wrong reason.
      expect(toml.indexOf('GAME_SERVER_URL:-'),
          lessThan(toml.lastIndexOf('flutter build web --release')),
          reason: 'the guard must precede the build command');
    });

    test('the packaged extensions may contact the hosted game server', () {
      const gameServer = 'https://ludo-1zpb.onrender.com';
      for (final m in const [
        'extension/manifest.chrome.json',
        'extension/manifest.firefox.json',
      ]) {
        final manifest = jsonDecode(File(m).readAsStringSync()) as Map;
        final csp = ((manifest['content_security_policy'] ?? {}) as Map)['extension_pages'] as String? ?? '';
        // The packaged add-ons broke on online play because their default
        // server URL resolved to ws://<extension-id>:8080/ws, and
        // OnlineLobbyScreen now routes extension pages to the hosted game
        // server instead. That URL is useless unless the add-on is allowed to
        // reach it, so pin the half that makes the packaged build different
        // from the web one: connect-src must name the hosted game server.
        expect(csp, contains(gameServer), reason: '$m must allow the hosted game server');
        // extension_pages is where Chrome and Firefox both enforce
        // connect-src for add-on pages; a policy naming only the page source
        // would silently forbid the socket.
        expect(csp, contains('connect-src'), reason: '$m must name connect-src');
      }
    });

    test('rejects a server URL that could never work', () {
      // Netlify scopes env vars per context, so Production can be right while a
      // deploy preview points somewhere useless. The build has to notice: a
      // build aimed at Render's *internal* address is a site that loads
      // perfectly and then cannot do anything, and the browser reports it as a
      // content-security violation rather than as an unreachable address.
      final cmd = toml.substring(toml.indexOf('command = '));
      expect(cmd, contains('wss://*|ws://*'),
          reason: 'plain http is blocked by the page and refused by the browser');
      expect(cmd, contains('*onrender.com*'),
          reason: 'a bare hostname is Render\'s private address, not the public one');
    });

    test('pins the same Flutter version as the Dockerfile', () {
      // pubspec needs Dart ^3.13.2, which ships with Flutter 3.47.2. The
      // cirruslabs images cannot resolve it, so a drift here breaks the build.
      final dockerfile = File('Dockerfile').readAsStringSync();
      final docker = RegExp(r'FLUTTER_VERSION=([0-9.]+)').firstMatch(dockerfile);
      expect(docker, isNotNull, reason: 'Dockerfile no longer pins a version');
      expect(toml, contains(docker!.group(1)),
          reason: 'netlify.toml and Dockerfile must build the same Flutter');
    });

    test('marks every app-shell file no-cache, like the Dart server does', () {
      const shell = [
        'index.html',
        'main.dart.js',
        'flutter_bootstrap.js',
        'flutter.js',
        'flutter_service_worker.js',
        'version.json',
        'manifest.json',
      ];
      for (final name in shell) {
        expect(webCacheHeaders('/$name')['cache-control'],
            'no-cache, must-revalidate',
            reason: '$name is shell to the server');
        expect(toml, contains('for = "/$name"'),
            reason: '$name has no Netlify rule, so it would fall through to the '
                'catch-all and be cached immutably for a year');
      }
    });

    test('holds only genuinely version-stable output immutable', () {
      // canvaskit ships under a Flutter-version-named directory; the launcher
      // icons are fixed images. Only those paths are safe to pin for a year.
      expect(webCacheHeaders('/canvaskit/skwasm.js')['cache-control'],
          'public, max-age=31536000, immutable');
      expect(webCacheHeaders('/icons/Icon-192.png')['cache-control'],
          'public, max-age=31536000, immutable');
      for (final dir in ['/canvaskit/*', '/icons/*']) {
        expect(toml, contains('for = "$dir"'));
      }
      // The old /assets/* blanket is gone: it pinned constant-named,
      // build-derived output (the icon font subset, the manifests) for a
      // year, so a deploy that added icons shipped last deploy's subset and
      // the new icons rendered blank.
      expect(toml, isNot(contains('for = "/assets/*"')));
      expect(webCacheHeaders('/assets/foo.png')['cache-control'],
          'no-cache, must-revalidate');
    });

    test('the build-derived assets revalidate, so new icons ship', () {
      // Every one of these is regenerated by each build under a CONSTANT
      // name: the tree-shaken MaterialIcons subset's glyph membership changes
      // the moment any icon is added, the manifests describe every other
      // asset, shaders are regenerated per Flutter version. An immutable
      // cache kept the previous build's bytes while the code asking for them
      // was fresh — exactly the "new icons do not render on the new deploy"
      // report. Both origins must revalidate these.
      const derived = [
        ('/assets/fonts/MaterialIcons-Regular.otf', 'for = "/assets/fonts/*"'),
        ('/assets/shaders/ink_sparkle.frag', 'for = "/assets/shaders/*"'),
        ('/assets/AssetManifest.bin', 'for = "/assets/AssetManifest.bin"'),
        (
          '/assets/AssetManifest.bin.json',
          'for = "/assets/AssetManifest.bin.json"',
        ),
        ('/assets/FontManifest.json', 'for = "/assets/FontManifest.json"'),
      ];
      for (final (path, rule) in derived) {
        expect(webCacheHeaders(path)['cache-control'],
            'no-cache, must-revalidate',
            reason: '$path is build-derived and cannot be pinned');
        expect(toml, contains(rule),
            reason: '$path has no Netlify rule, so it would fall through to '
                'the immutable blanket');
      }
    });

    test('does not blanket-cache the whole site immutable', () {
      // A deep link is answered by index.html, but Netlify picks the header
      // from the path the browser asked for. A `/*` cache rule would pin the
      // rewritten app shell immutable for a year on every shared game URL.
      final cacheRules = RegExp(r'for = "([^"]+)"\s*\n\s*\[headers\.values\]\s*\n'
              r'\s*Cache-Control = "([^"]*)"')
          .allMatches(toml)
          .map((m) => (m.group(1)!, m.group(2)!))
          .toList();
      expect(cacheRules.where((r) => r.$1 == '/*'), isEmpty,
          reason: 'a /* cache rule would make every SPA deep link stale');
    });

    test('leaves deep links and unknown paths on a revalidating default', () {
      // With no /* rule, a path Netlify rewrites to the shell inherits
      // Netlify's own `public, max-age=0, must-revalidate`. That is the safe
      // direction, and it is why the catch-all was dropped. Assert the set of
      // cache-controlled paths is exactly the shell plus the versioned
      // directories — no wildcard is left to claim a deep link.
      final controlled = RegExp(r'for = "([^"]+)"\s*\n\s*\[headers\.values\]\s*\n'
              r'\s*Cache-Control = "([^"]*)"')
          .allMatches(toml)
          .map((m) => m.group(1)!)
          .toSet();
      expect(
        controlled,
        {
          '/',
          '/index.html',
          '/main.dart.js',
          '/flutter_bootstrap.js',
          '/flutter.js',
          '/flutter_service_worker.js',
          '/version.json',
          '/manifest.json',
          '/assets/fonts/*',
          '/assets/shaders/*',
          '/assets/AssetManifest.bin',
          '/assets/AssetManifest.bin.json',
          '/assets/FontManifest.json',
          '/canvaskit/*',
          '/icons/*',
        },
        reason: 'a deep link must not match any cache rule, or the rewritten '
            'shell inherits the wrong Cache-Control',
      );
    });

    test('serves the SPA fallback without shadowing real files', () {
      expect(toml, contains('from = "/*"'));
      expect(toml, contains('to = "/index.html"'));
      expect(toml, contains('status = 200'));
      // force = true would rewrite /assets/* to index.html and the game would
      // load with no engine. Absent is the correct behaviour.
      expect(toml, isNot(contains('force = true')));
    });

    test('only main may build: the gate decides at the branch, not the UI', () {
      // Netlify's GitHub app proposes a run for every push to every branch
      // and every PR head. This repo promotes dev into main, so a dev merge
      // deploying the whole site was both a surprise rebuild and Netlify's
      // build minutes on a step that is not a release. The `ignore` command
      // is the gate, and it is PINNED by running it: exiting 0 tells
      // Netlify to skip the run, so main must be the only branch that
      // keeps it alive.
      final m = RegExp(r'ignore = "((?:[^"\\]|\\.)+)"').firstMatch(toml);
      expect(m, isNotNull, reason: 'the deploy gate must be an ignore command');
      // TOML unescapes \" to " before the shell sees it; the regex above
      // matched the escaped source, so undo that by hand.
      final command = m!.group(1)!.replaceAll(r'\"', '"');
      int verdict(String branch) => Process.runSync(
        'bash',
        ['-c', command],
        environment: {'BRANCH': branch, 'PATH': '/usr/bin:/bin'},
        workingDirectory: Directory.current.path,
      ).exitCode;
      expect(verdict('dev'), 0, reason: 'a dev merge must not build the site');
      expect(verdict('main'), isNot(0), reason: 'main is the only deploy lane');
    }, skip: Platform.isWindows);
  });

  group('local checks (the free stand-in for runner minutes)', () {
    test('tool/ci.sh runs the same gates the CI test job does', () {
      final ci = File('tool/ci.sh').readAsStringSync();
      // --fatal-infos is the part that matters: without it an unused import
      // scrolls past instead of failing, so local and CI would disagree about
      // whether the same commit is green.
      expect(ci, contains('flutter analyze --fatal-infos'));
      expect(ci, contains('flutter test'));
      expect(ci, contains('flutter build web --release'));
    });

    test('the changelog is generated locally, not by a bot', () {
      final changelog = File('tool/changelog.sh').readAsStringSync();
      expect(changelog, contains('git-cliff'));
      // The check that made the old CI job worth keeping: a regeneration that
      // erases a released section means the branch is missing commits, and the
      // changelog would silently rewrite history.
      expect(changelog, contains('would drop section'));
      expect(File('cliff.toml').existsSync(), isTrue);
    });

    test('the changelog has one writer: CI, on push', () {
      final workflow = File('.github/workflows/ci.yml').readAsStringSync();
      // The old arrangement had the hook and a CI job both regenerating
      // CHANGELOG.md, so whichever ran second produced a commit the other had
      // not verified. The hook no longer touches it; CI owns it.
      expect(workflow, matches(RegExp(r'^  release-prep:', multiLine: true)),
          reason: 'CI must generate the changelog');
      expect(workflow, contains("github.event_name == 'push'"),
          reason: 'generation is a push-time action');

      // Compared against the hook's *code*, not its prose: the header explains
      // at length why the hook no longer touches the changelog, and that
      // explanation is worth keeping. Asserting on the raw file would flag the
      // comment that documents the change as a violation of it.
      final hook = File('.githooks/pre-push')
          .readAsStringSync()
          .replaceAll(RegExp(r'^#.*$', multiLine: true), '');
      expect(hook, isNot(contains('changelog')),
          reason: 'the hook must not write or check it; CI is the only writer');
    });

    test('release-prep can actually open the pull request it describes', () {
      // Found in production, not in review: release-prep pushed its
      // chore/release-prep-* branch fine and then `gh pr create` died with
      // "GraphQL: Resource not accessible by integration
      // (repository.pullRequests)" — because the job had `contents: write`
      // and no `pull-requests: write`. The branch existed with no PR and no
      // path to main. Assert on the job's own block, so a permission that is
      // granted elsewhere in the file cannot satisfy this.
      final workflow = File('.github/workflows/ci.yml').readAsStringSync();
      final prep = RegExp(r'  release-prep:[\s\S]*?(?=\n  [a-z-]+:|$)')
          .firstMatch(workflow)
          ?.group(0);
      expect(prep, isNotNull, reason: 'the release-prep job must exist');
      expect(prep, contains('pull-requests: write'),
          reason: 'gh pr create needs pull-requests: write on this job, '
              'not just contents: write');
    });

    test('an ext-v* tag push triggers the workflow, and publishing can run there', () {
      // The release workflow is triggered by ext-v* tags (extension releases).
      // The ci.yml workflow no longer runs on v* tags to avoid duplicate runs
      // with release.yaml. The publish-firefox job now runs on ext-v* tags.
      final workflow = File('.github/workflows/ci.yml').readAsStringSync();
      expect(workflow, isNot(contains("tags: ['v*']")),
          reason: 'v* tags no longer trigger ci.yml (release.yaml handles them)');
      expect(workflow, contains('startsWith(github.ref, \'refs/tags/ext-v\')'),
          reason: 'ext-v* tags must trigger the publish-firefox job');
      expect(workflow, contains('needs: [release-prep, verify-release]'),
          reason: 'publishing must wait on a job that runs on tags');
      // Scoped to publish-firefox, not the whole file. `test` is legitimately
      // dependable from anything else that runs on a pull request; only the
      // tag path must never wait on it, because there it is skipped and the
      // dependency leaves the job pending forever. Asserting over the whole
      // file would forbid a future PR-path job from needing `test` - a correct
      // change the test would report as a regression.
      final fox = RegExp(r'  publish-firefox:[\s\S]*?(?=\n  [a-z-]+:|$)')
          .firstMatch(workflow)
          ?.group(0);
      expect(fox, isNotNull, reason: 'the publish job must exist');
      expect(fox, isNot(contains('needs: test')),
          reason: 'publishing must not wait on the PR-only test job');
      // The commented-out Chrome job had the same defect; keep it consistent.
      expect(workflow, contains('# needs: [release-prep, verify-release]'));
    });

    test('the pre-push hook gates pushes and does not rewrite them', () {
      final hook = File('.githooks/pre-push').readAsStringSync();
      expect(hook, contains('tool/ci.sh'));
      // Verifying rather than rewriting is deliberate: amending a commit
      // mid-push rewrites a ref the user already computed.
      expect(hook, isNot(contains('commit --amend')));
      expect(hook, isNot(contains('git commit')));
      // An escape hatch, but one that says what it costs.
      expect(hook, contains('SKIP_LOCAL_CI'));
    });

    test('the hook skips deletions and tag-only pushes', () {
      // Deletions arrive as ":refs/heads/x". Running the suite on one changes
      // no code and blocked a routine branch cleanup outright.
      final hook = File('.githooks/pre-push').readAsStringSync();
      expect(hook, contains('deleting refs; skipping the gate'));
      expect(hook, contains('tag-only or delete-only push'));
    });

    test('the hook still gates a real branch push', () {
      // Runs the real script with the ref shape git actually passes. Cheap:
      // SKIP_LOCAL_CI short-circuits the analyze/test half.
      final result = Process.runSync(
        '.githooks/pre-push',
        ['refs/heads/staging:refs/heads/staging'],
        environment: {'SKIP_LOCAL_CI': '1', 'PATH': '/usr/bin:/bin:/usr/local/bin'},
        workingDirectory: Directory.current.path,
      );
      final out = '${result.stdout}${result.stderr}';
      expect(out, isNot(contains('skipping the gate')),
          reason: 'a staging push must not be treated as a no-op: $out');
    }, skip: !File('.githooks/pre-push').existsSync());

    test('hooks are shipped executable, or git silently ignores them', () {
      // A non-executable hook is not a weaker check, it is no check at all,
      // and git reports nothing when it skips one.
      for (final f in ['tool/ci.sh', 'tool/changelog.sh', 'tool/deps.sh', 'tool/release_target.sh', '.githooks/pre-push']) {
        expect(File(f).existsSync(), isTrue, reason: '$f is missing');
        expect(File(f).statSync().mode & 0x111, isNot(0),
            reason: '$f is not executable — git will ignore it silently');
      }
    });

    test('the AMO upload uses `sign`, with the approval wait disabled', () {
      // `web-ext publish` is not a subcommand - the commands are build, sign,
      // run, lint, docs, dump-config - and web-ext runs with yargs strict, so
      // an unknown command fails on argument parsing before reaching AMO. The
      // job could never have worked, and the error names no obvious cause.
      //
      // --approval-timeout 0 is the fix for the hang: `sign` otherwise blocks
      // for the default 5 minutes on every submission waiting for AMO's
      // automatic approval, which is a runner doing nothing and then timing
      // out. New add-ons are held for human review regardless, so the wait
      // never produces a publishable result.
      final workflow = File('.github/workflows/ci.yml').readAsStringSync();
      final step = RegExp(r'npx --yes web-ext@[\d.]+ sign(?:[^\n]*\\\n)*[^\n]*')
          .firstMatch(workflow)
          ?.group(0);
      expect(step, isNotNull, reason: 'the upload step must invoke web-ext sign');
      expect(step, isNot(contains('web-ext publish')));
      expect(step, contains('--approval-timeout 0'));
      // The JWT flow needs issuer and secret as separate flags, not the
      // "issuer:secret" single argument.
      expect(step, contains('--api-key'));
      expect(step, contains('--api-secret'));
    });

    test('only PRs into main run tests; pushes run the release checks', () {
      // The two halves of the workflow, kept apart on purpose:
      //
      //   pull_request -> test only
      //   push         -> changelog + version verify (+ publish on a tag)
      //
      // Scoping is done with `on.pull_request.branches: [main]` rather than an
      // `if: github.base_ref == 'main'` inside the job. Both stop a PR into the
      // integration branch from billing a full suite, but the trigger filter
      // also stops the workflow from starting at all - an `if` still spins up
      // the runner and every job just to skip. Runner minutes are metered and
      // this repo exhausted them.
      final workflow = File('.github/workflows/ci.yml').readAsStringSync();
      expect(workflow, contains('if: github.event_name == \'pull_request\''),
          reason: 'the test job is pull-only');
      expect(workflow, isNot(contains("github.base_ref == 'main'")),
          reason: 'scope PRs with a trigger filter, not a job condition');
      expect(workflow, contains('branches: [main]'),
          reason: 'pushes must be limited to main');
      expect(workflow, contains('if: github.event_name == \'push\''),
          reason: 'changelog and version are push-time work');

      // Sliced out of the `on:` block rather than matched anywhere in the file:
      // `branches: [main]` legitimately appears twice (push and pull_request),
      // so a whole-file `contains` still passes with the PR filter deleted -
      // which is exactly the regression this test exists to catch. Verified by
      // removing the filter and watching this fail.
      final triggers = workflow.substring(0, workflow.indexOf('\njobs:'));
      final prBlock = triggers.substring(triggers.indexOf('pull_request:'));
      expect(prBlock, contains('branches: [main]'),
          reason: 'the PR trigger must be limited to main, or a PR into the '
              'integration branch runs the full suite');
      expect(prBlock, isNot(contains('branches: [main, ')),
          reason: 'no other branch may be added back to the PR trigger');
    });

    test('a bump is still one script, and a stale tag still fails', () {
      // The version lived in three files that had already drifted: pubspec said
      // 1.0.0, both manifests said 1.0.0, the newest tag said v1.1.0. AMO
      // rejects an upload whose version does not increase, so that drift fails
      // during a release, with credentials in hand.
      //
      // The bot that bumped it on every staging/dev push is gone, so the
      // guarantee now rests on two things: the script still writes all three
      // files together, and the workflow still refuses a tag whose version
      // disagrees with what is declared.
      final script = File('tool/version.sh').readAsStringSync();
      expect(script, contains('--bump'),
          reason: 'bumping is a local step now, not a job');
      expect(script, contains('--set'));

      final workflow = File('.github/workflows/ci.yml').readAsStringSync();
      // A tag that disagrees with the declared version must fail before upload.
      // This check is what replaced the automation: forgetting to bump stops the
      // release here, with a message naming the command, rather than shipping
      // drift that only fails once credentials are in hand.
      expect(workflow, contains('does not match the declared version'));
      // ...and the step must actually run on a tag, or it is decoration.
      final prep = workflow
          .split('\n')
          .skipWhile((l) => l != '  release-prep:')
          .skip(1)
          .takeWhile((l) => !RegExp(r'^  [a-z-]+:').hasMatch(l))
          .join('\n');
      expect(prep, contains("startsWith(github.ref, 'refs/tags/v')"));
    });

    test('one script owns every place the version is declared', () {
      // tool/version.sh is the only writer, so the three declarations cannot
      // drift apart again.
      final script = File('tool/version.sh').readAsStringSync();
      expect(script, contains('pubspec.yaml'));
      expect(script, contains('manifest.chrome.json'));
      expect(script, contains('manifest.firefox.json'));
      // Lexical tag sorting puts v1.9.0 above v1.10.0, and bumping from the
      // wrong "latest" silently moves the version backwards.
      expect(script, contains('--sort=-v:refname'));
      // Extension manifests reject anything that is not 1-4 integers < 65536,
      // so a typo must fail on a laptop rather than at AMO.
      expect(script, contains('65535'));
      expect(script, isNot(contains('--tags | sort')),
          reason: 'lexical tag sorting breaks at v1.10.0');
    });

    test('--set moves the Android build suffix forward across releases', () {
      // F-Droid treats an equal versionCode as "already installed" and never
      // offers the update. Resetting the pubspec suffix to +1 on every
      // release made every release after the first invisible, so the script
      // must carry the code forward when the version changes.
      final dir = Directory.systemTemp.createTempSync('game-club-version-');
      addTearDown(() => dir.deleteSync(recursive: true));
      Directory('${dir.path}/extension').createSync();
      Directory('${dir.path}/tool').createSync();
      File('tool/version.sh').copySync('${dir.path}/tool/version.sh');
      File('${dir.path}/pubspec.yaml')
          .writeAsStringSync('name: game_club\nversion: 1.3.0+1\n');
      for (final name in ['manifest.chrome.json', 'manifest.firefox.json']) {
        File('${dir.path}/extension/$name')
            .writeAsStringSync('{\n  "version": "1.3.0"\n}\n');
      }
      final git = Process.runSync('git', ['init', '-q'], workingDirectory: dir.path);
      expect(git.exitCode, 0, reason: '${git.stdout}${git.stderr}');

      String set(String version) {
        final r = Process.runSync(
          'bash',
          ['${dir.path}/tool/version.sh', '--set', version],
          workingDirectory: dir.path,
        );
        expect(r.exitCode, 0, reason: '${r.stdout}${r.stderr}');
        return File('${dir.path}/pubspec.yaml')
            .readAsLinesSync()
            .firstWhere((line) => line.startsWith('version: '));
      }

      expect(set('1.3.1'), 'version: 1.3.1+2');
      // Re-declaring the same version is idempotent: a retried release-prep
      // run must not move the code without a version to match it.
      expect(set('1.3.1'), 'version: 1.3.1+2');
      expect(set('1.4.0'), 'version: 1.4.0+3');
      expect(
        File('${dir.path}/extension/manifest.chrome.json').readAsStringSync(),
        contains('"version": "1.4.0"'),
      );
    });

    test('the git-cliff install step names a path that exists', () {
      // This step failed on its first real run with "Not found in archive".
      // The tarball's top directory is git-cliff-<version>; the asset filename
      // carries a platform triplet, and naming that instead fails with an
      // error that points at neither the cause nor the fix.
      final workflow = File('.github/workflows/ci.yml').readAsStringSync();
      final m = RegExp(r'- name: Install git-cliff\n(.*?)\n      - name:',
              multiLine: true, dotAll: true)
          .firstMatch(workflow)
          ?.group(1);
      expect(m, isNotNull, reason: 'the install step must exist');
      final body = m!;
      // The member must be <version>/git-cliff, never <triplet>/git-cliff.
      expect(body, contains(r'"git-cliff-${GIT_CLIFF_VERSION}/git-cliff"'));
      expect(body, isNot(contains('unknown-linux-gnu/git-cliff"')),
          reason: 'the triplet is the asset name, not the archive layout');
      // A pinned version and a checksum: @latest would let a renamed or
      // replaced asset execute.
      expect(body, contains('GIT_CLIFF_SHA256'));
      expect(body, contains('sha256sum -c -'));
    });

    test('a release tag cannot publish untested code', () {
      // `test` is pull-request-only, so the tag path had no test gate at all:
      // it verified the changelog and the version, built, and uploaded. A tag
      // must not ship code nothing has run.
      final workflow = File('.github/workflows/ci.yml').readAsStringSync();
      expect(workflow, matches(RegExp(r'^  verify-release:', multiLine: true)),
          reason: 'the tag path needs its own test gate');
      // The body is sliced out line-by-line rather than by regex. A lookahead
      // would need [\s\S]*? plus an end anchor, and Dart's RegExp is
      // ECMAScript-based: it has no \Z, which there matches a literal "Z" and
      // silently finds nothing.
      final body = workflow
          .split('\n')
          .skipWhile((l) => l != '  verify-release:')
          .skip(1)
          .takeWhile((l) => !RegExp(r'^  [a-z-]+:$').hasMatch(l))
          .join('\n');
      expect(body, isNotEmpty, reason: 'the job body must be found');
      expect(body, contains("startsWith(github.ref, 'refs/tags/v')"),
          reason: 'it gates tags, not every push');
      expect(body, contains('flutter test'));
      expect(body, contains('flutter analyze --fatal-infos'));
      // Publishing must wait for it, or the gate is decorative.
      expect(workflow, contains('needs: [release-prep, verify-release]'));
    });

    test('the release bot bumps and regenerates on main, via a PR', () {
      // Automatic release-prep, restored after the staging/dev triggers went
      // away and left the step unreachable. Two properties are load-bearing:
      //
      // 1. It commits THROUGH A PULL REQUEST. `guard-main` rejects any main head
      //    that is not a merge commit, and a bot push is not one — so a direct
      //    `git push origin HEAD:main` here fails the very next push, and the
      //    failure names the guard, not the cause.
      // 2. It runs BEFORE the changelog verify. The verify is `--check`, so with
      //    the order reversed it fails against the changelog the bot has not
      //    written yet, on every single main push.
      final workflow = File('.github/workflows/ci.yml').readAsStringSync();
      final steps = RegExp(r'      - name: ([^\n]+)')
              .allMatches(workflow)
              .map((m) => m.group(1)!.trim())
              .toList();
      final regen = steps.indexWhere((s) =>
          s.toLowerCase().contains('regenerate') ||
          s.toLowerCase().contains('bump'));
      final verify = steps.indexWhere(
          (s) => s.toLowerCase().contains('verify the changelog'));
      expect(regen, isNonNegative, reason: 'the bump step must exist');
      expect(verify, isNonNegative, reason: 'the verify step must exist');
      expect(regen, lessThan(verify),
          reason: 'regenerating after --check fails every main push');

      final prep = workflow
          .split('\n')
          .skipWhile((l) => l != '  release-prep:')
          .skip(1)
          .takeWhile((l) => !RegExp(r'^  [a-z-]+:$').hasMatch(l))
          .join('\n');
      expect(prep, contains('gh pr create'),
          reason: 'guard-main forbids a bot push to main');
      expect(prep, contains('tool/version.sh --set'));
      expect(prep, contains('tool/changelog.sh'));
      // A `chore:` subject is what makes this converge: cliff.toml skips it, so
      // the bot's own commit adds no changelog entry and does not re-stale the
      // file it just wrote. A `feat:`/`fix:` subject here loops forever.
      //
      // Matched on the `git commit` line specifically, not the string anywhere in
      // the job - `chore: release prep` also appears in the gh pr create --title,
      // so a looser assertion passes even when the commit subject is `feat:`.
      final commitLine = prep
          .split('\n')
          .firstWhere((l) => l.contains('git commit -m'), orElse: () => '');
      expect(commitLine, contains('chore:'),
          reason: 'a non-chore subject makes the bot re-stale its own changelog, '
              'forever');
      // Never --force: a branch can move between the check and the push, and a
      // force would discard whatever landed there.
      expect(prep, isNot(contains('push --force')));
      expect(prep, isNot(contains('push -f ')));
      // It must open a PR, never push to main: guard-main forbids the head of
      // main from being anything but a merge commit.
      expect(prep, isNot(contains('push origin HEAD:main')));
      expect(prep, isNot(contains('origin HEAD:refs/heads/main')));
    });

    test('release-prep regenerates the changelog even with no version bump', () {
      // The production failure: main had already declared 1.3.0 while the
      // newest tag was v1.2.1, so --bump returned 1.3.0, the old step read
      // `next == base` as "nothing to do" and exited BEFORE regenerating.
      // The stale changelog then failed --check on every push.
      final workflow = File('.github/workflows/ci.yml').readAsStringSync();
      final prep = workflow
          .split('\n')
          .skipWhile((l) => l != '  release-prep:')
          .skip(1)
          .takeWhile((l) => !RegExp(r'^  [a-z-]+:$').hasMatch(l))
          .join('\n');

      final nextAt = prep.indexOf(r'next=$(tool/version.sh --bump)');
      // The executable line, not the prose mention of the generator or the
      // later --check verification step.
      final regenAt = prep.indexOf('\n          tool/changelog.sh\n');
      expect(nextAt, isNonNegative,
          reason: 'the tag-derived next version is needed');
      expect(regenAt, isNonNegative,
          reason: 'the changelog must always be regenerated');
      expect(nextAt, lessThan(regenAt));
      expect(prep, isNot(contains('nothing to bump')),
          reason: 'the removed early exit is the bug this guards');
      expect(prep.substring(nextAt, regenAt), isNot(contains('exit 0')),
          reason: 'an early exit after --bump skips the stale changelog again');
      // The target is chosen before it is written, so a lagging tag cannot
      // move the declared version backwards.
      final targetAt = prep.indexOf('tool/release_target.sh');
      expect(targetAt, isNonNegative);
      expect(targetAt, lessThan(regenAt));
      expect(prep, contains(r'tool/version.sh --set "$target"'));
    });

    test('release target never moves the declared version backwards', () {
      ProcessResult run(String declared, String derived) => Process.runSync(
            'tool/release_target.sh',
            [declared, derived],
            workingDirectory: Directory.current.path,
          );

      // Same version: regenerate the changelog, but do not invent a bump.
      var r = run('1.3.0', '1.3.0');
      expect(r.exitCode, 0, reason: '${r.stdout}${r.stderr}');
      expect((r.stdout as String).trim(), '1.3.0');

      // A genuinely newer target still wins.
      r = run('1.3.0', '1.4.0');
      expect((r.stdout as String).trim(), '1.4.0');

      // History behind an already-declared version must not downgrade it.
      r = run('1.3.0', '1.2.2');
      expect((r.stdout as String).trim(), '1.3.0');
      expect((r.stderr as String), contains('keeping 1.3.0'));

      // Numeric, not lexical: 1.10.0 is above 1.9.0.
      r = run('1.9.0', '1.10.0');
      expect((r.stdout as String).trim(), '1.10.0');
      r = run('1.10.0', '1.9.0');
      expect((r.stdout as String).trim(), '1.10.0');

      // The release script is not a place for malformed versions.
      r = run('1.3.x', '1.4.0');
      expect(r.exitCode, isNot(0));
    });

    test('publishing follows the bump on ext-v* tag, not on main push', () {
      // The order: changelog + version bump, then the Firefox
      // upload. `needs` enforces the order — release-prep bumps, verify-release
      // is the only test gate on a push path, and publish runs after both.
      // 
      // IMPORTANT: Firefox publishing now runs on ext-v* tags (extension releases),
      // NOT on main push. This matches the Sudoku workflow pattern.
      final workflow = File('.github/workflows/ci.yml').readAsStringSync();
      // Sliced line-by-line, not by regex. A lookahead like `(?=\n  [a-z-]+:|\Z)`
      // matches the COMMENTED-OUT `publish-chrome` block, whose body is indented
      // two spaces and whose keys are commented - so the match stops early and
      // returns null. Slicing on real job headers cannot be fooled by a block
      // that is not a job.
      String jobBody(String name) => workflow
          .split('\n')
          .skipWhile((l) => l != '  $name:')
          .skip(1)
          .takeWhile((l) => !RegExp(r'^  [a-z-]+:\s*$').hasMatch(l))
          .join('\n');

      final fox = jobBody('publish-firefox');
      expect(fox, contains("startsWith(github.ref, 'refs/tags/ext-v')"),
          reason: 'an ext-v* tag carries the bump and must trigger the upload');
      expect(fox, contains('needs: [release-prep, verify-release]'),
          reason: 'publishing must wait for the bump and the test gate');

      // verify-release has to run on main too. If it were tag-only it would be
      // skipped on a push, and a job whose dependency was skipped never starts -
      // which is precisely how publishing got stuck before.
      final verify = jobBody('verify-release');
      expect(verify, contains("github.ref == 'refs/heads/main'"),
          reason: 'without a test gate on main, uploads ship untested');
    });

    test('nothing pushes on CI any more, so the race cannot recur', () {
      // The bot committed the changelog and pushed it back with a three-attempt
      // rebase-and-retry loop, because a branch moving mid-run rejects the push.
      // With staging/dev no longer triggering the workflow there is no writer
      // and no push, so the loop is gone rather than merely untested. Guarding
      // the absence is deliberate: if someone re-adds a pushing job, this fails
      // and makes them think about the race instead of copying the old loop.
      final workflow = File('.github/workflows/ci.yml').readAsStringSync();
      expect(workflow, isNot(contains('push --force')),
          reason: 'a force push could discard someone else\'s commit');
      expect(workflow, isNot(contains('push -f ')));
      expect(workflow, isNot(contains('git push origin HEAD:')),
          reason: 'the only writer of the changelog is a person now');
      expect(workflow, isNot(contains('for attempt in 1 2 3')),
          reason: 'the retry loop belonged to the push that no longer happens');
      // The verification it used to race against is still there.
      expect(workflow, contains('tool/changelog.sh --check'));
    });
  });

  group('conventions — trunk guards, branch pruning, agent rules', () {
    // CONVENTIONS.md is the rule book this group mechanically enforces:
    // main/dev advance only via pull requests, merged branches clean
    // themselves up, and every agent harness loads the same rules.

    test('the pre-push hook rejects a push that targets dev or main', () {
      // Runs the real script with the colon ref shape (the same shape the
      // staging bulk test above uses). The guard must fail the push BEFORE the
      // analyze/test half — a trunk push should be refused for free, which is
      // what SKIP_LOCAL_CI=1 proves here: even with the suite disabled the
      // push does not pass.
      for (final ref in ['refs/heads/dev:refs/heads/dev', 'refs/heads/main:refs/heads/main']) {
        final result = Process.runSync(
          '.githooks/pre-push',
          [ref],
          environment: {'SKIP_LOCAL_CI': '1', 'PATH': '/usr/bin:/bin:/usr/local/bin'},
          workingDirectory: Directory.current.path,
        );
        final out = '${result.stdout}${result.stderr}';
        expect(result.exitCode, isNot(0),
            reason: '$ref is a protected trunk and must be refused: $out');
        expect(out, contains('protected trunk'),
            reason: 'the refusal must name the rule, not just fail: $out');
      }
    }, skip: !File('.githooks/pre-push').existsSync());

    test('a merged main PR does not re-bill its own suite', () {
      // A merge into main fires push, and it closes the PR — which
      // `pull_request.closed` would ALSO trigger. Two full suites for one
      // commit, in parallel, on one shared runner pool: exactly the queue
      // pile the metered-runner policy exists to prevent, with the closed
      // event adding nothing the push run does not deliver.
      final workflow = File('.github/workflows/ci.yml').readAsStringSync();
      final triggers = workflow.substring(0, workflow.indexOf('\njobs:'));
      final prBlock = triggers.substring(triggers.indexOf('pull_request:'));
      expect(
        prBlock.split('\n').take(6).join('\n'),
        isNot(contains("'closed'")),
        reason: 'the PR trigger must not fire on merge closure',
      );
      expect(
        workflow,
        contains("github.event.action != 'closed'"),
        reason: 'the test job refuses a closed event even if the type '
            'returns to the list',
      );
    });

    test('every workflow cancels its own superseded runs, so nothing queues '
        'into a pile', () {
      // Each file owns its cadence (cheap guards, weekly scans, tag-gated
      // releases), but every one of them can be superseded by the next
      // event: another push in a burst, a re-tagged version, a re-triggered
      // scan. A queue of already-replaced runs is exactly what "Actions
      // queued forever" reads like; the concurrency block collapses it.
      for (final f in [
        'ci.yml',
        'codeql.yml',
        'deps-audit.yml',
        'release.yaml',
        'guard-dev.yml',
        'prune-branch.yml',
      ]) {
        final text = File('.github/workflows/$f').readAsStringSync();
        expect(text, contains('concurrency:'),
            reason: '$f stacks superseded runs into a queue');
        expect(text, contains('cancel-in-progress'),
            reason: '$f keeps superseded runs alive to the end');
      }
    });

    test('dev pushes are guarded in CI by a workflow of their own', () {
      // ci.yml deliberately bills the full suite only on main (see its own
      // comments), so a dev push would go unseen there. The guard lives in its
      // own file and stays cheap: the facts it asserts (merge-commitness,
      // no force-push, no deletion) are in the push event payload, so it never
      // checkout-drives the runner at all.
      final guard = File('.github/workflows/guard-dev.yml');
      expect(guard.existsSync(), isTrue, reason: 'guard-dev.yml is missing');
      final text = guard.readAsStringSync();
      expect(text, contains('branches: [dev]'),
          reason: 'the guard must trigger on pushes to dev');
      expect(text, contains('head_commit.parents'),
          reason: 'the merge-commit rule reads the event payload, not a checkout');
      expect(text, contains(".forced"),
          reason: 'a forced push to dev rewrites shared history — forbidden');
    });

    test('merged task branches prune themselves', () {
      // The pruner moved out of ci.yml whose pull_request trigger is scoped to
      // main: a job there could never see PRs into dev. Its own workflow has
      // both bases, plus the same three protections the inline job carried.
      final pruner = File('.github/workflows/prune-branch.yml');
      expect(pruner.existsSync(), isTrue, reason: 'prune-branch.yml is missing');
      final text = pruner.readAsStringSync();
      expect(text, contains('branches: [dev, main]'),
          reason: 'both trunk PRs must prune');
      expect(text, contains('merge-base --is-ancestor'),
          reason: 'a branch whose commits did not land must be kept');
      expect(text, isNot(contains('git push origin --force')),
          reason: 'pruning deletes the branch, it must not rewrite anything');

      final workflow = File('.github/workflows/ci.yml').readAsStringSync();
      expect(workflow, isNot(contains('  prune-branch:')),
          reason: 'the inline job is gone — one writer, as with the changelog');
    });

    test('agent rules are loaded by every harness, not just the README prose', () {
      // The convention files must exist AND carry their hard rules inline:
      // a harness that reads only AGENTS.md (Codex, Crush, OpenCode) still
      // sees the trunk rule, the PR target and the destructiveness ban —
      // following the pointer to CONVENTIONS.md must add depth, not be
      // required for compliance.
      final agents = File('AGENTS.md').readAsStringSync();
      expect(agents, contains('git checkout -b <name> dev'),
          reason: 'task branches are cut from dev, spelled out in the loaded copy');
      expect(agents, contains('gh pr create --base dev'),
          reason: 'the PR target is a rule, not advice');
      expect(agents, contains('are never worked on directly'),
          reason: 'the trunk rule is stated in the loaded copy');
      expect(agents, contains('No destructive operations'),
          reason: 'the destructive-ops ban is stated in the loaded copy');

      // CLAUDE.md imports rather than duplicates the rules: two copies drift.
      expect(File('CLAUDE.md').readAsStringSync(), contains('@AGENTS.md'));

      final conventions = File('CONVENTIONS.md').readAsStringSync();
      expect(conventions, contains('No database destruction'),
          reason: 'the full rule book names the database ban explicitly');
      expect(conventions, contains('prune-branch.yml'),
          reason: 'the full rule book documents the branch-cleanup workflow');
    });

    test('README is product facts only; process lives in CONVENTIONS.md', () {
      // The branch-flow narrative moved out of the README — keeping two
      // versions of the rules is two places to drift. The README may speak
      // about running and building, not about how the git graph behaves.
      final readme = File('README.md').readAsStringSync();
      expect(readme, isNot(contains('sandbox')),
          reason: 'the sandbox tier is gone from the flow and from the README');
      expect(readme, isNot(contains('staging')),
          reason: 'staging is no longer part of the flow');
      expect(readme, isNot(contains('## 🌲 Branches, PRs & CI')),
          reason: 'process documentation lives in CONVENTIONS.md now');
      expect(readme, contains('CONVENTIONS.md'),
          reason: 'the README must point contributors at the rule book');
      expect(readme, contains('ROADMAP.md'),
          reason: 'roadmap/todos live in their own file, not the README');
    });
    test('dependency health: Dependabot raises PRs, the OSV scan gates them', () {
      // Two lanes, one concern: version drift arrives as Dependabot PRs into
      // dev (bot branches are task work), known advisories fail their own
      // cheap workflow — and a PR that tries to merge a vulnerable lock into
      // main fails before it gets there.
      final dependabot = File('.github/dependabot.yml').readAsStringSync();
      expect(dependabot, contains('package-ecosystem: pub'),
          reason: 'pub is the ecosystem this repo ships from');
      expect(dependabot, contains('package-ecosystem: github-actions'),
          reason: 'pinned action versions drift too');
      expect("target-branch: dev".allMatches(dependabot).length, 2,
          reason: 'both lanes follow the PRs-into-dev rule, CONVENTIONS.md');
      expect("interval: weekly".allMatches(dependabot).length, 2,
          reason: 'both lanes refresh weekly, not fine-grained noise');
    });

    test('deps-audit.yml scans pubspec.lock against OSV, pinned binary', () {
      // The scanner itself must not become the vulnerability: it is pinned
      // version+sha256 the same way git-cliff is in ci.yml. And the gate is
      // source+all: pubspec.lock is what production resolves, which is ALSO
      // what the pre-push hook and CONVENTIONS.md tell agents to scan with
      // tool/deps.sh — one lock, one truth.
      final audit = File('.github/workflows/deps-audit.yml').readAsStringSync();
      expect(audit, contains('osv-scanner/releases/download/'),
          reason: 'the scanner is downloaded from its official release page');
      expect(audit, contains('OSV_SCANNER_SHA256: '),
          reason: 'the binary is sha256-verified before use');
      expect(audit, contains('sha256sum -c -'), reason: '…and the verification actually runs');
      expect(audit, contains('scan --lockfile='),
          reason: 'the scan covers the lockfile production resolves');
      expect(audit, contains('cron: '),
          reason: 'staleness cannot rely on someone remembering to look');
      final paths = RegExp(r'pull_request:[\s\S]*?branches: \[main\]');
      expect(paths.hasMatch(audit), isTrue,
          reason: 'a dependency PR into main runs the scan before it ships');
    });

    test('the prune allowlist covers the bots that now open PRs', () {
      // Dependabot PRs merge into dev like any task branch; if the pruner
      // ignored them its cleanup promise silently half-applied.
      final pruner = File('.github/workflows/prune-branch.yml').readAsStringSync();
      expect(pruner, contains('dependabot/*'),
          reason: 'merged dependabot branches must clean up too');
    });
  });
}
