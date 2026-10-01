import 'package:flutter_test/flutter_test.dart';

import 'package:game_club/screens/online_lobby_screen.dart';

void main() {
  group('sameOriginServerUrl', () {
    // A packaged add-on is NOT same-origin with anything playable. The page at
    // chrome-extension://<id>/index.html has a non-empty host (the id), so a
    // "reuse the page's host" check builds ws://<extension-id>:8080/ws — a URL
    // that can never dial. This is why the packed extensions could not play
    // online while the Netlify build (which bakes the URL in via dart-define)
    // could: same client, different default URL.
    test('chrome-extension pages resolve to the hosted game server', () {
      expect(
        OnlineLobbyScreen.sameOriginServerUrl(
          Uri.parse(
            'chrome-extension://abcdefghijklmnopqrstuvwxyz123456/index.html',
          ),
        ),
        'wss://ludo-1zpb.onrender.com/ws',
      );
    });

    test('moz-extension pages resolve to the hosted game server', () {
      expect(
        OnlineLobbyScreen.sameOriginServerUrl(
          Uri.parse('moz-extension://a1b2c3d4-e5f6-7890-abcd/index.html'),
        ),
        'wss://ludo-1zpb.onrender.com/ws',
      );
    });

    test('an https page keeps its own origin, port included', () {
      expect(
        OnlineLobbyScreen.sameOriginServerUrl(
          Uri.parse('https://ludo-1zpb.onrender.com/'),
        ),
        'wss://ludo-1zpb.onrender.com/ws',
      );
      expect(
        OnlineLobbyScreen.sameOriginServerUrl(
          Uri.parse('https://example.com:8443/'),
        ),
        'wss://example.com:8443/ws',
      );
    });

    test('plain http stays the local dev server on :8080', () {
      expect(
        OnlineLobbyScreen.sameOriginServerUrl(
          Uri.parse('http://localhost:8080/'),
        ),
        'ws://localhost:8080/ws',
      );
    });

    test('any other scheme falls back to the hosted server', () {
      // Not an extension case specifically: a page served over a scheme with
      // no meaningful origin (file://, app://, a future add-on scheme) has
      // nothing to be same-origin with, so the hosted server is the only
      // answer that can work.
      for (final page in [
        Uri.parse('file:///tmp/index.html'),
        Uri.parse('app://-/index.html'),
      ]) {
        expect(
          OnlineLobbyScreen.sameOriginServerUrl(page),
          'wss://ludo-1zpb.onrender.com/ws',
          reason: '$page',
        );
      }
    });
  });
}
