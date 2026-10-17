/// GIF search for table chat — provider-neutral, proxied through the
/// game server.
///
/// The short version of why the server is in the middle: a GIF API needs
/// a key, and a key baked into a web build is *published* — anyone
/// reading the JS bundle gets it. So the key lives in the server's
/// environment only, the client asks this server's `/media/gif`
/// endpoint, and blank results or a 503 there are not errors to a player
/// without a key: the GIF picker then offers the paste-a-link path
/// instead.
///
/// **Why a provider layer, not a hard-wired service.** Tenor's free API
/// was shut down by Google on 2026-06-30, and projects that had wired
/// Tenor names into every layer were stuck rewriting everything. The
/// wire format the client sees (`{ok, gifs, next, provider}`) is neutral
/// and pinned by tests; a provider is one class in [providersByEnv] —
/// adding a provider means adding a class + an env-key entry, nothing
/// else. Klipy ships first (lifetime-free, built by Tenor's own
/// founders, with a Tenor migration guide); GIPHY rides behind it
/// (beta keys are free but rate-capped per hour) so the switch is an env
/// flip, not a rewrite.
///
/// No caching yet: a chat GIF search is small enough to stay well inside
/// the free tiers, and a wrong cached page is worse than a
/// slightly-delayed one.
library;

import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:shelf/shelf.dart' as shelf;

/// One GIF item the client gets. Only what the picker needs: the inline
/// preview URL for the grid, the full-resolution URL for the message.
typedef GifResult = ({String url, String preview, String desc});

/// One page of provider results in the provider's own chat-open terms.
/// [nextCursor] is opaque state for the client's `pos=` — pages are
/// numbered for Klipy, absolute offsets for GIPHY.
class GifPage {
  const GifPage(this.gifs, {this.nextCursor});

  final List<GifResult> gifs;

  /// Non-null when the provider says more pages exist.
  final String? nextCursor;
}

/// An upstream call failed — status and reason go to the handler for the
/// player-facing message, never to the client as an HTML error page.
class GifFetchException implements Exception {
  GifFetchException(this.status, this.reason);

  final int? status;
  final String? reason;

  @override
  String toString() =>
      'GIF provider ${status == null ? 'unreachable' : 'HTTP $status'}: '
      '${reason ?? 'no reason given'}';
}

/// The seam each family sits behind. A cursor is opaque on this side:
/// the handler stores it from the client's `pos=` and hands it back
/// untouched next query.
abstract class GifProvider {
  /// Short identifier the picker can attribute ("Powered by …").
  String get name;

  Future<GifPage> search(String query, {String? cursor});
  Future<GifPage> trending({String? cursor});
}

// ─── KLIPY ────────────────────────────────────────────────────────────

/// Klipy (api.klipy.com): the key is part of the URL *path*
/// (`/api/v1/<key>/gifs/...`), pages are 1-based, and one page is
/// `{result, data: {data: [...], has_next}}`. Items come in four shapes —
/// gif/sticker (`file.<size>.<format>`), clip (top-level
/// `file.gif`), and ad (`type: "ad"`, which we drop: the chat has no
/// monetization lane). Size buckets are fixed: `hd` → `md` → `sm` →
/// `xs`; their own demo shares `hd|md|sm` and previews from `md|xs`.
class KlipyProvider implements GifProvider {
  KlipyProvider({required this.apiKey, http.Client? client})
    : _client = client ?? http.Client();

  final String apiKey;
  final http.Client _client;

  @override
  String get name => 'KLIPY';

  Future<http.Response> _get(String kind, String? query, String? cursor) =>
      _client
          .get(
            Uri.https('api.klipy.com', 'api/v1/$apiKey/$kind', {
              'q': ?query,
              'page': '${(int.tryParse(cursor ?? '') ?? 1).clamp(1, 999)}',
              'per_page': '12',
            }),
          )
          .timeout(const Duration(seconds: 10));

  @override
  Future<GifPage> search(String query, {String? cursor}) async {
    final res = await _get('gifs/search', query, cursor);
    if (res.statusCode != 200) {
      throw GifFetchException(res.statusCode, res.reasonPhrase);
    }
    return parseKlipyResponse(res.body);
  }

  @override
  Future<GifPage> trending({String? cursor}) async {
    final res = await _get('gifs/trending', null, cursor);
    if (res.statusCode != 200) {
      throw GifFetchException(res.statusCode, res.reasonPhrase);
    }
    return parseKlipyResponse(res.body);
  }
}

