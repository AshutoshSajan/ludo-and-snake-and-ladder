import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_web_plugins/url_strategy.dart';

import 'providers/app_providers.dart';
import 'screens/admin/admin_gate.dart';
import 'screens/admin/admin_login_screen.dart'
    if (dart.library.io) 'screens/admin/admin_login_stub.dart';
import 'screens/home_screen.dart';
import 'screens/invite_watcher.dart';
import 'ui/theme.dart';

/// The app-wide play-invite listener. One instance for the whole app —
/// it picks a fresh identity from storage each poll, so a guest who goes
/// online later starts hearing knocks without a restart.
final InviteWatcher inviteWatcher = InviteWatcher();

void main() {
  // Path URLs (…/admin) instead of hash URLs (…/#/admin) on web, so the
  // server's SPA fallback and deep links resolve to real routes. No-op
  // on desktop/mobile builds.
  if (kIsWeb) usePathUrlStrategy();
  // The knock listens on the app-level poller below, not on a screen's
  // lifecycle: a friend's invite must land wherever the player is.
  runApp(const ProviderScope(child: GameClubApp()));
  inviteWatcher.start();
}

class GameClubApp extends ConsumerWidget {
  const GameClubApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // Warm up persisted state early.
    ref.watch(profilesProvider);
    ref.watch(soundEnabledProvider);

    return _AppFocusPulse(
      child: MaterialApp(
        title: 'Game Club',
        debugShowCheckedModeBanner: false,
        theme: AppTheme.dark(),
        navigatorKey: InviteWatcher.navigatorKey,
        // The admin UI lives only in the hosted web app
        // ([isAdminUiAvailable]): native builds never compile the screens
        // and packaged add-ons run under an extension origin, so /admin is
        // registered nowhere else. Anything else falls back to home — a
        // mistyped deep link is a home screen, never a blank page.
        routes: {
          '/': (_) => const HomeScreen(),
          if (isAdminUiAvailable) '/admin': (_) => const AdminLoginScreen(),
        },
        onUnknownRoute: (_) =>
            MaterialPageRoute(builder: (_) => const HomeScreen()),
      ),
    );
  }
}

/// The tab-focus pulse for the play-invite knock: browsers throttle timers
/// in background tabs, so a player who switches back to their game after
/// sitting in another tab may have a pending invite that the coarse poller
/// (also throttled) did not raise while they were away. Every time the app
/// reports visible-and-resumed again, the watcher polls right now — and
/// its dedupe set keeps a repeated refocus from re-showing the same knock.
class _AppFocusPulse extends StatefulWidget {
  const _AppFocusPulse({required this.child});

  final Widget child;

  @override
  State<_AppFocusPulse> createState() => _AppFocusPulseState();
}

class _AppFocusPulseState extends State<_AppFocusPulse>
    with WidgetsBindingObserver {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      inviteWatcher.poke();
    }
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
