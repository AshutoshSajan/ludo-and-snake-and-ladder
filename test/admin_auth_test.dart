/// Auth tests: bcrypt password primitives, the users/sessions store, and
/// the login / setup / session-gated HTTP surface. Bcrypt costs are
/// threaded small (`rounds: 4`) for speed; production digests at
/// [defaultBcryptRounds] = 12. The absent-email decoy ([absentEmailHash])
/// is coupled to production verification and pays ~370ms per probe, so
/// the tests that touch absent probes are the slow ones, on purpose:
/// no test seam may ever cheapen what an attacker pays.
library;

import 'dart:convert';
import 'dart:io';

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
        adminSessionCookie,
        adminSetupHandler,
        adminStatusHandler,
        adminUsersHandler,
        adminStore,
        adminToken,
        clientIpWithForwarding,
        resetLoginAttempts,
        trustedProxies,
        trustedProxiesFromEnv;

shelf.Request _get(String path, {String? cookie, String? bearer}) =>
    shelf.Request(
      'GET',
      Uri.parse('http://localhost/$path'),
      headers: {
        'cookie': ?cookie,
        if (bearer != null) 'authorization': 'Bearer $bearer',
      },
    );

shelf.Request _post(
  String path,
  Map<String, dynamic> body, {
  String? cookie,
  String? bearer,
}) =>
    shelf.Request(
      'POST',
      Uri.parse('http://localhost/$path'),
      headers: {
        'cookie': ?cookie,
        if (bearer != null) 'authorization': 'Bearer $bearer',
        'content-type': 'application/json',
      },
      body: Stream.fromIterable([utf8.encode(jsonEncode(body))]),
    );

/// The `name=value` pair a successful setup/login answers with, ready to
/// be presented back as a `Cookie` header (attributes trimmed off — a
/// browser keeps HttpOnly/Max-Age for itself and re-sends only the pair).
/// [maxAgeSeconds] must equal the store's [AdminStore.sessionTtl]: the
/// cookie's advertised lifetime is exactly what the session row was
/// granted, or the browser would spend a credential the server refused.
String _sessionCookiePair(
  shelf.Response resp, {
  required int maxAgeSeconds,
}) {
  final set = resp.headers['set-cookie'];
  expect(set, isNotNull,
      reason: 'an auth success must mint the session cookie');
  expect(set, startsWith('$adminSessionCookie='),
      reason: 'the credential travels under the session cookie name');
  expect(set, contains('HttpOnly'),
      reason: 'the security property: no page script can read the token');
  expect(set, contains('SameSite=Strict'));
  expect(set, contains('Max-Age=$maxAgeSeconds'),
      reason: 'the cookie must live exactly as long as the session row');
  return set!.split(';').first.trim();
}

Future<Map<String, dynamic>> _json(shelf.Response r) async =>
    jsonDecode(await r.readAsString()) as Map<String, dynamic>;

/// Stands in for `HttpConnectionInfo` at the `shelf.io.connection_info`
/// key so requests can carry a chosen socket peer (see [_postFrom]).
class _ConnInfo {
  _ConnInfo(this.remoteAddress);

  final InternetAddress? remoteAddress;
}

/// A failed-login POST arriving [from] the given socket peer, optionally
/// carrying an `x-forwarded-for` chain. Login exercised the identity
/// plane: a miss records into the per-IP bucket.
shelf.Request _postFrom(
  String path,
  String bodyJson, {
  InternetAddress? from,
  String? xff,
}) {
  final conn = from == null ? null : _ConnInfo(from);
  return shelf.Request(
    'POST',
    Uri.parse('http://localhost/$path'),
    headers: {'content-type': 'application/json', 'x-forwarded-for': ?xff},
    context: {'shelf.io.connection_info': ?conn},
    body: Stream.fromIterable([utf8.encode(bodyJson)]),
  );
}

InternetAddress _addr(String literal) => InternetAddress.tryParse(literal)!;

