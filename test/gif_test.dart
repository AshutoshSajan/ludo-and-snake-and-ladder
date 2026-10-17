/// Tests for the chat GIF stack, provider-neutral edition:
///
/// 1. `parseKlipyResponse` / `parseGiphyResponse` — the upstream payload
///    shapes the layer normalizes (the two providers known today)
/// 2. `selectGifProvider` — env-driven provider choice
/// 3. `gifSearchHandler` — key-gating, search vs trending, cursors,
///    and error mapping
/// 4. `searchGifsPage` — the client side of `/media/gif`
///
/// All network is faked with `MockClient`; nothing here talks to a real
/// provider. (Tenor's API shut down on 2026-06-30 — that module is gone,
/// not tested.)
library;

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:game_club/server/gif.dart';
import 'package:game_club/services/gif_search.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shelf/shelf.dart' as shelf;

const _sampleKlipyBody = '''
{
  "result": true,
  "data": {
    "has_next": true,
    "data": [
      {
        "type": "gif",
        "slug": "dice-roll",
        "title": "dice roll",
        "file": {
          "hd": {"gif": {"url": "https://k.co/a/hd.gif"}},
          "md": {"gif": {"url": "https://k.co/a/md.gif"}},
          "xs": {"gif": {"url": "https://k.co/a/xs.gif"}}
        }
      },
      {
        "type": "gif",
        "slug": "webp-only",
        "title": "",
        "file": {"hd": {"webp": {"url": "https://k.co/b/hd.webp"}}}
      },
      {"type": "ad", "width": 100, "height": 100, "content": "https://ad.example/x"},
      {"type": "gif", "slug": "no-file", "title": "empty"}
    ]
  }
}
''';

const _sampleKlipyClip = '''
{
  "result": true,
  "data": {"has_next": false, "data": [
    {"type": "clip", "slug": "c1", "title": "clip", "file": {"gif": "https://k.co/c/clip.gif"}}
  ]}
}
''';

const _sampleGiphyBody = '''
{
  "data": [
    {"id": "g1", "title": "hi", "images": {
      "downsized_medium": {"url": "https://media.giphy.com/g1/downsized.gif"},
      "downsized": {"url": "https://media.giphy.com/g1/downsized.gif"},
      "fixed_width_small": {"url": "https://media.giphy.com/g1/small.gif"}
    }},
    {"id": "g2", "title": "", "images": {"downsized": {"url": "https://media.giphy.com/g2/g.gif"}}}
  ],
  "pagination": {"count": 2, "offset": 0, "total_count": 14}
}
''';

shelf.Request _req(Map<String, String> query, {String path = '/media/gif'}) =>
    shelf.Request('GET', Uri.http('server.local', path, query));

http.Response _res(int code, String body) =>
    http.Response(body, code, headers: {'content-type': 'application/json'});

