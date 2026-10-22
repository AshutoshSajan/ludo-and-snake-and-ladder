import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_web_plugins/url_strategy.dart';

import 'app_router.dart';
import 'providers/app_providers.dart';
import 'screens/invite_watcher.dart';
import 'ui/theme.dart';

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

class GameClubApp extends ConsumerStatefulWidget {
  const GameClubApp({super.key});

  @override
  ConsumerState<GameClubApp> createState() => _GameClubAppState();
}

class _GameClubAppState extends ConsumerState<GameClubApp> {
  /// One router per app instance: its page stack and browser history belong
  /// to this mount, and a fresh cold URL starts a fresh stack.
  late final RouterConfig<Object> _routerConfig;

  @override
  void initState() {
    super.initState();
    _routerConfig = createAppRouterConfig();
  }

  @override
  Widget build(BuildContext context) {
    // Warm up persisted state early.
    ref.watch(profilesProvider);
    ref.watch(soundEnabledProvider);

    return _AppFocusPulse(
      child: MaterialApp.router(
        title: 'Game Club',
        debugShowCheckedModeBanner: false,
        theme: AppTheme.dark(),
        // The router owns the screen stack: cold URLs and deep links build
        // it, every push records a real URL, and browser back/forward walk
        // the same entries. `/admin` is only registered by the router's
        // admin check, so native builds and packaged add-ons still fall
        // back to home. A mistyped deep link is a home screen, never a
        // blank page.
        routerConfig: _routerConfig,
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
