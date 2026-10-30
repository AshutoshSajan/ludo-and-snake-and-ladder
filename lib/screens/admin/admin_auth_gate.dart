/// The /admin front door that knows nothing yet.
///
/// Deep links to `/admin` (and cold loads of `/admin/dashboard`, whose live
/// client died with the tab that owned it) arrive before the app knows which
/// auth story is true: has the club's first admin been created or not?
/// Instead of guessing — a wrong guess paints a New Password form on a
/// server that wants just email+password, or asks a stranger to create the
/// first admin — this gate asks the server one question (`/admin/status`)
/// and hands the tab to the URL that matches: `/admin/login` when an
/// account exists, `/admin/signup` when the first one is still to be
/// created.
///
/// The handoff happens through [replaceAppScreen], so the browser URL lands
/// on the real auth page (deep-linkable, refreshable) and "back" skips the
/// gate. Only an unreachable server keeps the gate on screen — with a retry
/// card, worded like one, because a dead API is a service problem, not a
/// credentials problem.
///
/// A cold load of `/admin/dashboard` skips that story entirely when a
/// persisted session still validates client-side (see
/// `services/admin_session_store.dart`): the stored token is re-entered into
/// a client and the provider, and the operator is back where they were.
/// The server is the source of truth on top of that — a token the server has
/// revoked or expired 401s on the dashboard's first read and the dashboard
/// throws the operator back to the login form itself.
///
/// Compiled only on the web (`app_router.dart` conditional import); native
/// builds get [admin_auth_gate_stub.dart]'s placeholder and the route arms
/// never register it.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app_router.dart';
import '../../app_routes.dart';
import '../../providers/app_providers.dart';
import '../../services/admin_client.dart';
import '../../services/admin_session_store.dart';
import '../../services/server_url.dart';
import '../../ui/club_widgets.dart';
import '../../ui/theme.dart';
import 'admin_dashboard_screen.dart';
import 'admin_login_screen.dart';

class AdminAuthGate extends ConsumerStatefulWidget {
  const AdminAuthGate({super.key, this.clientFactory});

  /// Test seam: builds the client used for the status check. Null in
  /// production, where the target is [defaultServerUrl].
  final AdminClient Function()? clientFactory;

  @override
  ConsumerState<AdminAuthGate> createState() => _AdminAuthGateState();
}

class _AdminAuthGateState extends ConsumerState<AdminAuthGate> {
  bool _failed = false;

  AdminClient get _client =>
      widget.clientFactory?.call() ??
      AdminClient(serverUrl: defaultServerUrl());

  @override
  void initState() {
    super.initState();
    _handOff();
  }

  Future<void> _handOff() async {
    final client = _client;
    try {
      final status = await client.status();
      if (!mounted) return;
      final clientFactory = widget.clientFactory;
      if (status['setupRequired'] as bool? ?? false) {
        replaceAppScreen<void>(
          context,
          name: AppRoutes.adminSignup,
          builder: (_) =>
              AdminLoginScreen(mode: AdminAuthMode.signup, clientFactory: clientFactory),
        );
        return;
      }
      final restored = restoreAdminSession();
      if (restored != null) {
        // The persisted session outlives the tab this client belonged to:
        // re-seat the token into a fresh client and the provider, then put
        // the operator back on the dashboard at the same URL. A dead token
        // (revoked server-side, clock drifted) cannot be told apart from a
        // live one here without an extra request — the dashboard's first
        // read is that request, and a 401 there ends the session and lands
        // the login form, so no second status round-trip is spent.
        final dashClient = widget.clientFactory?.call() ?? _client;
        dashClient.token = restored.token;
        ref.read(adminSessionProvider.notifier).signIn(
          AdminSession(
            token: restored.token,
            email: restored.email,
            name: restored.name,
            expiresAt: restored.expiresAt,
          ),
        );
        replaceAppScreen<void>(
          context,
          name: AppRoutes.adminDashboard,
          builder: (_) =>
              AdminDashboardScreen(client: dashClient),
        );
        return;
      }
      // No usable session: the URL and server truth agree by construction
      // from here on — the replaced route names the mode, the screen mounts
      // knowing it.
      replaceAppScreen<void>(
        context,
        name: AppRoutes.adminLogin,
        builder: (_) =>
            AdminLoginScreen(mode: AdminAuthMode.login, clientFactory: clientFactory),
      );
    } catch (e) {
      if (!mounted) return;
      setState(() => _failed = true);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.felt,
      appBar: AppBar(
        title: const Text('Back office'),
        backgroundColor: AppColors.felt,
      ),
      body: ClubBackground(
        child: SafeArea(
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 470),
              child: ListView(
                padding: const EdgeInsets.fromLTRB(20, 28, 20, 40),
                shrinkWrap: true,
                children: [
                  if (_failed) ...[
                    // The API was unreachable, not the credentials wrong —
                    // the fix is to check the connection, not the form.
                    Text(
                      'Back office',
                      style: Theme.of(context).textTheme.headlineMedium
                          ?.copyWith(color: AppColors.ivory, height: 1.05),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      'Could not reach the admin API. Check your connection '
                      'and try again.',
                      style: const TextStyle(
                        fontFamily: AppFonts.body,
                        color: AppColors.textSecondary,
                        fontSize: 13.5,
                        height: 1.55,
                      ),
                    ),
                    const SizedBox(height: 22),
                    ClubCard(
                      padding: const EdgeInsets.fromLTRB(18, 18, 18, 18),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          Row(
                            children: [
                              const Icon(
                                Icons.error_outline,
                                size: 18,
                                color: AppColors.danger,
                              ),
                              const SizedBox(width: 10),
                              Expanded(
                                child: Text(
                                  'The admin API did not answer.',
                                  style: const TextStyle(
                                    fontFamily: AppFonts.body,
                                    color: AppColors.ivory,
                                    fontSize: 12.5,
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 16),
                          SizedBox(
                            width: double.infinity,
                            child: FilledButton(
                              onPressed: _handOff,
                              child: const Text('Check the server again'),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ] else ...[
                    const ClubCard(
                      padding: EdgeInsets.fromLTRB(18, 22, 18, 22),
                      child: Row(
                        children: [
                          SizedBox(
                            width: 20,
                            height: 20,
                            child: CircularProgressIndicator(
                              strokeWidth: 2.4,
                              color: AppColors.gold,
                            ),
                          ),
                          SizedBox(width: 12),
                          Expanded(
                            child: Text(
                              'Checking the admin API…',
                              style: TextStyle(
                                fontFamily: AppFonts.body,
                                color: AppColors.textSecondary,
                                fontSize: 13.5,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