/// A store whose password checks always miss without paying the
/// production bcrypt — for tests about the rate limiter, not credential
/// verification. A real (but unmatchable) account is seeded inside so
/// every miss rides the injected verifier; an absent email cannot be
/// cheapened this way — it always verifies the [absentEmailHash] decoy
/// through the production path, which is exactly the property its own
/// test below asserts.
Future<AdminStore> _missStore() async {
  final store = AdminStore.inMemory(
    verifier: (password, hash) => false,
    bcryptRounds: 4,
  );
  addTearDown(store.close);
  await store.createUser(
    email: 'ghost@x.io',
    name: 'Ghost',
    password: 'long-enough-1',
    role: 'user',
    by: 'test',
  );
  return store;
}

const _loginMiss = '{"email":"ghost@x.io","password":"wrong-1"}';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('password primitives', () {
    test('hash verifies, wrong password does not', () {
      final hash = hashPassword('correct-horse-1', rounds: 4);
      expect(verifyPassword('correct-horse-1', hash), isTrue);
      expect(verifyPassword('wrong', hash), isFalse);
    });

    test('salts differ, malformed hashes fail closed', () {
      final a = hashPassword('same-password', rounds: 4);
      final b = hashPassword('same-password', rounds: 4);
      expect(a, isNot(equals(b)));
      expect(verifyPassword('same-password', 'garbage'), isFalse);
      expect(verifyPassword('x', r'$2a$12$'), isFalse,
          reason: 'a truncated row must read as a miss, never a throw');
      expect(verifyPassword('x', r'$2a$10$not-a-valid-mime-b64-salt!!'), isFalse,
          reason: 'a corrupt salt must fail closed too');
    });

    test('emails normalize', () {
      expect(normalizeEmail('  Ada@Example.COM '), 'ada@example.com');
    });

    test('the production cost stays 12 — the measured inline budget', () {
      // Benched on this repo's server hardware: cost 12 takes ~370ms per
      // hash or verify, fine inline on the event loop; cost 14 or more
      // would demand Isolate.run again before the next login is served.
      // The decoy must never be minted cheaper than what production
      // digests at, or timing separates the two paths.
      expect(defaultBcryptRounds, 12);
      expect(absentEmailHash, startsWith(r'$2a$12$'));
    });

    test('an absent email cannot dodge the work factor', () async {
      // The verifier seam records each hash it is asked about, so the two
      // branches are observable separately — no timing flake: the seam
      // sees nothing on the absent path (it rides production
      // [verifyPassword] against the [absentEmailHash] const) while a
      // real account's miss is exactly one seam verification.
      final verified = <String>[];
      final store = AdminStore.inMemory(
        bcryptRounds: 4,
        verifier: (password, hash) {
          verified.add(hash);
          return false;
        },
      );
      addTearDown(store.close);

      final sw = Stopwatch()..start();
      expect(
        await store.checkCredentials('nobody@example.com', 'long-enough-1'),
        isNull,
      );
      sw.stop();
      expect(
        verified,
        isEmpty,
        reason: 'the injected verifier must be bypassed on the absent path: '
            'a seam in the way would let a test quietly skip the decoy '
            'while production pays',
      );
      // Cost 12 benches ~370ms on this repo's hardware, so a generous
      // floor still separates a real schedule from a skipped one (~0ms).
      // This assertion is the slow one — that is the security property
      // making itself felt.
      expect(
        sw.elapsed,
        greaterThan(const Duration(milliseconds: 100)),
        reason: 'absent probes pay the full bcrypt schedule (CWE-208): '
            'anything under ~100ms here means the work was skipped',
      );

      // A real account's wrong password runs exactly one verification —
      // through the seam, which is what lets rounds-threaded tests stay
      // fast without ever touching the absent branch.
      await store.createUser(
        email: 'root@example.com',
        name: 'Root',
        password: 'long-enough-1',
        by: 'test',
      );
      verified.clear();
      expect(
        await store.checkCredentials('root@example.com', 'wrong-1'),
        isNull,
      );
      expect(verified, hasLength(1));
      // Bcrypt rows are self-describing: salt and cost live in the stored
      // string, so verification needs nothing else fetched beside it.
      expect(verified.single, startsWith(r'$2a$'));
    });
  });

  group('users & sessions store', () {
    test('create/validate/revoke session', () async {
      final store = AdminStore.inMemory(bcryptRounds: 4);
      addTearDown(store.close);
      final user = await store.createUser(
        email: 'Root@Example.com',
        name: 'Root',
        password: 'long-enough-1',
        role: 'admin',
      );
      expect(user.email, 'root@example.com');
      expect(user.isAdmin, isTrue);

      expect(await store.checkCredentials('root@example.com', 'nope'), isNull);
      // Absent probe: pays the production decoy verify (~370ms) by design.
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
      final store = AdminStore.inMemory(
        bcryptRounds: 4,
        sessionTtl: const Duration(milliseconds: 1),
      );
      addTearDown(store.close);
      final user = await store.createUser(
        email: 'a@x.io',
        name: 'A',
        password: 'long-enough-1',
      );
      final short = await store.createSession(user.id);
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
      adminStore = AdminStore.inMemory(bcryptRounds: 4);
      adminToken = 'test-secret';
      addTearDown(() {
        adminStore = savedStore;
        adminToken = savedToken;
      });
      resetLoginAttempts();

      expect(
        (await _json(await adminStatusHandler(_get('x'))))['setupRequired'],
        isTrue,
      );

      // Weak password rejected, no user created.
      final weak = await adminSetupHandler(
        _post('admin/setup', {
          'email': 'r@x.io',
          'password': 'short',
          'setupToken': 'test-secret',
        }),
      );
      expect(weak.statusCode, 400);

      // The endpoint applies the form's shared strength rules: a password
      // that has length but no symbol, an invalid email, and an overlong
      // password are all refused before anything is created.
      final noSymbol = await adminSetupHandler(
        _post('admin/setup', {
          'email': 'r@x.io',
          'password': 'alllettersonly1',
          'setupToken': 'test-secret',
        }),
      );
      expect(noSymbol.statusCode, 400);
      expect((await _json(noSymbol))['text'], 'Add at least one symbol.');

      final badEmail = await adminSetupHandler(
        _post('admin/setup', {
          'email': 'root@',
          'password': 'long-enough-1',
          'setupToken': 'test-secret',
        }),
      );
      expect(badEmail.statusCode, 400);
      expect((await _json(badEmail))['text'], 'Enter a valid email address.');

      final tooLong = await adminSetupHandler(
        _post('admin/setup', {
          'email': 'r@x.io',
          'password': 'a1!${'x' * 58}',
          'setupToken': 'test-secret',
        }),
      );
      expect(tooLong.statusCode, 400);
      expect((await _json(tooLong))['text'], 'Use at most 60 characters.');

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
      final cookie = _sessionCookiePair(
        setup,
        maxAgeSeconds: adminStore.sessionTtl.inSeconds,
      );
      expect((setupJson['user'] as Map)['role'], 'admin');
      // The token never rides the body: the browser's cookie is the whole
      // credential, and the server owns the expiry entirely.
      expect(setupJson.containsKey('token'), isFalse);
      expect(setupJson.containsKey('expiresAt'), isFalse);

      expect(
        (await _json(await adminStatusHandler(_get('x'))))['setupRequired'],
        isFalse,
      );

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
        _post('admin/login', {
          'email': 'root@x.io',
          'password': 'wrong-pass-1',
        }),
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
      final loginJson = await _json(login);
      expect(loginJson.containsKey('token'), isFalse);
      expect(loginJson.containsKey('expiresAt'), isFalse);
      final loginCookie = _sessionCookiePair(
        login,
        maxAgeSeconds: adminStore.sessionTtl.inSeconds,
      );
      // Each success mints its own credential; the login pair is not the
      // setup pair and both were live moments ago.
      expect(loginCookie, isNot(cookie));

      // Session cookie authorizes admin endpoints.
      final overview = await adminOverviewHandler(
        _get('admin/overview', cookie: loginCookie),
      );
      expect(overview.statusCode, 200);

      final me = await adminMeHandler(_get('admin/me', cookie: loginCookie));
      expect(me.statusCode, 200);
      expect((await _json(me))['user']['email'], 'root@x.io');

      // No cookie, no session: denied before anything else answers.
      expect((await adminOverviewHandler(_get('admin/overview'))).statusCode,
          403);
      expect((await adminMeHandler(_get('admin/me'))).statusCode, 401);

      // Logout revokes the row and empties the cookie in place.
      final logout = await adminLogoutHandler(
        _post('admin/logout', {}, cookie: loginCookie),
      );
      expect(logout.statusCode, 200);
      final cleared = logout.headers['set-cookie'];
      expect(cleared, isNotNull);
      expect(cleared, startsWith('$adminSessionCookie=;'));
      expect(cleared, contains('Max-Age=0'));

      expect(
        (await adminOverviewHandler(
          _get('admin/overview', cookie: loginCookie),
        )).statusCode,
        403,
        reason: 'the server row is revoked: presenting the old cookie fails',
      );
      expect(
        (await adminMeHandler(_get('admin/me', cookie: loginCookie)))
            .statusCode,
        401,
      );
    });

    test('setup requires the setup secret when ADMIN_TOKEN is set', () async {
      final savedStore = adminStore;
      final savedToken = adminToken;
      adminStore = AdminStore.inMemory(bcryptRounds: 4);
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
        _post('admin/setup', {'email': 'r@x.io', 'password': 'long-enough-1'}),
      );
      expect(denied.statusCode, 403);
      expect((await _json(denied))['text'], contains('ADMIN_TOKEN'));
      // Nothing was created: the hole stays closed.
      expect(await adminStore.needsSetup, isTrue);
    });

    test('non-admin sessions cannot touch admin endpoints', () async {
      final savedStore = adminStore;
      final savedToken = adminToken;
      final store = AdminStore.inMemory(bcryptRounds: 4);
      adminStore = store;
      adminToken = 'legacy';
      addTearDown(() {
        adminStore = savedStore;
        adminToken = savedToken;
      });
      resetLoginAttempts();

      await store.createUser(
        email: 'admin@x.io',
        name: 'A',
        password: 'long-enough-1',
        role: 'admin',
      );
      await store.createUser(
        email: 'player@x.io',
        name: 'P',
        password: 'long-enough-1',
        role: 'user',
      );
      final adminSession = await store.createSession(
        (await store.findUserByEmail('admin@x.io'))!.id,
      );
      final userSession = await store.createSession(
        (await store.findUserByEmail('player@x.io'))!.id,
      );
      String pair(String token) => '$adminSessionCookie=$token';

      expect(
        (await adminOverviewHandler(
          _get('admin/overview', cookie: pair(userSession.token)),
        )).statusCode,
        403,
        reason: 'a user-role session is not an admin',
      );
      // Legacy service token keeps working for automation.
      expect(
        (await adminOverviewHandler(
          _get('admin/overview', bearer: 'legacy'),
        )).statusCode,
        200,
      );
      // Moderation attributed to the session identity, not a static string.
      final ban = await adminActionHandler(
        _post('admin/ban', {'seatId': 's9'}, cookie: pair(adminSession.token)),
      );
      expect(ban.statusCode, 200);
      final log = await store.auditLog(limit: 5);
      expect(log.any((e) => e.action == 'ban' && e.by == 'admin@x.io'), isTrue);
    });

    test('the legacy ADMIN_TOKEN still admits automation without a cookie',
        () async {
      final savedStore = adminStore;
      final savedToken = adminToken;
      adminStore = AdminStore.inMemory(bcryptRounds: 4);
      adminToken = 'legacy-1';
      addTearDown(() {
        adminStore = savedStore;
        adminToken = savedToken;
      });

      expect(
        (await adminMeHandler(_get('admin/me', bearer: 'legacy-1')))
            .statusCode,
        401,
        reason: 'solid tokens identify, they do not name a session owner',
      );
      expect(
        (await adminOverviewHandler(
          _get('admin/overview', bearer: 'legacy-1'),
        )).statusCode,
        200,
      );
      // An empty configured token refuses the legacy path entirely.
      adminToken = '';
      expect(
        (await adminOverviewHandler(
          _get('admin/overview', bearer: 'legacy-1'),
        )).statusCode,
        403,
      );
    });

    test('login rate-limits brute force', () async {
      final savedStore = adminStore;
      final savedToken = adminToken;
      adminStore = await _missStore();
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

    test('concurrent logins cannot all pass the failure check', () async {
      // The failure budget is checked before the body is read and only
      // spent after credentials are verified (CWE-307). Every request in
      // this burst reaches the check before any of them has recorded a
      // failure, so without a reservation all fifteen are verified; with
      // one, the ten-attempt budget holds.
      final savedStore = adminStore;
      final savedToken = adminToken;
      adminStore = await _missStore();
      adminToken = '';
      addTearDown(() {
        adminStore = savedStore;
        adminToken = savedToken;
        resetLoginAttempts();
      });
      resetLoginAttempts();

      final responses = await Future.wait([
        for (var i = 0; i < 15; i++)
          adminLoginHandler(
            _post('admin/login', {
              'email': 'ghost@x.io',
              'password': 'wrong-$i',
            }),
          ),
      ]);
      final codes = responses.map((r) => r.statusCode).toList();
      expect(
        codes.where((c) => c == 401).length,
        10,
        reason: 'only the ten-attempt budget may reach verification',
      );
      expect(codes.where((c) => c == 429).length, 5);

      // A reservation is capacity, not a failure: the bucket holds the
      // ten misses, so one more sequential attempt is refused.
      final after = await adminLoginHandler(
        _post('admin/login', {'email': 'ghost@x.io', 'password': 'wrong-x'}),
      );
      expect(after.statusCode, 429);
    });

    test('a successful login frees its slot without spending the budget',
        () async {
      final savedStore = adminStore;
      final savedToken = adminToken;
      adminStore = AdminStore.inMemory(bcryptRounds: 4);
      adminToken = '';
      addTearDown(() {
        adminStore = savedStore;
        adminToken = savedToken;
        resetLoginAttempts();
      });
      resetLoginAttempts();
      await adminStore.createUser(
        email: 'root@x.io',
        name: 'Root',
        password: 'long-enough-1',
        role: 'admin',
        by: 'test',
      );

      // Successes never spend the ten-failure budget: twelve in a row all
      // log in. An eleventh would be refused if a success were recorded
      // as a miss, and a leaked reservation would refuse one of ten.
      for (var i = 0; i < 12; i++) {
        final res = await adminLoginHandler(
          _post('admin/login', {
            'email': 'root@x.io',
            'password': 'long-enough-1',
          }),
        );
        expect(res.statusCode, 200, reason: 'login ${i + 1} of 12');
      }
    });

    test('admin can list and create users', () async {
      final savedStore = adminStore;
      final savedToken = adminToken;
      adminStore = AdminStore.inMemory(bcryptRounds: 4);
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
        }, bearer: 'legacy-2'),
      );
      expect(created.statusCode, 200);

      final listed = await adminUsersHandler(
        _get('admin/users', bearer: 'legacy-2'),
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
        }, bearer: 'legacy-2'),
      );
      expect(bad.statusCode, 400);
    });
  });

  // ----------------------------------------------------------------------
  // Rate-limit identity behind a proxy (CWE-307): with deploy/nginx.conf in
  // front, every socket is the shared loopback leg, and per-client buckets
  // used to collapse into one backend bucket — one unauthenticated client
  // could exhaust allowances for everyone. Identity now comes from the
  // forwarding chain through explicitly trusted hops only.
  // ----------------------------------------------------------------------
  group('rate-limit identity for unauthenticated buckets', () {
    const trusted = {'127.0.0.1', '::1'};

    test('a direct peer keys on itself, carrying its header for nothing', () {
      expect(
        clientIpWithForwarding('203.0.113.5', '9.9.9.9', trusted),
        '203.0.113.5',
        reason: 'not a configured proxy, not a claim that outranks the wire',
      );
      // Even a chain naming us directly changes nothing for a direct peer.
      expect(
        clientIpWithForwarding('203.0.113.5', '127.0.0.1, 9.9.9.9', trusted),
        '203.0.113.5',
      );
      expect(
        clientIpWithForwarding('unknown', null, trusted),
        'unknown',
        reason: 'no socket info stays the historical bucket key',
      );
    });

    test(
      'through a trusted front the rightmost non-trusted hop is the client',
      () {
        expect(
          clientIpWithForwarding('127.0.0.1', '1.1.1.1', trusted),
          '1.1.1.1',
        );
        // A forged client prefix loses to the appended, wire-observed hop.
        expect(
          clientIpWithForwarding('127.0.0.1', '8.8.8.8, 203.0.113.9', trusted),
          '203.0.113.9',
        );
        // A second trusted hop inside the chain is seen through.
        expect(
          clientIpWithForwarding('127.0.0.1', '1.1.1.1, ::1', trusted),
          '1.1.1.1',
        );
        expect(
          clientIpWithForwarding('::1', '1.1.1.1, 127.0.0.1', trusted),
          '1.1.1.1',
        );
        // Whitespace and empty segments never become identities.
        expect(
          clientIpWithForwarding('127.0.0.1', ' 1.1.1.1, , 2.2.2.2 ', trusted),
          '2.2.2.2',
        );
      },
    );

    test('a chain of nothing but trusted hops answers with the socket', () {
      expect(clientIpWithForwarding('127.0.0.1', null, trusted), '127.0.0.1');
      expect(clientIpWithForwarding('127.0.0.1', '', trusted), '127.0.0.1');
      expect(clientIpWithForwarding('127.0.0.1', '::1', trusted), '127.0.0.1');
      expect(
        clientIpWithForwarding('127.0.0.1', '127.0.0.1, ::1', trusted),
        '127.0.0.1',
        reason:
            'the shared-bucket fallback an untrusted answer used to be — '
            'minus any client-chosen key',
      );
    });

    test('TRUSTED_PROXIES parses exact addresses or keeps the loopback', () {
      const loopback = {'127.0.0.1', '::1'};
      expect(trustedProxiesFromEnv(null), loopback);
      expect(trustedProxiesFromEnv(''), loopback);
      expect(trustedProxiesFromEnv('   '), loopback);
      expect(trustedProxiesFromEnv(',,  '), loopback);
      expect(trustedProxiesFromEnv(' 10.0.0.7 , ::1 ,10.0.0.7 '), {
        '10.0.0.7',
        '::1',
      }, reason: 'case-folded, trimmed, deduplicated');
    });

    test(
      'separate clients through the one socket keep separate budgets',
      () async {
        final savedStore = adminStore;
        final savedToken = adminToken;
        final savedProxies = trustedProxies;
        adminStore = await _missStore();
        adminToken = '';
        trustedProxies = trusted;
        addTearDown(() {
          adminStore = savedStore;
          adminToken = savedToken;
          trustedProxies = savedProxies;
        });
        resetLoginAttempts();

        shelf.Response last = await adminLoginHandler(
          _postFrom('admin/login', _loginMiss, from: _addr('127.0.0.1'),
              xff: '203.0.113.1'),
        );
        for (var i = 0; i < 12; i++) {
          last = await adminLoginHandler(
            _postFrom('admin/login', _loginMiss, from: _addr('127.0.0.1'),
                xff: '203.0.113.1'),
          );
        }
        expect(last.statusCode, 429, reason: 'client A is spent');

        final fresh = await adminLoginHandler(
          _postFrom('admin/login', _loginMiss, from: _addr('127.0.0.1'),
              xff: '203.0.113.2'),
        );
        expect(
          fresh.statusCode,
          401,
          reason: 'client B arriving on the very same socket pays only for B',
        );
      },
    );

    test('a socket-borne client cannot overflow with forged claims', () async {
      final savedStore = adminStore;
      final savedToken = adminToken;
      final savedProxies = trustedProxies;
      adminStore = await _missStore();
      adminToken = '';
      trustedProxies = trusted;
      addTearDown(() {
        adminStore = savedStore;
        adminToken = savedToken;
        trustedProxies = savedProxies;
      });
      resetLoginAttempts();

      // A client at .9 with a habit of declaring itself famous: the proxy
      // appends .9 after every claim, so the identity never leaves .9.
      shelf.Response last = await adminLoginHandler(
        _postFrom('admin/login', _loginMiss, from: _addr('127.0.0.1'),
            xff: 'claim-1, 203.0.113.9'),
      );
      for (var i = 0; i < 12; i++) {
        last = await adminLoginHandler(
          _postFrom('admin/login', _loginMiss, from: _addr('127.0.0.1'),
              xff: 'claim-${i + 2}, 203.0.113.9'),
        );
      }
      expect(
        last.statusCode,
        429,
        reason: 'rotating the forged prefix buys nothing — same bucket',
      );

      // A second socket, the same habit: its appended hop makes its own
      // budget, and the famous claim never reached it.
      final neighbour = await adminLoginHandler(
        _postFrom('admin/login', _loginMiss, from: _addr('127.0.0.1'),
            xff: 'claim-again, 203.0.113.10'),
      );
      expect(
        neighbour.statusCode,
        401,
        reason: 'exhaustion landed on the appended peer, never the claim',
      );
    });

    test(
      "an unattached direct client cannot blast another identity's bucket",
      () async {
        final savedStore = adminStore;
        final savedToken = adminToken;
        final savedProxies = trustedProxies;
        adminStore = await _missStore();
        adminToken = '';
        trustedProxies = trusted;
        addTearDown(() {
          adminStore = savedStore;
          adminToken = savedToken;
          trustedProxies = savedProxies;
        });
        resetLoginAttempts();

        // A direct (untrusted) socket sends failures while claiming some
        // other identity entirely.
        shelf.Response last = await adminLoginHandler(
          _postFrom('admin/login', _loginMiss, from: _addr('203.0.113.5'),
              xff: '9.9.9.9'),
        );
        for (var i = 0; i < 12; i++) {
          last = await adminLoginHandler(
            _postFrom('admin/login', _loginMiss, from: _addr('203.0.113.5'),
                xff: '9.9.9.9'),
          );
        }
        expect(last.statusCode, 429);

        // The header was a dead letter: the same identity arriving through
        // the trusted front has a clean bucket. Nothing was exhausted for
        // it — the direct client only spent its own socket identity.
        final fameBehindProxy = await adminLoginHandler(
          _postFrom('admin/login', _loginMiss, from: _addr('127.0.0.1'),
              xff: '9.9.9.9'),
        );
        expect(fameBehindProxy.statusCode, 401);

        // And rotating the claim on the direct socket does not dodge its
        // own spent bucket either.
        final rotated = await adminLoginHandler(
          _postFrom('admin/login', _loginMiss, from: _addr('203.0.113.5'),
              xff: '8.8.8.8'),
        );
        expect(rotated.statusCode, 429);
      },
    );
  });
}
