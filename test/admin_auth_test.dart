/// Auth tests: password primitives, users/sessions store, and the login /
/// setup / session-gated HTTP surface. PBKDF2 iteration counts are kept
/// small here for speed; production uses [defaultPbkdf2Iterations].
library;

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:shelf/shelf.dart' as shelf;

import 'package:game_club/server/admin_store.dart';
import 'package:game_club/server/auth.dart';

import '../bin/server.dart'
    show
        adminActionHandler,
        adminLoginHandler,
        adminLogoutHandler,
        adminMeHandler,
        adminOverviewHandler,
        adminSetupHandler,
        adminStatusHandler,
        adminUsersHandler,
        adminStore,
        adminToken,
        resetLoginAttempts;

shelf.Request _get(String path, {String? token}) => shelf.Request(
  'GET',
  Uri.parse('http://localhost/$path'),
  headers: {if (token != null) 'authorization': 'Bearer $token'},
);

shelf.Request _post(String path, Map<String, dynamic> body, {String? token}) =>
    shelf.Request(
      'POST',
      Uri.parse('http://localhost/$path'),
      headers: {
        if (token != null) 'authorization': 'Bearer $token',
        'content-type': 'application/json',
      },
      body: Stream.fromIterable([utf8.encode(jsonEncode(body))]),
    );

