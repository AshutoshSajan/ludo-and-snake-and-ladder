import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_web_plugins/url_strategy.dart';

import 'providers/app_providers.dart';
import 'screens/admin/admin_login_screen.dart';
import 'screens/home_screen.dart';
import 'ui/theme.dart';

void main() {
  // Path URLs (…/admin) instead of hash URLs (…/#/admin) on web, so the
  // server's SPA fallback and deep links resolve to real routes. No-op
  // on desktop/mobile builds.
  if (kIsWeb) usePathUrlStrategy();
  runApp(const ProviderScope(child: GameClubApp()));
}

class GameClubApp extends ConsumerWidget {
  const GameClubApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // Warm up persisted state early.
    ref.watch(profilesProvider);
    ref.watch(soundEnabledProvider);

    return MaterialApp(
      title: 'Game Club',
      debugShowCheckedModeBanner: false,
      theme: AppTheme.dark(),
      // Web-only admin lives at /admin (no in-game entry point).
      // Anything else falls back to home — a mistyped deep link is a
      // home screen, never a blank page.
      routes: {
        '/': (_) => const HomeScreen(),
        '/admin': (_) => const AdminLoginScreen(),
      },
      onUnknownRoute: (_) =>
          MaterialPageRoute(builder: (_) => const HomeScreen()),
    );
  }
}
