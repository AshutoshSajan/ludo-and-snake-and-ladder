import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

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
  OverlayState? onOverlay,
}) {
  // The root navigator's overlay: game views live inside lobby screens
  // and route stacks, and the top-right corner must always resolve to
  // the same canvas. An app-level listener holding the *navigator's*
  // context cannot use the lookup — the overlay is below that context,
  // not above it — so it passes the navigator's overlay directly.
  final overlay = onOverlay ?? Overlay.of(context, rootOverlay: true);
  // A live knock outranks a five-second line: paragraph below in
  // [showInviteKnock]. The line is dropped rather than queued — a table
  // line's moment is the moment it happens; held longer it would lie.
  //
  // Only a *live* knock outranks it. A card whose overlay was torn down
  // (the screen changed, or a widget test moved to its next app) leaves
  // the kind behind; checking mount state lets the next line take the
  // corner instead of being dropped forever.
  if (_showingKind == _CardKind.knock && _showing?.mounted == true) return;
  final generation = ++_generation;
  // A table event can be announced mid-frame (a listener reads its flag
  // and fires the moment it finds it), so the insert waits one frame —
  // same reason the sibling dialog paths schedule a post-frame callback.
  WidgetsBinding.instance.addPostFrameCallback((_) {
    // Two calls inside one frame speak once: only the newest is allowed
    // to land, and a newer one has already removed the dismissed pair.
    if (generation != _generation) return;
    // Same yield, for the knock that climbed onto the corner while this
    // insert was quietly waiting for its frame.
    if (_showingKind == _CardKind.knock && _showing?.mounted == true) return;
    _removeShowing();
    final entry = OverlayEntry(
      builder: (overlayContext) => Positioned(
        top: _topInset,
        right: _rightInset,
        child: _TableAlert(text: text, icon: icon, onClose: _removeShowing),
      ),
    );
    _showing = entry;
    _showingKind = _CardKind.line;
    overlay.insert(entry);
  });
  // A post-frame callback alone does not request a frame. Without this, a
  // line raised by a poll or a listener while nothing else is repainting
  // would wait for the next unrelated frame — or never land at all.
  WidgetsBinding.instance.ensureVisualUpdate();
}

/// The entry showing right now, whatever surface called it: table
/// messages are spoken one at a time, and one shared holder is what makes
/// "a new call replaces the showing one" true across callers.
OverlayEntry? _showing;

/// What the shared holder is carrying — a passing line or a live knock —
/// so a five-second line knows to yield instead of cleaving a knock in
/// two.
enum _CardKind { line, knock }

_CardKind? _showingKind;

/// The live knock's answer channel, so a card displaced by a newer one
/// can tell its asker "they never pressed Join" — the asker must never
/// wait on a widget that is no longer on screen.
Completer<bool?>? _showingAnswer;

/// Bumped by every call so a deferred insert (post-frame) from an older
/// call cannot land after a newer one has already taken the corner.
int _generation = 0;

