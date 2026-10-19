/// The player directory: every registered player as a row with name + id,
/// the relationship state answering each row (you / friends / sent /
/// accept / blocked / add), and the one-tap request flow.
/// Mounted with a [MockClient] so nothing leaves the process.
library;

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:game_club/screens/player_directory_screen.dart';
import 'package:game_club/services/friend_client.dart';

const serverUrl = 'wss://players.test/ws';

http.Response ok(Object body) => http.Response(
  jsonEncode(body),
  200,
  headers: {'content-type': 'application/json'},
);

/// The friends bundle p1 sees, `friends/state`-like. After [requested]
/// flips, the outgoing tray carries p7 — what a refresh after a sent
/// request must show.
Map<String, dynamic> _stateBody({bool requested = false}) => {
  'ok': true,
  'me': {'seatId': 'p1', 'name': 'Swift Otter', 'code': 'PRK7VW'},
  'friends': [
    {
      'seatId': 'p9',
      'name': 'Small Fox',
      'code': 'FOXCDE',
      'since': 100,
      'latest': 0,
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
      'id': 5,
      'from': {'seatId': 'p1', 'name': 'Swift Otter', 'code': 'PRK7VW'},
      'to': {'seatId': 'p3', 'name': 'Ko Lee', 'code': 'KKKKKK'},
      'createdAt': 300,
    },
    if (requested)
      {
        'id': 9,
        'from': {'seatId': 'p1', 'name': 'Swift Otter', 'code': 'PRK7VW'},
        'to': {'seatId': 'p7', 'name': 'Ana', 'code': 'RRRRRR'},
        'createdAt': 600,
      },
  ],
  'invites': [],
  'blocked': [
    {'seatId': 'p8', 'name': 'Troll', 'blockedAt': 400},
  ],
};

List<Map<String, dynamic>> get _playersBody => [
  {'seatId': 'p1', 'name': 'Swift Otter', 'code': 'PRK7VW', 'lastSeen': 900},
  {'seatId': 'p7', 'name': 'Ana', 'code': 'RRRRRR', 'lastSeen': 800},
  {'seatId': 'p9', 'name': 'Small Fox', 'code': 'FOXCDE', 'lastSeen': 700},
  {'seatId': 'p2', 'name': 'Ash B', 'code': 'QQQQQQ', 'lastSeen': 600},
  {'seatId': 'p8', 'name': 'Troll', 'code': 'BBBBBB', 'lastSeen': 500},
  {'seatId': 'p3', 'name': 'Ko Lee', 'code': 'KKKKKK', 'lastSeen': 400},
];

