/// [TablematesSheet]: the board's own add-friend door. The lobby's seat
/// rows carry the one-tap friend lanes, but once the game starts the board
/// replaces them (playtest: "add friend option is not there on online
/// gameplay") — the game app bar's players action now opens the same
/// lanes for the same people.
///
/// Here the sheet is the subject against a real [OnlineClient] fed by a
/// fake channel: the roster lists everyone seated, the own seat does not
/// aim the friend sheets at yourself, and a tablemate row hands the tap
/// to [PlayerActionsSheet] with the table's server and the caller's
/// identity riding along.
library;

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:game_club/services/friend_client.dart';
import 'package:game_club/services/online_client.dart';
import 'package:game_club/ui/shared/tablemates_sheet.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'fake_channel.dart';

void main() {
  late FakeChannel channel;
  late OnlineClient client;

  setUp(() {
    channel = FakeChannel();
  });

  /// Joined 'CODE' as p2 (Bo), and the lobby roster has Ana (p1) seated
  /// too — the two-player table the board is playing.
  Future<void> pumpClient(WidgetTester tester) async {
    client = OnlineClient(
      'ws://x/ws',
      seatId: 'p2',
      name: 'Bo',
      gameType: 'ludo',
      channelFactory: (_) => channel,
    );
    final joined = client.connect(code: 'CODE');
    await tester.pump();
    channel.serverAdd({'type': 'joined', 'code': 'CODE', 'game': 'ludo'});
    await tester.pump();
    await joined;
    channel.serverAdd({
      'type': 'lobby',
      'started': true,
      'capacity': 2,
      'spectators': [],
      'seats': [
        {'name': 'Bo', 'color': 'green', 'seatId': 'p2', 'connected': true},
        {'name': 'Ana', 'color': 'red', 'seatId': 'p1', 'connected': true},
      ],
    });
    await tester.pump();
  }

  Future<void> pumpSheet(
    WidgetTester tester, {
    required void Function(http.Request) onCall,
  }) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => Center(
              child: TextButton(
                onPressed: () => TablematesSheet.show(
                  context,
                  client: client,
                  friendClientForTest: FriendClient(
                    serverUrl: 'ws://x/ws',
                    httpClient: MockClient((req) async {
                      onCall(req);
                      return http.Response(
                        jsonEncode({
                          'ok': true,
                          'me': {
                            'seatId': 'p2',
                            'name': 'Bo',
                            'code': 'PRK7VW',
                          },
                          'friends': [],
                          'incoming': [],
                          'outgoing': [],
                          'invites': [],
                          'blocked': [],
                        }),
                        200,
                      );
                    }),
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

  testWidgets('the table roster lists everyone seated, with status', (
    tester,
  ) async {
    await pumpClient(tester);
    await pumpSheet(tester, onCall: (req) {});

    expect(find.text('Players at this table'), findsOneWidget);
    expect(find.text('Ana'), findsOneWidget);
    expect(find.text('Bo'), findsOneWidget);
    expect(find.textContaining('at the table'), findsNWidgets(2),
        reason: 'a live seat says where it is; a friendless row is still '
            'readable before anyone taps');
  });

  testWidgets('my own seat does not aim the friend sheet at myself', (
    tester,
  ) async {
    final friendCalls = <http.Request>[];
    await pumpClient(tester);
    await pumpSheet(tester, onCall: friendCalls.add);

    // The tap lands on the row, but the row is inert for my own seat: the
    // tablemates sheet stays, no friend surface opens.
    await tester.tap(find.text('Bo'));
    await tester.pumpAndSettle();

    expect(find.text('Players at this table'), findsOneWidget);
    expect(find.textContaining('friend'), findsNothing,
        reason: 'adding yourself is not an action the table offers');
    expect(friendCalls, isEmpty, reason: 'own seat made no friend HTTP');
  });

  testWidgets('a tablemate row hands the tap to the player actions sheet', (
    tester,
  ) async {
    final friendCalls = <http.Request>[];
    await pumpClient(tester);
    await pumpSheet(tester, onCall: friendCalls.add);

    await tester.tap(find.text('Ana'));
    await tester.pumpAndSettle();

    expect(find.text('Add Ana as a friend'), findsOneWidget,
        reason: 'the same lanes the lobby seat rows use, now from the '
            'board — the thing the playtest said was missing');
    expect(find.text('Block Ana'), findsOneWidget);

    // The room's own origin and identity ride along, so a tablemate who
    // never opened the friends screen still resolves server-side.
    final stateCall = friendCalls.single;
    expect(stateCall.url.host, 'x');
    final body =
        (jsonDecode(stateCall.body) as Map).cast<String, dynamic>();
    expect(body['seatId'], 'p2');
    expect(body['name'], 'Bo');
  });
}
