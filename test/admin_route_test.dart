import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:game_club/main.dart';
import 'package:game_club/providers/app_providers.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  testWidgets('home has no admin entry point', (tester) async {
    SharedPreferences.setMockInitialValues({});
    await tester.pumpWidget(const ProviderScope(child: GameClubApp()));
    await tester.pumpAndSettle();

    expect(find.byIcon(Icons.admin_panel_settings_outlined), findsNothing);
  });

  testWidgets('unknown route falls back to home', (tester) async {
    SharedPreferences.setMockInitialValues({});
    await tester.pumpWidget(const ProviderScope(child: GameClubApp()));
    await tester.pumpAndSettle();
    final ctx = tester.element(find.text('Game Club'));
    Navigator.of(ctx).pushNamed('/does-not-exist');
    await tester.pumpAndSettle();

    expect(find.text('Ludo'), findsOneWidget);
    expect(find.text('Email'), findsNothing);
  });

  testWidgets('/admin shows the admin sign-in', (tester) async {
    SharedPreferences.setMockInitialValues({});
    await tester.pumpWidget(
      const ProviderScope(
        child: MaterialApp(
          home: GameClubApp(),
        ),
      ),
    );
    await tester.pumpAndSettle();
    final ctx = tester.element(find.text('Game Club'));
    Navigator.of(ctx).pushNamed('/admin');
    await tester.pumpAndSettle();

    expect(find.text('Email'), findsOneWidget);
    expect(find.text('Password'), findsOneWidget);
  });

  testWidgets('signed-in admin is badged on home, tap opens dashboard', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    await tester.pumpWidget(const ProviderScope(child: GameClubApp()));
    await tester.pumpAndSettle();
    expect(find.textContaining('Admin ·'), findsNothing);

    final ctx = tester.element(find.text('Game Club'));
    ProviderScope.containerOf(ctx).read(adminSessionProvider.notifier).signIn(
      const AdminSession(
        token: 't',
        email: 'root@x.io',
        name: 'Root',
        serverUrl: 'ws://localhost:8080/ws',
      ),
    );
    await tester.pumpAndSettle();

    // Home chip with identity.
    expect(find.text('Admin · root@x.io'), findsOneWidget);

    // Tapping it opens the dashboard (API errors render, no crash).
    await tester.tap(find.text('Admin · root@x.io'));
    await tester.pumpAndSettle();
    expect(find.text('Admin dashboard'), findsOneWidget);
  });

  testWidgets('signing out removes every badge', (tester) async {    SharedPreferences.setMockInitialValues({});
    await tester.pumpWidget(const ProviderScope(child: GameClubApp()));
    await tester.pumpAndSettle();
    final ctx = tester.element(find.text('Game Club'));
    final notifier = ProviderScope.containerOf(
      ctx,
    ).read(adminSessionProvider.notifier);
    notifier.signIn(
      const AdminSession(
        token: 't',
        email: 'root@x.io',
        name: 'Root',
        serverUrl: 'ws://localhost:8080/ws',
      ),
    );
    await tester.pumpAndSettle();
    expect(find.textContaining('Admin ·'), findsOneWidget);

    notifier.signOut();
    await tester.pumpAndSettle();
    expect(find.textContaining('Admin ·'), findsNothing);
  });
}
