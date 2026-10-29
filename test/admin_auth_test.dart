/// Auth tests: password primitives, users/sessions store, and the login /
/// setup / session-gated HTTP surface. PBKDF2 iteration counts are kept
/// small here for speed; production uses [defaultPbkdf2Iterations].
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
        adminSetupHandler,
        adminStatusHandler,
        adminUsersHandler,
        adminStore,
        adminToken,
        clientIpWithForwarding,
        resetLoginAttempts,
        trustedProxies,
        trustedProxiesFromEnv;

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

/// Stands in for `HttpConnectionInfo` at the `shelf.io.connection_info`
/// key so requests can carry a chosen socket peer (see [_postFrom]).
class _ConnInfo {
  _ConnInfo(this.remoteAddress);

  final InternetAddress? remoteAddress;
}

/// A failed-login POST arriving [from] the given socket peer, optionally
/// carrying an `x-forwarded-for` chain. Login exercised the identity
/// plane: a miss records into the per-IP bucket, and an empty store
/// answers 401 for every attempt, needing no seeded users.
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

const _loginMiss = '{"email":"ghost@x.io","password":"wrong-1"}';

/// A store whose password checks always miss and never pay PBKDF2 — for
/// tests about rate limiting, not credential verification.
AdminStore _rejectingStore() =>
    AdminStore.inMemory(verifier: (password, hash) => false);

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

    test('an absent email still pays the password work factor', () async {
      // The verifier seam records the hash each path verifies against,
      // so this is deterministic — no timing assertion. Countershape:
      // before the fix, the absent path called no verifier at all.
      final verified = <String>[];
      final store = AdminStore.inMemory(
        verifier: (password, hash) {
          verified.add(hash);
          return false;
        },
      );
      addTearDown(store.close);

      expect(
        await store.checkCredentials('nobody@example.com', 'long-enough-1'),
        isNull,
      );
      expect(
        verified,
        hasLength(1),
        reason: 'an absent account must still run the KDF',
      );
      final parts = verified.single.split(r'$');
      expect(parts.first, 'pbkdf2');
      expect(
        int.parse(parts[1]),
        defaultPbkdf2Iterations,
        reason: 'the dummy hash must carry the production work factor',
      );

      // A real account's wrong password runs exactly one verification
      // too — the same shape as the dummy path.
      await store.createUser(
        email: 'root@example.com',
        name: 'Root',
        password: 'long-enough-1',
        iterations: 1000,
        by: 'test',
      );
      verified.clear();
      expect(
        await store.checkCredentials('root@example.com', 'wrong-1'),
        isNull,
      );
      expect(verified, hasLength(1));
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
      final token = setupJson['token'] as String;
      expect((setupJson['user'] as Map)['role'], 'admin');

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
      expect(log.any((e) => e.action == 'ban' && e.by == 'admin@x.io'), isTrue);
    });

    test('login rate-limits brute force', () async {
      final savedStore = adminStore;
      final savedToken = adminToken;
      adminStore = _rejectingStore();
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
      adminStore = _rejectingStore();
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

    test(
      'a successful login frees its slot without spending the budget',
      () async {
        final savedStore = adminStore;
        adminStore = AdminStore.inMemory();
        addTearDown(() {
          adminStore = savedStore;
          resetLoginAttempts();
        });
        resetLoginAttempts();
        await adminStore.createUser(
          email: 'root@x.io',
          name: 'Root',
          password: 'long-enough-1',
          role: 'admin',
          iterations: 1000,
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
      },
    );

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
        adminStore = _rejectingStore();
        adminToken = '';
        trustedProxies = trusted;
        addTearDown(() {
          adminStore = savedStore;
          adminToken = savedToken;
          trustedProxies = savedProxies;
        });
        resetLoginAttempts();

        shelf.Response last = await adminLoginHandler(
          _postFrom(
            'admin/login',
            _loginMiss,
            from: _addr('127.0.0.1'),
            xff: '203.0.113.1',
          ),
        );
        for (var i = 0; i < 12; i++) {
          last = await adminLoginHandler(
            _postFrom(
              'admin/login',
              _loginMiss,
              from: _addr('127.0.0.1'),
              xff: '203.0.113.1',
            ),
          );
        }
        expect(last.statusCode, 429, reason: 'client A is spent');

        final fresh = await adminLoginHandler(
          _postFrom(
            'admin/login',
            _loginMiss,
            from: _addr('127.0.0.1'),
            xff: '203.0.113.2',
          ),
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
      adminStore = _rejectingStore();
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
        _postFrom(
          'admin/login',
          _loginMiss,
          from: _addr('127.0.0.1'),
          xff: 'claim-1, 203.0.113.9',
        ),
      );
      for (var i = 0; i < 12; i++) {
        last = await adminLoginHandler(
          _postFrom(
            'admin/login',
            _loginMiss,
            from: _addr('127.0.0.1'),
            xff: 'claim-${i + 2}, 203.0.113.9',
          ),
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
        _postFrom(
          'admin/login',
          _loginMiss,
          from: _addr('127.0.0.1'),
          xff: 'claim-again, 203.0.113.10',
        ),
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
        adminStore = _rejectingStore();
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
          _postFrom(
            'admin/login',
            _loginMiss,
            from: _addr('203.0.113.5'),
            xff: '9.9.9.9',
          ),
        );
        for (var i = 0; i < 12; i++) {
          last = await adminLoginHandler(
            _postFrom(
              'admin/login',
              _loginMiss,
              from: _addr('203.0.113.5'),
              xff: '9.9.9.9',
            ),
          );
        }
        expect(last.statusCode, 429);

        // The header was a dead letter: the same identity arriving through
        // the trusted front has a clean bucket. Nothing was exhausted for
        // it — the direct client only spent its own socket identity.
        final fameBehindProxy = await adminLoginHandler(
          _postFrom(
            'admin/login',
            _loginMiss,
            from: _addr('127.0.0.1'),
            xff: '9.9.9.9',
          ),
        );
        expect(fameBehindProxy.statusCode, 401);

        // And rotating the claim on the direct socket does not dodge its
        // own spent bucket either.
        final rotated = await adminLoginHandler(
          _postFrom(
            'admin/login',
            _loginMiss,
            from: _addr('203.0.113.5'),
            xff: '8.8.8.8',
          ),
        );
        expect(rotated.statusCode, 429);
      },
    );
  });
}
