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

    test('pull requests run tests; pushes run changelog, version and publish', () {
      // The two halves of the workflow, kept apart on purpose:
      //
      //   pull_request -> test only
      //   push         -> changelog + version bump (+ publish on a tag)
      //
      // They used to overlap, which meant a push to dev ran a test job scoped
      // away to nothing while a PR into dev ran no checks at all.
      final workflow = File('.github/workflows/ci.yml').readAsStringSync();
      expect(workflow, contains('if: github.event_name == \'pull_request\''),
          reason: 'the test job is pull-only, and unscoped by base branch');
      // A base_ref restriction is what left PRs into dev with no CI.
      expect(workflow, isNot(contains("github.base_ref == 'main'")),
          reason: 'tests must run for every PR, not only those targeting main');
      expect(workflow, contains('if: github.event_name == \'push\''),
          reason: 'changelog and version are push-time work');
    });

    test('the version is bumped on push, in the same commit as the changelog', () {
      // The version lived in three files that had already drifted: pubspec said
      // 1.0.0, both manifests said 1.0.0, the newest tag said v1.1.0. AMO
      // rejects an upload whose version does not increase, so that drift fails
      // during a release, with credentials in hand.
      final workflow = File('.github/workflows/ci.yml').readAsStringSync();
      expect(workflow, contains('tool/version.sh --bump'));
      expect(workflow, contains('tool/version.sh --set'));
      // One commit: two could land in either order and re-introduce the drift.
      expect(workflow, contains('git add CHANGELOG.md pubspec.yaml extension/'));
      // A tag that disagrees with the declared version must fail before upload.
      expect(workflow, contains('does not match the declared version'));
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

    test('the bot retries its push instead of failing on a race', () {
      // If the branch moved during the run the push is rejected. Going red for
      // a race nobody caused is noise that trains people to ignore CI - and it
      // happened twice locally while this branch was being built.
      final workflow = File('.github/workflows/ci.yml').readAsStringSync();
      expect(workflow, contains('for attempt in 1 2 3'));
      expect(workflow, contains('pull --rebase'));
      // Never --force: that could discard someone else's commit.
      expect(workflow, isNot(contains('push --force')));
      expect(workflow, isNot(contains('push -f ')));
    });
  });
}
