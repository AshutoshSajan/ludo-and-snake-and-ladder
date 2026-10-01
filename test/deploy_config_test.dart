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
      expect(workflow, matches(RegExp(r'^  changelog:', multiLine: true)),
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
      expect(workflow, contains('needs: changelog'),
          reason: 'publishing must wait on a job that runs on tags');
      expect(workflow, isNot(matches(RegExp(r'^\s*needs: test', multiLine: true))),
          reason: 'nothing on the tag path may depend on the PR-only test job');
      // The commented-out Chrome job had the same defect; keep it consistent.
      expect(workflow, contains('# needs: changelog'));
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
  });
}
