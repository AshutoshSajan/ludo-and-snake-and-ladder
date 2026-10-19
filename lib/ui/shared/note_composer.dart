import 'dart:async';

import 'package:flutter/material.dart';

import '../../services/note_recorder.dart';
import '../theme.dart';

/// The voice-note control for a chat composer row: a mic chip when idle,
/// and — while recording — a compact bar with the elapsed clock, a cancel,
/// and a send that uploads through [send].
///
/// One widget does both states on purpose: the recording (microphone
/// session, timers) must survive the parent swapping the rest of the row
/// around it, so the parent only learns about state changes through
/// [onRecordingChanged] and never rebuilds this one. The recorder's cap is
/// enforced here with a timer that sends a finished note automatically —
/// a recording that outgrows the server (2 MiB / 60 s) is a silent
/// disappointment otherwise.
class NoteComposer extends StatefulWidget {
  const NoteComposer({
    super.key,
    required this.send,
    this.onError,
    this.onRecordingChanged,
  });

  /// Uploads and announces a finished recording. False means refused —
  /// the composer reports through [onError] rather than swallowing it.
  final Future<bool> Function(NoteRecording recording) send;

  final void Function(String message)? onError;

  final void Function(bool recording)? onRecordingChanged;

  @override
  State<NoteComposer> createState() => _NoteComposerState();
}

class _NoteComposerState extends State<NoteComposer>
    with SingleTickerProviderStateMixin {
  NoteRecorder? _rec;
  late final AnimationController _pulse = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 900),
  )..repeat(reverse: true);

  /// The display clock — a separate, generous stopwatch so the visible
  /// "0:07" never stutters waiting for the recorder's own win tote.
  Stopwatch? _clock;
  Timer? _ticker;
  Timer? _cap;
  bool _finishing = false;

  bool get _recording => _rec != null;

  Future<void> _start() async {
    final rec = await NoteRecorder.start();
    if (!mounted) return;
    if (rec == null) {
      widget.onError?.call('No microphone — check mic access');
      return;
    }
    setState(() {
      _rec = rec;
      _clock = Stopwatch()..start();
    });
    widget.onRecordingChanged?.call(true);
    _ticker = Timer.periodic(
      const Duration(milliseconds: 250),
      (_) { if (mounted) setState(() {}); },
    );
    _cap = Timer(NoteRecorder.max, () => _finish());
  }

  Future<void> _finish() async {
    if (_finishing || !_recording) return;
    setState(() => _finishing = true);
    _stopTimers();
    final rec = _rec!;
    final recording = await rec.finish();
    if (mounted) {
      setState(() {
        _rec = null;
        _clock = null;
        _finishing = false;
      });
    }
    widget.onRecordingChanged?.call(false);
    if (recording == null) {
      widget.onError?.call('Nothing was recorded');
      return;
    }
    // Upload happens after the composer is back to idle: an upload that
    // takes three seconds must not read as "still recording".
    final ok = await widget.send(recording);
    if (!ok) widget.onError?.call('Voice note refused — try again');
  }

  Future<void> _cancel() async {
    if (!_recording) return;
    _stopTimers();
    final rec = _rec!;
    if (mounted) {
      setState(() {
        _rec = null;
        _clock = null;
        _finishing = false;
      });
    }
    widget.onRecordingChanged?.call(false);
    await rec.cancel();
  }

  void _stopTimers() {
    _ticker?.cancel();
    _ticker = null;
    _cap?.cancel();
    _cap = null;
  }

  @override
  void dispose() {
    _stopTimers();
    _pulse.dispose();
    unawaited(_rec?.cancel());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (!_recording) {
      return _chip(
        icon: Icons.mic_none,
        tooltip: 'Record a voice note',
        foreground: AppColors.gold,
        onPressed: _finishing ? null : _start,
      );
    }

    final elapsed = _clock!.elapsed;
    final clock =
        '${elapsed.inMinutes}:${(elapsed.inSeconds % 60).toString().padLeft(2, '0')}';
    return Container(
      padding: const EdgeInsets.fromLTRB(10, 4, 4, 4),
      decoration: BoxDecoration(
        color: AppColors.danger.withValues(alpha: 0.14),
        border: Border.all(color: AppColors.danger.withValues(alpha: 0.5)),
        borderRadius: BorderRadius.circular(16),
      ),
      child: Row(
        children: [
          FadeTransition(
            opacity: Tween(begin: 0.35, end: 1.0).animate(_pulse),
            child: const Icon(Icons.fiber_manual_record,
                size: 14, color: AppColors.danger),
          ),
          const SizedBox(width: 6),
          Text(
            clock,
            style: const TextStyle(
              color: AppColors.ivory,
              fontWeight: FontWeight.w700,
              fontSize: 13,
            ),
          ),
          const Spacer(),
          _chip(
            icon: Icons.close,
            tooltip: 'Discard recording',
            foreground: AppColors.ivory.withValues(alpha: 0.75),
            onPressed: _cancel,
          ),
          _finishing
              ? const Padding(
                  padding: EdgeInsets.symmetric(horizontal: 10),
                  child: SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                )
              : _chip(
                  icon: Icons.send,
                  tooltip: 'Send voice note',
                  foreground: AppColors.gold,
                  onPressed: _finish,
                ),
        ],
      ),
    );
  }

  Widget _chip({
    required IconData icon,
    required String tooltip,
    required Color foreground,
    VoidCallback? onPressed,
  }) {
    return IconButton(
      icon: Icon(icon, color: foreground, size: 20),
      tooltip: tooltip,
      constraints: const BoxConstraints(minWidth: 36, minHeight: 36),
      onPressed: onPressed,
    );
  }
}
