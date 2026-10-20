import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../providers/app_providers.dart';
import '../../ui/theme.dart';
import 'pulse.dart';

/// The screen-wide dim behind the walkthrough: everything dark except a
/// rounded hole punched even-odd over the current target (or nothing — a
/// full veil — when the step points at no widget).
///
/// Public so the widget tests can read what the painter is showing.
class TutorialSpotlightPainter extends CustomPainter {
  const TutorialSpotlightPainter({required this.hole});

  /// The lit rect, or null for a full-screen veil with no hole.
  final Rect? hole;

  @override
  void paint(Canvas canvas, Size size) {
    final dim = Paint()..color = _dim;
    if (hole == null) {
      canvas.drawRect(Offset.zero & size, dim);
      return;
    }
    canvas.drawPath(
      Path()
        ..fillType = PathFillType.evenOdd
        ..addRect(Offset.zero & size)
        ..addRRect(
          RRect.fromRectAndRadius(hole!, Radius.circular(_spotRadius)),
        ),
      dim,
    );
  }

  @override
  bool shouldRepaint(TutorialSpotlightPainter old) => old.hole != hole;
}

/// The gold rim breathed by [Pulse] over the spotlight hole. Sized exactly
/// to the hole rect, so [Pulse]'s centred scale keeps the rim aligned while
/// it gently breathes "this is the button".
class _SpotlightRimPainter extends CustomPainter {
  const _SpotlightRimPainter();

  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawRRect(
      RRect.fromRectAndRadius(Offset.zero & size, Radius.circular(_spotRadius)),
      Paint()
        ..color = AppColors.gold
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2.5,
    );
  }

  @override
  bool shouldRepaint(_SpotlightRimPainter old) => false;
}

/// One stop of the tutorial tour: [title], a sentence or two of [body], and
/// an optional [key] pointing at the widget being highlighted.
///
/// [key] must be the exact `ValueKey('tour-…')` attached to a live widget on
/// the underlying screen (see [TutorialWalkthrough.homeSteps] and the keys
/// in `home_screen.dart`). A step with a null key — the "you're set"
/// finisher — points at nothing: the whole screen stays under the dim and
/// the card is the guest in the middle.
class TutorialStep {
  const TutorialStep({this.key, required this.title, required this.body});

  final Key? key;
  final String title;
  final String body;
}

/// The guided walkthrough for the game club — the thing the playtest asked
/// for: "when user opens the game he should be asked for the tutorial and if
/// he accepts it then this tutorial with button highlights etc should start
/// and he can navigate one by one."
///
/// A full-screen, non-opaque route on the root navigator dims everything at
/// ~66% black EXCEPT the spotlight hole over the current step's target. A
/// gold rim over the hole breathes gently ([Pulse] — which also respects
/// the battery-saver "Board animations" preference), and a coach card sits
/// above or below the hole — never overlapping it — with Skip / Back / Next;
/// the last step's button reads "Done", which persists `gc.tutorialDone`.
///
/// How targets are found: by [Key] inside the live widget tree below the
/// root overlay, not via a GlobalKey registry. A registry would force every
/// screen to hold GlobalKeys for the tour's benefit; walking the tree keeps
/// the screens the single source of truth and re-targets automatically at
/// each step. Measurement runs post-frame per step and on window resize, so
/// rotation and resize re-spotlight.
class TutorialWalkthrough extends ConsumerStatefulWidget {
  const TutorialWalkthrough._({required this.steps});

  final List<TutorialStep> steps;

  /// The home-screen tour, ordered as the screen reads. [ValueKey]s match
  /// the `tour-…` keys attached to the home screen's entry points; the last
  /// step carries no key on purpose (see [TutorialStep.key]).
  static const List<TutorialStep> homeSteps = [
    TutorialStep(
      key: ValueKey('tour-ludo'),
      title: 'This is Ludo',
      body:
          'Tap to set up a table — name the seats, add bots if you are '
          'short-handed, then start. Everything is saved between screens.',
    ),
    TutorialStep(
      key: ValueKey('tour-snakes'),
      title: 'Snakes & Ladders',
      body:
          'The classic board for 2 to 10 players. Set up seats the same '
          'way here, and let the dice do the rest.',
    ),
    TutorialStep(
      key: ValueKey('tour-online'),
      title: 'Play online',
      body:
          'Connect to the club server, create a room, and share its '
          'four-letter code — or join a friend by code.',
    ),
    TutorialStep(
      key: ValueKey('tour-friends'),
      title: 'Your friends',
      body:
          'Add friends by their code, chat with them, and invite them '
          'straight to a table.',
    ),
    TutorialStep(
      key: ValueKey('tour-leaderboard'),
      title: 'Leaderboards',
      body:
          'Career boards kept by the club server — a top podium per game '
          'across the tables you have played.',
    ),
    TutorialStep(
      key: ValueKey('tour-settings'),
      title: 'Settings',
      body:
          'Sound, haptics and battery-saving toggles live here — and this '
          'tour can replay from Settings any time.',
    ),
    // The finisher: no key, no hole. The screen dims fully and the card
    // floats in the middle — a deliberate last look at the whole club.
    TutorialStep(
      title: "You're set",
      body:
          'That is the whole club on one screen. Pick a table and have a '
          'good game.',
    ),
  ];

