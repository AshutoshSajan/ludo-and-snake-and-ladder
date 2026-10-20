import 'dart:async';

import 'package:flutter/material.dart';

import '../theme.dart';

/// The table's one spoken surface: a gold-rimmed pill at the top right,
/// under the app bar.
///
/// The playtest asked for this surface in one sentence — "too many
/// unwanted alert popups now … keep only necessary alert popups make
/// their design good, show them on top right of the screen" — and both
/// halves live here: at most ONE table message on screen at a time (a new
/// call takes the showing one's place), it leaves by itself after five
/// seconds and leaves earlier when tapped, and it settles in from the
/// right over 220ms instead of popping.
///
/// It is deliberately not a [ScaffoldMessenger] snackbar: snackbars
/// anchor to the bottom edge and queue up over the controls, while a
/// table message is spoken over the board, once, where the corner area
/// under the app bar is free of everything worth reading.
///
/// The cap is 460 wide — the same family as the removal dialog and the
/// win podium, which use `BoxConstraints(maxWidth: 460)` — and the
/// minimum touch height of 44 keeps the pill itself a dismiss target,
/// not look-only text.
void showTableAlert(
  BuildContext context,
  String text, {
  IconData icon = Icons.info_outline,
}) {
  // The root navigator's overlay: game views live inside lobby screens
  // and route stacks, and the top-right corner must always resolve to
  // the same canvas.
  final overlay = Overlay.of(context, rootOverlay: true);
  final generation = ++_generation;
  // A table event can be announced mid-frame (a listener reads its flag
  // and fires the moment it finds it), so the insert waits one frame —
  // same reason the sibling dialog paths schedule a post-frame callback.
  WidgetsBinding.instance.addPostFrameCallback((_) {
    // Two calls inside one frame speak once: only the newest is allowed
    // to land, and a newer one has already removed the dismissed pair.
    if (generation != _generation) return;
    _removeShowing();
    final entry = OverlayEntry(
      builder: (overlayContext) => Positioned(
        top: _topInset,
        right: _rightInset,
        child: _TableAlert(text: text, icon: icon, onClose: _removeShowing),
      ),
    );
    _showing = entry;
    overlay.insert(entry);
  });
}

/// The entry showing right now, whatever surface called it: table
/// messages are spoken one at a time, and one shared holder is what makes
/// "a new call replaces the showing one" true across callers.
OverlayEntry? _showing;

/// Bumped by every call so a deferred insert (post-frame) from an older
/// call cannot land after a newer one has already taken the corner.
int _generation = 0;

void _removeShowing() {
  final entry = _showing;
  _showing = null;
  if (entry != null && entry.mounted) entry.remove();
}

/// 56-high app bar, 8 below it: reading distance from the corner without
/// covering the board's own first row.
const double _topInset = kToolbarHeight + 8;

/// The right-edge inset: close to the corner, clear of the page edge.
const double _rightInset = 12;

/// How long a table line lingers before clearing itself.
const Duration _lifeOfAlert = Duration(seconds: 5);

/// One table line: slide-in from the right with a fade over 220ms
/// (skipped under reduced motion), tap to leave early, and a five-second
/// timer that clears the corner on its own.
class _TableAlert extends StatefulWidget {
  const _TableAlert({
    required this.text,
    required this.icon,
    required this.onClose,
  });

  final String text;
  final IconData icon;
  final VoidCallback onClose;

  @override
  State<_TableAlert> createState() => _TableAlertState();
}

class _TableAlertState extends State<_TableAlert> {
  Timer? _life;

  @override
  void initState() {
    super.initState();
    _life = Timer(_lifeOfAlert, widget.onClose);
  }

  @override
  void dispose() {
    _life?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final reduced = MediaQuery.of(context).disableAnimations;
    return TweenAnimationBuilder<double>(
      tween: Tween(begin: reduced ? 1.0 : 0.0, end: 1.0),
      duration: reduced ? Duration.zero : const Duration(milliseconds: 220),
      curve: Curves.easeOut,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: widget.onClose,
        // A line that only the speech engine notices is a line the
        // table missed: liveRegion has it read out as it appears.
        child: Semantics(
          liveRegion: true,
          label: widget.text,
          excludeSemantics: true,
          child: Container(
            key: const Key('table-alert'),
            constraints: const BoxConstraints(minHeight: 44, maxWidth: 460),
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
            decoration: BoxDecoration(
              // The TurnCountdown plate's materials: translucent black
              // over the felt, gold rim at the same calm alpha.
              color: Colors.black.withValues(alpha: 0.31),
              borderRadius: BorderRadius.circular(14),
              border: Border.all(color: AppColors.gold.withAlpha(160)),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(widget.icon, size: 18, color: AppColors.gold),
                const SizedBox(width: 8),
                Flexible(
                  child: Text(
                    widget.text,
                    maxLines: 3,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontSize: 13.5,
                      fontWeight: FontWeight.w600,
                      color: AppColors.ivory,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
      builder: (context, t, pill) => Opacity(
        opacity: t,
        child: Transform.translate(
          offset: Offset((1 - t) * 28, 0),
          child: pill,
        ),
      ),
    );
  }
}
