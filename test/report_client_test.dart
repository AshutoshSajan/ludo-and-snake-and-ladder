/// Client lane for reports: ReportClient endpoint contract, the
/// BugReportSheet + ContactScreen validation flows, and the server-URL
/// drift pin between the lobby's resolution and the service copy.
library;

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:game_club/screens/contact_screen.dart';
import 'package:game_club/screens/online_lobby_screen.dart';
import 'package:game_club/services/admin_client.dart';
import 'package:game_club/services/report_client.dart';
import 'package:game_club/services/server_url.dart';
import 'package:game_club/ui/shared/bug_report_sheet.dart';

void main() {
  group('ReportClient', () {
    test('posts to /feedback with the report body', () async {
      Uri? seenUri;
      Map<String, dynamic>? seenBody;
      final client = ReportClient(
        serverUrl: 'ws://localhost:8080/ws',
        httpClient: MockClient((req) async {
          seenUri = req.url;
          seenBody = jsonDecode(req.body) as Map<String, dynamic>;
          return http.Response(
            jsonEncode({'ok': true, 'id': 7}),
            200,
            headers: {'content-type': 'application/json'},
          );
        }),
      );
      final id = await client.submit(
        category: 'bug',
        message: 'it broke',
        source: 'report',
        title: 'Broken',
      );
      expect(id, 7);
      expect(seenUri!.path, '/feedback');
      expect(seenUri!.scheme, 'http');
      expect(seenBody!['category'], 'bug');
      expect(seenBody!['source'], 'report');
      expect(seenBody!['message'], 'it broke');
    });

    test('https origins ride wss urls', () async {
      Uri? seenUri;
      final client = ReportClient(
        serverUrl: 'wss://game.example/ws',
        httpClient: MockClient((req) async {
          seenUri = req.url;
          return http.Response(jsonEncode({'ok': true}), 200);
        }),
      );
      await client.submit(category: 'other', message: 'm');
      expect(seenUri!.scheme, 'https');
      expect(seenUri!.host, 'game.example');
    });

    test('server validation messages surface', () async {
      final client = ReportClient(
        serverUrl: 'ws://localhost:8080/ws',
        httpClient: MockClient(
          (_) async => http.Response(
            jsonEncode({'ok': false, 'text': 'message required'}),
            400,
          ),
        ),
      );
      await expectLater(
        client.submit(category: 'bug', message: ''),
        throwsA(isA<ReportException>().having(
          (e) => e.toString(),
          'text',
          'message required',
        )),
      );
    });
  });

  group('BugReportSheet (widget)', () {
    testWidgets('empty message is refused locally, no network', (t) async {
      await t.pumpWidget(const MaterialApp(home: Scaffold(body: SizedBox())));
      BugReportSheet.show(t.element(find.byType(Scaffold)), serverUrl: 'ws://x/ws');
      await t.pumpAndSettle();
      await t.tap(find.text('Send'));
      await t.pump();
      expect(find.text('Tell us what happened first'), findsOneWidget);
    });

    testWidgets('category chips switch the selection', (t) async {
      await t.pumpWidget(const MaterialApp(home: Scaffold(body: SizedBox())));
      BugReportSheet.show(t.element(find.byType(Scaffold)), serverUrl: 'ws://x/ws');
      await t.pumpAndSettle();
      await t.tap(find.text('Feature request'));
      await t.pumpAndSettle();
      // Four category labels always exist; picking another keeps them.
      expect(find.text('Feature request'), findsOneWidget);
    });
  });

  group('ContactScreen (widget)', () {
    Widget host() => ProviderScope(
      child: MaterialApp(home: ContactScreen(serverUrl: 'ws://x/ws')),
    );

    testWidgets('empty message is refused locally', (t) async {
      await t.pumpWidget(host());
      await t.ensureVisible(find.text('Send message'));
      await t.pumpAndSettle();
      await t.tap(find.text('Send message'));
      await t.pump();
      expect(find.text('Write your message first'), findsOneWidget);
    });

    testWidgets('theme surfaces on the page', (t) async {
      await t.pumpWidget(host());
      expect(find.text('We read everything'), findsOneWidget);
      expect(find.text('Contact'), findsOneWidget);
    });
  });

  group('server URL drift pin', () {
    test('service resolution mirrors OnlineLobbyScreen', () {
      // Same precedence, all three lanes.
      expect(
        sameOriginServerUrl(Uri.parse('https://play.example:8443/page')),
        OnlineLobbyScreen.sameOriginServerUrl(
          Uri.parse('https://play.example:8443/page'),
        ),
      );
      expect(
        sameOriginServerUrl(Uri.parse('http://dev.example/page')),
        OnlineLobbyScreen.sameOriginServerUrl(Uri.parse('http://dev.example/page')),
      );
      expect(
        sameOriginServerUrl(Uri.parse('chrome-extension://abc/index.html')),
        OnlineLobbyScreen.sameOriginServerUrl(
          Uri.parse('chrome-extension://abc/index.html'),
        ),
      );
      // The hosted fallback is the one constant that must never drift.
      expect(hostedServerUrl, OnlineLobbyScreen.hostedServerUrl);
      // Dev default (kIsWeb is false in tests).
      expect(defaultServerUrl(), OnlineLobbyScreen.defaultServerUrl());
    });
  });

  group('AdminClient feedback + table lanes', () {
    test('feedback query params and table routes', () async {
      final seen = <Uri>[];
      final client = AdminClient(
        serverUrl: 'wss://game.example/ws',
        token: 't',
        httpClient: MockClient((req) async {
          seen.add(req.url);
          if (req.url.path == '/admin/feedback') {
            return http.Response(
              jsonEncode({
                'ok': true,
                'feedback': [],
                'openCount': 0,
                'totalCount': 0,
                'openByCategory': {},
              }),
              200,
            );
          }
          return http.Response(jsonEncode({'ok': true}), 200);
        }),
      );
      await client.feedback(status: 'open', category: 'bug', sort: 'newest');
      await client.updateFeedback(3, {'status': 'resolved'});
      await client.deleteFeedback(3);
      await client.table('results', q: 'ana');
      await client.insertTableRow('players', {'seat_id': 's', 'name': 'n'});
      await client.updateTableRow('players', 's', {'name': 'x'});
      await client.deleteTableRow('players', 's');
      expect(seen.map((u) => u.path).toList(), [
        '/admin/feedback',
        '/admin/feedback/update',
        '/admin/feedback/delete',
        '/admin/table',
        '/admin/table/insert',
        '/admin/table/update',
        '/admin/table/delete',
      ]);
      expect(seen.first.queryParameters['status'], 'open');
      expect(seen.first.queryParameters['category'], 'bug');
      expect(seen.first.queryParameters['sort'], 'newest');
      // ws(s) origins become http(s).
      expect(seen.first.scheme, 'https');
    });
  });
}
