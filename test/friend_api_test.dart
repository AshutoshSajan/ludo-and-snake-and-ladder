/// Friends HTTP layer: the state bundle, code lookup, the request →
/// friendship handshake, DM reads/sends/likes, play invites, block /
/// unblock, player reports into the feedback queue, and the per-IP
/// throttle that bounds the whole family.
library;

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:shelf/shelf.dart' as shelf;
import 'package:sqlite3/sqlite3.dart' show sqlite3;

import 'package:game_club/server/admin_store.dart';
import 'package:game_club/server/friend_store.dart';
import 'package:game_club/server/report_store.dart';

import '../bin/server.dart'
    show
        adminFeedbackHandler,
        adminStore,
        adminToken,
        friendStore,
        friendsBlockHandler,
        friendsChatHandler,
        friendsChatLikeHandler,
        friendsChatSendHandler,
        friendsInviteHandler,
        friendsInviteRespondHandler,
        friendsLookupHandler,
        friendsRemoveHandler,
        friendsReportHandler,
        friendsRequestHandler,
        friendsRespondHandler,
        friendsStateHandler,
        friendsUnblockHandler,
        reportStore,
        resetFeedbackAttempts,
        resetFriendAttempts;

shelf.Request _get(String path, {Map<String, String>? query}) => shelf.Request(
  'GET',
  Uri.parse('http://localhost/$path').replace(queryParameters: query),
);

shelf.Request _post(String path, Map<String, dynamic> body) => shelf.Request(
  'POST',
  Uri.parse('http://localhost/$path'),
  headers: {'content-type': 'application/json'},
  body: Stream.fromIterable([utf8.encode(jsonEncode(body))]),
);

Future<Map<String, dynamic>> _json(shelf.Response r) async =>
    jsonDecode(await r.readAsString()) as Map<String, dynamic>;

/// Dispatches to the friends handlers exactly like main()'s route
/// switch does, so tests exercise the wiring too.
Future<shelf.Response> _call(String path, shelf.Request req) => switch (path) {
  'friends/state' => friendsStateHandler(req),
  'friends/lookup' => friendsLookupHandler(req),
  // Retired route: mirrors bin/server.dart's in-switch 404 (the helper
  // that serves it there is private to the server library).
  'friends/players' => Future.value(shelf.Response(
    404,
    body: jsonEncode({'ok': false, 'text': 'not found'}),
    headers: {'content-type': 'application/json'},
  )),
  'friends/request' => friendsRequestHandler(req),
  'friends/respond' => friendsRespondHandler(req),
  'friends/remove' => friendsRemoveHandler(req),
  'friends/chat' => friendsChatHandler(req),
  'friends/chat/send' => friendsChatSendHandler(req),
  'friends/chat/like' => friendsChatLikeHandler(req),
  'friends/invite' => friendsInviteHandler(req),
  'friends/invite/respond' => friendsInviteRespondHandler(req),
  'friends/block' => friendsBlockHandler(req),
  'friends/unblock' => friendsUnblockHandler(req),
  'friends/report' => friendsReportHandler(req),
  _ => throw StateError('no handler wired for $path'),
};

/// Registers (or re-serves) a profile via the state endpoint, which is
/// not throttled by design.
Future<Map<String, dynamic>> _serve(String seatId, [String? name]) async =>
    _json(
      await _call(
        'friends/state',
        _post('friends/state', {'seatId': seatId, 'name': name ?? seatId}),
      ),
    );

