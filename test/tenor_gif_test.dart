/// Tests for the chat GIF stack:
///
/// 1. `parseTenorResponse` — the Tenor v2 payload shape the proxy normalizes
/// 2. `tenorHandler` — key-gating, upstream relay, and error mapping
/// 3. `searchGifs` — the client side of `/media/tenor`
///
/// All network is faked with `MockClient`; nothing here talks to Tenor.
library;

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:game_club/server/tenor.dart';
import 'package:game_club/services/gif_search.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shelf/shelf.dart' as shelf;

const _sampleTenorBody = '''
{
  "results": [
    {
      "id": "a1",
      "content_description": "dice roll",
      "media_formats": {
        "gif": {"url": "https://media.tenor.com/a/full.gif"},
        "tinygif": {"url": "https://media.tenor.com/a/tiny.gif"}
      }
    },
    {
      "id": "a2",
      "content_descriptions": [],
      "media_formats": {
        "gif": {"url": "https://media.tenor.com/b/full.gif"}
      }
    },
    {
      "id": "a3",
      "media_formats": {}
    }
  ],
  "next": "abc123"
}
''';

shelf.Request _req(Map<String, String> query) => shelf.Request(
      'GET',
      Uri.http('server.local', '/media/tenor', query),
    );

http.Response _res(int code, String body) =>
    http.Response(body, code, headers: {'content-type': 'application/json'});

void main() {
  group('parseTenorResponse', () {
    test('normalizes results into url/preview/desc', () {
      final parsed = parseTenorResponse(_sampleTenorBody);
      expect(parsed['ok'], isTrue);
      final gifs = parsed['gifs'] as List;
      expect(
        gifs,
        hasLength(2),
        reason: 'a result without a gif entry is skipped',
      );
      expect(gifs.first['url'], 'https://media.tenor.com/a/full.gif');
      expect(gifs.first['preview'], 'https://media.tenor.com/a/tiny.gif');
      expect(gifs.first['desc'], 'dice roll');
      // No tinygif variant: the full gif doubles as the preview.
      expect(gifs.last['preview'], 'https://media.tenor.com/b/full.gif');
      expect(gifs.last['desc'], isEmpty);
      // Tenor's cursor rides through for pagination.
      expect(parsed['next'], 'abc123');
    });

    test('an empty upstream page produces an empty grid and no cursor', () {
      final parsed = parseTenorResponse('{"results": []}');
      expect((parsed['gifs'] as List), isEmpty);
      expect(parsed.containsKey('next'), isFalse);
    });
  });

  group('tenorHandler', () {
    test('without a key it is a 503 naming the fallback path', () async {
      final res = await tenorHandler(
        _req({'q': 'dice'}),
        apiKey: null,
        client: MockClient((_) => throw StateError('must not dial')),
      );
      expect(res.statusCode, 503);
      final body = jsonDecode(await res.readAsString()) as Map<String, dynamic>;
      expect(body['ok'], isFalse);
      expect(
        (body['text'] as String).contains('image link'),
        isTrue,
        reason: 'the message names the paste-a-link fallback',
      );
    });

    test('relays the search with the key server-side', () async {
      late Uri requested;
      final res = await tenorHandler(
        _req({'q': 'dice roll', 'pos': 'cur1'}),
        apiKey: 'secret-key',
        client: MockClient((req) async {
          requested = req.url;
          return _res(200, _sampleTenorBody);
        }),
      );
      expect(res.statusCode, 200);
      // The key never leaves the description path — but it does go to Tenor.
      expect(requested.host, 'g.tenor.com');
      expect(requested.queryParameters['key'], 'secret-key');
      expect(requested.queryParameters['q'], 'dice roll');
      expect(requested.queryParameters['pos'], 'cur1');
      expect(requested.queryParameters['limit'], '12');

      final body = jsonDecode(await res.readAsString()) as Map<String, dynamic>;
      expect(body['ok'], isTrue);
      expect((body['gifs'] as List), hasLength(2));
      expect(body['next'], 'abc123');
    });

    test('a missing q is a 400, not a Tenor round trip', () async {
      var dialed = 0;
      final res = await tenorHandler(
        _req({}),
        apiKey: 'secret-key',
        client: MockClient((_) async {
          dialed++;
          return _res(200, '{"results":[]}');
        }),
      );
      expect(res.statusCode, 400);
      expect(dialed, 0);
    });

    test('an upstream failure is a 502 the picker can fall back from', () async {
      final res = await tenorHandler(
        _req({'q': 'dice'}),
        apiKey: 'secret-key',
        client: MockClient((_) async => _res(500, 'boom')),
      );
      expect(res.statusCode, 502);
      expect((jsonDecode(await res.readAsString()) as Map)['ok'], isFalse);
    });
  });

  group('searchGifs (client side)', () {
    test('asks the http origin, not the websocket scheme', () async {
      List<Uri> asked = [];
      final gifs = await searchGifs(
        'wss://game.example/ws',
        'ludo',
        pos: 'cur2',
        httpClient: MockClient((req) async {
          asked = [req.url];
          // The server answers with its normalized shape — exactly what
          // tenorHandler emits — not with Tenor's raw payload.
          return _res(200, jsonEncode(parseTenorResponse(_sampleTenorBody)));
        }),
      );
      expect(asked.single.host, 'game.example');
      expect(asked.single.scheme, 'https');
      expect(asked.single.path, '/media/tenor');
      expect(asked.single.queryParameters, {'q': 'ludo', 'pos': 'cur2'});
      expect(gifs, hasLength(2));
      expect(gifs.first.url, 'https://media.tenor.com/a/full.gif');
    });

    test('a 503 becomes the typed exception the picker reads', () async {
      await expectLater(
        searchGifs(
          'ws://localhost:8080/ws',
          'ludo',
          httpClient: MockClient(
            (_) async => _res(503, '{"ok":false,"text":"not configured"}'),
          ),
        ),
        throwsA(
          isA<GifSearchException>().having(
            (e) => e.text,
            'text',
            'not configured',
          ),
        ),
      );
    });
  });
}
