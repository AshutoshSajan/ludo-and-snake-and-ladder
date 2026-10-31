/// The HTTP entry's page rule for the auth URLs.
///
/// `/admin/login` and `/admin/signup` are real browser pages a bookmark,
/// a reload, or a shared link can reopen — and the API switch also claims
/// those names for their POST endpoints. Before the page rule existed the
/// switch's POST-only refusal won: `GET /admin/login` answered raw JSON
/// `405 Method Not Allowed`, so refreshing the login page showed an
/// unstyled error instead of the app. These tests drive `httpHandler`
/// itself, so the wiring is under test, not a parallel copy of the
/// router.
///
/// `/admin/setup` and `/admin/logout` are deliberately NOT pages: a GET
/// there stays a protocol misuse and keeps its 405.
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:game_club/server/admin_store.dart';
import 'package:shelf/shelf.dart' as shelf;

import '../bin/server.dart' show httpHandler, serverEnv, adminStore, adminToken;

/// The stub web build. The serving tests point `serverEnv['WEB_DIR']` at
/// this directory, which [webDir] reads before its defaults.
final Directory stubWeb = () {
  final dir = Directory.systemTemp.createTempSync('gc_web_stub');
  File('${dir.path}/index.html')
      .writeAsStringSync('<title>gc-shell-stub</title>');
  return dir;
}();

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // One stub web build per suite; deleted when the suite ends.
  tearDownAll(() {
    try {
      stubWeb.deleteSync(recursive: true);
    } catch (_) {}
  });

  // adminStore / serverEnv / adminToken are the same globals main() fills
  // for a production boot; each test swaps them with a restore, as the
  // other handler tests do.
  void useTestGate() {
    final savedStore = adminStore;
    final savedToken = adminToken;
    final savedEnv = serverEnv;
    adminStore = AdminStore.inMemory(bcryptRounds: 4);
    adminToken = '';
    serverEnv = {'WEB_DIR': stubWeb.path};
    addTearDown(() {
      adminStore = savedStore;
      adminToken = savedToken;
      serverEnv = savedEnv;
    });
  }

  Future<shelf.Response> call(String method, String path) => httpHandler(
    shelf.Request(
      method,
      Uri.parse('http://localhost$path'),
      headers: const {'content-type': 'application/json'},
    ),
  );

  Future<Map<String, dynamic>> jsonBody(shelf.Response r) async =>
      jsonDecode(await r.readAsString()) as Map<String, dynamic>;

  group('auth page URLs are served to browsers', () {
    test(
      'a GET for /admin/login reaches the web build, not a JSON 405',
      () async {
        useTestGate();
        final r = await call('GET', '/admin/login');
        expect(
          r.statusCode,
          200,
          reason: 'a reload or deep link must open the app',
        );
        expect(r.headers['content-type'], startsWith('text/html'));
        expect(
          await r.readAsString(),
          contains('gc-shell-stub'),
          reason: 'the shell, not an API body',
        );
      },
    );

    test('a GET for /admin/signup reaches the web build too', () async {
      useTestGate();
      final r = await call('GET', '/admin/signup');
      expect(r.statusCode, 200);
      expect(r.headers['content-type'], startsWith('text/html'));
      expect(await r.readAsString(), contains('gc-shell-stub'));
    });
  });

  group('the API forms keep their contract under the page rule', () {
    test('POST /admin/login still reaches the API switch', () async {
      useTestGate();
      // No users exist in this store, so the API path must answer 401 in
      // its {ok, text} shape — proof the page rule did not swallow POSTs.
      final r = await call('POST', '/admin/login');
      expect(r.statusCode, 401);
      expect((await jsonBody(r))['ok'], isFalse);
    });

    test('GET /admin/setup stays a POST-only 405 — it is not a page', () async {
      useTestGate();
      final r = await call('GET', '/admin/setup');
      expect(r.statusCode, 405);
      expect((await jsonBody(r))['text'], 'POST only');
    });
  });

  group('the untouched static behaviour keeps its guarantees', () {
    test('the shell loads at / and under /admin as before', () async {
      useTestGate();
      for (final page in ['/', '/admin', '/admin/dashboard']) {
        final r = await call('GET', page);
        expect(r.statusCode, 200, reason: page);
        expect(r.headers['content-type'], startsWith('text/html'));
        expect(await r.readAsString(), contains('gc-shell-stub'), reason: page);
      }
    });

    test('an extension-based asset miss still answers 404', () async {
      useTestGate();
      final r = await call('GET', '/assets/nope.js');
      expect(r.statusCode, 404);
    });
  });
}
