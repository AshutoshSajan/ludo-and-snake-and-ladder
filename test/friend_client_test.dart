/// FriendClient contract: URL building off the ws(s) server URL, the
/// server's row shapes parsed into client-side views (peer picking,
/// mine/them, reply snapshots), failure mapping to人人-readable
/// FriendException texts, and the lookup-miss that stays null.
library;

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:game_club/services/friend_client.dart';

const serverUrl = 'wss://ludo.test/ws';

FriendClient clientWith(http.Client mock) =>
    FriendClient(serverUrl: serverUrl, httpClient: mock);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('state bundle parsing', () {
    test('friends state builds peers from the store rows', () async {
      final mock = MockClient(
        (req) async => http.Response(
          jsonEncode({
            'ok': true,
            'me': {'seatId': 'p1', 'name': 'Swift Otter', 'code': 'PRK7VW'},
            'friends': [
              {
                'seatId': 'p9',
                'name': 'Small Fox',
                'code': 'ABCDEF',
                'since': 100,
                'latest': 42,
              },
            ],
            'incoming': [
              {
                'id': 7,
                'from': {'seatId': 'p2', 'name': 'Ash B', 'code': 'QQQQQQ'},
                'to': {'seatId': 'p1', 'name': 'Swift Otter', 'code': 'PRK7VW'},
                'createdAt': 500,
              },
            ],
            'outgoing': [
              {
                'id': 8,
                'to': {'seatId': 'p3', 'name': 'Neo C', 'code': 'RRRRRR'},
                'from': {
                  'seatId': 'p1',
                  'name': 'Swift Otter',
                  'code': 'PRK7VW',
                },
                'createdAt': 501,
              },
            ],
            'invites': [
              {
                'id': 3,
                'from': {'seatId': 'p4', 'name': 'Dice D'},
                'game': 'ludo',
                'code': 'PLUM',
                'status': 'pending',
                'createdAt': 502,
              },
            ],
            'blocked': [
              {'seatId': 'p8', 'name': 'Troll', 'blockedAt': 400},
            ],
          }),
          200,
          headers: {'content-type': 'application/json'},
        ),
      );
      final state = await clientWith(mock)
          .state(seatId: 'p1', name: 'Swift Otter');

      expect(state.me.code, 'PRK7VW');
      expect(state.friends.single.seatId, 'p9');
      expect(state.friends.single.latest, 42);
      // Incoming request: the peer is the sender.
      expect(state.incoming.single.seatId, 'p2');
      expect(state.incoming.single.name, 'Ash B');
      // Outgoing: the peer is the recipient.
      expect(state.outgoing.single.seatId, 'p3');
      expect(state.invites.single.game, 'ludo');
      expect(state.invites.single.code, 'PLUM');
      expect(state.blocked.single.name, 'Troll');
    });

    test('the state bundle parses the table lane and tolerates no table', () {
      // The lane ships with the tablemate bundle; name-only rows, since
      // everything else a friendship needs is minted on ask.
      const withTable = {
        'me': {'seatId': 'p1', 'name': 'Swift Otter', 'code': 'PRK7VW'},
        'table': [
          {'seatId': 'p2', 'name': 'Ash B'},
          {'seatId': 'p3', 'name': 'Neo C'},
        ],
      };
      final mine = FriendState.fromJson(withTable, mySeatId: 'p1');
      expect([for (final t in mine.table) t.name], ['Ash B', 'Neo C']);

      // Older servers (or a caller not seated anywhere) omit the lane;
      // absence reads as an empty list, never a crash.
      expect(
        FriendState.fromJson(const {
          'me': {'seatId': 'p1'},
        }, mySeatId: 'p1').table,
        isEmpty,
      );
    });

    test('lookup miss maps the 404 to null without throwing', () async {
      final mock = MockClient(
        (_) async => http.Response(
          jsonEncode({'ok': false, 'text': 'no player with that friend code'}),
          404,
        ),
      );
      expect(
        await clientWith(mock).lookup('ZZZZZZ'),
        isNull,
        reason: 'a miss is an answer, not an error',
      );
    });
  });

  group('requests ride the right URLs and bodies', () {
    test('send POSTs friends/request with the target', () async {
      late String path;
      late Map<String, dynamic> sent;
      final mock = MockClient((req) async {
        path = req.url.toString();
        sent = jsonDecode(req.body) as Map<String, dynamic>;
        return http.Response(
          jsonEncode({'ok': true, 'status': 'pending'}),
          200,
        );
      });
      final status = await clientWith(mock)
          .request(seatId: 'p1', name: 'Swift Otter', target: 'PRK7VW');
      expect(status, 'pending');
      expect(path, 'https://ludo.test/friends/request');
      expect(sent['target'], 'PRK7VW');
      expect(sent['name'], 'Swift Otter');
    });

    test('DM send carries the reply quote id', () async {
      late Map<String, dynamic> sent;
      final mock = MockClient((req) async {
        sent = jsonDecode(req.body) as Map<String, dynamic>;
        return http.Response(
          jsonEncode({
            'ok': true,
            'message': {
              'id': 12,
              'from': 'p1',
              'to': 'p2',
              'body': 'roll a four?!',
              'liked': false,
              'createdAt': 900,
              'replyTo': 3,
              'replyFrom': 'p2',
              'replyBody': 'their old joke',
            },
          }),
          200,
        );
      });
      final view = await clientWith(mock)
          .send(seatId: 'p1', to: 'p2', body: 'roll a four?!', replyTo: 3);
      expect(sent['replyTo'], 3);
      expect(view.id, 12);
      expect(view.fromMe, isTrue, reason: 'my seat id owns the row');
      expect(view.replyBody, 'their old joke');
      expect(view.replyFromMe, isFalse, reason: 'the quote came from p2');
    });

    test('chat read marks rows mine or theirs by seat id', () async {
      late String url;
      final mock = MockClient((req) async {
        url = req.url.toString();
        return http.Response(
          jsonEncode({
            'ok': true,
            'messages': [
              {
                'id': 1,
                'from': 'p2',
                'to': 'p1',
                'body': 'hey',
                'liked': false,
                'createdAt': 1,
              },
              {
                'id': 2,
                'from': 'p1',
                'to': 'p2',
                'body': 'hola',
                'liked': false,
                'createdAt': 2,
              },
            ],
            'latest': 2,
          }),
          200,
        );
      });
      final page = await clientWith(mock).chat(seatId: 'p1', peer: 'p2');
      expect(url.startsWith('https://ludo.test/friends/chat?'), isTrue);
      expect(page.messages.first.fromMe, isFalse);
      expect(page.messages.last.fromMe, isTrue);
      expect(page.latest, 2);
    });
  });

  group('failure mapping', () {
    test('server wording rides through as FriendException.text', () async {
      final mock = MockClient(
        (_) async => http.Response(
          jsonEncode({
            'ok': false,
            'text': 'that player is not accepting friend requests',
          }),
          400,
        ),
      );
      await expectLater(
        clientWith(mock).request(seatId: 'p1', name: 'X', target: 'p2'),
        throwsA(
          isA<FriendException>().having(
            (e) => e.toString(),
            'text',
            'that player is not accepting friend requests',
          ),
        ),
      );
    });

    test('a dead socket is a reachable-problem message', () async {
      final mock = MockClient((_) => throw http.ClientException('down'));
      await expectLater(
        clientWith(mock).state(seatId: 'p1', name: 'X'),
        throwsA(
          isA<FriendException>().having(
            (e) => e.toString(),
            'text',
            contains('Could not reach the server'),
          ),
        ),
      );
    });
  });

  group('unblock + report + invite answers', () {
    test('unblock reports whether a block existed', () async {
      final mock = MockClient(
        (_) async => http.Response(jsonEncode({'ok': false}), 200),
      );
      expect(
        await clientWith(mock).unblock(seatId: 'p1', target: 'p2'),
        isFalse,
      );
    });

    test('invite accept returns the room code, none when gone', () async {
      late Map<String, dynamic> sent;
      final mock = MockClient((req) async {
        sent = jsonDecode(req.body) as Map<String, dynamic>;
        return http.Response(
          jsonEncode({
            'ok': true,
            'code': sent['accept'] == true ? 'PLUM' : null,
          }),
          200,
        );
      });
      expect(
        await clientWith(mock).respondInvite(seatId: 'p2', id: 3, accept: true),
        'PLUM',
      );
      expect(sent['accept'], isTrue);
      expect(
        await clientWith(mock)
            .respondInvite(seatId: 'p2', id: 3, accept: false),
        isNull,
        reason: 'a decline has no code',
      );
    });
  });
}
