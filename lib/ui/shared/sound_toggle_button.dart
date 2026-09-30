import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../providers/app_providers.dart';
import '../theme.dart';

/// Mute toggle for the board itself, so sound can be silenced without leaving
/// a game to find it in Settings — the moment you want it is usually mid-roll.
///
/// Reads and writes the same [soundEnabledProvider] the Settings screen uses,
/// so the two can never disagree: muting here shows as off in Settings, and
/// flipping it there updates this icon immediately. The choice is persisted by
/// the notifier, so it survives a restart like every other preference.
class SoundToggleButton extends ConsumerWidget {
  const SoundToggleButton({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final enabled = ref.watch(soundEnabledProvider);
    return IconButton(
      icon: Icon(enabled ? Icons.volume_up : Icons.volume_off),
      color: enabled ? null : AppColors.ivoryDark,
      tooltip: enabled ? 'Sound on — tap to mute' : 'Muted — tap for sound',
      onPressed: () => ref.read(soundEnabledProvider.notifier).toggle(),
    );
  }
}
