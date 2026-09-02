import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'providers/app_providers.dart';
import 'screens/home_screen.dart';
import 'ui/theme.dart';

void main() {
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
      home: const HomeScreen(),
    );
  }
}
