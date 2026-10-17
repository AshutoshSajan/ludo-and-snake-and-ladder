/// GIF picking for table chat.
///
/// [search] talks to the game server's `/media/tenor` endpoint (same origin
/// the leaderboard uses) rather than to Tenor directly: the API key only
/// ever exists on the server, and a picker that degrades to paste-a-link
/// still works on servers without one. One GIF item is what a chat line
/// carries — the inline preview URL for the grid and the full-resolution
/// URL for the message itself.
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

  /// Small static/still frame shown in the search grid.
  final String preview;

  /// Tenor's description, shown as a caption in the grid.
  final String desc;
}

class GifSearchException implements Exception {
  GifSearchException(this.text);
  final String text;

  @override
  String toString() => text;
}

Future<List<GifItem>> searchGifs(
  String serverUrl,
  String query, {
  String? pos,
  http.Client? httpClient,
  Duration timeout = const Duration(seconds: 10),
}) async {
  final ws = Uri.parse(serverUrl);
  final uri = ws.replace(
    scheme: ws.scheme == 'wss' ? 'https' : 'http',
    path: '/media/tenor',
    queryParameters: {
      'q': query,
      if (pos != null && pos.isNotEmpty) 'pos': pos,
    },
  );
  final client = httpClient ?? http.Client();
  try {
    final res = await client.get(uri).timeout(timeout);
    if (res.statusCode == 503) {
      // The server says search is not configured — that is the fallback
      // path, surfaced as a typed state rather than a generic failure.
      throw GifSearchException(_textFromBody(res.body));
    }
    if (res.statusCode != 200) {
      throw GifSearchException('GIF search failed (${res.statusCode})');
    }
    final root = jsonDecode(res.body) as Map<String, dynamic>;
    return [
      for (final g in (root['gifs'] as List? ?? []))
        GifItem.fromJson((g as Map).cast<String, dynamic>()),
    ];
  } finally {
    if (httpClient == null) client.close();
  }
}

String _textFromBody(String body) {
  try {
    return (jsonDecode(body) as Map)['text'] as String? ?? 'GIF search failed';
  } catch (_) {
    return 'GIF search failed';
  }
}
