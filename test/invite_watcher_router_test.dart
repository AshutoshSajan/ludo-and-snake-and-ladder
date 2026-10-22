/// The production router must own the watcher's navigator key.
///
/// The watcher's widget tests pass their own `MaterialApp(navigatorKey:)`,
/// so a router that forgot to attach the key would still leave every unit
/// test green while the real app polled into a null context and never
/// knocked. This test mounts the production `RouterConfig` instead.
library;

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:game_club/app_router.dart';
import 'package:game_club/screens/invite_watcher.dart';
import 'package:game_club/services/friend_client.dart';
import 'package:game_club/ui/theme.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('the production router attaches the watcher navigator key', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({'gc.tutorialAsked': true});
    final watcher = InviteWatcher(
      interval: const Duration(milliseconds: 50),
      clientFactory: () => FriendClient(
        serverUrl: 'wss://test/ws',
        httpClient: MockClient((req) async {
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
                'invites': [
                  {
                    'id': 7,
                    'from': {
                      'seatId': 'buddy',
                      'name': 'Swift Otter',
                      'code': 'JKXQWB',
                    },
                    'to': {'seatId': 'p2', 'name': 'Bo', 'code': 'PRK7VW'},
                    'game': 'ludo',
                    'code': '',
                    'status': 'pending',
                    'createdAt': 10,
                  },
                ],
              }),
              200,
            );
          }
          return http.Response('{}', 200);
        }),
      ),
      identityOverride: Future.value((seatId: 'p2', name: 'Bo')),
      chime: () async {},
    );

    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp.router(
          theme: AppTheme.dark(),
          routerConfig: createAppRouterConfig(),
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 60));

    expect(
      InviteWatcher.navigatorKey.currentContext,
      isNotNull,
      reason:
          'without this key every production poll returns at the first '
          'line and the invite never knocks',
    );

    watcher.start();
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 260));

    expect(find.text('Play invite'), findsOneWidget);
    watcher.stop();
  });
}
