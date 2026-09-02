import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:game_club/main.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  testWidgets('app boots to home with both game cards', (tester) async {
    SharedPreferences.setMockInitialValues({});
    await tester.pumpWidget(const ProviderScope(child: GameClubApp()));
    await tester.pumpAndSettle();

    expect(find.text('Game Club'), findsOneWidget);
    expect(find.text('Ludo'), findsOneWidget);
    expect(find.text('Snakes & Ladders'), findsOneWidget);
    expect(find.text('Leaderboards'), findsOneWidget);
  });

  testWidgets('tapping Ludo opens the setup screen', (tester) async {
    SharedPreferences.setMockInitialValues({});
    await tester.pumpWidget(const ProviderScope(child: GameClubApp()));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Ludo'));
    await tester.pumpAndSettle();

    expect(find.text('Ludo — New game'), findsOneWidget);
    expect(find.text('Start game'), findsOneWidget);
  });
}
