/// Friends tray screen: the me-code card, unread dots on the friend
/// list, the incoming-requests tray, and the actions that refresh.
/// Mounted with an injected [MockClient] so nothing leaves the process.
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

const serverUrl = 'wss://friends.test/ws';

/// The friends state one seat (p1) sees, shaped `friends/state`-like.
Map<String, dynamic> _stateBody({int latestForP9 = 7}) => {
  'ok': true,
  'me': {'seatId': 'p1', 'name': 'Swift Otter', 'code': 'PRK7VW'},
  'friends': [
    {
      'seatId': 'p9',
      'name': 'Small Fox',
      'code': 'FOXCDE',
      'since': 100,
      'latest': latestForP9,
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
  'outgoing': [],
  'invites': [],
  'blocked': [
    {'seatId': 'p8', 'name': 'Troll', 'blockedAt': 400},
  ],
};

http.Response ok(Object body) => http.Response(
  jsonEncode(body),
  200,
  headers: {'content-type': 'application/json'},
);

Future<void> _pump(WidgetTester tester, FriendClient client) async {
  SharedPreferences.setMockInitialValues({});
  await tester.pumpWidget(
    ProviderScope(
      child: MaterialApp(home: FriendsScreen(client: client)),
    ),
  );
  // Bounded pumps instead of pumpAndSettle: the 6s polling cadence must
  // not be driven here, and the async first fetch resolves within a
  // handful of microtask-flushing pumps.
  for (var i = 0; i < 8; i++) {
    await tester.pump(const Duration(milliseconds: 40));
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('shows my friend code, friends and the unread dot', (
    tester,
  ) async {
    await _pump(
      tester,
      FriendClient(
        serverUrl: serverUrl,
        httpClient: MockClient((_) async => ok(_stateBody())),
      ),
    );
    expect(find.textContaining('PRK7VW'), findsOneWidget);
    expect(find.text('Small Fox'), findsOneWidget);
    // latest(7) > read marker (nothing read) → the gold dot shows.
    expect(find.byIcon(Icons.circle), findsOneWidget);
    expect(find.byIcon(Icons.sports_esports), findsOneWidget);
  });

  testWidgets('a caught-up friend shows no unread dot', (tester) async {
    await _pump(
      tester,
      FriendClient(
        serverUrl: serverUrl,
        httpClient: MockClient((_) async => ok(_stateBody(latestForP9: 0))),
      ),
    );
    expect(find.byIcon(Icons.circle), findsNothing);
  });

  testWidgets('requests tray offers accept and decline', (tester) async {
    final answered = <Map<String, dynamic>>[];
    await _pump(
      tester,
      FriendClient(
        serverUrl: serverUrl,
        httpClient: MockClient((req) async {
          if (req.url.path == '/friends/respond') {
            answered.add(jsonDecode(req.body) as Map<String, dynamic>);
            return ok({'ok': true});
          }
          return ok(_stateBody());
        }),
      ),
    );
    expect(find.text('Ash B'), findsOneWidget);
    await tester.tap(find.byIcon(Icons.check_circle_outline));
    await tester.pumpAndSettle();
    expect(answered.single['id'], 7);
    expect(answered.single['accept'], isTrue);
  });

  testWidgets('long-press opens the remove / block / report sheet', (
    tester,
  ) async {
    await _pump(
      tester,
      FriendClient(
        serverUrl: serverUrl,
        httpClient: MockClient((_) async => ok(_stateBody())),
      ),
    );
    // The buddy row: long-press the tap-to-chat subtitle text under it.
    await tester.longPress(find.text('tap to chat · long-press for more'));
    await tester.pumpAndSettle();
    expect(find.textContaining('Remove Small Fox'), findsOneWidget);
    expect(find.textContaining('Block Small Fox'), findsOneWidget);
    expect(find.textContaining('Report Small Fox'), findsOneWidget);
  });
}
