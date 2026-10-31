/// HTTP client for the admin API (`/admin/*` on `bin/server.dart`).
///
/// Same-origin as the game client (`/admin` is only registered on http(s)
/// origins), so the admin session is browser-managed: login/setup answer
/// with an HttpOnly `Set-Cookie` (see [sessionCookieHeader] server-side)
/// and the browser stores, attaches and expires the cookie itself — no
/// token is ever held in script-reachable memory.
///
/// Native targets (reachable through widget tests and the compiled screens)
/// have no browser to manage the cookie, so the client captures the
/// `Set-Cookie` header when one is visible and replays it as a `Cookie`
/// header in memory only. On the web the header is invisible, capture
/// stays null, and the transport is entirely the browser's.
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
    http.Client? httpClient,
  }) : _client = httpClient ?? http.Client(),
       _ownsClient = httpClient == null;

  final String serverUrl;

  /// The captured session cookie (`gc_admin_session=...` plus attributes
  /// trimmed off), when a `Set-Cookie` header was observable. Null on web —
  /// and null everywhere before login. Never persisted anywhere.
  String? _sessionCookie;
  final http.Client _client;
  final bool _ownsClient;

  Map<String, String> get _headers => {
    'content-type': 'application/json',
    'cookie': ?_sessionCookie,
  };

  Uri _uri(String path, [Map<String, String>? query]) {
    final ws = Uri.parse(serverUrl);
    return ws.replace(
      scheme: ws.scheme == 'wss' ? 'https' : 'http',
      path: path,
      queryParameters: query,
    );
  }

  /// Lifts the usable `name=value` pair out of a Set-Cookie header when one
  /// is observable (native targets). Silver bullet not required: the
  /// browser path never sees the header, and this replay exists only so
  /// non-web targets touch the same API. An empty pair (the logout header
  /// clears the cookie with null value) is ignored, never captured.
  void _captureFrom(http.Response resp) {
    final raw = resp.headers['set-cookie'];
    if (raw == null || raw.isEmpty) return;
    final pair = raw.split(';').first;
    if (pair.contains('=') && pair.split('=')[1].trim().isNotEmpty) {
      _sessionCookie = pair;
    }
  }

  /// A `{ok, text}`-shaped admin failure.
  AdminException _fail(http.Response resp) =>
      AdminException(resp.statusCode, resp.body);

  Future<Map<String, dynamic>> _get(
    String path, [
    Map<String, String>? query,
  ]) async {
    final resp = await _client.get(_uri(path, query), headers: _headers);
    if (resp.statusCode != 200) throw _fail(resp);
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
    if (resp.statusCode != 200) throw _fail(resp);
    // Only an auth-minting response carries a fresh Set-Cookie; other POSTs
    // answer without one, and this stays a no-op there. The logout header
    // clears the cookie, which also captures as nothing.
    _captureFrom(resp);
    return jsonDecode(resp.body) as Map<String, dynamic>;
  }

  Future<Map<String, dynamic>> overview() => _get('/admin/overview');

  Future<Map<String, dynamic>> status() => _get('/admin/status');

  Future<Map<String, dynamic>> me() => _get('/admin/me');

  /// First-run bootstrap. The server attaches the session cookie to the
  /// response; returns {ok, user}.
  Future<Map<String, dynamic>> setup({
    required String email,
    required String password,
    String name = '',
    String? setupToken,
  }) => _post('/admin/setup', {
    'email': email,
    'password': password,
    'name': name,
    if (setupToken != null && setupToken.isNotEmpty)
      'setupToken': setupToken,
  });

  /// Email+password login. The server attaches the session cookie to the
  /// response; returns {ok, user}.
  Future<Map<String, dynamic>> login({
    required String email,
    required String password,
  }) => _post('/admin/login', {'email': email, 'password': password});

  Future<void> logout() async {
    try {
      await _post('/admin/logout', const {});
    } finally {
      // Whatever the answer, this client stops presenting a session: the
      // server deleted its row and emptied the cookie in the answer.
      _sessionCookie = null;
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

  /// The friends-credential recovery path: clears the seat's stored
  /// friends binding, so a seat hijacked by a first-bind takeover
  /// (attacker's token bound before the owner's first sign-in) becomes
  /// signable again by the owner's own device. See the bind point in
  /// `bin/server.dart` for why a first bind carries no control proof.
  Future<void> friendsUnbind(String seatId) =>
      _post('/admin/friends/unbind', {'seatId': seatId});

  Future<void> rename(String seatId, String name) =>
      _post('/admin/rename', {'seatId': seatId, 'name': name});

  Future<void> deleteGame(String gameId) =>
      _post('/admin/delete-game', {'gameId': gameId});

  Future<void> closeRoom(String code) =>
      _post('/admin/rooms/close', {'code': code});

  // ------------------------------------------------------- feedback lane

  /// The triage queue. Sorted actionable-first (open, priority-ranked,
  /// newest tiebreak) unless `sort: 'newest'`.
  Future<Map<String, dynamic>> feedback({
    String? status,
    String? category,
    String sort = 'priority',
    int limit = 100,
  }) =>
      _get('/admin/feedback', {
        if (status != null && status.isNotEmpty) 'status': status,
        if (category != null && category.isNotEmpty) 'category': category,
        'sort': sort,
        'limit': '$limit',
      });

  /// Partial update: present keys only. Known keys: category, status,
  /// priority, title, message, contact, adminNotes.
  Future<void> updateFeedback(int id, Map<String, dynamic> fields) =>
      _post('/admin/feedback/update', {'id': id, ...fields});

  Future<void> deleteFeedback(int id) =>
      _post('/admin/feedback/delete', {'id': id});

  // ------------------------------------------------------- Data tab CRUD

  Future<Map<String, dynamic>> table(
    String name, {
    int limit = 100,
    int offset = 0,
    String? q,
  }) =>
      _get('/admin/table', {
        'table': name,
        'limit': '$limit',
        'offset': '$offset',
        if (q != null && q.trim().isNotEmpty) 'q': q.trim(),
      });

  Future<void> insertTableRow(String table, Map<String, dynamic> values) =>
      _post('/admin/table/insert', {'table': table, 'values': values});

  Future<void> updateTableRow(String table, String pk, Map<String, dynamic> values) =>
      _post('/admin/table/update', {'table': table, 'pk': pk, 'values': values});

  Future<void> deleteTableRow(String table, String pk) =>
      _post('/admin/table/delete', {'table': table, 'pk': pk});

  void close() {
    if (_ownsClient) _client.close();
  }
}
