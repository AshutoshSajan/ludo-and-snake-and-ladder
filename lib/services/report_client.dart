/// HTTP client for the public report endpoint (`POST /feedback`).
///
/// Unauthenticated by design — every player can report a bug — the
/// server throttles per IP and validates strictly. The admin side of the
/// same queue lives in `admin_client.dart`.
library;

import 'dart:convert';

import 'package:http/http.dart' as http;

class ReportException implements Exception {
  ReportException(this.text);

  final String text;

  @override
  String toString() => text;
}

class ReportClient {
  ReportClient({required this.serverUrl, http.Client? httpClient})
    : _client = httpClient ?? http.Client(),
      _ownsClient = httpClient == null;

  /// Same-origin game server URL (ws(s)://host/ws form, as everywhere).
  final String serverUrl;
  final http.Client _client;
  final bool _ownsClient;

  /// Files one report. Returns the server-assigned row id. Throws
  /// [ReportException] with a user-presentable message on any failure.
  Future<int> submit({
    required String category,
    required String message,
    String source = 'report',
    String? title,
    String? contact,
    String? gameId,
    String? seatId,
  }) async {
    final uri = Uri.parse(serverUrl).replace(
      scheme: Uri.parse(serverUrl).scheme == 'wss' ? 'https' : 'http',
      path: '/feedback',
    );
    final resp = await _client.post(
      uri,
      headers: {'content-type': 'application/json'},
      body: jsonEncode({
        'category': category,
        'source': source,
        'title': title,
        'message': message,
        'contact': contact,
        'gameId': gameId,
        'seatId': seatId,
      }),
    );
    if (resp.statusCode != 200) {
      String text = 'Could not send your report (${resp.statusCode})';
      try {
        final body = jsonDecode(resp.body) as Map<String, dynamic>;
        if (body['text'] is String) text = body['text'] as String;
      } catch (_) {}
      throw ReportException(text);
    }
    final body = jsonDecode(resp.body) as Map<String, dynamic>;
    return (body['id'] as num?)?.toInt() ?? -1;
  }

  void close() {
    if (_ownsClient) _client.close();
  }
}
