import 'dart:async';

import 'package:flutter/material.dart';

import '../../services/online_client.dart';
import '../theme.dart';

/// The on-turn seat's remaining seconds, as a plate beside the game's
/// subtitle — `12 s` in gold under its own timer glyph, red under ten.
///
/// A **plate**, not bare text: the old caption used to sit in white70 at
/// the row's end, and at a table the question "how long do I have?" was
/// the one thing people looked for and missed. The plate is the standing
/// answer — visible from the first armed turn on every seat's screen.
///
/// Live only on online tables: the authoritative server arms a turn timer —
/// thirty seconds to roll, or to move with the roll in hand — and skips the
/// seat on expiry, counting a miss. Five consecutive misses drop the seat
/// from the table, so this plate is standing instructions, not decoration.
///
/// Mechanics: the server attaches the remaining milliseconds to every state
/// broadcast (so a browser's clock never has to agree with the server's),
/// and this widget counts it down locally with a 1-second ticker that only
/// lives while a deadline does. No deadline — offline games, finished games,
/// a table gone quiet — means the plate is absent entirely.
class TurnCountdown extends StatefulWidget {
  const TurnCountdown({super.key, required this.client});

  final OnlineClient client;

  @override
  State<TurnCountdown> createState() => _TurnCountdownState();
}

class _TurnCountdownState extends State<TurnCountdown> {
  Timer? _ticker;

  /// Remaining-ms from the latest broadcast, and the seconds the local
  /// ticker has burned since it arrived: the chip re-baselines when the
  /// server announces a different deadline and drains downward one second
  /// per tick in between. A counted tick, not a wall-clock delta, so the
  /// number moves exactly when the screen redraws it — the <1s drift
  /// against real time never outpaces the server's own expiry judgement.
  int? _lastTurnMs;
  int _burnedMs = 0;

  @override
  void initState() {
    super.initState();
    _rememberClientClock();
  }

  @override
  void didUpdateWidget(TurnCountdown old) {
    super.didUpdateWidget(old);
    _rememberClientClock();
  }

  /// Tracks when the remaining-ms figure arrived, so countdown seconds can
  /// be derived between broadcasts: remaining minus burned-seconds since.
  void _rememberClientClock() {
    final ms = widget.client.turnMs;
    if ((ms != null && ms != _lastTurnMs) ||
        (ms == null && _lastTurnMs != null)) {
      _lastTurnMs = ms;
      _burnedMs = 0;
    }
    _syncTicker(ms != null);
  }

  void _syncTicker(bool active) {
    if (active && _ticker == null) {
      _ticker = Timer.periodic(const Duration(seconds: 1), (_) {
        if (mounted) {
          setState(() => _burnedMs += 1000);
        }
      });
    } else if (!active && _ticker != null) {
      _ticker!.cancel();
      _ticker = null;
    }
  }

  @override
  void dispose() {
    _ticker?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final ms = widget.client.turnMs;
    if (ms == null) return const SizedBox.shrink();
    final left = (ms - _burnedMs) / 1000;
    final seconds = left.ceil().clamp(0, 999);
    final danger = seconds <= 10;
    final tint = danger ? AppColors.danger : AppColors.gold;
    return Semantics(
      // Spoken in full by screen readers, not a bare "<n>s".
      label: '$seconds seconds left on this turn',
      excludeSemantics: true,
      child: Padding(
        padding: const EdgeInsets.only(left: 10),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
          decoration: BoxDecoration(
            color: Colors.black.withValues(alpha: 0.31),
            border: Border.all(
              color: tint.withAlpha(danger ? 200 : 120),
            ),
            borderRadius: BorderRadius.circular(14),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                danger ? Icons.timer_sharp : Icons.timer_outlined,
                size: 16,
                color: tint,
              ),
              const SizedBox(width: 5),
              Text(
                '$seconds s',
                style: TextStyle(
                  fontSize: 14,
                  fontWeight: danger ? FontWeight.w800 : FontWeight.w700,
                  color: tint,
                  fontFeatures: const [FontFeature.tabularFigures()],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
