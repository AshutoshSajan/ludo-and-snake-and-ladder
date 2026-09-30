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
}
