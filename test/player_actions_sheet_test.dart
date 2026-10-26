/// [PlayerActionsSheet]: the add-friend / block / report moves a player
/// needs on the spot, opened from a table chat line or a lobby roster row.
///
/// The friends screen's tray actions are pinned in its own suite; here the
/// sheet is the subject — which rows it shows per relationship state, and
/// that the room context rides along (the peer's roster name as
/// targetName, so a tablemate who never opened the friends screen still
/// resolves server-side). The HTTP layer is a capturing mock; every hit
/// lands in [_Wire.hits] with its endpoint and decoded body.
library;

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:game_club/services/friend_client.dart';
import 'package:game_club/ui/shared/player_actions_sheet.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

/// The friends HTTP surface, captured. [state] is the tray the sheet
/// reads on open — per-test fixtures shape which rows render.
class _Wire {
  _Wire({
    Map<String, dynamic>? state,
    this.requestStatus = 'pending',
    this.failState,
  }) : state = state ?? _emptyState();

  Map<String, dynamic> state;

  /// What /friends/request answers — 'accepted' is the both-pressed-add
  /// match, 'pending' the ordinary send.
  String requestStatus;

  /// When set, /friends/state answers this error text with a 500 — the
  /// sheet must surface the server's wording instead of a blank body.
  final String? failState;

  final List<({String endpoint, Map<String, dynamic> body})> hits = [];

  http.Client client() => MockClient((req) async {
    final endpoint = req.url.pathSegments.last;
    final body = (req.body.isEmpty ? '{}' : req.body) == '{}'
        ? const <String, dynamic>{}
        : (jsonDecode(req.body) as Map).cast<String, dynamic>();
    hits.add((endpoint: endpoint, body: body));
    switch (endpoint) {
      case 'state':
        if (failState != null) {
          return http.Response(
            jsonEncode({'ok': false, 'text': failState}),
            500,
          );
        }
        return http.Response(jsonEncode(state), 200);
      case 'request':
        return http.Response(
          jsonEncode({'ok': true, 'status': requestStatus}),
          200,
        );
      case 'block':
        return http.Response(jsonEncode({'ok': true, 'blocked': true}), 200);
      case 'unblock':
        return http.Response(jsonEncode({'ok': true, 'unblocked': true}), 200);
      case 'report':
        return http.Response(jsonEncode({'ok': true, 'id': 3}), 200);
      default:
        return http.Response('{"ok":false,"text":"unknown endpoint"}', 404);
    }
  });

  Iterable<({String endpoint, Map<String, dynamic> body})> calls(
    String endpoint,
  ) => hits.where((h) => h.endpoint == endpoint);
}

/// A tray with nobody on it — caller re-shaped per test. The 'ok' flag
/// mirrors the real handler's envelope; without it the client unwrapper
/// reads the tray as a failure.
Map<String, dynamic> _emptyState() => {
  'ok': true,
  'me': {'seatId': 'p1', 'name': 'Sam', 'code': 'PRK7VW'},
  'friends': [],
  'incoming': [],
  'outgoing': [],
  'invites': [],
  'blocked': [],
};

