/// The 1:1 DM screen: WhatsApp-style bubble sides (mine right, theirs
/// left) with circular identicons, double-tap liking with the full
/// round-trip, and the read marker being stamped persistently on load.
library;

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:game_club/screens/friends_screen.dart';
import 'package:game_club/services/friend_client.dart';
import 'package:game_club/ui/shared/player_avatar.dart';

const serverUrl = 'wss://chat.test/ws';

/// The invited peer as the server prints its row.
FriendEntry _peer() => FriendEntry.fromJson({
  'seatId': 'p2',
  'name': 'Small Fox',
  'code': 'FOXCDE',
  'latest': 2,
});

http.Response ok(Object body) => http.Response(
  jsonEncode(body),
  200,
  headers: {'content-type': 'application/json'},
);

Future<void> _pump(WidgetTester tester, FriendClient client) async {
  SharedPreferences.setMockInitialValues({});
  await tester.pumpWidget(
    ProviderScope(
      child: MaterialApp(
        home: FriendsChatScreen(
          client: client,
          me: 'p1',
          myName: 'Swift Otter',
          peer: _peer(),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

/// Two taps inside the double-tap window: the test framework's clock
/// advances per pump, so both land as one double-tap.
Future<void> _doubleTap(WidgetTester tester, Finder finder) async {
  final center = tester.getCenter(finder);
  final first = await tester.startGesture(center);
  await first.up();
  await tester.pump(const Duration(milliseconds: 120));
  final second = await tester.startGesture(center);
  await second.up();
  await tester.pump();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('the peer row parses from server-shaped JSON', () {
    final p = _peer();
    expect(p.seatId, 'p2');
    expect(p.name, 'Small Fox');
  });

  testWidgets('bubbles side correctly with identicons', (tester) async {
    await _pump(
      tester,
      FriendClient(
        serverUrl: serverUrl,
        credential: 'test-credential',
        httpClient: MockClient(
          (_) async => ok({
            'ok': true,
            'messages': [
              {
                'id': 1,
                'from': 'p2',
                'to': 'p1',
                'body': 'your move yet?',
                'liked': false,
                'createdAt': 1000,
              },
              {
                'id': 2,
                'from': 'p1',
                'to': 'p2',
                'body': 'finishing now!',
                'liked': false,
                'createdAt': 1001,
              },
            ],
            'latest': 2,
          }),
        ),
      ),
    );
    expect(find.byType(PlayerAvatar), findsNWidgets(2));
    final theirs = tester.getRect(find.text('your move yet?'));
    final mine = tester.getRect(find.text('finishing now!'));
    expect(
      mine.center.dx > theirs.center.dx,
      isTrue,
      reason: 'my bubble renders right of theirs, WhatsApp-style',
    );
  });

  testWidgets('double-tap likes, and double-tapping again unlikes', (
    tester,
  ) async {
    var serverLiked = false;
    await _pump(
      tester,
      FriendClient(
        serverUrl: serverUrl,
        credential: 'test-credential',
        httpClient: MockClient((req) async {
          if (req.url.path == '/friends/chat/like') {
            serverLiked = jsonDecode(req.body)['liked'] as bool;
            return ok({'ok': true, 'liked': serverLiked});
          }
          return ok({
            'ok': true,
            'messages': [
              {
                'id': 1,
                'from': 'p2',
                'to': 'p1',
                'body': 'your move yet?',
                'liked': serverLiked,
                'createdAt': 1000,
              },
            ],
            'latest': 1,
          });
        }),
      ),
    );
    expect(find.byIcon(Icons.favorite), findsNothing);
    await _doubleTap(tester, find.text('your move yet?'));
    await tester.pumpAndSettle();
    expect(find.byIcon(Icons.favorite), findsOneWidget);
    // Double-tap again un-likes.
    await _doubleTap(tester, find.text('your move yet?'));
    await tester.pumpAndSettle();
    expect(find.byIcon(Icons.favorite), findsNothing);
  });

  testWidgets('reading the chat stamps the persisted read marker', (
    tester,
  ) async {
    await _pump(
      tester,
      FriendClient(
        serverUrl: serverUrl,
        credential: 'test-credential',
        httpClient: MockClient(
          (_) async => ok({
            'ok': true,
            'messages': [
              {
                'id': 1,
                'from': 'p2',
                'to': 'p1',
                'body': 'your move yet?',
                'liked': false,
                'createdAt': 1000,
              },
            ],
            'latest': 1,
          }),
        ),
      ),
    );
    final sp = await SharedPreferences.getInstance();
    final raw = sp.getString('gc.friendRead');
    expect(raw, isNotNull);
    expect(jsonDecode(raw!)['p2'], 1, reason: 'marker records the latest id');
  });
}
