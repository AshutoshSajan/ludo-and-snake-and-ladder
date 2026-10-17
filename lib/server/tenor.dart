/// GIF search for table chat, proxied through the game server.
///
/// The short version of why the server is in the middle: Tenor's API needs a
/// key, and a key baked into a web build is *published* — anyone reading the
/// JS bundle gets it. So the key lives in the server's environment only, the
/// client asks this server's `/media/tenor` endpoint, and blank results or a
/// 503 there are not errors to a player without a key: the GIF picker then
/// offers the paste-a-link path instead.
///
/// No caching yet: a chat GIF search is small enough to stay well inside the
/// free tier, and a wrong cached page is worse than a slightly-delayed one.
library;

import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:shelf/shelf.dart' as shelf;

/// The Tenor descriptors the client gets. Only what the picker needs.
typedef GifResult = ({String url, String preview, String desc});

/// Parses a Tenor v2 search response into the server's normalized JSON:
/// `{ok: true, gifs: [{url, preview, desc}], next: ?}`. Public because the
/// upstream shape is the one thingTypeId in this stack tests can pin without
/// talking to Tenor.
Map<String, dynamic> parseTenorResponse(String raw) {
  final root = jsonDecode(raw) as Map<String, dynamic>;
  final results = (root['results'] as List? ?? []).cast<Map<String, dynamic>>();

  final gifs = <Map<String, dynamic>>[];
  for (final r in results) {
    final formats = (r['media_formats'] as Map? ?? const {}).cast<String,
        dynamic>();
    final gif = formats['gif'] as Map? ?? const {};
    final url = gif['url'] as String?;
    if (url == null || url.isEmpty) continue;
    final tiny = formats['tinygif'] as Map? ?? const {};
    gifs.add({
      'url': url,
      'preview': tiny['url'] as String? ?? url,
      'desc': r['content_description'] as String? ?? '',
    });
  }
  final next = root['next'] as String?;
  return {
    'ok': true,
    'gifs': gifs,
    if (next != null && next.isNotEmpty) 'next': next,
  };
}

/// GET /media/tenor?q=apple&pos=... — proxies Tenor v2 search.
Future<shelf.Response> tenorHandler(
  shelf.Request req, {
  required String? apiKey,
  required http.Client client,
}) async {
  shelf.Response json(int code, Map<String, dynamic> body) => shelf.Response(
    code,
    body: jsonEncode(body),
    headers: {'content-type': 'application/json'},
  );

  if (apiKey == null || apiKey.isEmpty) {
    // Config absence is a feature, not an outage: the picker falls back
    // to paste-a-link, which needs no key at all.
    return json(503, {
      'ok': false,
      'text': 'GIF search is not configured on this server — paste an '
          'image link instead',
    });
  }

  final query = (req.url.queryParameters['q'] ?? '').trim();
  if (query.isEmpty || query.length > 60) {
    return json(400, {
      'ok': false,
      'text': 'a search term of 1..60 characters is required',
    });
  }
  final pos = (req.url.queryParameters['pos'] ?? '').trim();

  final uri = Uri.https('g.tenor.com', 'v2/search', {
    'q': query,
    'key': apiKey,
    'client_key': 'game-club',
    'limit': '12',
    'rating': 'pg-13',
    'media_filter': 'gif,tinygif',
    if (pos.isNotEmpty) 'pos': pos,
  });

  try {
    final res = await client.get(uri).timeout(const Duration(seconds: 10));
    if (res.statusCode != 200) {
      // Upstream trouble is handed to the client as JSON — the CORS/JSON
      // middlewares already wrap plain shelf.Response codes everywhere.
      return json(502, {
        'ok': false,
        'text': 'GIF search unavailable right now (Tenor ${res.statusCode})',
      });
    }
    return json(200, parseTenorResponse(res.body));
  } catch (_) {
    return json(502, {'ok': false, 'text': 'GIF search could not be reached'});
  }
}
