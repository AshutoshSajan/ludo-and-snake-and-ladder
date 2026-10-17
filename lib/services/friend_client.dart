/// HTTP client for the friends endpoints (`/friends/...`).
///
/// Mirrors `report_client.dart`: the ws(s) server URL is rewritten to
/// http(s), every failure becomes a [FriendException] whose text is the
/// server's user-presentable wording, and a per-test injectable
/// `http.Client` keeps tests off the wire. The server is
/// unauthenticated by design — identity is the seat id the WS `hello`
/// path already asserts, bounded by per-IP throttles and per-seat caps.
///
/// The server's shape knowledge lives here in one place: every row lands
/// as the store's `toJson()`, so the fromJson factories below take an
/// optional `mySeatId` and compute "mine / theirs" and the peer side
/// client-side instead of asking the server to re-word rows per viewer.
library;

import 'dart:convert';

import 'package:http/http.dart' as http;

class FriendException implements Exception {
  FriendException(this.text);

  final String text;

  @override
  String toString() => text;
}

/// A friend profile as the server shows it (mine or a looked-up one).
class FriendProfile {
  FriendProfile({required this.seatId, required this.name, required this.code});

  factory FriendProfile.fromJson(Map<String, dynamic> json) => FriendProfile(
    seatId: json['seatId'] as String? ?? '',
    name: json['name'] as String? ?? '',
    code: json['code'] as String? ?? '',
  );

  final String seatId;
  final String name;
  final String code;
}

/// An accepted friend, carrying the pair's latest message id so the list
/// can show an unread dot without a chat fetch.
class FriendEntry {
  FriendEntry({
    required this.profile,
    required this.sinceMs,
    required this.latest,
  });

  factory FriendEntry.fromJson(Map<String, dynamic> json) => FriendEntry(
    profile: FriendProfile.fromJson(json),
    sinceMs: (json['since'] as num?)?.toInt() ?? 0,
    latest: (json['latest'] as num?)?.toInt() ?? 0,
  );

  final FriendProfile profile;
  final int sinceMs;

  /// Latest DM id in the pair's thread (0 when none) — the unread dot
  /// comes from comparing this against the stored read marker.
  final int latest;

  String get seatId => profile.seatId;
  String get name => profile.name;
}

/// A friend request, whichever tray it sits in. `seatId`/`name` are the
/// peer: the sender when incoming, the recipient when outgoing.
class FriendRequestView {
  FriendRequestView({
    required this.id,
    required this.seatId,
    required this.name,
    required this.sinceMs,
  });

  factory FriendRequestView.fromJson(
    Map<String, dynamic> json, {
    required String mySeatId,
  }) {
    // The store prints requests as {id, from: {..}, to: {..}, createdAt};
    // whichever object is not me is the peer.
    final from = json['from'] as Map<String, dynamic>? ?? {};
    final to = json['to'] as Map<String, dynamic>? ?? {};
    final outgoing = (from['seatId'] as String? ?? '') == mySeatId;
    final peer = outgoing ? to : from;
    return FriendRequestView(
      id: (json['id'] as num?)?.toInt() ?? 0,
      seatId: peer['seatId'] as String? ?? '',
      name: peer['name'] as String? ?? '',
      sinceMs: (json['createdAt'] as num?)?.toInt() ?? 0,
    );
  }

  final int id;
  final String seatId;
  final String name;
  final int sinceMs;
}

/// A play invitation. Same peer rule as requests — the store prints the
/// sender's profile, so an incoming view shows the sender.
class FriendInviteView {
  FriendInviteView({
    required this.id,
    required this.seatId,
    required this.name,
    required this.game,
    required this.code,
    required this.status,
    required this.sinceMs,
  });