Future<Map<String, dynamic>> _json(shelf.Response r) async =>
    jsonDecode(await r.readAsString()) as Map<String, dynamic>;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('password primitives', () {
    test('hash verifies, wrong password does not', () {
      final hash = hashPassword('correct-horse-1', iterations: 1000);
      expect(verifyPassword('correct-horse-1', hash), isTrue);
      expect(verifyPassword('wrong', hash), isFalse);
    });

    test('salts differ, malformed hashes fail closed', () {
      final a = hashPassword('same-password', iterations: 500);
      final b = hashPassword('same-password', iterations: 500);
      expect(a, isNot(equals(b)));
      expect(verifyPassword('same-password', 'garbage'), isFalse);
      expect(verifyPassword('x', 'pbkdf2\$10\$abc'), isFalse);
    });

    test('emails normalize', () {
      expect(normalizeEmail('  Ada@Example.COM '), 'ada@example.com');
    });
  });

  group('users & sessions store', () {
    test('create/validate/revoke session', () async {
      final store = AdminStore.inMemory();
      addTearDown(store.close);
      final user = await store.createUser(
        email: 'Root@Example.com',
        name: 'Root',
        password: 'long-enough-1',
        role: 'admin',
        iterations: 1000,
      );
      expect(user.email, 'root@example.com');
      expect(user.isAdmin, isTrue);

      expect(await store.checkCredentials('root@example.com', 'nope'), isNull);
      expect(
        await store.checkCredentials('nobody@example.com', 'long-enough-1'),
        isNull,
      );
      final authed = await store.checkCredentials(
        'ROOT@example.com',
        'long-enough-1',
      );
      expect(authed?.id, user.id);

      final session = await store.createSession(user.id);
      expect((await store.validateSession(session.token))?.id, user.id);
      await store.revokeSession(session.token);
      expect(await store.validateSession(session.token), isNull);
    });

    test('expired sessions die, short passwords and dupes rejected', () async {
      final store = AdminStore.inMemory();
      addTearDown(store.close);
      final user = await store.createUser(
        email: 'a@x.io',
        name: 'A',
        password: 'long-enough-1',
        iterations: 500,
      );
      final short = await store.createSession(
        user.id,
        ttl: const Duration(milliseconds: 1),
      );
      await Future<void>.delayed(const Duration(milliseconds: 15));
      expect(await store.validateSession(short.token), isNull);

      await expectLater(
        store.createUser(email: 'b@x.io', name: 'B', password: 'short'),
        throwsArgumentError,
      );
      await expectLater(
        store.createUser(
          email: 'a@x.io',
          name: 'A2',
          password: 'long-enough-1',
        ),
        throwsStateError,
      );
    });
  });

  group('setup + login HTTP', () {
    test('status, one-time setup, login, me, logout', () async {
      final savedStore = adminStore;
      final savedToken = adminToken;
      adminStore = AdminStore.inMemory();
      adminToken = 'test-secret';
      addTearDown(() {
        adminStore = savedStore;
        adminToken = savedToken;
      });
      resetLoginAttempts();

      expect((await _json(await adminStatusHandler(_get('x'))))['setupRequired'], isTrue);

      // Weak password rejected, no user created.
      final weak = await adminSetupHandler(
        _post('admin/setup', {
          'email': 'r@x.io',
          'password': 'short',
          'setupToken': 'test-secret',
        }),
      );
      expect(weak.statusCode, 400);

      final setup = await adminSetupHandler(
        _post('admin/setup', {
          'email': 'Root@x.io',
          'name': 'Root',
          'password': 'long-enough-1',
          'setupToken': 'test-secret',
        }),
      );
      expect(setup.statusCode, 200);
      final setupJson = await _json(setup);
      final token = setupJson['token'] as String;
      expect((setupJson['user'] as Map)['role'], 'admin');

      expect((await _json(await adminStatusHandler(_get('x'))))['setupRequired'], isFalse);

      // Setup is one-time.
      final again = await adminSetupHandler(
        _post('admin/setup', {
          'email': 'r2@x.io',
          'password': 'long-enough-1',
          'setupToken': 'test-secret',
        }),
      );
      expect(again.statusCode, 403);

      // Wrong password: generic 401, no enumeration.
      final bad = await adminLoginHandler(
        _post('admin/login', {'email': 'root@x.io', 'password': 'wrong-pass-1'}),
      );
      expect(bad.statusCode, 401);
      expect((await _json(bad))['text'], 'invalid credentials');

      final login = await adminLoginHandler(
        _post('admin/login', {
          'email': 'root@x.io',
          'password': 'long-enough-1',
        }),
      );
      expect(login.statusCode, 200);
      final loginToken = (await _json(login))['token'] as String;

      // Session authorizes admin endpoints.
      final overview = await adminOverviewHandler(
        _get('admin/overview', token: loginToken),
      );
      expect(overview.statusCode, 200);

      final me = await adminMeHandler(_get('admin/me', token: loginToken));
      expect(me.statusCode, 200);
      expect((await _json(me))['user']['email'], 'root@x.io');

      // Logout kills the session.
      await adminLogoutHandler(_post('admin/logout', {}, token: loginToken));
      expect(
        (await adminOverviewHandler(_get('admin/overview', token: loginToken)))
            .statusCode,
        403,
      );
      expect(token, isNotEmpty);
    });

    test('setup requires the setup secret when ADMIN_TOKEN is set', () async {
      final savedStore = adminStore;
      final savedToken = adminToken;
      adminStore = AdminStore.inMemory();
      adminToken = 'service-secret';
      addTearDown(() {
        adminStore = savedStore;
        adminToken = savedToken;
      });

      final denied = await adminSetupHandler(
        _post('admin/setup', {'email': 'r@x.io', 'password': 'long-enough-1'}),
      );
      expect(denied.statusCode, 403);

      final ok = await adminSetupHandler(
        _post('admin/setup', {
          'email': 'r@x.io',
          'password': 'long-enough-1',
          'setupToken': 'service-secret',
        }),
      );
      expect(ok.statusCode, 200);
    });

    test('setup is disabled without ADMIN_TOKEN (fail closed)', () async {
      // Regression lock for the GHAS finding: an open first-run setup lets
      // anyone who reaches /admin/setup first claim the instance. With no
      // token configured the endpoint must refuse — even with no users yet.
      final savedStore = adminStore;
      final savedToken = adminToken;
      adminStore = AdminStore.inMemory();
      adminToken = '';
      addTearDown(() {
        adminStore = savedStore;
        adminToken = savedToken;
      });

      final denied = await adminSetupHandler(
        _post('admin/setup', {
          'email': 'r@x.io',
          'password': 'long-enough-1',
        }),
      );
      expect(denied.statusCode, 403);
      expect((await _json(denied))['text'], contains('ADMIN_TOKEN'));
      // Nothing was created: the hole stays closed.
      expect(await adminStore.needsSetup, isTrue);
    });

    test('non-admin sessions cannot touch admin endpoints', () async {
      final savedStore = adminStore;
      final savedToken = adminToken;
      adminStore = AdminStore.inMemory();
      adminToken = 'legacy';
      addTearDown(() {
        adminStore = savedStore;
        adminToken = savedToken;
      });
      resetLoginAttempts();

      await adminStore.createUser(
        email: 'admin@x.io',
        name: 'A',
        password: 'long-enough-1',
        role: 'admin',
        iterations: 500,
      );
      await adminStore.createUser(
        email: 'player@x.io',
        name: 'P',
        password: 'long-enough-1',
        role: 'user',
        iterations: 500,
      );
      final adminSession = await adminStore.createSession(
        (await adminStore.findUserByEmail('admin@x.io'))!.id,
      );
      final userSession = await adminStore.createSession(
        (await adminStore.findUserByEmail('player@x.io'))!.id,
      );

      expect(
        (await adminOverviewHandler(
          _get('admin/overview', token: userSession.token),
        )).statusCode,
        403,
      );
      // Legacy service token keeps working for automation.
      expect(
        (await adminOverviewHandler(_get('admin/overview', token: 'legacy')))
            .statusCode,
        200,
      );
      // Moderation attributed to the session identity, not a static string.
      final ban = await adminActionHandler(
        _post('admin/ban', {'seatId': 's9'}, token: adminSession.token),
      );
      expect(ban.statusCode, 200);
      final log = await adminStore.auditLog(limit: 5);
      expect(
        log.any((e) => e.action == 'ban' && e.by == 'admin@x.io'),
        isTrue,
      );
    });

    test('login rate-limits brute force', () async {
      final savedStore = adminStore;
      final savedToken = adminToken;
      adminStore = AdminStore.inMemory();
      adminToken = '';
      addTearDown(() {
        adminStore = savedStore;
        adminToken = savedToken;
      });
      resetLoginAttempts();

      shelf.Response last = await adminLoginHandler(
        _post('admin/login', {'email': 'ghost@x.io', 'password': 'wrong-1'}),
      );
      for (var i = 0; i < 12; i++) {
        last = await adminLoginHandler(
          _post('admin/login', {'email': 'ghost@x.io', 'password': 'wrong-2'}),
        );
      }
      expect(last.statusCode, 429);
    });

    test('admin can list and create users', () async {
      final savedStore = adminStore;
      final savedToken = adminToken;
      adminStore = AdminStore.inMemory();
      adminToken = 'legacy-2';
      addTearDown(() {
        adminStore = savedStore;
        adminToken = savedToken;
      });

      final created = await adminUsersHandler(
        _post('admin/users', {
          'email': 'mod@x.io',
          'name': 'Mod',
          'password': 'long-enough-1',
          'role': 'moderator',
        }, token: 'legacy-2'),
      );
      expect(created.statusCode, 200);

      final listed = await adminUsersHandler(
        _get('admin/users', token: 'legacy-2'),
      );
      expect(listed.statusCode, 200);
      final users = (await _json(listed))['users'] as List;
      expect(users.single['role'], 'moderator');

      // Unknown roles rejected.
      final bad = await adminUsersHandler(
        _post('admin/users', {
          'email': 'x@x.io',
          'password': 'long-enough-1',
          'role': 'superuser',
        }, token: 'legacy-2'),
      );
      expect(bad.statusCode, 400);
    });
  });
}
