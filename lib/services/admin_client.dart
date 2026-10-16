/// HTTP client for the admin API (`/admin/*` on `bin/server.dart`).
///
/// Same-origin as the game client: pass the WebSocket URL and the matching
/// http(s) origin is derived, mirroring `OnlineClient.fetchLeaderboard`.
library;

import 'dart:convert';

import 'package:http/http.dart' as http;

class AdminException implements Exception {
  AdminException(this.statusCode, this.body);

  final int statusCode;
  final String body;

  @override
  String toString() => 'Admin request failed (HTTP $statusCode)';
}

class AdminClient {
  AdminClient({
    required this.serverUrl,
    this.token,
    http.Client? httpClient,
  }) : _client = httpClient ?? http.Client(),
       _ownsClient = httpClient == null;

  final String serverUrl;

  /// Session token (or legacy ADMIN_TOKEN). Mutable: set after login.
  String? token;
  final http.Client _client;
  final bool _ownsClient;

  Map<String, String> get _headers => {
    if (token != null && token!.isNotEmpty) 'authorization': 'Bearer $token',
    'content-type': 'application/json',
  };

  Uri _uri(String path, [Map<String, String>? query]) {
    final ws = Uri.parse(serverUrl);
    return ws.replace(
      scheme: ws.scheme == 'wss' ? 'https' : 'http',
      path: path,
      queryParameters: query,
    );
  }

  Future<Map<String, dynamic>> _get(String path) async {
    final resp = await _client.get(_uri(path), headers: _headers);
    if (resp.statusCode != 200) {
      throw AdminException(resp.statusCode, resp.body);
    }
    return jsonDecode(resp.body) as Map<String, dynamic>;
  }

  Future<Map<String, dynamic>> _post(
    String path, [
    Map<String, dynamic>? body,
  ]) async {
    final resp = await _client.post(
      _uri(path),
      headers: _headers,
      body: jsonEncode(body ?? const {}),
    );
    if (resp.statusCode != 200) {
      throw AdminException(resp.statusCode, resp.body);
    }
    return jsonDecode(resp.body) as Map<String, dynamic>;
  }

  Future<Map<String, dynamic>> overview() => _get('/admin/overview');

  Future<Map<String, dynamic>> status() => _get('/admin/status');

  Future<Map<String, dynamic>> me() => _get('/admin/me');

  /// First-run bootstrap. Returns {token, expiresAt, user}; sets [token].
  Future<Map<String, dynamic>> setup({
    required String email,
    required String password,
    String name = '',
    String? setupToken,
  }) async {
    final out = await _post('/admin/setup', {
      'email': email,
      'password': password,
      'name': name,
      if (setupToken != null && setupToken.isNotEmpty)
        'setupToken': setupToken,
    });
    token = out['token'] as String?;
    return out;
  }

  /// Email+password login. Returns {token, expiresAt, user}; sets [token].
  Future<Map<String, dynamic>> login({
    required String email,
    required String password,
  }) async {
    final out = await _post('/admin/login', {
      'email': email,
      'password': password,
    });
    token = out['token'] as String?;
    return out;
  }

  Future<void> logout() async {
    try {
      await _post('/admin/logout', const {});
    } finally {
      token = null;
    }
  }

  Future<Map<String, dynamic>> users() => _get('/admin/users');

  Future<Map<String, dynamic>> createUser({
    required String email,
    required String password,
    String name = '',
    String role = 'user',
  }) => _post('/admin/users', {
    'email': email,
    'password': password,
    'name': name,
    'role': role,
  });

  Future<Map<String, dynamic>> players({int limit = 100}) =>
      _get('/admin/players');

  Future<Map<String, dynamic>> rooms({int limit = 50}) =>
      _get('/admin/rooms');

  Future<Map<String, dynamic>> audit({int limit = 50}) =>
      _get('/admin/audit');

  Future<void> ban(String seatId, {String reason = 'banned', int? untilMs}) =>
      _post('/admin/ban', {
        'seatId': seatId,
        'reason': reason,
        'untilMs': ?untilMs,
      });

  Future<void> unban(String seatId) =>
      _post('/admin/unban', {'seatId': seatId});

  Future<void> rename(String seatId, String name) =>
      _post('/admin/rename', {'seatId': seatId, 'name': name});

  Future<void> deleteGame(String gameId) =>
      _post('/admin/delete-game', {'gameId': gameId});

  Future<void> closeRoom(String code) =>
      _post('/admin/rooms/close', {'code': code});

  void close() {
    if (_ownsClient) _client.close();
  }
}