  factory FriendInviteView.fromJson(
    Map<String, dynamic> json, {
    required String mySeatId,
  }) {
    final from = json['from'] as Map<String, dynamic>? ?? {};
    return FriendInviteView(
      id: (json['id'] as num?)?.toInt() ?? 0,
      seatId: from['seatId'] as String? ?? '',
      name: from['name'] as String? ?? '',
      game: json['game'] as String? ?? '',
      code: json['code'] as String? ?? '',
      status: json['status'] as String? ?? '',
      sinceMs: (json['createdAt'] as num?)?.toInt() ?? 0,
    );
  }

  final int id;
  final String seatId;
  final String name;
  final String game;
  final String code;
  final String status;
  final int sinceMs;

  bool get pending => status == 'pending';
}

/// A player I have blocked (name as of the block moment).
class FriendBlockView {
  FriendBlockView({
    required this.seatId,
    required this.name,
    required this.sinceMs,
  });

  factory FriendBlockView.fromJson(Map<String, dynamic> json) =>
      FriendBlockView(
        seatId: json['seatId'] as String? ?? '',
        name: json['name'] as String? ?? '',
        sinceMs: (json['blockedAt'] as num?)?.toInt() ?? 0,
      );

  final String seatId;
  final String name;
  final int sinceMs;
}

/// One DM row: the body, the like flag, and the reply snapshot when the
/// message quotes another one. `fromMe` is computed against the reader's
/// seat id, so the same row renders correctly in both trays.
class FriendMessageView {
  FriendMessageView({
    required this.id,
    required this.fromMe,
    required this.body,
    required this.liked,
    required this.sinceMs,
    this.replyTo,
    this.replyFromMe,
    this.replyBody,
  });

  factory FriendMessageView.fromJson(
    Map<String, dynamic> json, {
    required String mySeatId,
  }) => FriendMessageView(
    id: (json['id'] as num?)?.toInt() ?? 0,
    fromMe: json['from'] == mySeatId,
    body: json['body'] as String? ?? '',
    liked: json['liked'] as bool? ?? false,
    sinceMs: (json['createdAt'] as num?)?.toInt() ?? 0,
    replyTo: (json['replyTo'] as num?)?.toInt(),
    replyFromMe: json['replyFrom'] == null
        ? null
        : json['replyFrom'] == mySeatId,
    replyBody: json['replyBody'] as String?,
  );

  final int id;
  final bool fromMe;
  final String body;
  final bool liked;
  final int sinceMs;
  final int? replyTo;
  final bool? replyFromMe;
  final String? replyBody;
}

/// One chat page read: the messages plus the fresh read marker.
class FriendChatPage {
  FriendChatPage({required this.messages, required this.latest});

  final List<FriendMessageView> messages;
  final int latest;
}

/// One screen of friends state — what `POST friends/state` returns in
/// total, so the screen can poll coarsely.
class FriendState {
  FriendState({
    required this.me,
    required this.friends,
    required this.incoming,
    required this.outgoing,
    required this.invites,
    required this.blocked,
  });

  factory FriendState.fromJson(
    Map<String, dynamic> json, {
    required String mySeatId,
  }) => FriendState(
    me: FriendProfile.fromJson(json['me'] as Map<String, dynamic>? ?? {}),
    friends: [
      for (final f in (json['friends'] as List? ?? const []))
        FriendEntry.fromJson(f as Map<String, dynamic>),
    ],
    incoming: [
      for (final r in (json['incoming'] as List? ?? const []))
        FriendRequestView.fromJson(
          r as Map<String, dynamic>,
          mySeatId: mySeatId,
        ),
    ],
    outgoing: [
      for (final r in (json['outgoing'] as List? ?? const []))
        FriendRequestView.fromJson(
          r as Map<String, dynamic>,
          mySeatId: mySeatId,
        ),
    ],
    invites: [
      for (final i in (json['invites'] as List? ?? const []))
        FriendInviteView.fromJson(
          i as Map<String, dynamic>,
          mySeatId: mySeatId,
        ),
    ],
    blocked: [
      for (final b in (json['blocked'] as List? ?? const []))
        FriendBlockView.fromJson(b as Map<String, dynamic>),
    ],
  );

