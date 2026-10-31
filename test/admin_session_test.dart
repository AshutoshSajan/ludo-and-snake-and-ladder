/// The AdminClient's session cookie transport, at the level the VM reaches.
///
/// `flutter test` runs on the VM (a native target), so what is asserted
/// here is the client's own machinery: capture the `Set-Cookie` header on
/// a login/setup answer, replay it as a `Cookie` header on every later
/// request — in memory only, nothing persisted — and stop presenting it
/// after logout, whatever the logout answer was. On the web the header is
/// invisible to script and the browser performs these jobs natively (it
/// stores, re-sends and expires the cookie itself); that path wins by
/// construction here — the mock simply never shows the header.
library;

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:game_club/services/admin_client.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

http.Response _ok(Map<String, dynamic> body, {Map<String, String>? headers}) =>
    http.Response(
      jsonEncode(body),
      200,
      headers: {'content-type': 'application/json', ...?headers},
    );

/// The mint header a successful setup/login answers with.
const _mintCookieHeaders = {
  'set-cookie': 'gc_admin_session=tok-123; HttpOnly; Secure; '
      'SameSite=Strict; Path=/; Max-Age=7200',
};

const _userBody = {
  'ok': true,
  'user': {'email': 'root@x.io', 'name': 'Root'},
};

void main() {
  test('login captures the cookie and later requests replay it',
      () async {
    final seen = <String, Map<String, String>>{};
    final client = AdminClient(
      serverUrl: 'ws://localhost:8080/ws',
      httpClient: MockClient((request) async {
        seen[request.url.path] = request.headers;
        if (request.url.path == '/admin/login') {
          return _ok(_userBody, headers: _mintCookieHeaders);
        }
        return _ok({'ok': true});
      }),
    );
    addTearDown(client.close);

    final authed = await client.login(email: 'root@x.io', password: 'pw-1234!');
    expect(authed['ok'], isTrue);
    expect((authed['user'] as Map)['email'], 'root@x.io');

    await client.me();
    // The credential presented is the captured pair, trimmed to what a
    // browser would re-send (attributes stay the browser's business).
    expect(seen['/admin/me']?['cookie'], 'gc_admin_session=tok-123');
    // ...and nothing token-shaped rides any other header anymore.
    expect(seen['/admin/me']?['authorization'], isNull);
  });

  test('nothing is presented before a login, and a new login wins', () async {
    final seen = <String, Map<String, String>>{};
    final client = AdminClient(
      serverUrl: 'ws://localhost:8080/ws',
      httpClient: MockClient((request) async {
        seen[request.url.path] = request.headers;
        if (request.url.path == '/admin/login') {
          return _ok(
            _userBody,
            headers: {
              ..._mintCookieHeaders,
            },
          );
        }
        if (request.url.path == '/admin/status') {
          return _ok({'setupRequired': false});
        }
        return _ok(_userBody, headers: {
          'set-cookie': 'gc_admin_session=tok-999; HttpOnly; Secure; '
              'SameSite=Strict; Path=/; Max-Age=7200',
        });
      }),
    );
    addTearDown(client.close);

    await client.status();
    expect(seen['/admin/status']?['cookie'], isNull,
        reason: 'no credential before a login mints one');
    expect(seen['/admin/status']?['authorization'], isNull);

    await client.login(email: 'root@x.io', password: 'pw-1234!');
    await client.me();
    expect(seen['/admin/me']?['cookie'], 'gc_admin_session=tok-123');

    // A re-login (password change, fresh window) replaced the pair: the
    // client always presents exactly its latest captured session.
    await client.setup(email: 'root@x.io', password: 'another-pw-1');
    await client.me();
    expect(seen['/admin/me']?['cookie'], 'gc_admin_session=tok-999');
  });

  test('logout clears the empty-value header from presentation', () async {
    final seen = <String, Map<String, String>>{};
    final client = AdminClient(
      serverUrl: 'ws://localhost:8080/ws',
      httpClient: MockClient((request) async {
        seen[request.url.path] = request.headers;
        if (request.url.path == '/admin/login') {
          return _ok(_userBody, headers: _mintCookieHeaders);
        }
        if (request.url.path == '/admin/logout') {
          return _ok({'ok': true}, headers: {
            'set-cookie': 'gc_admin_session=; HttpOnly; Secure; '
                'SameSite=Strict; Path=/; Max-Age=0',
          });
        }
        return _ok({'ok': true});
      }),
    );
    addTearDown(client.close);

    await client.login(email: 'root@x.io', password: 'pw-1234!');
    await client.logout();
    await client.me();
    expect(seen['/admin/me']?['cookie'], isNull,
        reason: 'the emptied clear pair was never captured, and the logout '
            'itself dropped the presented session: no dead cookie lingers');
  });

  test('a failed logout still stops presenting the session', () async {
    final seen = <String, Map<String, String>>{};
    final client = AdminClient(
      serverUrl: 'ws://localhost:8080/ws',
      httpClient: MockClient((request) async {
        seen[request.url.path] = request.headers;
        if (request.url.path == '/admin/login') {
          return _ok(_userBody, headers: _mintCookieHeaders);
        }
        if (request.url.path == '/admin/logout') {
          // A dead network answer: the server never got the word.
          return http.Response('socket died', 503);
        }
        return _ok({'ok': true});
      }),
    );
    addTearDown(client.close);

    await client.login(email: 'root@x.io', password: 'pw-1234!');
    await expectLater(
      client.logout(),
      throwsA(isA<AdminException>().having(
        (e) => e.statusCode,
        'statusCode',
        503,
      )),
    );
    await client.me();
    expect(seen['/admin/me']?['cookie'], isNull,
        reason: 'belt to the server-side revocation it asked for: this '
            'client has finished presenting whatever it captured');
  });

  test('a non-200 surface carries its code and body verbatim', () async {
    final client = FakeAdminClient();
    addTearDown(client.close);
    await expectLater(
      client.me(),
      throwsA(
        isA<AdminException>()
            .having((e) => e.statusCode, 'statusCode', 401)
            .having(
              (e) => e.body,
              'body',
              '{"ok":false,"text":"session required"}',
            ),
      ),
    );
  });
}

/// A client stuck against an API that refuses every read — the shape the
/// dashboard's death watch reacts to.
class FakeAdminClient extends AdminClient {
  FakeAdminClient()
      : super(
          serverUrl: 'ws://localhost:8080/ws',
          httpClient: MockClient(
            (request) async => http.Response(
              '{"ok":false,"text":"session required"}',
              401,
              headers: {'content-type': 'application/json'},
            ),
          ),
        );
}