void _removeShowing() {
  final entry = _showing;
  final kind = _showingKind;
  final answer = _showingAnswer;
  _showing = null;
  _showingKind = null;
  _showingAnswer = null;
  // A knock leaving the corner anywhere but its own buttons chose so —
  // a newer knock took the slot — and its asker still waits on the
  // future: resolve it as "not joined" instead of hanging forever.
  if (kind == _CardKind.knock && answer != null && !answer.isCompleted) {
    answer.complete(false);
  }
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

/// The invite knock: the same top-right gold-rimmed card, but with
/// answers.
///
/// Where a table line speaks and fades, the knock *asks* — "{name} has
/// sent you a play invite — join?" — so it carries its two buttons ("for
/// example Join game / Not now") and it does not fade on a timer: an
/// invitation that vanished by itself before anyone read it would lose
/// invites wholesale. The predecessor was a bare [AlertDialog], styled
/// by the material default — the playtest plainly asked otherwise:
/// "alert popups are still white plane popups … make their design good,
/// show them on top right of the screen".
///
/// Slot rules with [showTableAlert], one shared corner:
///
/// - a knock **replaces** whatever the corner shows;
/// - while a knock is up, five-second table lines **yield** and do not
///   speak — an unanswered friend outranks a passing line, and a line
///   older than its moment would lie anyway. The knock leaves by its own
///   two buttons only;
/// - two knocks in a row: the newest one wins, and the displaced asker
///   hears `false` — never a hang.
///
/// Returns the answer's future: `true` for the confirm button, `false`
/// for everything else it leaves the screen by.
///
/// Takes the [OverlayState] itself, not a BuildContext: the knock's
/// caller may be an app-level listener holding a navigator key, and
/// `Overlay.of` runs *up* a context — from a navigator's own context
/// there is no overlay above to find. The navigator's overlay is the
/// same canvas the whole family speaks on.
Future<bool?> showInviteKnock(
  OverlayState overlay, {
  required String title,
  required String body,
  IconData icon = Icons.sports_esports,
  String confirmLabel = 'Join game',
  String dismissLabel = 'Not now',
}) {
  final answer = Completer<bool?>();

  void decide(bool joined) {
    if (!answer.isCompleted) answer.complete(joined);
    _removeShowing();
  }

  void land() {
    // The app can unmount while a knock waits its frame (a player
    // closing the screen mid-arrival); a defunct overlay has nothing
    // left to insert into, and the asker hears "not joined".
    if (!overlay.mounted) {
      if (!answer.isCompleted) answer.complete(false);
      return;
    }
    // One corner, one question. Whatever was showing — a line, or a
    // knock nobody has answered yet — steps down for the newer ask.
    _removeShowing();
    final entry = OverlayEntry(
      builder: (overlayContext) => Positioned(
        top: _topInset,
        right: _rightInset,
        child: _KnockCard(
          key: const Key('invite-knock'),
          title: title,
          body: body,
          icon: icon,
          confirmLabel: confirmLabel,
          dismissLabel: dismissLabel,
          onConfirm: () => decide(true),
          onDismiss: () => decide(false),
        ),
      ),
    );
    _showing = entry;
    _showingKind = _CardKind.knock;
    _showingAnswer = answer;
    overlay.insert(entry);
  }

  // The card lands the moment the ask happens. The one exception is a
  // caller inside the build phase itself — inserting while the tree is
  // building would assert — and that one waits a frame instead.
  if (SchedulerBinding.instance.schedulerPhase ==
      SchedulerPhase.persistentCallbacks) {
    WidgetsBinding.instance.addPostFrameCallback((_) => land());
  } else {
    land();
  }
  return answer.future;
}

/// The knock card's materials and actions; its container owns the
/// `invite-knock` key so tests — and only tests — find it.
class _KnockCard extends StatefulWidget {
  const _KnockCard({
    super.key,
    required this.title,
    required this.body,
    required this.icon,
    required this.confirmLabel,
    required this.dismissLabel,
    required this.onConfirm,
    required this.onDismiss,
  });

  final String title;
  final String body;
  final IconData icon;
  final String confirmLabel;
  final String dismissLabel;
  final VoidCallback onConfirm;
  final VoidCallback onDismiss;

  @override
  State<_KnockCard> createState() => _KnockCardState();
}

class _KnockCardState extends State<_KnockCard> {
  @override
  Widget build(BuildContext context) {
    final reduced = MediaQuery.of(context).disableAnimations;
    // The theme already paints FilledButton in the family gold; here it
    // only needs the 44px minimum the answers promise as touch targets.
    final confirm = FilledButton.styleFrom(minimumSize: const Size(112, 44));
    final dismiss = TextButton.styleFrom(minimumSize: const Size(64, 44));
    return TweenAnimationBuilder<double>(
      tween: Tween(begin: reduced ? 1.0 : 0.0, end: 1.0),
      duration: reduced ? Duration.zero : const Duration(milliseconds: 220),
      curve: Curves.easeOut,
      child: Container(
        key: const Key('invite-knock-card'),
        constraints: const BoxConstraints(minWidth: 320, maxWidth: 460),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        decoration: BoxDecoration(
          color: Colors.black.withValues(alpha: 0.31),
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: AppColors.gold.withAlpha(160)),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // One live announcement for the words; the answers stay
            // outside it so screen readers (and semantic-click automation)
            // keep Join game and Not now as separate buttons.
            Semantics(
              liveRegion: true,
              label: '${widget.title}. ${widget.body}',
              excludeSemantics: true,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(widget.icon, size: 20, color: AppColors.gold),
                      const SizedBox(width: 8),
                      Flexible(
                        child: Text(
                          widget.title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            fontSize: 14.5,
                            fontWeight: FontWeight.w700,
                            color: AppColors.ivory,
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 6),
                  Text(
                    widget.body,
                    maxLines: 3,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontSize: 13.5,
                      fontWeight: FontWeight.w600,
                      color: AppColors.ivory,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 12),
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                // The invite answer is a real decision: both targets
                // stay at the 44px minimum the family asks for.
                FilledButton(
                  key: const Key('invite-knock-join'),
                  style: confirm,
                  onPressed: widget.onConfirm,
                  child: Text(widget.confirmLabel),
                ),
                const SizedBox(width: 8),
                TextButton(
                  key: const Key('invite-knock-dismiss'),
                  style: dismiss,
                  onPressed: widget.onDismiss,
                  child: Text(widget.dismissLabel),
                ),
              ],
            ),
          ],
        ),
      ),
      builder: (context, t, card) => Opacity(
        opacity: t,
        child: Transform.translate(
          offset: Offset((1 - t) * 28, 0),
          child: card,
        ),
      ),
    );
  }
}
