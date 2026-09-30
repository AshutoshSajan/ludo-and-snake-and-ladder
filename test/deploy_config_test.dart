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

    test('CI no longer regenerates the changelog — it would race the hook', () {
      final workflow =
          File('.github/workflows/ci.yml').readAsStringSync();
      // Match the job definition and the shell that would run it, not the
      // word "git-cliff" — the explanatory comment above the removed job
      // legitimately names it.
      expect(workflow, isNot(matches(RegExp(r'^\s{2}changelog:', multiLine: true))));
      expect(workflow, isNot(matches(RegExp(r'run:.*git-cliff'))));
      // The backstop stays: a hook is bypassable with --no-verify, so these
      // are the only checks that run on a merge made from the GitHub UI.
      expect(workflow, contains('guard-main:'));
      expect(workflow, contains('  test:'));
    });

    test('the pre-push hook gates pushes and does not rewrite them', () {
      final hook = File('.githooks/pre-push').readAsStringSync();
      expect(hook, contains('tool/ci.sh'));
      expect(hook, contains('tool/changelog.sh --check'));
      // Verifying rather than rewriting is deliberate: amending a commit
      // mid-push rewrites a ref the user already computed.
      expect(hook, isNot(contains('commit --amend')));
      expect(hook, isNot(contains('git commit')));
      // An escape hatch, but one that says what it costs.
      expect(hook, contains('SKIP_LOCAL_CI'));
    });

    test('the hook reads the branch from after the colon, or never fires', () {
      // Git passes "<local-ref>:<remote-ref>". Matching the whole argument
      // against refs/heads/staging looks correct and never matches, so the
      // changelog gate would be installed, silent, and doing nothing.
      final hook = File('.githooks/pre-push').readAsStringSync();
      expect(hook, contains(r'${remote_ref#*:}'),
          reason: 'the hook must strip the local ref before matching the branch');
      expect(hook, isNot(contains(r'for remote_ref in "${@-"')),
          reason: r'"${@-}" is not valid parameter expansion');
    });

    test('the hook actually gates a trunk push', () {
      // Runs the real script with the ref shape git actually passes. Cheap:
      // SKIP_LOCAL_CI short-circuits the analyze/test half, so this exercises
      // only the ref parsing and the changelog check.
      final result = Process.runSync(
        '.githooks/pre-push',
        ['refs/heads/staging:refs/heads/staging'],
        environment: {'SKIP_LOCAL_CI': '1', 'PATH': '/usr/bin:/bin:/usr/local/bin'},
        workingDirectory: Directory.current.path,
      );
      final out = '${result.stdout}${result.stderr}';
      expect(out, contains('checking CHANGELOG.md'),
          reason: 'a staging push must verify the changelog: $out');

      final dev = Process.runSync(
        '.githooks/pre-push',
        ['refs/heads/dev:refs/heads/dev'],
        environment: {'SKIP_LOCAL_CI': '1', 'PATH': '/usr/bin:/bin:/usr/local/bin'},
        workingDirectory: Directory.current.path,
      );
      expect('${dev.stdout}${dev.stderr}', isNot(contains('checking CHANGELOG')),
          reason: 'a dev push should not pay for the changelog check');
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
