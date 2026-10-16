import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:game_club/main.dart';
import 'package:game_club/providers/app_providers.dart';
import 'package:game_club/screens/admin/admin_login_screen.dart';
import 'package:game_club/ui/admin_badge.dart';
import 'package:game_club/ui/page_app_bar.dart';
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

  testWidgets('password field menu offers Paste and it fills the field', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    // Widget tests run with no clipboard plugin: answer the channel
    // directly instead of setData (whose future never completes here).
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method == 'Clipboard.getData') return {'text': 's3cr3t-pass'};
      return null;
    });
    addTearDown(
      () => messenger.setMockMethodCallHandler(SystemChannels.platform, null),
    );

    await tester.pumpWidget(
      const ProviderScope(child: MaterialApp(home: AdminLoginScreen())),
    );
    await tester.pumpAndSettle();

    final field = find.widgetWithText(TextField, 'Password');
    expect(field, findsOneWidget);
    await tester.longPress(field);
    await tester.pumpAndSettle();

    // The framework-built menu must carry a Paste entry (this is the
    // mouse/touch path, independent of the browser's Ctrl+V delivery).
    expect(find.text('Paste'), findsOneWidget);
    await tester.tap(find.text('Paste'));
    await tester.pumpAndSettle();

    // Reveal the obscured field to verify what landed.
    await tester.tap(find.byTooltip('Show').first);
    await tester.pumpAndSettle();
    expect(find.text('s3cr3t-pass'), findsOneWidget);
  });

  testWidgets('admin badge ends where the page content ends', (tester) async {
    SharedPreferences.setMockInitialValues({});
    const marker = Key('body-marker');
    await tester.pumpWidget(
      const ProviderScope(
        child: MaterialApp(
          home: Scaffold(
            appBar: PageAppBar(title: 'T'),
            body: ContentColumn(
              child: SizedBox(
                key: marker,
                width: double.infinity,
                height: 40,
              ),
            ),
          ),
        ),
      ),
    );
    final ctx = tester.element(find.text('T'));
    ProviderScope.containerOf(ctx).read(adminSessionProvider.notifier).signIn(
      const AdminSession(
        token: 't',
        email: 'root@x.io',
        name: 'Root',
        serverUrl: 'ws://localhost:8080/ws',
      ),
    );
    await tester.pumpAndSettle();

    // The bar's row honors the same 16px body inset: the badge must not
    // overhang the content column the way a full-bleed row did.
    final badgeRight = tester.getRect(find.byType(AdminBadge)).right;
    final columnRight = tester.getRect(find.byKey(marker)).right;
    expect(columnRight - badgeRight, closeTo(16, 0.5));
  });
}
