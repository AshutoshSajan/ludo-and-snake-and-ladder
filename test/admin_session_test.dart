/// The admin session store + provider wiring, at the level the VM can
/// reach.
///
/// `flutter test` runs on the VM, so the conditional import for
/// `admin_session_store` resolves the stub: the *decision* logic is shared
/// and asserted here (`AdminAuthRecord` shape, expiry rule, notifier
/// state flow); the actual localStorage reads/writes are web-build
/// behavior and cannot be exercised without a browser runtime — the stub
/// contract pins the fact that native reads as signed out.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:game_club/providers/app_providers.dart';
import 'package:game_club/services/admin_session_store.dart';

void main() {
  group('AdminAuthRecord', () {
    test('round-trips through JSON with every field intact', () {
      const record = AdminAuthRecord(
        token: 'tok-abc',
        email: 'root@x.io',
        name: 'Root',
        expiresAt: 1234567890123,
      );
      final json = record.toJson();
      final rebuilt = AdminAuthRecord.fromJson(json);
      expect(rebuilt.token, 'tok-abc');
      expect(rebuilt.email, 'root@x.io');
      expect(rebuilt.name, 'Root');
      // An int through a double JSON decode stays the same instant: the
      // expiry is ms-since-epoch and the num-cast must not round it.
      expect(rebuilt.expiresAt, 1234567890123);
    });

    test('a truncated record fails loudly enough for the store to forget '
        'it', () {
      // The web store catches and deletes; this pins that the parse is the
      // thing that throws rather than the store envying a null return.
      expect(
        () => AdminAuthRecord.fromJson(
          {'token': 't', 'email': 'e@x.io'} as Map<String, dynamic>,
        ),
        throwsA(anything),
        reason: 'expiry or name missing = malformed, not a valid record',
      );
    });

    test('the expiry rule is closed against now', () {
      const record = AdminAuthRecord(
        token: 't',
        email: 'e@x.io',
        name: 'e',
        expiresAt: 1000,
      );
      expect(
        record.expiredAt(999),
        isFalse,
        reason: 'at 999ms the session still has a ms left',
      );
      expect(
        record.expiredAt(1000),
        isTrue,
        reason: 'at exactly expiresAt the session is spent — the server '
            'rejects it the same instant, so the client must not differ',
      );
      expect(record.expiredAt(1001), isTrue);
    });
  });

  group('the store on a native target', () {
    test('restores as signed out and persists nothing', () {
      // dart.library.io resolves the stub — native binaries compiled the
      // admin screens away, so there is nothing to restore and nowhere to
      // persist. The calls must be safe no-ops, not errors.
      persistAdminSession(
        const AdminAuthRecord(
          token: 't',
          email: 'e@x.io',
          name: 'e',
          expiresAt: 1,
        ),
      );
      expect(restoreAdminSession(), isNull);
      forgetAdminSession();
      expect(restoreAdminSession(), isNull);
    });
  });

  group('AdminSessionNotifier', () {
    test('a fresh container opens signed out', () {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      expect(container.read(adminSessionProvider), isNull);
    });

    test('signIn seats the whole session, signOut clears it', () {
      final container = ProviderContainer();
      addTearDown(container.dispose);

      const session = AdminSession(
        token: 'tok',
        email: 'root@x.io',
        name: 'Root',
        expiresAt: 9876543210000,
      );
      container.read(adminSessionProvider.notifier).signIn(session);
      final restored = container.read(adminSessionProvider);
      expect(restored?.token, 'tok');
      expect(restored?.expiresAt, 9876543210000,
          reason: 'the expiry rides the session — knock it off and the '
              'store cannot drop a dead record');

      container.read(adminSessionProvider.notifier).signOut();
      expect(container.read(adminSessionProvider), isNull);
    });
  });
}
