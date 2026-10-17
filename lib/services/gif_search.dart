/// GIF picking for table chat.
///
/// [searchGifsPage] talks to the game server's `/media/gif` endpoint
/// (same origin the leaderboard uses) rather than to a GIF API directly:
/// the API key only ever exists on the server, and a picker that
/// degrades to paste-a-link still works on servers without one. One item
/// is what a chat line carries — the inline preview URL for the grid and
/// the full-resolution URL for the message itself.
///
/// The endpoint is provider-neutral (Klipy today, GIPHY or strangers
/// tomorrow behind the same shape — see `lib/server/gif.dart`): the page
/// result carries the provider's name for attribution and an opaque
/// pagination cursor for the next call.
library;

import 'dart:convert';

import 'package:http/http.dart' as http;

class GifItem {
  const GifItem({
    required this.url,
    required this.preview,
    required this.desc,
  });

  factory GifItem.fromJson(Map<String, dynamic> j) => GifItem(
    url: j['url'] as String,
    preview: j['preview'] as String? ?? j['url'] as String,
    desc: j['desc'] as String? ?? '',
  );

  /// The full GIF, sent as the message.
  final String url;

  /// Small animated frame shown in the search grid.
  final String preview;

  /// The provider's caption, shown under the tile in the grid.
  final String desc;
}

/// One search (or trending) page plus the cursor for the next one.
class GifSearchPage {
  const GifSearchPage(this.gifs, {this.next, this.provider = ''});

  final List<GifItem> gifs;

  /// Opaque pagination cursor; null when the provider has no more
  /// pages, so the picker retires its load-more affordance.
  final String? next;

  /// The provider behind this page's results ("KLIPY"…) — shown as the
  /// attribution line the providers require.
  final String provider;
}

class GifSearchException implements Exception {
  GifSearchException(this.text);
  final String text;

  @override
  String toString() => text;
}

/// Searches the server's GIF proxy. An empty [query] is legitimate: the
/// provider's trending feed fills the picker's first screen.
Future<GifSearchPage> searchGifsPage(
  String serverUrl,
  String query, {
  String? pos,
  http.Client? httpClient,
  Duration timeout = const Duration(seconds: 10),
}) async {
  final ws = Uri.parse(serverUrl);
  final uri = ws.replace(
    scheme: ws.scheme == 'wss' ? 'https' : 'http',
    path: '/media/gif',
    queryParameters: {
      if (query.isNotEmpty) 'q': query,
      if (pos != null && pos.isNotEmpty) 'pos': pos,
    },
  );
  final client = httpClient ?? http.Client();
  try {
    final res = await client.get(uri).timeout(timeout);
    if (res.statusCode != 200) {
      // 503 (no provider configured) and 502 (provider hiccup) both
      // carry a player-facing text: the fallback is paste-a-link, and
      // the sheet spells out why.
      throw GifSearchException(
        _textFromBody(res.body) ?? 'GIF search failed (${res.statusCode})',
      );
    }
    final root = jsonDecode(res.body) as Map<String, dynamic>;
    return GifSearchPage(
      [
        for (final g in (root['gifs'] as List? ?? []))
          GifItem.fromJson((g as Map).cast<String, dynamic>()),
      ],
      next: root['next'] as String?,
      provider: root['provider'] as String? ?? '',
    );
  } finally {
    if (httpClient == null) client.close();
  }
}

String? _textFromBody(String body) {
  try {
    return (jsonDecode(body) as Map)['text'] as String?;
  } catch (_) {
    return null;
  }
}
