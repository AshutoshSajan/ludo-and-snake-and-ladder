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

    test('holds versioned assets immutable, matching the server', () {
      expect(webCacheHeaders('/assets/foo.png')['cache-control'],
          'public, max-age=31536000, immutable');
      // Named directories, not a blanket: see the deep-link test below.
      for (final dir in ['/assets/*', '/canvaskit/*', '/fonts/*']) {
        expect(toml, contains('for = "$dir"'));
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
          '/assets/*',
          '/canvaskit/*',
          '/fonts/*',
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

    test('a tag push triggers the workflow, and publishing can run there', () {
      // Two separate defects made the release path unreachable while the
      // workflow still looked correct on screen.
      //
      // 1. on.push listed only branches, so `git push origin v1.0.0` ran no
      //    workflow at all and no publishing job could ever be reached.
      // 2. publish-firefox had `needs: test`. `test` is scoped to pull
      //    requests, so on a tag it is skipped, and a job whose dependency was
      //    skipped never starts - which is what displayed as "waiting for
      //    approval".
      final workflow = File('.github/workflows/ci.yml').readAsStringSync();
      expect(workflow, contains("tags: ['v*']"),
          reason: 'release tags must trigger the workflow');
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
      for (final f in ['tool/ci.sh', 'tool/changelog.sh', '.githooks/pre-push']) {
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

    test('publishing follows the bump on main, not a hand-pushed tag', () {
      // The order the user asked for: changelog + version, then the Firefox
      // upload. `needs` is what enforces it — release-prep bumps, verify-release
      // is the only test gate on a push path, and publish runs after both.
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
      expect(fox, contains("github.ref == 'refs/heads/main'"),
          reason: 'a main merge carries the bump and must trigger the upload');
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
}