Future<void> _pump(
  WidgetTester tester, {
  required Future<http.Response> Function(http.Request req) handler,
}) async {
  // Identity is the same persisted pair the lobby mints (the storage
  // service's private key names, seeded here so the directory's rows
  // orient against p1 exactly like the server bundle does).
  SharedPreferences.setMockInitialValues({
    'gc.onlinePlayerId': 'p1',
    'gc.onlineName': 'Swift Otter',
  });
  await tester.pumpWidget(
    ProviderScope(
      child: MaterialApp(
        home: PlayerDirectoryScreen(
          client: FriendClient(
            serverUrl: serverUrl,
            httpClient: MockClient(handler),
          ),
        ),
      ),
    ),
  );
  for (var i = 0; i < 8; i++) {
    await tester.pump(const Duration(milliseconds: 40));
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('every player is a row with their id, state answered', (
    tester,
  ) async {
    await _pump(tester, handler: (req) async {
      if (req.url.path.endsWith('/friends/players')) {
        return ok({'ok': true, 'players': _playersBody});
      }
      if (req.url.path.endsWith('/friends/state')) {
        return ok(_stateBody());
      }
      return http.Response('nope', 404);
    });

    // The id the old add flow demanded from thin air is ON the row.
    expect(find.text('Ana'), findsOneWidget);
    expect(find.textContaining('id: p7'), findsOneWidget);

    // Each relationship state gets its own answer.
    expect(find.text('You'), findsOneWidget, reason: 'my own row adds nobody');
    expect(find.text('Friends'), findsOneWidget, reason: 'Small Fox: accepted');
    expect(find.text('Accept'), findsOneWidget,
        reason: 'Ash B asked me first — the row takes the answer');
    expect(find.text('Blocked'), findsOneWidget, reason: 'Troll stays put');
    expect(find.text('Sent'), findsOneWidget, reason: 'Ko Lee: my request waits');
    expect(find.text('Add'), findsOneWidget, reason: 'Ana is the addable one');
  });

  testWidgets('Add confirms, sends the request, and the row reads Sent', (
    tester,
  ) async {
    var requested = false;
    final sent = <Map<String, dynamic>>[];
    await _pump(tester, handler: (req) async {
      if (req.url.path.endsWith('/friends/players')) {
        return ok({'ok': true, 'players': _playersBody});
      }
      if (req.url.path.endsWith('/friends/state')) {
        return ok(_stateBody(requested: requested));
      }
      if (req.url.path.endsWith('/friends/request')) {
        requested = true;
        sent.add(jsonDecode(req.body) as Map<String, dynamic>);
        return ok({'ok': true, 'status': 'pending'});
      }
      return http.Response('nope', 404);
    });

    await tester.tap(find.text('Add'));
    await tester.pump();
    expect(find.text('Add Ana?'), findsOneWidget,
        reason: 'a request is a social action — confirm with the consequence '
            'named first');
    await tester.tap(find.text('Send request'));
    for (var i = 0; i < 8; i++) {
      await tester.pump(const Duration(milliseconds: 40));
    }

    expect(sent, hasLength(1));
    expect(sent.single['seatId'], 'p1', reason: 'the caller asserts identity');
    expect(sent.single['target'], 'p7', reason: 'the row IS the target');
    expect(find.text('Request sent'), findsOneWidget);
    expect(find.text('Sent'), findsNWidgets(2),
        reason: 'the refresh moved Ana to the outgoing state, next to '
            'Ko Lee who was already waiting');
    expect(find.text('Add'), findsNothing);
  });

  testWidgets('Accept answers an incoming request from the row', (tester) async {
    final responded = <Map<String, dynamic>>[];
    await _pump(tester, handler: (req) async {
      if (req.url.path.endsWith('/friends/players')) {
        return ok({'ok': true, 'players': _playersBody});
      }
      if (req.url.path.endsWith('/friends/state')) {
        return ok(_stateBody());
      }
      if (req.url.path.endsWith('/friends/respond')) {
        responded.add(jsonDecode(req.body) as Map<String, dynamic>);
        return ok({'ok': true});
      }
      return http.Response('nope', 404);
    });

    await tester.tap(find.text('Accept'));
    for (var i = 0; i < 8; i++) {
      await tester.pump(const Duration(milliseconds: 40));
    }
    expect(responded, hasLength(1));
    expect(responded.single['accept'], true);
    expect(find.text('You are friends with Ash B'), findsOneWidget);
  });

  testWidgets('the search narrows rows by name or id', (tester) async {
    await _pump(tester, handler: (req) async {
      if (req.url.path.endsWith('/friends/players')) {
        return ok({'ok': true, 'players': _playersBody});
      }
      if (req.url.path.endsWith('/friends/state')) {
        return ok(_stateBody());
      }
      return http.Response('nope', 404);
    });

    await tester.enterText(find.byType(TextField), 'ana');
    await tester.pump();
    expect(find.text('Ana'), findsOneWidget);
    expect(find.text('Small Fox'), findsNothing);

    await tester.enterText(find.byType(TextField), 'p9');
    await tester.pump();
    expect(find.text('Small Fox'), findsOneWidget,
        reason: 'the id matches too — the directory is the answer to "who '
            'is p9"');
    expect(find.text('Ana'), findsNothing);
  });

  testWidgets('a failed load says so with a way back', (tester) async {
    await _pump(
      tester,
      handler: (req) async => http.Response(
        jsonEncode({'ok': false, 'text': 'Could not reach the server'}),
        200,
      ),
    );
    expect(find.textContaining('Could not reach the server'), findsOneWidget);
    expect(find.text('Try again'), findsOneWidget,
        reason: 'an error names the fix path — here, another attempt');
  });
}
