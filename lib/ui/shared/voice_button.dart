import 'package:flutter/material.dart';

import '../../services/online_client.dart';
import '../theme.dart';

/// Table voice: join/leave, and a mute toggle that only matters once
/// joined. Two controls on purpose: mute must never sit in the same tap
/// as leaving — one untimed tap silencing you while you think you left,
/// or worse, dropping the call while you meant to hush, is exactly the
/// kind of small confusion that makes people stop using voice.
///
/// Both buttons read their state off the [OnlineClient], so a lobby row
/// and a board app bar show the same truth and neither needs local state.
class VoiceButton extends StatelessWidget {
  const VoiceButton({super.key, required this.client});

  final OnlineClient client;

  Future<void> _join(BuildContext context) async {
    final granted = await client.joinVoice();
    if (granted || !context.mounted) return;
    // A refusal is a permission answer, not a bug — say what to do about
    // it. Web shows the mic prompt; a dismissed prompt leaves voice off.
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        const SnackBar(
          content: Text('No microphone — allow mic access to use table voice'),
        ),
      );
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: client,
      builder: (context, _) {
        final joined = client.voiceJoined;
        return IconButton(
          icon: Icon(
            joined ? Icons.spatial_audio : Icons.spatial_audio_off,
            color: joined ? AppColors.gold : null,
          ),
          tooltip: joined ? 'Leave table voice' : 'Join table voice',
          onPressed: joined ? client.leaveVoice : () => _join(context),
        );
      },
    );
  }
}

/// The mute toggle next to [VoiceButton]. Hidden until you have actually
/// joined table voice: a mute toggle before joining is a control that
/// answers every tap with nothing (it cannot mute a call you are not
/// on), and in a row with the voice-note mic it read as a second mic
/// that did not work. Once joined it appears — red while muted — so the
/// state that matters (transmitting or not) stays one tap away.
class MicButton extends StatelessWidget {
  const MicButton({super.key, required this.client});

  final OnlineClient client;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: client,
      builder: (context, _) {
        final joined = client.voiceJoined;
        final muted = client.voiceMuted;
        if (!joined) return const SizedBox.shrink();
        return IconButton(
          icon: Icon(
            muted ? Icons.mic_off : Icons.mic,
            color: muted ? Colors.redAccent : AppColors.ivory.withAlpha(180),
          ),
          tooltip: muted ? 'Unmute my mic' : 'Mute my mic',
          onPressed: joined ? () => client.setVoiceMuted(!muted) : null,
        );
      },
    );
  }
}