  final FriendProfile me;
  final List<FriendEntry> friends;
  final List<FriendRequestView> incoming;
  final List<FriendRequestView> outgoing;
  final List<FriendInviteView> invites;
  final List<FriendBlockView> blocked;
}

class FriendClient {
  FriendClient({required this.serverUrl, http.Client? httpClient})
    : _client = httpClient ?? http.Client(),
      _ownsClient = httpClient == null;

  /// Same-origin game server URL (ws(s)://host/ws form, as everywhere).
  final String serverUrl;
  final http.Client _client;
  final bool _ownsClient;

  Uri _uri(String path) {
    final base = Uri.parse(serverUrl);
    return base.replace(
      scheme: base.scheme == 'wss' ? 'https' : 'http',
      path: '/$path',
    );
  }

  /// One JSON POST; unwraps `{ok: true, ...}` and maps every failure to
  /// [FriendException] with the server's wording.
  Future<Map<String, dynamic>> _post(
    String path,
    Map<String, dynamic> body,
  ) async {
    final resp = await _attempt(
      () => _client.post(
        _uri(path),
        headers: {'content-type': 'application/json'},
        body: jsonEncode(body),
      ),
    );
    return _unwrap(resp);
  }

  /// GET ferry for chat paging (the only friends read route).
  Future<Map<String, dynamic>> _get(
    String path,
    Map<String, String> query,
  ) async {
    final resp = await _attempt(
      () => _client.get(_uri(path).replace(queryParameters: {...query})),
    );
    return _unwrap(resp);
  }

  Future<http.Response> _attempt(Future<http.Response> Function() send) async {
    try {
      return await send();
    } catch (_) {
      throw FriendException(
        'Could not reach the server — check your connection',
      );
    }
  }

  /// Unwraps `{ok: true, ...}` with failures as [FriendException], or
  /// passes a 200 `ok: false` through for endpoints whose false VALUES
  /// are answers, not errors (unblock says "nothing was blocked").
  Future<Map<String, dynamic>> _postLoose(
    String path,
    Map<String, dynamic> body,
  ) async {
    final resp = await _attempt(
      () => _client.post(
        _uri(path),
        headers: {'content-type': 'application/json'},
        body: jsonEncode(body),
      ),
    );
    try {
      return jsonDecode(resp.body) as Map<String, dynamic>;
    } catch (_) {
      throw FriendException('Something went wrong (${resp.statusCode})');
    }
  }

  Map<String, dynamic> _unwrap(http.Response resp) {
    Map<String, dynamic> body;
    try {
      body = jsonDecode(resp.body) as Map<String, dynamic>;
    } catch (_) {
      body = {};
    }
    if (resp.statusCode != 200 || body['ok'] != true) {
      throw FriendException(
        body['text'] is String
            ? body['text'] as String
            : 'Something went wrong (${resp.statusCode})',
      );
    }
    return body;
  }

  /// The one-call state bundle my friends screen polls.
  Future<FriendState> state({
    required String seatId,
    required String name,
  }) async {
    final body = await _post('friends/state', {'seatId': seatId, 'name': name});
    return FriendState.fromJson(body, mySeatId: seatId);
  }

  /// Resolves a friend code (or seat id) to a profile; null on a miss —
  /// a miss is AN answer (the add-friend dialog says so plainly), not a
  /// crash. The miss wording is the server's.
  Future<FriendProfile?> lookup(String target) async {
    try {
      final body = await _post('friends/lookup', {'target': target});
      final profile = body['profile'];
      return profile == null
          ? null
          : FriendProfile.fromJson(profile as Map<String, dynamic>);
    } on FriendException catch (e) {
      if ('$e'.contains('no player with that friend code')) return null;
      rethrow;
    }
  }

  /// Sends (or matches) a friend request; returns the server status.
  Future<String> request({
    required String seatId,
    required String name,
    required String target,
  }) async {
    final body = await _post('friends/request', {
      'seatId': seatId,
      'name': name,
      'target': target,
    });
    return body['status'] as String? ?? 'pending';
  }

