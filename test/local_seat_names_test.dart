import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:game_club/engine/core/player_profiles.dart' show GameKind;
import 'package:game_club/screens/setup_screen.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Generated names for local seats.
///
/// The name is painted on the pawn, so a duplicate is worse here than on a
/// leaderboard: two "Swift Otter" pawns on one board and you cannot tell which
/// one you are steering. Uniqueness within the table is the property that
/// matters, and it is invisible until a collision actually happens.
void main() {
  Future<void> openSetup(WidgetTester tester, {int maxSeats = 10}) async {
    SharedPreferences.setMockInitialValues({});
    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(home: SetupScreen(game: GameKind.snakes)),
      ),
    );
    await tester.pumpAndSettle();
  }

  /// Every name currently typed into a seat field.
  List<String> seatNames(WidgetTester tester) => tester
      .widgetList<TextFormField>(find.byType(TextFormField))
      .map((f) => f.initialValue ?? '')
      .toList();

  testWidgets('seats get generated names, not "Player 1" and "Bot 2"', (
    tester,
  ) async {
    await openSetup(tester);
    final names = seatNames(tester);
    expect(names, isNotEmpty);
    expect(names, isNot(contains('Player 1')));
    expect(names, isNot(contains('Bot 2')));
    // Two words, capitalised — the same shape the online board uses.
    for (final n in names) {
      expect(n.trim().split(RegExp(r'\s+')).length, 2,
          reason: '"$n" is not a generated name');
    }
  });

  testWidgets('no two seats at one table share a name', (tester) async {
    await openSetup(tester);
    final names = seatNames(tester);
    expect(names.toSet().length, names.length,
        reason: 'duplicate seat names: $names');
  });
}
