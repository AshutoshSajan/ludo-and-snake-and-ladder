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
import 'package:game_club/ui/club_widgets.dart';

const serverUrl = 'wss://friends.test/ws';

/// The friends state one seat (p1) sees, shaped `friends/state`-like.
Map<String, dynamic> _stateBody({
  int latestForP9 = 7,
  List<Map<String, Object?>> table = const [],
  List<Map<String, Object?>>? friends,
}) => {
  'ok': true,
  'me': {'seatId': 'p1', 'name': 'Swift Otter', 'code': 'PRK7VW'},
  'table': table,
  'friends':
      friends ??
      [
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

  testWidgets('the Play row opens the pick-a-game dialog', (tester) async {
    // The play handoff starts with a picker ("Invite Small Fox to…"),
    // never a silent tap: a build where this dialog does not show has
    // lost the handoff entirely and must fail loudly here.
    await _pump(
      tester,
      FriendClient(
        serverUrl: serverUrl,
        httpClient: MockClient((_) async => ok(_stateBody())),
      ),
    );
    await tester.tap(find.widgetWithText(TextButton, 'Play'));
    await tester.pump();

    expect(find.text('Invite Small Fox to…'), findsOneWidget);
    expect(find.text('Ludo'), findsOneWidget);
    expect(find.text('Snakes & Ladders'), findsOneWidget);
  });

  testWidgets(
    'tablemates land in their own section and open the actions sheet',
    (tester) async {
      final stateCalls = <String>[];
      await _pump(
        tester,
        FriendClient(
          serverUrl: serverUrl,
          httpClient: MockClient((req) async {
            stateCalls.add(req.url.path);
            return ok(
              _stateBody(
                table: [
                  {'seatId': 'p5', 'name': 'Terry Test'},
                ],
              ),
            );
          }),
        ),
      );
      expect(find.text('At your table'), findsOneWidget);
      expect(find.text('Terry Test'), findsOneWidget);

      // A tablemate row leads into the same actions sheet the table rows
      // use — add, block, report — so the screen carries no second copy of
      // the flow. The sheet's one-shot tray fetch goes over the same mock.
      await tester.tap(find.text('Terry Test'));
      await tester.pump();
      for (var i = 0; i < 6; i++) {
        await tester.pump(const Duration(milliseconds: 150));
      }
      expect(stateCalls.where((p) => p == '/friends/state'), isNotEmpty);
      final texts = [
        for (final t in tester.widgetList<Text>(find.byType(Text)))
          if (t.data != null) t.data!,
      ].join(' | ');
      expect(texts, contains('Report Terry Test'), reason: texts);
      expect(
        find.text('Add Terry Test as a friend'),
        findsOneWidget,
        reason: 'the sheet, not a bespoke flow, owns the tablemate actions',
      );
    },
  );

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
    // The buddy row: long-press the friend's name tile itself (the row is
    // one line now — the old instructing subtitle lives in no card).
    await tester.longPress(find.text('Small Fox'));
    await tester.pumpAndSettle();
    expect(find.textContaining('Remove Small Fox'), findsOneWidget);
    expect(find.textContaining('Block Small Fox'), findsOneWidget);
    expect(find.textContaining('Report Small Fox'), findsOneWidget);
  });

  testWidgets('add friend dialog shows one short placeholder', (tester) async {
    await _pump(
      tester,
      FriendClient(
        serverUrl: serverUrl,
        httpClient: MockClient((_) async => ok(_stateBody())),
      ),
    );
    await tester.tap(find.byTooltip('Add a friend'));
    await tester.pumpAndSettle();

    expect(find.text('Add a friend'), findsOneWidget);
    expect(find.text('Friend code or player ID'), findsOneWidget);
    expect(find.textContaining('(e.g.'), findsNothing);
  });

  testWidgets('friend cards leave a ten pixel gap', (tester) async {
    tester.view.physicalSize = const Size(900, 2000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await _pump(
      tester,
      FriendClient(
        serverUrl: serverUrl,
        httpClient: MockClient(
          (_) async => ok(
            _stateBody(
              friends: [
                {
                  'seatId': 'p9',
                  'name': 'Small Fox',
                  'code': 'FOXCDE',
                  'since': 100,
                  'latest': 0,
                },
                {
                  'seatId': 'p10',
                  'name': 'Big Bear',
                  'code': 'BEARCD',
                  'since': 101,
                  'latest': 0,
                },
              ],
            ),
          ),
        ),
      ),
    );

    final first = find.ancestor(
      of: find.text('Small Fox'),
      matching: find.byType(ClubCard),
    );
    final second = find.ancestor(
      of: find.text('Big Bear'),
      matching: find.byType(ClubCard),
    );
    expect(first, findsOneWidget);
    expect(second, findsOneWidget);
    final gap = tester.getTopLeft(second).dy - tester.getBottomLeft(first).dy;
    expect(gap, greaterThanOrEqualTo(10));
  });
}