  /// Accepts / declines / withdraws a request; true when it went through.
  Future<bool> respond({
    required String seatId,
    required int id,
    required bool accept,
    bool withdraw = false,
  }) async {
    final body = await _post('friends/respond', {
      'seatId': seatId,
      'id': id,
      'accept': accept,
      'withdraw': withdraw,
    });
    return body['ok'] == true;
  }

  /// Un-friends. Either side may do it.
  Future<void> remove({required String seatId, required String target}) =>
      _post('friends/remove', {'seatId': seatId, 'target': target});

  /// DM history — `since` skips already-read ids (the unread discipline).
  Future<FriendChatPage> chat({
    required String seatId,
    required String peer,
    int? since,
    int limit = 200,
  }) async {
    final body = await _get('friends/chat', {
      'seatId': seatId,
      'peer': peer,
      if (since != null && since > 0) 'since': '$since',
      'limit': '$limit',
    });
    return FriendChatPage(
      messages: [
        for (final m in (body['messages'] as List? ?? const []))
          FriendMessageView.fromJson(
            m as Map<String, dynamic>,
            mySeatId: seatId,
          ),
      ],
      latest: (body['latest'] as num?)?.toInt() ?? 0,
    );
  }

  /// Sends a DM (optionally quoting the message being replied to); the
  /// fresh row comes back already marked mine.
  Future<FriendMessageView> send({
    required String seatId,
    required String to,
    required String body,
    int? replyTo,
  }) async {
    final json = await _post('friends/chat/send', {
      'seatId': seatId,
      'to': to,
      'body': body,
      'replyTo': replyTo,
    });
    return FriendMessageView.fromJson(
      json['message'] as Map<String, dynamic>? ?? {},
      mySeatId: seatId,
    );
  }

  /// Toggles a like; returns the new state.
  Future<bool> like({
    required String seatId,
    required int messageId,
    bool liked = true,
  }) async {
    final body = await _post('friends/chat/like', {
      'seatId': seatId,
      'messageId': messageId,
      'liked': liked,
    });
    return body['liked'] == true;
  }

  /// Invites a friend to a room I opened; returns the pending invite id.
  Future<int> invite({
    required String seatId,
    required String name,
    required String to,
    required String game,
    String? code,
  }) async {
    final body = await _post('friends/invite', {
      'seatId': seatId,
      'name': name,
      'to': to,
      'game': game,
      'code': code,
    });
    final invite = body['invite'] as Map<String, dynamic>? ?? {};
    return (invite['id'] as num?)?.toInt() ?? 0;
  }

  /// Answers a pending invite; on accept returns the room code the
  /// invite carried (null when the invite was code-less or it is gone).
  Future<String?> respondInvite({
    required String seatId,
    required int id,
    required bool accept,
  }) async {
    final body = await _post('friends/invite/respond', {
      'seatId': seatId,
      'id': id,
      'accept': accept,
    });
    return body['code'] as String?;
  }

  /// Blocks a player (severs friendship + pendings, denies contact).
  Future<void> block({required String seatId, required String target}) =>
      _post('friends/block', {'seatId': seatId, 'target': target});

  /// Lifts a block; true when one actually existed (a false here is an
  /// answer the UI shows, so `ok: false` rides through).
  Future<bool> unblock({required String seatId, required String target}) async {
    final body = await _postLoose('friends/unblock', {
      'seatId': seatId,
      'target': target,
    });
    return body['ok'] == true;
  }

  /// Reports a player into the admin feedback queue.
  Future<int> report({
    required String seatId,
    required String target,
    String reason = '',
  }) async {
    final body = await _post('friends/report', {
      'seatId': seatId,
      'target': target,
      'reason': reason,
    });
    return (body['id'] as num?)?.toInt() ?? -1;
  }

  void close() {
    if (_ownsClient) _client.close();
  }
}