Future<void> _openSheet(
  WidgetTester tester,
  _Wire wire, {
  String mySeatId = 'p1',
  String myName = 'Sam',
  String peerSeatId = 'p3',
  String peerName = 'Bo',
}) async {
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: Builder(
          builder: (context) => Center(
            child: FilledButton(
              onPressed: () => showModalBottomSheet<void>(
                context: context,
                backgroundColor: Colors.white,
                builder: (_) => PlayerActionsSheet(
                  serverUrl: 'ws://table.test/ws',
                  mySeatId: mySeatId,
                  myName: myName,
                  myCredential: 'test-credential',
                  peerSeatId: peerSeatId,
                  peerName: peerName,
                  friendClientForTest: FriendClient(
                    serverUrl: 'ws://table.test/ws',
                    credential: 'test-credential',
                    httpClient: wire.client(),
                  ),
                ),
              ),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('open'));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('a stranger shows the three moves: add, block, report', (
    tester,
  ) async {
    await _openSheet(tester, _Wire());

    expect(find.text('Add Bo as a friend'), findsOneWidget);
    expect(find.text('Block Bo'), findsOneWidget);
    expect(find.text('Report Bo'), findsOneWidget);
    // The head names who the sheet is about.
    expect(find.text('Bo'), findsOneWidget);
  });

  testWidgets('sending the request posts the seat id and the roster name', (
    tester,
  ) async {
    final wire = _Wire();
    await _openSheet(tester, wire);

    await tester.tap(find.text('Add Bo as a friend'));
    await tester.pumpAndSettle();
    // The confirm dialog stands between the tap and the sent request.
    await tester.tap(find.text('Send request'));
    await tester.pumpAndSettle();

    expect(find.text('Request sent'), findsOneWidget);
    final calls = wire.calls('request').toList();
    expect(calls, hasLength(1));
    expect(calls.single.body['seatId'], 'p1');
    expect(calls.single.body['name'], 'Sam');
    expect(calls.single.body['target'], 'p3');
    // The room context: mints a tablemate who never opened friends.
    expect(calls.single.body['targetName'], 'Bo');
  });

  testWidgets("the both-pressed-add match reads as 'friends' immediately", (
    tester,
  ) async {
    final wire = _Wire(requestStatus: 'accepted');
    await _openSheet(tester, wire);

    await tester.tap(find.text('Add Bo as a friend'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Send request'));
    await tester.pumpAndSettle();

    expect(find.text('They added you back — you are friends!'), findsOneWidget);
  });

  testWidgets('an accepted friend shows the bond, not an add button', (
    tester,
  ) async {
    final state = _emptyState()
      ..['friends'] = [
        {'seatId': 'p3', 'name': 'Bo', 'code': 'CQK3VW', 'since': 123},
      ];
    await _openSheet(tester, _Wire(state: state));

    expect(find.text('Already friends'), findsOneWidget);
    expect(find.text('Add Bo as a friend'), findsNothing);
    // Block still applies to a friend — that is what severing warns about.
    expect(find.text('Block Bo'), findsOneWidget);
  });

  testWidgets('a pending request of mine shows as pending, not sendable', (
    tester,
  ) async {
    final state = _emptyState()
      ..['outgoing'] = [
        {
          'id': 8,
          'from': {'seatId': 'p1', 'name': 'Sam', 'code': 'PRK7VW'},
          'to': {'seatId': 'p3', 'name': 'Bo', 'code': 'RRRRRR'},
          'createdAt': 501,
        },
      ];
    await _openSheet(tester, _Wire(state: state));

    expect(find.text('Request pending'), findsOneWidget);
    expect(find.text('Add Bo as a friend'), findsNothing);
  });

  testWidgets('a blocked seatmate offers unblock and drops the block row', (
    tester,
  ) async {
    final state = _emptyState()
      ..['blocked'] = [
        {'seatId': 'p3', 'name': 'Bo', 'blockedAt': 9},
      ];
    await _openSheet(tester, _Wire(state: state));

    expect(find.text('Unblock Bo'), findsOneWidget);
    expect(find.text('Block Bo'), findsNothing);
    // Report stays available: hiding it would let a blocked player act
    // without recourse.
    expect(find.text('Report Bo'), findsOneWidget);
  });

  testWidgets('unblock calls friends/unblock, then reloads the tray', (
    tester,
  ) async {
    final state = _emptyState()
      ..['blocked'] = [
        {'seatId': 'p3', 'name': 'Bo', 'blockedAt': 9},
      ];
    final wire = _Wire(state: state);
    await _openSheet(tester, wire);

    await tester.tap(find.text('Unblock Bo'));
    await tester.pumpAndSettle();

    final calls = wire.calls('unblock').toList();
    expect(calls, hasLength(1));
    expect(calls.single.body['target'], 'p3');
    expect(find.text('Bo unblocked'), findsOneWidget);
  });

  testWidgets('block posts with the roster name and the scary wording', (
    tester,
  ) async {
    final wire = _Wire();
    await _openSheet(tester, wire);

    await tester.tap(find.text('Block Bo'));
    await tester.pumpAndSettle();
    // The dialog says what blocking severs before the consequences land.
    expect(find.text('Block Bo?'), findsOneWidget);
    expect(find.textContaining('pending request'), findsOneWidget);
    await tester.tap(find.widgetWithText(FilledButton, 'Block'));
    await tester.pumpAndSettle();

    final calls = wire.calls('block').toList();
    expect(calls, hasLength(1));
    expect(calls.single.body['target'], 'p3');
    expect(calls.single.body['targetName'], 'Bo');
    expect(find.text('Bo blocked'), findsOneWidget);
  });

  testWidgets('report carries the typed reason to the moderators', (
    tester,
  ) async {
    final wire = _Wire();
    await _openSheet(tester, wire);

    await tester.tap(find.text('Report Bo'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'table flaming');
    await tester.tap(find.text('OK'));
    await tester.pumpAndSettle();

    final calls = wire.calls('report').toList();
    expect(calls, hasLength(1));
    expect(calls.single.body['target'], 'p3');
    expect(calls.single.body['reason'], 'table flaming');
  });

  testWidgets("the sheet refuses to act on the caller's own line", (
    tester,
  ) async {
    await _openSheet(tester, _Wire(), peerSeatId: 'p1', peerName: 'Sam');
    expect(find.text('This is you'), findsOneWidget);
    expect(find.text('Add Sam as a friend'), findsNothing);
    expect(find.text('Block Sam'), findsNothing);
  });

  testWidgets('a server failure explains itself instead of a bare sheet', (
    tester,
  ) async {
    await _openSheet(tester, _Wire(failState: 'friends service is down'));

    // The head subtitle and the body both carry the server's wording —
    // never an unexplained empty sheet.
    expect(find.text('friends service is down'), findsWidgets);
    expect(find.byType(ListTile), findsNothing);
  });
}