  /// Pushes the tour as a full-screen modal on the root navigator, so it
  /// covers pushed routes and dialogs alike and the screen under it dims.
  static void show(BuildContext context, {required List<TutorialStep> steps}) {
    Navigator.of(context, rootNavigator: true).push(
      PageRouteBuilder(
        opaque: false,
        transitionDuration: const Duration(milliseconds: 180),
        reverseTransitionDuration: const Duration(milliseconds: 150),
        pageBuilder: (_, _, _) => TutorialWalkthrough._(steps: steps),
        transitionsBuilder: (_, animation, _, child) =>
            FadeTransition(opacity: animation, child: child),
      ),
    );
  }

  @override
  ConsumerState<TutorialWalkthrough> createState() =>
      _TutorialWalkthroughState();
}

const _dim = Color(0xAA000000); // ~66% black, the tour's veil
const _spotRadius = 14.0; // the hole's corners
const _holeInset = 6.0; // hole margin around the target widget
const _cardGap = 12.0; // between the hole and the card
const _cardMargin = 16.0; // breathing room from the screen edges
const _cardMinWidth = 260.0;
const _cardMaxWidth = 320.0;

/// Expected card height for the fits-above test. The shipped copy stays
/// under it; underestimate costs a tight top edge only, never a hole cover.
const _expectedCardHeight = 170.0;

class _TutorialWalkthroughState extends ConsumerState<TutorialWalkthrough> {
  int _index = 0;

  /// The spotlight rect, measured post-frame and clamped inside the screen,
  /// then grown by [_holeInset]. Null means one of two things, told apart
  /// by [_measured]: "not measured yet" (first frame — dim only, no card),
  /// or the finisher's point-at-nothing (full dim, card centred).
  Rect? _spot;
  bool _measured = false;

  @override
  void initState() {
    super.initState();
    _scheduleMeasure();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // MediaQuery changed (rotation, desktop resize): re-target for the new
    // window. Harmlessly re-runs on the first build alongside initState.
    _scheduleMeasure();
  }

  void _scheduleMeasure() {
    WidgetsBinding.instance.addPostFrameCallback((_) => _measure());
  }

  void _measure() {
    if (!mounted) return;
    final size = MediaQuery.sizeOf(context);
    final key = widget.steps[_index].key;
    final raw = key == null ? null : _targetRect(key);
    setState(() {
      _measured = true;
      _spot = raw == null ? null : _clamp(raw, size).inflate(_holeInset);
    });
  }

  /// The target's screen rect, found by key walking the live tree below the
  /// root overlay — the underlying screens live there, as does this route
  /// (which carries no tour keys). Unmeasurable today → null.
  Rect? _targetRect(Key key) {
    Element? found;
    void visit(Element element) {
      if (found != null) return;
      if (element.widget.key == key) {
        found = element;
        return;
      }
      element.visitChildElements(visit);
    }

    try {
      Overlay.of(context, rootOverlay: true).context.visitChildElements(visit);
    } on StateError {
      // The overlay was defunct mid-teardown; the next measure fixes the
      // picture. Report "not found" for this pass.
      return null;
    }
    if (found == null) return null;
    final render = found!.findRenderObject();
    if (render is! RenderBox || !render.attached || !render.hasSize) {
      return null;
    }
    return render.localToGlobal(Offset.zero) & render.size;
  }

  /// Keeps a rect on screen with margin to spare; a fully off-screen target
  /// degenerates to a small hole at the centre band, so the card and its
  /// buttons stay reachable instead of following the target off-screen.
  Rect _clamp(Rect rect, Size size) {
    final bounds = Rect.fromLTWH(
      _cardMargin,
      _cardMargin,
      size.width - 2 * _cardMargin,
      size.height - 2 * _cardMargin,
    );
    final fit = rect.intersect(bounds);
    if (fit.width <= 0 || fit.height <= 0) {
      return Rect.fromCenter(center: bounds.center, width: 60, height: 60);
    }
    return fit;
  }

  void _back() {
    if (_index == 0) return;
    setState(() => _index--);
    _scheduleMeasure();
  }

  void _advance() {
    if (_index == widget.steps.length - 1) {
      ref.read(storageProvider).saveTutorialDone(true);
      Navigator.of(context).pop();
      return;
    }
    setState(() => _index++);
    _scheduleMeasure();
  }

