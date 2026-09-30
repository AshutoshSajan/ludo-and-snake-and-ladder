import 'package:flutter_test/flutter_test.dart';
import 'package:game_club/services/online_client.dart';
import 'package:game_club/services/storage_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// The online identity: created once, reused every time, editable.
///
/// Both used to be per-session. The id mattered most: the server keys every
/// recorded result by it, so a fresh id each session made every session a
/// different player, and no online career ever accumulated.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('a player id is created once and then reused', () async {
    SharedPreferences.setMockInitialValues({});
    final storage = StorageService();

    final first = await storage.loadOnlinePlayerId();
    expect(first, isNotEmpty);

    // A second service, as a later app launch would be, sees the same id.
    expect(
      await StorageService().loadOnlinePlayerId(),
      first,
      reason: 'the id must be stable, or every session is a new player',
    );
  });

  test('the name is remembered, editable, and survives a restart', () async {
    SharedPreferences.setMockInitialValues({});
    final storage = StorageService();

    expect(
      await storage.loadOnlineName(),
      isEmpty,
      reason: 'first visit has nothing to offer yet',
    );

    await storage.saveOnlineName('Asha');
    expect(await StorageService().loadOnlineName(), 'Asha');

    // Editing replaces it rather than appending.
    await storage.saveOnlineName('Asha R');
    expect(await StorageService().loadOnlineName(), 'Asha R');
  });

  test('the id is not disturbed by renaming', () async {
    SharedPreferences.setMockInitialValues({});
    final storage = StorageService();
    final id = await storage.loadOnlinePlayerId();

    await storage.saveOnlineName('A new name entirely');
    expect(
      await StorageService().loadOnlinePlayerId(),
      id,
      reason: 'renaming must not orphan the recorded career',
    );
  });

  group('default names', () {
    test('are generated, and well formed', () {
      final name = DefaultNames.generate();
      expect(name, isNotEmpty);
      expect(name.split(' '), hasLength(2));
      expect(name, matches(RegExp(r'^[A-Z][a-z]+ [A-Z][a-z]+$')));
    });

    test('the same salt always gives the same name', () {
      // This is the property that matters: a name that changed on every visit would
      // scatter one player's career across the leaderboard.
      final a = DefaultNames.generate(salt: 12345);
      final b = DefaultNames.generate(salt: 12345);
      expect(a, b);
    });

    test('different salts give different names', () {
      final names = {
        for (var i = 0; i < 40; i++) DefaultNames.generate(salt: i * 977),
      };
      expect(
        names.length,
        greaterThan(20),
        reason: 'the generator must not collapse onto a few names',
      );
    });
  });
}
