/// The /admin front door that knows nothing yet.
///
/// Deep links to `/admin` arrive before the app knows which auth story is
/// true: has the club's first admin been created or not? Instead of
/// guessing — a wrong guess paints a New Password form on a server that
/// wants just email+password, or asks a stranger to create the first
/// admin — this gate asks the server one question (`/admin/status`) and
/// hands the tab to the URL that matches: `/admin/login` when an account
/// exists, `/admin/signup` when the first one is still to be created.
///
/// The handoff happens through [replaceAppScreen], so the browser URL lands
/// on the real auth page (deep-linkable, refreshable) and "back" skips the
/// gate. Only an unreachable server keeps the gate on screen — with a retry
/// card, worded like one, because a dead API is a service problem, not a
/// credentials problem.
///
/// There is deliberately no client-side restore arm here anymore: the
/// session credential is the browser's HttpOnly cookie, kept and re-presented
/// by the browser itself. The gate still cannot see that cookie — only the
/// server can — so once `/admin/status` says an account exists, it asks one
/// more question (`/admin/me`) before choosing a screen: a 200 hands off to
/// the dashboard at `/admin/dashboard`, a 401/403 hands off to the sign-in
/// form. Skipping that question is what made a reload look like a logout —
/// the gate sent every cold load to the form whether or not the cookie was
/// alive. A dashboard cold load proves the cookie again on its own first
/// read, so an expired session still lands on the form without the gate.
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
      // No setup pending, so an account exists. Whether *this* browser may
      // skip the form is the server's call — the cookie is HttpOnly and the
      // page cannot read it, so /admin/me is the only honest probe. A live
      // session goes straight to the dashboard; its own death watch keeps
      // watching from there. The answer also seeds the home door's snapshot,
      // so a cold load straight into /admin does not ask the same question a
      // second time.
      final Map<String, dynamic> me;
      try {
        me = await client.me();
      } on AdminException catch (e) {
        if (e.statusCode != 401 && e.statusCode != 403) rethrow;
        if (!mounted) return;
        replaceAppScreen<void>(
          context,
          name: AppRoutes.adminLogin,
          builder: (_) =>
              AdminLoginScreen(mode: AdminAuthMode.login, clientFactory: clientFactory),
        );
        return;
      }
      if (!mounted) return;
      final session = AdminSession.fromUser(me['user']);
      if (session != null) {
        ref.read(adminSessionProvider.notifier).signIn(session);
      }
      replaceAppScreen<void>(
        context,
        name: AppRoutes.adminDashboard,
        builder: (_) => AdminDashboardScreen(client: client),
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