  @override
  Widget build(BuildContext context) {
    final size = MediaQuery.sizeOf(context);
    final step = widget.steps[_index];
    final hole = _measured ? _spot : null;
    final card = _TutorialCard(
      step: step,
      stepNumber: _index + 1,
      total: widget.steps.length,
      onSkip: () => Navigator.of(context).pop(),
      onBack: _index == 0 ? null : _back,
      onNext: _advance,
    );

    return Material(
      type: MaterialType.transparency,
      child: Stack(
        children: [
          Positioned.fill(
            child: CustomPaint(painter: TutorialSpotlightPainter(hole: hole)),
          ),
          // The rim breathes only where there is a spotlight; the finisher
          // has none, by design — the dim *is* the last step's look.
          if (hole != null)
            Positioned(
              left: hole.left,
              top: hole.top,
              width: hole.width,
              height: hole.height,
              child: Pulse(
                active: true,
                child: IgnorePointer(
                  child: CustomPaint(painter: const _SpotlightRimPainter()),
                ),
              ),
            ),
          // The card waits for its first measure, then sits above or below
          // the hole — never over it — or centred for the keyless finisher
          // (at the same bounded width, or the Spacer row stretches it to
          // the window's full width).
          if (_measured)
            _spot == null
                ? Align(
                    child: SizedBox(width: _cardWidthFor(size), child: card),
                  )
                : _positionCard(card, size),
        ],
      ),
    );
  }

  Widget _positionCard(Widget card, Size size) {
    final hole = _spot!;
    final cardWidth = _cardWidthFor(size);
    final left = (hole.center.dx - cardWidth / 2).clamp(
      _cardMargin,
      size.width - _cardMargin - cardWidth,
    );

    // Room above the hole vs below it. Above wins only when it fits a card;
    // otherwise the card goes under, hugging the bottom if need be.
    final above = hole.top - _cardGap - _cardMargin;
    final below = size.height - hole.bottom - _cardGap - _cardMargin;
    if (above >= _expectedCardHeight && above >= below) {
      return Positioned(
        left: left,
        bottom: size.height - hole.top + _cardGap,
        width: cardWidth,
        child: card,
      );
    }
    return Positioned(
      left: left,
      top: hole.bottom + _cardGap,
      width: cardWidth,
      child: card,
    );
  }

  double _cardWidthFor(Size size) =>
      (size.width - 2 * _cardMargin).clamp(_cardMinWidth, _cardMaxWidth);
}

/// The coach card: house styling (felt card, gold title — same family as the
/// win podium), one step of copy, a step counter, and Skip / Back / Next|Done.
class _TutorialCard extends StatelessWidget {
  const _TutorialCard({
    required this.step,
    required this.stepNumber,
    required this.total,
    required this.onSkip,
    required this.onBack,
    required this.onNext,
  });

  final TutorialStep step;
  final int stepNumber;
  final int total;

  final VoidCallback onSkip;
  final VoidCallback? onBack;
  final VoidCallback onNext;

  /// The app theme leaves TextButton at M3's 40px height; the conventions
  /// floor every touch target at 44 logoical px, so the two text buttons
  /// get their own floor while keeping the house's default look otherwise.
  static const _touchFloor = ButtonStyle(
    minimumSize: WidgetStatePropertyAll(Size(44, 44)),
  );

  @override
  Widget build(BuildContext context) {
    final last = stepNumber == total;
    return Container(
      key: const ValueKey('tutorial-card'),
      padding: const EdgeInsets.fromLTRB(20, 16, 20, 10),
      decoration: BoxDecoration(
        color: AppColors.feltLight,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: AppColors.gold.withValues(alpha: 0.45)),
        boxShadow: const [
          BoxShadow(
            color: Colors.black54,
            blurRadius: 24,
            offset: Offset(0, 6),
          ),
        ],
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            step.title,
            style: const TextStyle(
              fontSize: 16,
              fontWeight: FontWeight.w800,
              color: AppColors.gold,
            ),
          ),
          const SizedBox(height: 6),
          Text(
            step.body,
            style: const TextStyle(
              fontSize: 13.5,
              height: 1.35,
              color: Colors.white70,
            ),
          ),
          const SizedBox(height: 4),
          // Step counter — "1 of 7" per the spec's either-or (dots needed 77px
          // the row could not spare: at the 320 card the buttons overflowed
          // and taps missed entirely).
          Text(
            '$stepNumber of $total',
            style: const TextStyle(fontSize: 12, color: Colors.white38),
          ),
          Row(
            children: [
              const Spacer(),
              TextButton(
                style: _touchFloor,
                onPressed: onSkip,
                child: const Text('Skip'),
              ),
              TextButton(
                style: _touchFloor,
                onPressed: onBack,
                child: const Text('Back'),
              ),
              FilledButton(
                onPressed: onNext,
                child: Text(last ? 'Done' : 'Next'),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
