import 'package:flutter/material.dart';

import '../../services/online_client.dart';
import 'table_notice.dart';
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
    showTableNotice(
      context,
      'No microphone — allow mic access to use table voice',
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
///
/// It is also the table's speaking indicator: while the mic actually
/// hears your voice, a beam of expanding gold rings plays around it.
/// That replaces the chip row the game boards used to carry for the same
/// fact — the row slid the board down every time anyone said a word, and
/// the answer to "am I live?" belongs on the control that does the
/// transmitting. Reduced-motion settings get the same truth without the
/// motion: the icon alone turns gold while the microphone is hot.
class MicButton extends StatefulWidget {
  const MicButton({super.key, required this.client});

  final OnlineClient client;

  @override
  State<MicButton> createState() => _MicButtonState();
}

class _MicButtonState extends State<MicButton>
    with SingleTickerProviderStateMixin {
  /// One full beam sweep: a pair of rings expanding out and fading, then
  /// repeating for as long as speech holds.
  static const Duration _beamPeriod = Duration(milliseconds: 1300);

  AnimationController? _beam;

  /// Voice truths last read off the client. A diff against the next read
  /// is the only rebuild: the speaking probe beats notify on their own
  /// schedule too, and a mostly-unchanged state must not pump frames.
  bool _joined = false;
  bool _muted = false;
  bool _hot = false;

  /// Held from [MediaQuery] once it is readable: animation policy is
  /// honoured without re-dancing the whole button on every restore.
  bool _reducedMotion = false;

  @override
  void initState() {
    super.initState();
    widget.client.addListener(_sync);
    _read(animate: false);
  }

  @override
  void didUpdateWidget(MicButton old) {
    super.didUpdateWidget(old);
    if (old.client != widget.client) {
      old.client.removeListener(_sync);
      widget.client.addListener(_sync);
      _read(animate: false);
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final reduced = MediaQuery.of(context).disableAnimations;
    if (reduced == _reducedMotion) return;
    _reducedMotion = reduced;
    if (_reducedMotion && _beam != null) {
      _dropBeam();
    } else if (!_reducedMotion && _hot) {
      _startBeam();
    }
  }

  /// Reads the client's voice truth and only then rebuilds: the caller set
  /// the subscription up (or swapped it) and needs the drawn state fresh,
  /// not another notice-driven pass.
  void _read({required bool animate}) {
    final client = widget.client;
    final joined = client.voiceJoined;
    final muted = joined && client.voiceMuted;
    // A muted mic cannot be "heard speaking", whatever the level probe
    // believed a beat ago: the transmit switch owns the indicator.
    final hot = joined && !muted && client.voiceSpeaking.contains(client.seatId);
    final changed = joined != _joined || muted != _muted;
    _joined = joined;
    _muted = muted;
    if (hot != _hot) {
      _hot = hot;
      if (_hot && !_reducedMotion) {
        _startBeam();
      } else if (!_hot && _beam != null) {
        // The mic went quiet (or reduced motion turned beam duty off):
        // the rings stop and the icon settles back on its own.
        _dropBeam();
      }
      if (mounted) setState(() {});
      return;
    }
    if (changed && mounted) setState(() {});
  }

  /// A client beat arrived (state, seats, voice probe). Voice truths are
  /// the only ones this button draws; everything else is diffed away here.
  void _sync() => _read(animate: true);

  void _startBeam() {
    var controller = _beam;
    controller ??= AnimationController(vsync: this, duration: _beamPeriod);
    _beam = controller;
    controller.repeat();
  }

  void _dropBeam() {
    _beam?.dispose();
    _beam = null;
  }

  @override
  void dispose() {
    widget.client.removeListener(_sync);
    _dropBeam();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (!_joined) return const SizedBox.shrink();
    final beam = _beam;
    return SizedBox(
      width: 48,
      height: 48,
      child: Stack(
        alignment: Alignment.center,
        children: [
          if (beam != null)
            // Inside the button's own 48 px box, exactly: beams must never
            // borrow from the neighbours' layout — that is the whole
            // point of moving the indicator off its own chip row.
            IgnorePointer(
              key: const Key('mic-speaking-beam'),
              child: AnimatedBuilder(
                animation: beam,
                builder: (context, _) => CustomPaint(
                  size: const Size.square(48),
                  painter: _BeamPainter(beam.value),
                ),
              ),
            ),
          IconButton(
            icon: Icon(
              _muted ? Icons.mic_off : Icons.mic,
              color: _muted
                  ? Colors.redAccent
                  : _hot
                  ? AppColors.gold
                  : AppColors.ivory.withAlpha(180),
            ),
            tooltip: _muted ? 'Unmute my mic' : 'Mute my mic',
            onPressed: () => widget.client.setVoiceMuted(!_muted),
          ),
        ],
      ),
    );
  }
}

/// The beam itself: two rings per period, staggered half a sweep apart, so
/// speech reads as a continuous pulse rather than a metronome tick. Rings
/// start outside the glyph's own radius and stay inside the button box.
class _BeamPainter extends CustomPainter {
  const _BeamPainter(this.progress);

  /// 0..1 through one sweep.
  final double progress;

  @override
  void paint(Canvas canvas, Size size) {
    final centre = Offset(size.width / 2, size.height / 2);
    for (final phase in [progress, (progress + 0.5) % 1.0]) {
      final ring = Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2
        ..color = AppColors.gold.withAlpha(((1 - phase) * 140).round());
      canvas.drawCircle(centre, 13.5 + 10 * phase, ring);
    }
  }

  @override
  bool shouldRepaint(_BeamPainter old) => old.progress != progress;
}