void main() {
  group('parseKlipyResponse', () {
    test('normalizes buckets into url/preview/desc and skips ads', () {
      final page = parseKlipyResponse(_sampleKlipyBody);
      // gif(1) + gif(2, webp-only) survive; the ad and the file-less item
      // drop.
      expect(page.gifs, hasLength(2));
      expect(page.gifs.first.url, 'https://k.co/a/hd.gif');
      expect(page.gifs.first.preview, 'https://k.co/a/md.gif');
      expect(page.gifs.first.desc, 'dice roll');
      // No gif variant anywhere: an animated webp is still sendable.
      expect(page.gifs[1].url, 'https://k.co/b/hd.webp');
      expect(page.gifs[1].desc, isEmpty);
      // Klipy pages are 1-based: this answered page 1 of a has_next body.
      expect(page.nextCursor, '2');
    });

    test('clip items carry their flat gif url as both preview and payload', () {
      final page = parseKlipyResponse(_sampleKlipyClip);
      expect(page.gifs.single.url, 'https://k.co/c/clip.gif');
      expect(page.gifs.single.preview, 'https://k.co/c/clip.gif');
      expect(page.nextCursor, isNull,
          reason: 'has_next: false means the grid ends here');
    });

    test('an empty upstream page produces an empty grid and no cursor', () {
      final page = parseKlipyResponse('{"result": true, "data": {"data": []}}');
      expect(page.gifs, isEmpty);
      expect(page.nextCursor, isNull);
    });
  });

  group('parseGiphyResponse', () {
    test('normalizes images into url/preview/desc with the offset cursor',
        () {
      final page = parseGiphyResponse(_sampleGiphyBody);
      expect(page.gifs.first.url, 'https://media.giphy.com/g1/downsized.gif');
      expect(page.gifs.first.preview, 'https://media.giphy.com/g1/small.gif');
      expect(page.gifs.first.desc, 'hi');
      // No small variant: the downsized url doubles as the preview.
      expect(page.gifs.last.preview, 'https://media.giphy.com/g2/g.gif');
      // 0 + 2 < 14 — rebuild the cursor: the next offset.
      expect(page.nextCursor, '2');
    });

    test('a last page has no cursor', () {
      final page = parseGiphyResponse(
        '{"data": [{"id": "g", "images": {"downsized": {"url": "https://giphy.com/g.gif"}}}],'
        '"pagination": {"count": 1, "offset": 13, "total_count": 14}}',
      );
      expect(page.gifs.single.url, 'https://giphy.com/g.gif');
      expect(page.nextCursor, isNull);
    });
  });

  group('selectGifProvider', () {
    test('keys win in order: klipy first, giphy behind it', () {
      final a = selectGifProvider(klipyKey: 'k', giphyKey: 'g', preferred: '');
      expect(a, isA<KlipyProvider>());
      expect(a!.name, 'KLIPY');
      final b = selectGifProvider(klipyKey: '', giphyKey: 'g', preferred: '');
      expect(b, isA<GiphyProvider>());
      expect(b!.name, 'GIPHY');
    });

    test('GIF_PROVIDER pins one provider above the default order', () {
      final pinned = selectGifProvider(
        klipyKey: 'k',
        giphyKey: 'g',
        preferred: 'giphy',
      );
      expect(pinned, isA<GiphyProvider>());
    });

    test('a pinned provider without its key is no provider at all', () {
      final none = selectGifProvider(
        klipyKey: 'k',
        giphyKey: '',
        preferred: 'giphy',
      );
      expect(none, isNull,
          reason: 'silently falling back would serve a provider the operator '
              'did not ask for');
    });

    test('no keys anywhere is a null the handler turns into 503', () {
      expect(
        selectGifProvider(klipyKey: '', giphyKey: '', preferred: ''),
        isNull,
      );
    });
  });

  group('gifSearchHandler', () {
    test('without a provider it is a 503 naming the fallback path', () async {
      final res = await gifSearchHandler(
        _req({'q': 'dice'}),
        provider: null,
      );
      expect(res.statusCode, 503);
      final body = jsonDecode(await res.readAsString()) as Map<String, dynamic>;
      expect(body['ok'], isFalse);
      expect((body['text'] as String).contains('image link'), isTrue,
          reason: 'the message names the paste-a-link fallback');
    });

    test('relays a search with the key server-side, cursor passthrough', () async {
      late Uri requested;
      final res = await gifSearchHandler(
        _req({'q': 'dice roll', 'pos': '3'}),
        provider: KlipyProvider(
          apiKey: 'secret',
          client: MockClient((req) async {
            requested = req.url;
            return _res(200, _sampleKlipyBody);
          }),
        ),
      );
      expect(res.statusCode, 200);
      // The key never leaves the origin hop — but it does go to Klipy,
      // in their path convention.
      expect(requested.host, 'api.klipy.com');
      expect(requested.pathSegments.last, 'search');
      expect(requested.pathSegments.contains('secret'), isTrue);
      expect(requested.queryParameters['q'], 'dice roll');
      expect(requested.queryParameters['page'], '3');

      final body = jsonDecode(await res.readAsString()) as Map<String, dynamic>;
      expect(body['ok'], isTrue);
      expect(body['provider'], 'KLIPY');
      expect(body['gifs'], hasLength(2));
      expect(body['next'], '2');
      final gif = (body['gifs'] as List).first as Map<String, dynamic>;
      expect(gif['url'], isA<String>());
      expect(gif['preview'], isA<String>());
      expect(gif['desc'], 'dice roll');
    });

    test('an empty q is trending, not an error', () async {
      late Uri requested;
      final res = await gifSearchHandler(
        _req({}),
        provider: KlipyProvider(
          apiKey: 'secret',
          client: MockClient((req) async {
            requested = req.url;
            return _res(200, _sampleKlipyBody);
          }),
        ),
      );
      expect(res.statusCode, 200);
      expect(requested.queryParameters.containsKey('q'), isFalse);
      expect(requested.pathSegments.last, 'trending');
    });

    test('a too-long q is a 400 with no upstream call', () async {
      var dialed = 0;
      final res = await gifSearchHandler(
        _req({'q': 'x' * 61}),
        provider: KlipyProvider(
          apiKey: 'k',
          client: MockClient((_) async {
            dialed++;
            return _res(200, '{"result":true,"data":{"data":[]}}');
          }),
        ),
      );
      expect(res.statusCode, 400);
      expect(dialed, 0);
    });

    test('an upstream failure is a 502 the picker can fall back from',
        () async {
      final res = await gifSearchHandler(
        _req({'q': 'dice'}),
        provider: GiphyProvider(
          apiKey: 'k',
          client: MockClient((_) async => _res(403, 'permission denied')),
        ),
      );
      expect(res.statusCode, 502);
      final body = jsonDecode(await res.readAsString()) as Map<String, dynamic>;
      expect(body['ok'], isFalse);
    });

    test('the old /media/tenor path works as the same handler', () async {
      final res = await gifSearchHandler(
        _req({'q': 'dice'}, path: '/media/tenor'),
        provider: null,
      );
      expect(res.statusCode, 503,
          reason: 'the alias routes verbatim — same 503 without a key');
    });
  });

  group('searchGifsPage (client side)', () {
    test('asks the http origin, not the websocket scheme', () async {
      List<Uri> asked = [];
      final page = await searchGifsPage(
        'wss://game.example/ws',
        'ludo',
        pos: '2',
        httpClient: MockClient((req) async {
          asked = [req.url];
          return _res(
            200,
            jsonEncode({
              'ok': true,
              'provider': 'KLIPY',
              'gifs': [
                for (final r in parseKlipyResponse(_sampleKlipyBody).gifs)
                  {'url': r.url, 'preview': r.preview, 'desc': r.desc},
              ],
              'next': '2',
            }),
          );
        }),
      );
      expect(asked.single.host, 'game.example');
      expect(asked.single.scheme, 'https');
      expect(asked.single.path, '/media/gif');
      expect(asked.single.queryParameters, {'q': 'ludo', 'pos': '2'});
      expect(page.gifs, hasLength(2));
      expect(page.gifs.first.url, 'https://k.co/a/hd.gif');
      expect(page.next, '2');
      expect(page.provider, 'KLIPY');
    });

    test('an empty query omits q, so the server trends', () async {
      List<Uri> asked = [];
      await searchGifsPage(
        'wss://game.example/ws',
        '',
        httpClient: MockClient((req) async {
          asked = [req.url];
          return _res(200, '{"ok":true,"gifs":[]}');
        }),
      );
      expect(asked.single.queryParameters.containsKey('q'), isFalse);
    });

    test('a 503 becomes the typed exception the picker reads', () async {
      await expectLater(
        searchGifsPage(
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

    test('a 502 carries its player-facing text too', () async {
      await expectLater(
        searchGifsPage(
          'ws://localhost:8080/ws',
          'ludo',
          httpClient: MockClient(
            (_) async => _res(502, '{"ok":false,"text":"unavailable now"}'),
          ),
        ),
        throwsA(
          isA<GifSearchException>().having((e) => e.text, 'text', 'unavailable now'),
        ),
      );
    });
  });
}