/// Parses a Klipy search/trending body into the neutral [GifPage]. The
/// page is 1-based (`[page]` is the page this body answers) and the
/// cursor is simply the next page number. Public because the upstream
/// shape is the one thing in this stack tests can pin without talking to
/// Klipy.
GifPage parseKlipyResponse(String raw, {int page = 1}) {
  final root = jsonDecode(raw) as Map<String, dynamic>;
  final pageBody = root['data'] as Map<String, dynamic>? ?? const {};
  final items = (pageBody['data'] as List? ?? []).cast<Map<String, dynamic>>();

  final gifs = <GifResult>[];
  for (final item in items) {
    final r = _klipyItem(item);
    if (r != null) gifs.add(r);
  }
  return GifPage(
    gifs,
    nextCursor: (pageBody['has_next'] == true && gifs.isNotEmpty)
        ? '${page + 1}'
        : null,
  );
}

GifResult? _klipyItem(Map<String, dynamic> item) {
  final type = item['type'] as String? ?? '';
  if (type == 'ad') return null;

  // Clip items carry flat url strings; gif/sticker items carry nested
  // size buckets.
  if (type == 'clip') {
    final url = (item['file'] as Map? ?? const {})['gif'] as String?;
    return url == null || url.isEmpty
        ? null
        : (url: url, preview: url, desc: item['title'] as String? ?? '');
  }

  final file = (item['file'] as Map? ?? const {}).cast<String, dynamic>();
  String? pick(String bucket, String format) =>
      ((file[bucket] as Map? ?? const {})[format] as Map?)?['url'] as String?;

  // Full resolution for a chat bubble: their demo's "high def" chain.
  final url = _firstUrl(
    [
      ('hd', 'gif'),
      ('md', 'gif'),
      ('sm', 'gif'),
      ('hd', 'webp'),
      ('md', 'webp'),
    ].map((b) => () => pick(b.$1, b.$2)),
  );
  // Clips aside, an item with no animated variant is not sendable.
  if (url == null) return null;

  // A light frame for the grid: their demo's "low quality" chain.
  final preview =
      _firstUrl(
          [
            ('md', 'gif'),
            ('xs', 'gif'),
            ('sm', 'gif'),
          ].map((b) => () => pick(b.$1, b.$2)),
        ) ??
      url;
  return (
    url: url,
    preview: preview,
    desc: item['title'] as String? ?? '',
  );
}

String? _firstUrl(Iterable<String? Function()> probes) {
  for (final p in probes) {
    final url = p();
    if (url != null && url.isNotEmpty) return url;
  }
  return null;
}

// ─── GIPHY ────────────────────────────────────────────────────────────

/// GIPHY: the key rides in the query string, searches take an integer
/// `offset`, and a page is `{data: [...], pagination: {...}}`. Public
/// `images.downsized_*` urls are permanent; `fixed_width_small` is their
/// cheap animated preview.
class GiphyProvider implements GifProvider {
  GiphyProvider({required this.apiKey, http.Client? client})
    : _client = client ?? http.Client();

  final String apiKey;
  final http.Client _client;

  static const _limit = '12';

  @override
  String get name => 'GIPHY';

  Uri _uri(String path, Map<String, String> extra) => Uri.https(
    'api.giphy.com',
    path,
    {...extra, 'api_key': apiKey, 'limit': _limit, 'rating': 'pg-13'},
  );

  @override
  Future<GifPage> search(String query, {String? cursor}) async {
    final res = await _client
        .get(
          _uri('v1/gifs/search', {
            'q': query,
            'offset': '${int.tryParse(cursor ?? '') ?? 0}',
          }),
        )
        .timeout(const Duration(seconds: 10));
    if (res.statusCode != 200) {
      throw GifFetchException(res.statusCode, res.reasonPhrase);
    }
    return parseGiphyResponse(res.body);
  }

  @override
  Future<GifPage> trending({String? cursor}) async {
    final res = await _client
        .get(_uri('v1/gifs/trending', {}))
        .timeout(const Duration(seconds: 10));
    if (res.statusCode != 200) {
      throw GifFetchException(res.statusCode, res.reasonPhrase);
    }
    return parseGiphyResponse(res.body);
  }
}

