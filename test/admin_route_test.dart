import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:game_club/main.dart';
import 'package:game_club/providers/app_providers.dart';
import 'package:game_club/screens/admin/admin_login_screen.dart';
import 'package:game_club/ui/admin_badge_web.dart';
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

  testWidgets('/admin is not registered outside the web app', (tester) async {
    // flutter test runs on the VM (dart.library.io): the conditional import
    // resolves the stub and the route stays unregistered, so the deep link
    // falls back to home instead of a sign-in form. (The web build registers
    // the real screen; that half cannot run under `flutter test`.)
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

    expect(find.text('Ludo'), findsOneWidget);
    expect(find.text('Email'), findsNothing);
  });

  testWidgets('web admin badge shows identity and opens the dashboard', (
    tester,
  ) async {
    // The app shell resolves the stub on non-web builds, so the real badge
    // is exercised directly: this is the widget the web build compiles in.
    SharedPreferences.setMockInitialValues({});
    const session = AdminSession(
      token: 't',
      email: 'root@x.io',
      name: 'Root',
      serverUrl: 'ws://localhost:8080/ws',
    );
    await tester.pumpWidget(
      const ProviderScope(
        child: MaterialApp(
          home: Scaffold(body: Center(child: AdminBadge(session: session))),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Admin · root@x.io'), findsOneWidget);

    // Tapping it opens the dashboard (API errors render, no crash).
    await tester.tap(find.text('Admin · root@x.io'));
    await tester.pumpAndSettle();
    expect(find.text('Admin dashboard'), findsOneWidget);
  });

  testWidgets('signing out removes the web badge', (tester) async {
    SharedPreferences.setMockInitialValues({});
    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          home: Scaffold(
            body: Center(
              child: Consumer(
                builder: (context, ref, _) {
                  final session = ref.watch(adminSessionProvider);
                  return session == null
                      ? const Text('signed out')
                      : AdminBadge(session: session);
                },
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    final ctx = tester.element(find.text('signed out'));
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
    expect(find.text('Admin · root@x.io'), findsOneWidget);

    notifier.signOut();
    await tester.pumpAndSettle();
    expect(find.text('Admin · root@x.io'), findsNothing);
    expect(find.text('signed out'), findsOneWidget);
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

  testWidgets('page bar content honors the 16px body inset', (tester) async {
    // The bar's row carries the same inset as the page bodies, so trailing
    // slots (like the admin badge) end where the content ends instead of
    // overhanging the cards below. Measured with a fixed-width action so
    // the test does not depend on the badge variant this platform compiles.
    SharedPreferences.setMockInitialValues({});
    const actionKey = Key('trailing-action');
    const marker = Key('body-marker');
    await tester.pumpWidget(
      const ProviderScope(
        child: MaterialApp(
          home: Scaffold(
            appBar: PageAppBar(
              title: 'T',
              actions: [SizedBox(key: actionKey, width: 120, height: 10)],
            ),
            body: ContentColumn(
              child: SizedBox(key: marker, width: double.infinity, height: 40),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final actionRight = tester.getRect(find.byKey(actionKey)).right;
    final columnRight = tester.getRect(find.byKey(marker)).right;
    expect(columnRight - actionRight, closeTo(16, 0.5));
  });
}