Future<shelf.Response> _state(String seatId) => _call(
  'friends/state',
  _post('friends/state', {'seatId': seatId, 'name': seatId}),
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late AdminStore savedAdmin;
  late ReportStore savedReports;
  late String savedToken;
  late FriendStore savedFriend;

  setUp(() {
    savedAdmin = adminStore;
    savedReports = reportStore;
    savedToken = adminToken;
    savedFriend = friendStore;
    final db = sqlite3.openInMemory();
    adminStore = AdminStore.fromDb(db);
    reportStore = ReportStore.fromDb(db);
    // A fresh friends table per test: seat ids repeat across scenarios,
    // and a leftover friendship from a previous test would 400 them.
    friendStore = FriendStore.inMemory();
    adminToken = 'secret';
    resetFriendAttempts();
    resetFeedbackAttempts();
    addTearDown(() {
      friendStore.close();
      friendStore = savedFriend;
      adminStore = savedAdmin;
      reportStore = savedReports;
      adminToken = savedToken;
      resetFriendAttempts();
      resetFeedbackAttempts();
    });
  });

  /// Registers both players over HTTP and accepts the handshake.
  Future<void> makeFriends(String a, String b) async {
    await _serve(a);
    await _serve(b);
    await _call(
      'friends/request',
      _post('friends/request', {'seatId': a, 'name': a, 'target': b}),
    );
    final stateB = await _json(await _state(b));
    final id = (stateB['incoming'] as List).single['id'] as int;
    await _json(
      await _call(
        'friends/respond',
        _post('friends/respond', {'seatId': b, 'id': id, 'accept': true}),
      ),
    );
  }

  group('state bundle', () {
    test('serves the profile and empty trays', () async {
      final r = await _state('p1');
      expect(r.statusCode, 200);
      final body = await _json(r);
      expect(body['ok'], isTrue);
      expect(
        RegExp(r'^[2-9A-HJ-NP-Z]{6}$')
            .hasMatch((body['me'] as Map)['code'] as String),
        isTrue,
      );
      expect(body['friends'], isEmpty);
      expect(body['incoming'], isEmpty);
      expect(body['outgoing'], isEmpty);
      expect(body['invites'], isEmpty);
      expect(body['blocked'], isEmpty);
    });

    test('blocks ride in the bundle', () async {
      await makeFriends('p1', 'p2');
      await _json(
        await _call(
          'friends/block',
          _post('friends/block', {'seatId': 'p1', 'target': 'p2'}),
        ),
      );
      final state = await _json(await _state('p1'));
      final blocked = (state['blocked'] as List).single as Map;
      expect(blocked['seatId'], 'p2');
      expect(state['friends'], isEmpty, reason: 'block severed the pair');
    });
  });

  group('lookup + requests', () {
    test('code lookup resolves and misses politely', () async {
      final me = (await _serve('p1', 'Swift Otter'))['me'] as Map;
      final r = await _call(
        'friends/lookup',
        _post('friends/lookup', {'target': me['code']}),
      );
      expect(r.statusCode, 200);
      expect(((await _json(r))['profile'] as Map)['seatId'], 'p1');

      final miss = await _call(
        'friends/lookup',
        _post('friends/lookup', {'target': 'ZZZZZZ'}),
      );
      expect(miss.statusCode, 404);
    });

    test('request → respond(accept) → both sides see the friend', () async {
      await makeFriends('p1', 'p2');
      final state = await _json(await _state('p1'));
      expect((state['friends'] as List).single['seatId'], 'p2');
    });

    test('the retired player enumeration answers 404, not a listing', () async {
      await _serve('pOld', 'Old Name');
      final r = await _call('friends/players', _get('friends/players'));
      expect(r.statusCode, 404,
          reason: 'add-a-friend discovery lives at the table now: the '
              'server-wide player list was removed with the directory '
              'screen, and a registry enumeration must not come back');
    });

    test('unknown target maps to a readable 400', () async {
      final r = await _call(
        'friends/request',
        _post('friends/request', {
          'seatId': 'p1',
          'name': 'p1',
          'target': 'ZZZZZZ',
        }),
      );
      expect(r.statusCode, 400);
      final body = await _json(r);
      expect(body['ok'], isFalse);
      expect(body['text'], contains('no player matches'));
    });

    test('decline closes the incoming request', () async {
      await _serve('p1');
      await _serve('p2');
      await _call(
        'friends/request',
        _post('friends/request', {
          'seatId': 'p1',
          'name': 'p1',
          'target': 'p2',
        }),
      );
      final inbox = (await _json(await _state('p2')))['incoming'] as List;
      final r = await _json(
        await _call(
          'friends/respond',
          _post('friends/respond', {
            'seatId': 'p2',
            'id': (inbox.single as Map)['id'],
            'accept': false,
          }),
        ),
      );
      expect(r['ok'], isTrue);
      final after = await _json(await _state('p2'));
      expect(after['incoming'], isEmpty);
    });

    test('unfriend removes the pair for both sides', () async {
      await makeFriends('p1', 'p2');
      final r = await _call(
        'friends/remove',
        _post('friends/remove', {'seatId': 'p1', 'target': 'p2'}),
      );
      expect(r.statusCode, 200);
      expect((await _json(r))['ok'], isTrue);
      expect(((await _json(await _state('p2')))['friends'] as List), isEmpty);
      final again = await _call(
        'friends/remove',
        _post('friends/remove', {'seatId': 'p1', 'target': 'p2'}),
      );
      expect(again.statusCode, 404);
    });
  });

  group('DMs over HTTP', () {
    test('send → read → like, and non-friends are refused', () async {
      // Not friends: the send is refused with the store's wording.
      final refused = await _call(
        'friends/chat/send',
        _post('friends/chat/send', {'seatId': 'p1', 'to': 'p2', 'body': 'hi'}),
      );
      expect(refused.statusCode, 400);

      await makeFriends('p1', 'p2');
      final sent = await _json(
        await _call(
          'friends/chat/send',
          _post('friends/chat/send', {
            'seatId': 'p1',
            'to': 'p2',
            'body': 'gg',
          }),
        ),
      );
      final id = (sent['message'] as Map)['id'] as int;
      expect((sent['message'] as Map)['body'], 'gg');

      final page = await _json(
        await _call(
          'friends/chat',
          _get('friends/chat', query: {'seatId': 'p2', 'peer': 'p1'}),
        ),
      );
      expect((page['messages'] as List).single['id'], id);
      expect(page['latest'], id);

      final liked = await _json(
        await _call(
          'friends/chat/like',
          _post('friends/chat/like', {'seatId': 'p2', 'messageId': id}),
        ),
      );
      expect(liked['liked'], isTrue);
      final unliked = await _json(
        await _call(
          'friends/chat/like',
          _post('friends/chat/like', {
            'seatId': 'p2',
            'messageId': id,
            'liked': false,
          }),
        ),
      );
      expect(unliked['liked'], isFalse);
    });

    test('reply rides as a snapshot quote', () async {
      await makeFriends('p1', 'p2');
      final first = await _json(
        await _call(
          'friends/chat/send',
          _post('friends/chat/send', {
            'seatId': 'p1',
            'to': 'p2',
            'body': 'roll a four?',
          }),
        ),
      );
      final id = (first['message'] as Map)['id'] as int;
      final reply = await _json(
        await _call(
          'friends/chat/send',
          _post('friends/chat/send', {
            'seatId': 'p2',
            'to': 'p1',
            'body': 'no, a six!',
            'replyTo': id,
          }),
        ),
      );
      expect((reply['message'] as Map)['replyBody'], 'roll a four?');
    });

    test('since prunes the read gap', () async {
      await makeFriends('p1', 'p2');
      for (var i = 0; i < 3; i++) {
        await _json(
          await _call(
            'friends/chat/send',
            _post('friends/chat/send', {
              'seatId': 'p1',
              'to': 'p2',
              'body': 'm$i',
            }),
          ),
        );
      }
      final full = await _json(
        await _call(
          'friends/chat',
          _get('friends/chat', query: {'seatId': 'p2', 'peer': 'p1'}),
        ),
      );
      final latest = full['latest'] as int;
      final gap = await _json(
        await _call(
          'friends/chat',
          _get(
            'friends/chat',
            query: {'seatId': 'p2', 'peer': 'p1', 'since': '$latest'},
          ),
        ),
      );
      expect(gap['messages'], isEmpty);
    });
  });

  group('play invites over HTTP', () {
    test('send → accept returns the room code, decline returns none', () async {
      await makeFriends('p1', 'p2');
      await _json(
        await _call(
          'friends/invite',
          _post('friends/invite', {
            'seatId': 'p1',
            'name': 'p1',
            'to': 'p2',
            'game': 'ludo',
            'code': 'PLUM',
          }),
        ),
      );
      final state = await _json(await _state('p2'));
      final invite = (state['invites'] as List).single as Map;
      expect(invite['status'], 'pending');
      expect(invite['game'], 'ludo');

      final accepted = await _json(
        await _call(
          'friends/invite/respond',
          _post('friends/invite/respond', {
            'seatId': 'p2',
            'id': invite['id'],
            'accept': true,
          }),
        ),
      );
      expect(accepted['code'], 'PLUM');

      // Asking again is harmless and code-less — the screen re-polls.
      final again = await _json(
        await _call(
          'friends/invite/respond',
          _post('friends/invite/respond', {
            'seatId': 'p2',
            'id': invite['id'],
            'accept': true,
          }),
        ),
      );
      expect(again['ok'], isTrue);
      expect(again['code'], isNull);
    });

    test('a bad game is a 400, not a crash', () async {
      await makeFriends('p1', 'p2');
      final r = await _call(
        'friends/invite',
        _post('friends/invite', {
          'seatId': 'p1',
          'name': 'p1',
          'to': 'p2',
          'game': 'poker',
        }),
      );
      expect(r.statusCode, 400);
      expect(((await _json(r))['text'] as String), contains('game must be'));
    });
  });

  group('block + unblock over HTTP', () {
    test('block denies chat and requests, unblock reopens', () async {
      await makeFriends('p1', 'p2');
      final blocked = await _json(
        await _call(
          'friends/block',
          _post('friends/block', {'seatId': 'p1', 'target': 'p2'}),
        ),
      );
      expect(blocked['blocked'], isTrue);

      final chat = await _call(
        'friends/chat/send',
        _post('friends/chat/send', {'seatId': 'p1', 'to': 'p2', 'body': 'hi'}),
      );
      expect(chat.statusCode, 400);
      expect(
        ((await _json(chat))['text'] as String),
        contains('message friends'),
      );

      final req = await _call(
        'friends/request',
        _post('friends/request', {
          'seatId': 'p2',
          'name': 'p2',
          'target': 'p1',
        }),
      );
      expect(req.statusCode, 400);

      expect(
        ((await _json(
          await _call(
            'friends/unblock',
            _post('friends/unblock', {'seatId': 'p1', 'target': 'p2'}),
          ),
        )))['ok'],
        isTrue,
      );
      // A second unblock reports that nothing was there to lift.
      final repeat = (await _json(
        await _call(
          'friends/unblock',
          _post('friends/unblock', {'seatId': 'p1', 'target': 'p2'}),
        ),
      ));
      expect(repeat['ok'], isFalse);
    });
  });

  group('report a player', () {
    test('lands in the feedback queue as a player report', () async {
      await _serve('p1');
      await _serve('p2', 'Bad Actor');
      final r = await _call(
        'friends/report',
        _post('friends/report', {
          'seatId': 'p1',
          'target': 'p2',
          'reason': 'abusive chat',
        }),
      );
      expect(r.statusCode, 200);
      expect((await _json(r))['ok'], isTrue);

      final open = await _json(
        await adminFeedbackHandler(
          shelf.Request(
            'GET',
            Uri.parse('http://localhost/admin/feedback'),
            headers: {'authorization': 'Bearer secret'},
          ),
        ),
      );
      final entries = open['feedback'] as List;
      expect(entries, hasLength(1));
      final entry = entries.single as Map;
      expect(entry['category'], 'player');
      expect(entry['source'], 'report');
      expect(entry['message'], contains('Bad Actor'));
      expect(entry['message'], contains('abusive chat'));
      expect(entry['seatId'], 'p1', reason: 'the reporter is recorded');
    });
  });

  group('throttling', () {
    test('the 41st friend action in the hour is refused', () async {
      // Twenty accepted pairs spend exactly the 40-hit action bucket.
      for (var i = 0; i < 20; i++) {
        await makeFriends('a$i', 'b$i');
      }
      await _serve('pX');
      final r = await _call(
        'friends/request',
        _post('friends/request', {
          'seatId': 'pX',
          'name': 'pX',
          'target': 'a0',
        }),
      );
      expect(r.statusCode, 429);
      expect(
        ((await _json(r))['text'] as String),
        contains('too many friend actions'),
      );
    });
  });
}
