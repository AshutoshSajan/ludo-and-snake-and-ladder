/// The home admin door must survive a refresh.
///
/// A cold load has no in-memory snapshot to read, so the door used to
/// vanish for the operator the cookie still admits — the refresh bug seen
/// from the other side. The provider now asks `/admin/me` once, and these
/// pin both what the answer does and what the absence of one does: no
/// door, never a bounce.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:game_club/providers/app_providers.dart';
import 'package:game_club/screens/home_screen.dart';
import 'package:game_club/services/admin_client.dart';

/// The answer a live cookie earns from `/admin/me`.
http.Response _signedIn({String email = 'root@x.io', String name = 'Root'}) =>
    http.Response(
      '{"ok":true,"user":{"email":"$email","name":"$name"}}',
      200,
      headers: {'content-type': 'application/json'},
    );

http.Response _refused() => http.Response(
  '{"ok":false,"text":"session required"}',
  401,
  headers: {'content-type': 'application/json'},
);

/// An [AdminClient] whose every answer comes from [handler], with the
/// server URL the production client would use.
AdminClient Function() _client(
  Future<http.Response> Function(http.Request request) handler,
) =>
    () => AdminClient(
      serverUrl: 'ws://localhost:8080/ws',
      httpClient: MockClient(handler),
    );

ProviderContainer _container(AdminClient Function()? build) {
  final container = ProviderContainer(
    overrides: [adminRestoreClientProvider.overrideWithValue(build)],
  );
  addTearDown(container.dispose);
  return container;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('a cold load with a live cookie names the operator', () async {
    var asked = 0;
    final container = _container(
      _client((request) async {
        asked++;
        expect(request.url.path, '/admin/me');
        return _signedIn();
      }),
    );

    // The synchronous first read is signed-nobody: the door waits for the
    // server rather than guessing.
    expect(container.read(adminSessionProvider), isNull);
    await pumpEventQueue();

    expect(asked, 1);
    final session = container.read(adminSessionProvider);
    expect(session, isNotNull);
    expect(session!.email, 'root@x.io');
    expect(session.name, 'Root');
  });

  test('a refused cookie leaves the door shut, not an error', () async {
    final container = _container(_client((_) async => _refused()));

    container.read(adminSessionProvider);
    await pumpEventQueue();

    expect(container.read(adminSessionProvider), isNull);
  });

  test('an unreachable server answers the same as a refused cookie', () async {
    final container = _container(
      _client((_) async => throw http.ClientException('connection refused')),
    );

    container.read(adminSessionProvider);
    await pumpEventQueue();

    expect(container.read(adminSessionProvider), isNull);
  });

  test('off-web there is no cookie lane, so no probe and no session', () async {
    // No override here: the production default answers null off-web,
    // because native builds hold the session token in memory only.
    final container = ProviderContainer();
    addTearDown(container.dispose);

    container.read(adminSessionProvider);
    await pumpEventQueue();

    expect(container.read(adminSessionProvider), isNull);
  });

  test('a sign-in that lands first is not overwritten by the probe', () async {
    final answer = Completer<http.Response>();
    final container = _container(_client((_) => answer.future));

    container.read(adminSessionProvider);
    container
        .read(adminSessionProvider.notifier)
        .signIn(const AdminSession(email: 'human@x.io', name: 'Human'));
    answer.complete(_signedIn());
    await pumpEventQueue();

    expect(container.read(adminSessionProvider)!.email, 'human@x.io');
  });

  test('a rebuilt provider restores again, not just its first build', () async {
    var asked = 0;
    final container = _container(
      _client((_) async {
        asked++;
        return _signedIn();
      }),
    );
    // A listener keeps the provider alive across the invalidation, which is
    // what any real refresh affordance would do.
    container.listen(adminSessionProvider, (_, _) {});
    await pumpEventQueue();
    expect(asked, 1);
    expect(container.read(adminSessionProvider), isNotNull);

    container.invalidate(adminSessionProvider);
    await pumpEventQueue();

    expect(asked, 2, reason: 'the rebuild asks the cookie again');
    expect(
      container.read(adminSessionProvider),
      isNotNull,
      reason: 'the second answer must land too, not be dropped as stale',
    );
  });

  test('a 403 on the probe is a dead cookie too', () async {
    final container = _container(
      _client(
        (_) async => http.Response(
          '{"ok":false,"text":"forbidden"}',
          403,
          headers: {'content-type': 'application/json'},
        ),
      ),
    );

    container.read(adminSessionProvider);
    await pumpEventQueue();

    expect(container.read(adminSessionProvider), isNull);
  });

  test('an answer without a usable user keeps the door shut', () async {
    const bodies = [
      '{"ok":true}', // no user at all
      '{"ok":true,"user":"nope"}', // wrong shape
      '{"ok":true,"user":{"name":"Root"}}', // no email to name the door with
    ];
    for (final body in bodies) {
      final container = _container(
        _client(
          (_) async => http.Response(
            body,
            200,
            headers: {'content-type': 'application/json'},
          ),
        ),
      );
      container.read(adminSessionProvider);
      await pumpEventQueue();
      expect(container.read(adminSessionProvider), isNull, reason: body);
    }
  });

  testWidgets('a server that never answers times out into no door', (
    tester,
  ) async {
    // A black-holed network answers nothing at all, which is neither a 401
    // nor a connection refusal: without a deadline the door stays undecided
    // for the OS TCP timeout.
    final answer = Completer<http.Response>();
    final container = _container(_client((_) => answer.future));

    container.read(adminSessionProvider);
    await tester.pump(const Duration(seconds: 6));

    // The late answer must not resurrect the door: the probe already gave up.
    answer.complete(_signedIn());
    await tester.pump();

    expect(container.read(adminSessionProvider), isNull);
  });

  test('signing out clears the snapshot the door reads', () async {
    final container = _container(_client((_) async => _signedIn()));
    container.read(adminSessionProvider);
    await pumpEventQueue();
    expect(container.read(adminSessionProvider), isNotNull);

    container.read(adminSessionProvider.notifier).signOut();
    expect(container.read(adminSessionProvider), isNull);
  });

  testWidgets('home grows the admin door once the cookie is proven', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({'gc.tutorialAsked': true});
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          adminRestoreClientProvider.overrideWithValue(
            _client((_) async => _signedIn()),
          ),
        ],
        child: const MaterialApp(home: HomeScreen()),
      ),
    );

    // First frame: the probe has not answered, so signed-nobody.
    expect(find.byKey(const ValueKey('home-admin-door')), findsNothing);

    await tester.pump();
    await tester.pump(const Duration(milliseconds: 60));

    expect(find.byKey(const ValueKey('home-admin-door')), findsOneWidget);
    expect(find.text('Admin'), findsOneWidget);
  });

  testWidgets('home keeps the door shut for a browser without a session', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({'gc.tutorialAsked': true});
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          adminRestoreClientProvider.overrideWithValue(
            _client((_) async => _refused()),
          ),
        ],
        child: const MaterialApp(home: HomeScreen()),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 60));

    expect(find.byKey(const ValueKey('home-admin-door')), findsNothing);
    // The rest of the row is untouched: Settings keeps its place.
    expect(find.text('Settings'), findsOneWidget);
  });
}
