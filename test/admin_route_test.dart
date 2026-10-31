import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:game_club/main.dart';
import 'package:game_club/providers/app_providers.dart';
import 'package:game_club/screens/admin/admin_auth_gate.dart';
import 'package:game_club/screens/admin/admin_dashboard_screen.dart';
import 'package:game_club/screens/admin/admin_login_screen.dart';
import 'package:game_club/services/admin_client.dart';
import 'package:game_club/shared/admin_credentials.dart';
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

  testWidgets('a signed-in admin gets a door beside Settings, nobody else '
      'does', (tester) async {
    // The door exists only while a session is live: signed-out users see
    // exactly the three doors they had before (the icon's absence is the
    // first test in this file).
    SharedPreferences.setMockInitialValues({});
    await tester.pumpWidget(
      const ProviderScope(child: MaterialApp(home: GameClubApp())),
    );
    await tester.pumpAndSettle();
    final container = ProviderScope.containerOf(
      tester.element(find.text('Game Club')),
    );
    container
        .read(adminSessionProvider.notifier)
        .signIn(
          const AdminSession(
            token: 't',
            email: 'root@x.io',
            name: 'Root',
            expiresAt: 9876543210000,
          ),
        );
    await tester.pumpAndSettle();

    expect(find.text('Admin'), findsOneWidget);
    expect(find.text('Back office'), findsOneWidget);
    expect(find.byIcon(Icons.admin_panel_settings_outlined), findsOneWidget);
  });

  testWidgets('the page bar carries no admin identity, signed in or out', (
    tester,
  ) async {
    // The compact badge that every PageAppBar screen used to trail is gone;
    // the home door is the one re-entry point now. A signed-in provider is
    // the strongest form of this claim: nothing renders even then.
    SharedPreferences.setMockInitialValues({});
    await tester.pumpWidget(
      const ProviderScope(
        child: MaterialApp(
          home: Scaffold(appBar: PageAppBar(title: 'T')),
        ),
      ),
    );
    final ctx = tester.element(find.byType(PageAppBar));
    ProviderScope.containerOf(ctx)
        .read(adminSessionProvider.notifier)
        .signIn(
          const AdminSession(
            token: 't',
            email: 'root@x.io',
            name: 'Root',
            expiresAt: 9876543210000,
          ),
        );
    await tester.pumpAndSettle();

    expect(find.text('Admin · root@x.io'), findsNothing);
    expect(find.byType(PageAppBar), findsOneWidget);
  });

  testWidgets('a successful sign-in keeps the server-set expiry on the '
      'session', (tester) async {
    SharedPreferences.setMockInitialValues({});
    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          home: AdminLoginScreen(
            clientFactory: () => AdminClient(
              serverUrl: 'ws://localhost:8080/ws',
              httpClient: MockClient((request) async {
                if (request.url.path == '/admin/status') {
                  return http.Response(
                    jsonEncode({'setupRequired': false}),
                    200,
                    headers: {'content-type': 'application/json'},
                  );
                }
                if (request.url.path == '/admin/login') {
                  return http.Response(
                    jsonEncode({
                      'token': 'tok-123',
                      'expiresAt': 1234567890123,
                      'user': {'email': 'root@x.io', 'name': 'Root'},
                    }),
                    200,
                    headers: {'content-type': 'application/json'},
                  );
                }
                return http.Response('{}', 404);
              }),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    final container = ProviderScope.containerOf(
      tester.element(find.byType(AdminLoginScreen)),
    );

    await tester.enterText(
      find.widgetWithText(TextField, 'Email'),
      'root@x.io',
    );
    await tester.enterText(find.widgetWithText(TextField, 'Password'), 's3cr3t-pass');
    final submit = find.widgetWithText(FilledButton, 'Sign in');
    await tester.ensureVisible(submit);
    await tester.pumpAndSettle();
    await tester.tap(submit);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));

    final session = container.read(adminSessionProvider);
    expect(session, isNotNull);
    expect(session!.token, 'tok-123');
    expect(
      session.expiresAt,
      1234567890123,
      reason: 'the persisted record must carry the server clock, not a '
          'client guess — a rebuilt session later restores exactly this',
    );
  });

  testWidgets('a dead session evicts the operator to a fresh login', (
    tester,
  ) async {
    // Every dashboard read rides the one token. When the server refuses it
    // outright (expired past the 12h window, revoked), a dashboard of
    // failing buttons is not an operator experience: the session watch
    // signs out and takes the stack back to a rooted login form.
    SharedPreferences.setMockInitialValues({});
    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          home: AdminDashboardScreen(
            client: AdminClient(
              serverUrl: 'ws://localhost:8080/ws',
              httpClient: MockClient((request) async {
                if (request.url.path == '/admin/status') {
                  return http.Response(
                    jsonEncode({'setupRequired': false}),
                    200,
                    headers: {'content-type': 'application/json'},
                  );
                }
                // me(), overview(), rooms(): all the same dead token.
                return http.Response(
                  jsonEncode({'ok': false, 'text': 'invalid session'}),
                  401,
                  headers: {'content-type': 'application/json'},
                );
              }),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final container = ProviderScope.containerOf(
      tester.element(find.byType(AdminLoginScreen).last),
    );
    expect(find.text('Admin dashboard'), findsNothing);
    expect(find.text('Admin sign in'), findsOneWidget);
    expect(
      ModalRoute.of(tester.element(find.byType(AdminLoginScreen).last))
          ?.settings
          .name,
      '/admin',
      reason: 'the dead dashboard is not kept in the stack for back to '
          'reach — the login form is the new root',
    );
    expect(container.read(adminSessionProvider), isNull,
        reason: 'the eviction signs out: no usable token stays in storage '
            'or the provider');
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
    expect(find.text('Enter your password.'), findsNothing);
    final password = tester.widget<EditableText>(
      find.descendant(
        of: find.widgetWithText(TextField, 'Password'),
        matching: find.byType(EditableText),
      ),
    );
    expect(password.focusNode.hasFocus, isTrue);
  });

  testWidgets(
    'first-run setup hints a new password and walks confirm to the token',
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
      final confirm = tester.widget<TextField>(
        find.widgetWithText(TextField, 'Confirm password'),
      );
      expect(name.autofillHints, const [AutofillHints.name]);
      expect(password.autofillHints, const [AutofillHints.newPassword]);
      expect(confirm.autofillHints, const [AutofillHints.newPassword]);
      expect(password.maxLength, adminPasswordMaxLength);
      expect(confirm.maxLength, adminPasswordMaxLength);

      final field = find.widgetWithText(TextField, 'Password');
      await tester.tap(field);
      await tester.pump();
      await tester.enterText(field, 'a-long-enough-1');
      await tester.testTextInput.receiveAction(TextInputAction.next);
      await tester.pumpAndSettle();

      // Next must reach the confirmation, not fire a half-filled setup.
      expect(find.text('Enter your email address.'), findsNothing);
      final confirmField = tester.widget<EditableText>(
        find.descendant(
          of: find.widgetWithText(TextField, 'Confirm password'),
          matching: find.byType(EditableText),
        ),
      );
      expect(confirmField.focusNode.hasFocus, isTrue);

      await tester.enterText(
        find.widgetWithText(TextField, 'Confirm password'),
        'a-long-enough-1',
      );
      await tester.testTextInput.receiveAction(TextInputAction.next);
      await tester.pumpAndSettle();

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

  testWidgets('setup submits every field through the shared value mapping', (
    tester,
  ) async {
    // The web form and the Flutter fallback hand the same
    // [AdminFormValues] to the screen, so the fallback pins the mapping:
    // name and setup token must survive the trip, not just email/password.
    Map<String, dynamic>? posted;
    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          home: AdminLoginScreen(
            clientFactory: () => AdminClient(
              serverUrl: 'ws://localhost:8080/ws',
              httpClient: MockClient((request) async {
                if (request.url.path == '/admin/status') {
                  return http.Response(
                    jsonEncode({'setupRequired': true}),
                    200,
                    headers: {'content-type': 'application/json'},
                  );
                }
                if (request.url.path == '/admin/setup') {
                  posted = jsonDecode(request.body) as Map<String, dynamic>;
                  return http.Response(
                    jsonEncode({
                      'token': 'tok',
                      'user': {'email': 'root@x.io', 'name': 'Root'},
                    }),
                    200,
                    headers: {'content-type': 'application/json'},
                  );
                }
                return http.Response('{}', 404);
              }),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.enterText(
      find.widgetWithText(TextField, 'Email'),
      'root@x.io',
    );
    await tester.enterText(
      find.widgetWithText(TextField, 'Name (optional)'),
      'Root',
    );
    await tester.enterText(
      find.widgetWithText(TextField, 'Password'),
      'a-new-long-password1',
    );
    await tester.enterText(
      find.widgetWithText(TextField, 'Confirm password'),
      'a-new-long-password1',
    );
    await tester.enterText(
      find.widgetWithText(TextField, 'Setup token (server ADMIN_TOKEN)'),
      'admin-token-123',
    );
    final submit = find.widgetWithText(FilledButton, 'Create admin account');
    await tester.ensureVisible(submit);
    await tester.pumpAndSettle();
    await tester.tap(submit);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));

    expect(posted, {
      'email': 'root@x.io',
      'password': 'a-new-long-password1',
      'name': 'Root',
      'setupToken': 'admin-token-123',
    });
  });

  testWidgets('sign-in refuses a malformed email before the API call', (
    tester,
  ) async {
    var posted = false;
    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          home: AdminLoginScreen(
            clientFactory: () => AdminClient(
              serverUrl: 'ws://localhost:8080/ws',
              httpClient: MockClient((request) async {
                if (request.url.path == '/admin/status') {
                  return http.Response(
                    jsonEncode({'setupRequired': false}),
                    200,
                    headers: {'content-type': 'application/json'},
                  );
                }
                posted = true;
                return http.Response('{}', 200);
              }),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.enterText(find.widgetWithText(TextField, 'Email'), 'root@');
    await tester.enterText(
      find.widgetWithText(TextField, 'Password'),
      'hunter2!',
    );
    final submit = find.widgetWithText(FilledButton, 'Sign in');
    await tester.ensureVisible(submit);
    await tester.pumpAndSettle();
    await tester.tap(submit);
    await tester.pumpAndSettle();

    expect(find.text('Enter a valid email address.'), findsOneWidget);
    expect(posted, isFalse);
  });

  testWidgets('setup enforces password strength and confirmation', (
    tester,
  ) async {
    var posted = false;
    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          home: AdminLoginScreen(
            clientFactory: () => AdminClient(
              serverUrl: 'ws://localhost:8080/ws',
              httpClient: MockClient((request) async {
                if (request.url.path == '/admin/status') {
                  return http.Response(
                    jsonEncode({'setupRequired': true}),
                    200,
                    headers: {'content-type': 'application/json'},
                  );
                }
                posted = true;
                return http.Response('{}', 200);
              }),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.enterText(
      find.widgetWithText(TextField, 'Email'),
      'root@x.io',
    );
    await tester.enterText(
      find.widgetWithText(TextField, 'Password'),
      'alllettersonly',
    );
    await tester.enterText(
      find.widgetWithText(TextField, 'Confirm password'),
      'alllettersonly',
    );
    await tester.enterText(
      find.widgetWithText(TextField, 'Setup token (server ADMIN_TOKEN)'),
      'admin-token-123',
    );
    final submit = find.widgetWithText(FilledButton, 'Create admin account');
    await tester.ensureVisible(submit);
    await tester.pumpAndSettle();
    await tester.tap(submit);
    await tester.pumpAndSettle();

    // Letters alone are not enough.
    expect(find.text('Add at least one number.'), findsOneWidget);
    expect(posted, isFalse);

    // A strong password with a confirmation typo is still refused.
    await tester.enterText(
      find.widgetWithText(TextField, 'Password'),
      'alllettersonly1!',
    );
    await tester.enterText(
      find.widgetWithText(TextField, 'Confirm password'),
      'alllettersonly1?',
    );
    await tester.ensureVisible(submit);
    await tester.pumpAndSettle();
    await tester.tap(submit);
    await tester.pumpAndSettle();

    expect(find.text('Passwords do not match.'), findsOneWidget);
    expect(posted, isFalse);
  });

  testWidgets('setup caps a new password at 60 characters', (tester) async {
    SharedPreferences.setMockInitialValues({});
    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(home: _loginScreen(setupRequired: true)),
      ),
    );
    await tester.pumpAndSettle();

    final password = find.widgetWithText(TextField, 'Password');
    await tester.enterText(password, 'a1!${'x' * 80}');
    await tester.pump();

    final field = tester.widget<TextField>(password);
    expect(field.controller!.text.length, adminPasswordMaxLength);
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

  testWidgets('a cold /admin lands on /admin/login when the server is set up', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(home: AdminAuthGate(clientFactory: _goodApi(false))),
      ),
    );
    await tester.pumpAndSettle();

    final ctx = tester.element(find.text('Admin sign in'));
    expect(
      ModalRoute.of(ctx)?.settings.name,
      '/admin/login',
      reason: 'the gate replaces itself with the URL it served',
    );
  });

  testWidgets('a fresh server lands on /admin/signup from /admin', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(home: AdminAuthGate(clientFactory: _goodApi(true))),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Open the first table'), findsOneWidget);
    final ctx = tester.element(find.text('Open the first table'));
    expect(ModalRoute.of(ctx)?.settings.name, '/admin/signup');
  });

  testWidgets('a dead admin API keeps the gate with a retry, not a form', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    var healthy = false;
    AdminClient stubFor() => AdminClient(
      serverUrl: 'ws://localhost:8080/ws',
      httpClient: MockClient((request) async {
        if (!healthy) return http.Response('unavailable', 503);
        return http.Response(
          jsonEncode({'setupRequired': false}),
          200,
          headers: {'content-type': 'application/json'},
        );
      }),
    );
    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(home: AdminAuthGate(clientFactory: stubFor)),
      ),
    );
    await tester.pumpAndSettle();

    // Nothing credential-shaped may render while the server is a question
    // mark: a dead API is a service problem, not a form problem.
    expect(find.text('The admin API did not answer.'), findsOneWidget);
    expect(find.widgetWithText(TextField, 'Email'), findsNothing);

    healthy = true;
    await tester.tap(find.text('Check the server again'));
    await tester.pumpAndSettle();
    expect(find.text('Admin sign in'), findsOneWidget);
  });

  testWidgets(
    '/admin/signup redirects to /admin/login when an account exists',
    (tester) async {
      SharedPreferences.setMockInitialValues({});
      // The signup URL assumed the first admin was still to be created; the
      // server disagrees, so the tab must move where the truth is.
      await tester.pumpWidget(
        ProviderScope(
          child: MaterialApp(home: _loginScreen(mode: AdminAuthMode.signup)),
        ),
      );
      await tester.pumpAndSettle();

      expect(_currentRouteName(tester), '/admin/login');
      expect(find.text('Admin sign in'), findsOneWidget);
      expect(find.widgetWithText(TextField, 'Confirm password'), findsNothing);
    },
  );

  testWidgets('/admin/login redirects to /admin/signup on a fresh server', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          home: _loginScreen(setupRequired: true, mode: AdminAuthMode.login),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(_currentRouteName(tester), '/admin/signup');
    expect(find.text('Open the first table'), findsOneWidget);
    expect(
      find.widgetWithText(TextField, 'Confirm password'),
      findsOneWidget,
      reason: 'the setup form has the confirmation the story needs',
    );
  });
}

/// The name of the route that currently owns the screen's front-most
/// element — how the clipboard-free world asserts a redirect happened.
String _currentRouteName(WidgetTester tester) {
  final ctx = tester.element(find.byType(AdminLoginScreen).last);
  return ModalRoute.of(ctx)?.settings.name ?? 'none';
}

/// The status half of the fake API, shared by the gate tests.
AdminClient Function() _goodApi(bool setupRequired) {
  return () => AdminClient(
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
  );
}

/// The login screen against a fake admin API: the status probe answers
/// immediately, so tests assert on a settled form instead of racing a real
/// connection attempt to localhost.
AdminLoginScreen _loginScreen({
  bool setupRequired = false,
  AdminAuthMode mode = AdminAuthMode.login,
}) {
  return AdminLoginScreen(
    mode: mode,
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
