import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:game_club/main.dart';
import 'package:game_club/providers/app_providers.dart';
import 'package:game_club/screens/admin/admin_login_screen.dart';
import 'package:game_club/services/admin_client.dart';
import 'package:game_club/ui/admin_badge_web.dart';
import 'package:game_club/ui/page_app_bar.dart';
import 'package:game_club/ui/theme.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  // Home-landing tests: the ask is home's story (test/tutorial_test.dart);
  // admin route tests answer it away in storage.
  setUp(() {
    SharedPreferences.setMockInitialValues({'gc.tutorialAsked': true});
  });

  testWidgets('home has no admin entry point', (tester) async {
    await tester.pumpWidget(const ProviderScope(child: GameClubApp()));
    await tester.pumpAndSettle();

    expect(find.byIcon(Icons.admin_panel_settings_outlined), findsNothing);
  });

  testWidgets('unknown route falls back to home', (tester) async {
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
    await tester.pumpWidget(
      const ProviderScope(child: MaterialApp(home: GameClubApp())),
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
    const session = AdminSession(token: 't', email: 'root@x.io', name: 'Root');
    await tester.pumpWidget(
      const ProviderScope(
        child: MaterialApp(
          home: Scaffold(
            body: Center(child: AdminBadge(session: session)),
          ),
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
    final notifier = ProviderScope.containerOf(ctx)
        .read(adminSessionProvider.notifier);
    notifier.signIn(
      const AdminSession(token: 't', email: 'root@x.io', name: 'Root'),
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
      ProviderScope(child: MaterialApp(home: _loginScreen())),
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

  testWidgets('admin sign-in asks for credentials only, not a server', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    await tester.pumpWidget(
      ProviderScope(child: MaterialApp(home: _loginScreen())),
    );
    await tester.pumpAndSettle();

    // The target is a build-time fact (dart-define, same-origin, or the dev
    // default), exactly like the online lobby — no field may redirect the
    // back office at a foreign host.
    expect(find.text('Server WS URL'), findsNothing);
    expect(find.byIcon(Icons.dns_outlined), findsNothing);
    expect(find.widgetWithText(TextField, 'Email'), findsOneWidget);
    expect(find.widgetWithText(TextField, 'Password'), findsOneWidget);
  });

  testWidgets('admin fields advertise the login autofill pair', (tester) async {
    SharedPreferences.setMockInitialValues({});
    await tester.pumpWidget(
      ProviderScope(child: MaterialApp(home: _loginScreen())),
    );
    await tester.pumpAndSettle();

    final email = tester.widget<TextField>(
      find.widgetWithText(TextField, 'Email'),
    );
    final password = tester.widget<TextField>(
      find.widgetWithText(TextField, 'Password'),
    );
    // Password managers match the identifier and secret hints as a pair; one
    // group keeps them from being split across two forms.
    expect(email.autofillHints, const [AutofillHints.username]);
    expect(password.autofillHints, const [AutofillHints.password]);
    expect(
      find.descendant(
        of: find.byType(AutofillGroup),
        matching: find.widgetWithText(TextField, 'Password'),
      ),
      findsOneWidget,
    );

    // Leaving without a successful sign-in discards the context instead of
    // prompting to save a credential the server never accepted.
    final group = tester.widget<AutofillGroup>(find.byType(AutofillGroup));
    expect(group.onDisposeAction, AutofillContextAction.cancel);
  });

  testWidgets('email Next advances to the password instead of submitting', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    await tester.pumpWidget(
      ProviderScope(child: MaterialApp(home: _loginScreen())),
    );
    await tester.pumpAndSettle();

    final email = find.widgetWithText(TextField, 'Email');
    await tester.tap(email);
    await tester.pump();
    await tester.enterText(email, 'root@x.io');
    await tester.testTextInput.receiveAction(TextInputAction.next);
    await tester.pumpAndSettle();

    // Enter on the email used to call _submit with an empty password and
    // paint an error; the keyboard's Next must only move focus.
    expect(find.text('Enter email and password.'), findsNothing);
    final password = tester.widget<EditableText>(
      find.descendant(
        of: find.widgetWithText(TextField, 'Password'),
        matching: find.byType(EditableText),
      ),
    );
    expect(password.focusNode.hasFocus, isTrue);
  });

  testWidgets(
    'first-run setup hints a new password and advances to the token',
    (tester) async {
      SharedPreferences.setMockInitialValues({});
      await tester.pumpWidget(
        ProviderScope(
          child: MaterialApp(home: _loginScreen(setupRequired: true)),
        ),
      );
      await tester.pumpAndSettle();

      final name = tester.widget<TextField>(
        find.widgetWithText(TextField, 'Name (optional)'),
      );
      final password = tester.widget<TextField>(
        find.widgetWithText(TextField, 'Password'),
      );
      expect(name.autofillHints, const [AutofillHints.name]);
      expect(password.autofillHints, const [AutofillHints.newPassword]);

      final field = find.widgetWithText(TextField, 'Password');
      await tester.tap(field);
      await tester.pump();
      await tester.enterText(field, 'a-long-enough-password');
      await tester.testTextInput.receiveAction(TextInputAction.next);
      await tester.pumpAndSettle();

      // Next must reach the setup token, not fire a half-filled setup request.
      expect(find.text('Enter email and password.'), findsNothing);
      final token = tester.widget<EditableText>(
        find.descendant(
          of: find.widgetWithText(
            TextField,
            'Setup token (server ADMIN_TOKEN)',
          ),
          matching: find.byType(EditableText),
        ),
      );
      expect(token.focusNode.hasFocus, isTrue);
    },
  );

  testWidgets('admin fields sit on the dark input fill with ivory type', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(theme: AppTheme.dark(), home: _loginScreen()),
      ),
    );
    await tester.pumpAndSettle();

    // The screen is normally mounted under AppTheme.dark(); mount it with
    // the real theme here so the contrast assertion covers the shipped
    // input decoration rather than Material's light default.
    final field = find.widgetWithText(TextField, 'Password');
    expect(field, findsOneWidget);
    final editable = tester.widget<EditableText>(
      find.descendant(of: field, matching: find.byType(EditableText)),
    );
    final theme = Theme.of(tester.element(field));
    final fill = theme.inputDecorationTheme.fillColor;
    final ink = editable.style.color;
    expect(fill, AppColors.input);
    expect(ink, isNotNull);
    expect(fill!.computeLuminance(), lessThan(0.05));
    expect(ink!.computeLuminance(), greaterThan(0.5));
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

/// The login screen against a fake admin API: the status probe answers
/// immediately, so tests assert on a settled form instead of racing a real
/// connection attempt to localhost.
AdminLoginScreen _loginScreen({bool setupRequired = false}) {
  return AdminLoginScreen(
    clientFactory: () => AdminClient(
      serverUrl: 'ws://localhost:8080/ws',
      httpClient: MockClient((request) async {
        if (request.url.path == '/admin/status') {
          return http.Response(
            jsonEncode({'setupRequired': setupRequired}),
            200,
            headers: {'content-type': 'application/json'},
          );
        }
        return http.Response('{}', 404);
      }),
    ),
  );
}