/// Parses a GIPHY search/trending body into the neutral [GifPage].
GifPage parseGiphyResponse(String raw) {
  final root = jsonDecode(raw) as Map<String, dynamic>;
  final items = (root['data'] as List? ?? []).cast<Map<String, dynamic>>();

  final gifs = <GifResult>[];
  for (final item in items) {
    final images = (item['images'] as Map? ?? const {});
    final url =
        ((images['downsized_medium'] ?? images['downsized']) as Map?)?['url']
            as String?;
    final rawPreview = images['fixed_width_small'] as Map?;
    final preview =
        rawPreview?['url'] as String? ??
        ((images['downsized'] as Map?)?['url'] as String?);
    if (url == null || url.isEmpty) continue;
    gifs.add((
      url: url,
      preview: preview ?? url,
      desc: item['title'] as String? ?? '',
    ));
  }

  // GIPHY expresses pagination as offset+count against total, not as a
  // cursor: rebuild the next call's absolute offset locally.
  final pagination = root['pagination'] as Map? ?? const {};
  final count = pagination['count'] as int? ?? gifs.length;
  final offset = pagination['offset'] as int? ?? 0;
  final total = pagination['total_count'] as int? ?? 0;
  return GifPage(
    gifs,
    nextCursor:
        (total > 0 && (offset + count) < total) ? '${offset + count}' : null,
  );
}

// ─── Selection ────────────────────────────────────────────────────────

/// Builds the provider the environment asks for. `GIF_PROVIDER=klipy|giphy`
/// pins one explicitly: a pin without its key is **no provider** —
/// silently serving a different provider than the operator asked for
/// would pretend a configuration exists that does not. Without a pin the
/// first key present wins, Klipy by default, GIPHY for servers that only
/// ever obtained one of those.
GifProvider? selectGifProvider({
  required String klipyKey,
  required String giphyKey,
  required String preferred,
}) {
  final wanted = preferred.trim().toLowerCase();
  if (wanted == 'klipy') {
    return klipyKey.isNotEmpty ? KlipyProvider(apiKey: klipyKey) : null;
  }
  if (wanted == 'giphy') {
    return giphyKey.isNotEmpty ? GiphyProvider(apiKey: giphyKey) : null;
  }
  if (klipyKey.isNotEmpty) return KlipyProvider(apiKey: klipyKey);
  if (giphyKey.isNotEmpty) return GiphyProvider(apiKey: giphyKey);
  return null;
}

// ─── Handler ──────────────────────────────────────────────────────────

/// GET /media/gif?q=apple&pos=2 — a neutral search across whatever the
/// server configured. An empty `q` is legitimate: the provider's
/// trending feed fills the picker's first screen, so an empty state is a
/// designed one instead of a dead prompt. `/media/tenor` is aliased onto
/// this handler for already-shipped clients, whose picker still points
/// at the old name.
Future<shelf.Response> gifSearchHandler(
  shelf.Request req, {
  required GifProvider? provider,
}) async {
  shelf.Response json(int code, Map<String, dynamic> body) => shelf.Response(
    code,
    body: jsonEncode(body),
    headers: {'content-type': 'application/json'},
  );

  final providerName = provider?.name ?? 'GIF search';
  if (provider == null) {
    // Config absence is a feature, not an outage: the picker falls back
    // to paste-a-link, which needs no key at all.
    return json(503, {
      'ok': false,
      'text': 'GIF search is not configured on this server — paste an '
          'image link instead',
    });
  }

  final query = (req.url.queryParameters['q'] ?? '').trim();
  if (query.isNotEmpty && query.length > 60) {
    return json(400, {
      'ok': false,
      'text': 'a search term of 1..60 characters is required',
    });
  }
  final cursor = req.url.queryParameters['pos'];

  try {
    final page = query.isEmpty
        ? await provider.trending(cursor: cursor)
        : await provider.search(query, cursor: cursor);
    return json(200, {
      'ok': true,
      'provider': providerName,
      'gifs': [
        for (final r in page.gifs)
          {'url': r.url, 'preview': r.preview, 'desc': r.desc},
      ],
      // The cursor rides through opaquely — the client stores it and
      // repeats it verbatim for the next page.
      if (page.nextCursor != null) 'next': page.nextCursor!,
    });
  } on GifFetchException catch (e) {
    return json(502, {
      'ok': false,
      'text': 'GIF search unavailable right now ($e)',
    });
  } catch (_) {
    return json(502, {'ok': false, 'text': 'GIF search could not be reached'});
  }
}
