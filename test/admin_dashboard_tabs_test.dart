/// The admin dashboard's panel switch never paints the red error widget.
///
/// The reported flicker was real and reproducible: the panels share one
/// widget slot (only one is mounted at a time), so switching tabs reuses
/// the slot's FutureBuilder state, and FutureBuilder keeps the *previous*
/// future's resolved snapshot until the new future completes. For a frame
/// (or a slow round-trip on web), the previous panel's JSON flowed through
/// the new panel's casts — the rooms tab read `overview`'s Map `live`
/// through `as List?`, the Data tab read the feedback queue through
/// `d['pk'] as String` — and the throws painted the error widget. The
/// panels now key their FutureBuilders (`admin-panel-*`), so a switch
/// recreates the state and shows its own loading card instead.
///
/// The wire bodies below are copied verbatim from a live server capture,
/// including the empty shapes (`live: []`, `feedback: []`, no `pk` in the
/// reports payload) that used to prove fatal when they arrived in the
/// wrong tab's parser.
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:game_club/screens/admin/admin_dashboard_screen.dart';
import 'package:game_club/services/admin_client.dart';

/// The recorded live shapes, one per /admin endpoint the dashboard asks.
String _recordedBody(String path) => switch (path) {
  '/admin/me' =>
    '{"ok":true,"user":{"id":1,"email":"keeper@club.test",'
        '"name":"Keeper","role":"admin","createdAt":1793258457193}}',
  '/admin/overview' =>
    '{"ok":true,"instance":"game-1","live":{"connections":0,'
        '"rooms":0,"spectators":0},"stored":{"totalPlayers":2,'
        '"totalGames":0,"totalRooms":0,"bannedPlayers":0,'
        '"finishedGames":0,"gamesByGame":{"ludo":0,"snakes":0},'
        '"openFeedback":0,"feedbackByCategory":{}},'
        '"leaderboardBackend":"sqlite"}',
  '/admin/rooms' => '{"ok":true,"live":[],"recent":[],"totalRooms":0}',
  '/admin/players' =>
    '{"ok":true,"players":[{"seatId":"phnnnvy0x9cb6k",'
        '"name":"Merry Ibex 037C","firstSeen":1793259164720,'
        '"lastSeen":1793259169675,"banned":false}]}',
  '/admin/users' =>
    '{"ok":true,"users":[{"id":1,"email":"keeper@club.test",'
        '"name":"Keeper","role":"admin","createdAt":1793258457193}]}',
  '/admin/audit' =>
    '{"ok":true,"audit":[{"action":"userCreate",'
        '"seatId":"keeper@club.test","by":"setup","at":1793258457856}]}',
  '/admin/feedback' =>
    '{"ok":true,"feedback":[],"openCount":0,"totalCount":0,'
        '"openByCategory":{}}',
  '/admin/table' =>
    '{"ok":true,"table":"feedback","pk":"id","columns":'
        '["id","category","source","title","message"],'
        '"editable":["title"],"insertable":true,"deletable":true,'
        '"rows":[],"total":0}',
  _ => '{"ok":true}',
};

http.Response _ok(String body) =>
    http.Response(body, 200, headers: {'content-type': 'application/json'});

/// The recorded shapes, answered instantly.
AdminClient recordedClient() => AdminClient(
  serverUrl: 'ws://localhost:8080/ws',
  httpClient: MockClient((req) async => _ok(_recordedBody(req.url.path))),
);

/// Same shapes, but every reply is [delay] late: the window between a
/// panel switch and its response is exactly where the reused slot used
/// to leak the previous panel's snapshot into build().
AdminClient slowClient(Duration delay) => AdminClient(
  serverUrl: 'ws://localhost:8080/ws',
  httpClient: MockClient((req) async {
    await Future<void>.delayed(delay);
    return _ok(_recordedBody(req.url.path));
  }),
);

Future<void> pumpDashboard(WidgetTester tester, AdminClient client) async {
  // The reported flicker happens on the desktop window (the rail is the
  // sidebar the screen is clicked through at 1280×800).
  tester.view.physicalSize = const Size(1280, 800);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    ProviderScope(
      child: MaterialApp(home: AdminDashboardScreen(client: client)),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  testWidgets("switching panels twice over reads each panel with its own data, "
      "never its neighbor's payload", (tester) async {
    await pumpDashboard(tester, recordedClient());

    // The dashboard opens on the Overview panel, fed by /admin/overview.
    expect(find.text('Overview'), findsOneWidget);
    expect(
      tester.takeException(),
      isNull,
      reason: 'the Overview panel paints without a build exception',
    );

    // Two passes over every panel, like the reported flicker: switching
    // through the whole rail and back again. Before the panel keys this
    // threw `Map is not a subtype of List?` in the Rooms panel and
    // `Null is not a subtype of String` in the Data panel.
    for (var pass = 0; pass < 2; pass++) {
      for (final label in const [
        'Stats',
        'Rooms',
        'Players',
        'Users',
        'Audit',
        'Reports',
        'Data',
      ]) {
        await tester.tap(find.text(label).first);
        await tester.pumpAndSettle();
        expect(
          tester.takeException(),
          isNull,
          reason:
              'the $label panel paints its own data, on pass $pass — '
              'not the payload of a neighboring panel whose cast chain '
              'would throw',
        );
      }
    }

    // The data actually belongs to each panel: Players lists the
    // recorded player; Data parses its real table spec (the shape whose
    // missing `pk` used to be fatal when the feedback queue's payload
    // landed in it).
    await tester.tap(find.text('Players').first);
    await tester.pumpAndSettle();
    expect(find.text('Merry Ibex 037C'), findsOneWidget);

    await tester.tap(find.text('Data').first);
    await tester.pumpAndSettle();
    expect(find.text('No rows match'), findsOneWidget);

    expect(
      tester.takeException(),
      isNull,
      reason: 'settled on Data without a build exception',
    );
  });

  testWidgets('a slow round-trip holds the loading card, switches clean', (
    tester,
  ) async {
    await pumpDashboard(tester, slowClient(const Duration(milliseconds: 50)));
    await tester.tap(find.text('Rooms').first);
    // Advance a few frames WITH the Rooms future still in flight: the
    // reused-slot behavior built against the Overview payload in this
    // window; the keyed panels show their own loading card instead.
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 30));
    expect(
      tester.takeException(),
      isNull,
      reason:
          'the in-flight Rooms window paints its loading card — never '
          'the Overview payload whose `live` Map cannot be a List',
    );
    await tester.pumpAndSettle();
    expect(find.text('No tables are open'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
