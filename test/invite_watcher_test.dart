/// The invite knock as real client behaviour against a scripted HTTP
/// surface (a MockClient standing in for the friends endpoints):
///
/// - a pending invite arriving `/friends/state` raises the app-level
///   knock with a Join game button — the playtest contract: "invitation
///   request should show up to the person whom we are inviting and on
///   clicking on that invitation request join game btn he should be able
///   to join and play";
/// - Join answers `friends/invite/respond` (accept) and walks the player
///   into the room the invite carries its code for;
/// - Not now never answers the server and never re-knocks the same
///   invite this session;
/// - a code-less answer ("their table is not ready") stays on screen as
///   the column toast instead of a mystery push;
/// - no persisted online identity means no polls at all.
library;

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:game_club/screens/invite_watcher.dart';
import 'package:game_club/services/friend_client.dart';

void main() {
  const interval = Duration(milliseconds: 50);
  const inviteRow = {
    'id': 7,
    'from': {'seatId': 'buddy', 'name': 'Swift Otter', 'code': 'JKXQWB'},
    'to': {'seatId': 'p2', 'name': 'Bo', 'code': 'PRK7VW'},
    'game': 'ludo',
    'code': '',
    'status': 'pending',
    'createdAt': 10,
  };

  Future<InviteWatcher> watcherWith(
    MockClient mock, {
    ({String seatId, String name}) identity = const (
      seatId: 'p2',
      name: 'Bo',
    ),
  }) async {
    final watcher = InviteWatcher(
      interval: interval,
      clientFactory: () => FriendClient(
        serverUrl: 'wss://test/ws',
        httpClient: mock,
      ),
      identityOverride: Future.value(identity),
    );
    return watcher;
  }

  Widget shell() => ProviderScope(
        child: MaterialApp(
          navigatorKey: InviteWatcher.navigatorKey,
          home: Scaffold(body: const Center(child: Text('home'))),
        ),
      );

  testWidgets('a pending invite knocks and Join takes them to the room', (
    tester,
  ) async {
    final posts = <http.Request>[];
    var deliverInvite = false;
    final watcher = await watcherWith(
      MockClient((req) async {
        posts.add(req);
        if (req.url.path == '/friends/state') {
          return http.Response(
            jsonEncode({
              'ok': true,
              'me': {'seatId': 'p2', 'name': 'Bo', 'code': 'PRK7VW'},
              'friends': [],
              'incoming': [],
              'outgoing': [],
              'blocked': [],
              'table': [],
              if (deliverInvite) 'invites': [inviteRow],
            }),
            200,
          );
        }
        if (req.url.path == '/friends/invite/respond') {
          return http.Response(jsonEncode({'ok': true, 'code': 'ABCD'}), 200);
        }
        return http.Response('{}', 200);
      }),
    );
    await tester.pumpWidget(shell());
    watcher.start();
    await tester.pump(interval); // first poll: nothing pending
    expect(find.text('Join game'), findsNothing);

    deliverInvite = true; // the friend just invited us to their table
    await tester.pump(interval);
    await tester.pump();
    expect(find.text('Play invite'), findsOneWidget,
        reason:
            'the invitation request shows up wherever the invitee is, not '
            'only inside the friends tray');
    expect(find.textContaining('Swift Otter invites you to Ludo'),
        findsOneWidget);

    await tester.tap(find.text('Join game'));
    await tester.pumpAndSettle();

    final respond = posts.lastWhere(
      (r) => r.url.path == '/friends/invite/respond',
      orElse: () => throw StateError('no respond call'),
    );
    final answered =
        jsonDecode(respond.body) as Map<String, dynamic>;
    expect(answered['accept'], isTrue);
    expect(answered['id'], 7);
    // And the app is no longer on 'home': the lobby — which lists the
    // room it just joined — owns the screen.
    expect(find.text('home'), findsNothing);
    expect(find.textContaining('Ludo'), findsWidgets,
        reason: 'the room screen came up ahead of everything else');
    watcher.stop();
  });

  testWidgets('Not now answers nothing and never re-knocks', (tester) async {
    final posts = <http.Request>[];
    final watcher = await watcherWith(
      MockClient((req) async {
        posts.add(req);
        return http.Response(
          jsonEncode({
            'ok': true,
            'me': {'seatId': 'p2', 'name': 'Bo', 'code': 'PRK7VW'},
            'friends': [],
            'incoming': [],
            'outgoing': [],
            'blocked': [],
            'table': [],
            'invites': [inviteRow],
          }),
          200,
        );
      }),
    );
    await tester.pumpWidget(shell());
    watcher.start();
    await tester.pump(interval);
    await tester.pump();
    expect(find.text('Not now'), findsOneWidget);

    await tester.tap(find.text('Not now'));
    await tester.pump();

    expect(
      posts.where((r) => r.url.path == '/friends/invite/respond'),
      isEmpty,
      reason: 'the invite stays pending in the tray — only the knock sits down',
    );
    // Polls keep happening; the same invite must not knock again.
    await tester.pump(interval * 3);
    await tester.pump();
    expect(find.text('Join game'), findsNothing,
        reason: 'one knock per invite per session');
    watcher.stop();
  });

  testWidgets('a table already gone answers as the column toast, no push', (
    tester,
  ) async {
    final watcher = await watcherWith(
      MockClient((req) async {
        if (req.url.path == '/friends/state') {
          return http.Response(
            jsonEncode({
              'ok': true,
              'me': {'seatId': 'p2', 'name': 'Bo', 'code': 'PRK7VW'},
              'friends': [],
              'incoming': [],
              'outgoing': [],
              'blocked': [],
              'table': [],
              'invites': [inviteRow],
            }),
            200,
          );
        }
        // The inviter closed the room before the answer landed.
        return http.Response(jsonEncode({'ok': true, 'code': null}), 200);
      }),
    );
    await tester.pumpWidget(shell());
    watcher.start();
    await tester.pump(interval);
    await tester.pump();
    await tester.tap(find.text('Join game'));
    await tester.pump();
    await tester.pump();

    expect(find.textContaining('table is not ready'), findsOneWidget);
    // The dialog closed and nothing was pushed: the home route owns the
    // screen again, delivering its own Scaffold for the toast.
    expect(find.text('home'), findsOneWidget);
    watcher.stop();
  });

  testWidgets('no online identity means no poll and no knock', (tester) async {
    final posts = <http.Request>[];
    final watcher = await watcherWith(
      MockClient((req) async {
        posts.add(req);
        return http.Response('{}', 200);
      }),
      identity: (seatId: '', name: ''),
    );
    await tester.pumpWidget(shell());
    watcher.start();
    await tester.pump(interval);
    await tester.pump(interval * 3);
    expect(posts, isEmpty,
        reason: 'a guest has nobody to invite them anywhere');
    watcher.stop();
  });
}
