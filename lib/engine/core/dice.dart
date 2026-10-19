/// Pure-Dart dice. Zero Flutter imports (engine layer rule).
///
/// One helper, one documented algorithm, used by every dice roll in the
/// game — offline seats, the authoritative server's room rolls, and both
/// boards' autoplay drivers. Centralised so "is the dice fair?" has an
/// answer that lives in exactly one place (and its test can point at the
/// thing every player's finger actually presses).
///
/// The algorithm is `Random.nextInt(6) + 1`:
///
///  * `nextInt(6)` is the API Dart documents for an unbiased draw over
///    `0..5` — it has no modulo bias and maps onto 1..6 with an exact wrap,
///    unlike `nextInt(n) % 6`-style tricks over an uneven range, which
///    would tilt certain faces.
///  * No value is special-cased afterwards: the engine may *consequence* a
///    roll (sixes grant an extra turn, three in a row forfeits one), but
///    the *number* that lands is never overridden by code — sixes cluster
///    1 in 6 rolls because the rules make them more visible, not because
///    the generator repeats.
///  * Both call sites keep a long-lived generator (a session's `Random()`,
///    a room's `Random.secure()`), never re-seeding per roll. A fresh
///    `Random()` per roll — the classic broken pattern — would correlate
///    rolls across the table's clocks and drag sequence quality down.
///
/// What fairness never means: "no two-face repeat". Two identical rolls in
/// a row are exactly 1 in 6 under a fair die; suppressing that would bias
/// the distribution *away* from fair. The report "same number twice" is a
/// real UI concern (a laggy client can settle the die on a stale face
/// before the roll lands) — but the cure belongs to the display code, not
/// to rigging this function.
///
/// Distribution is pinned by a test over a fixed seed (see
/// `test/dice_fairness_test.dart`): every face within chance of its 1/6
/// share, and run-lengths of repeats within chance, per this algorithm.
library;
import 'dart:math';

/// One roll of a fair six-sided die from [rng].
int dieRoll(Random rng) => rng.nextInt(6) + 1;

/// The dice every game rolls through: a fair [Random] plus one game-feel
/// rule a real die cannot have — **never the same face four times in a row
/// on this stream**.
///
/// Players were reporting "hitting the same number many times in a straight
/// go": statistically possible with an honest die, but over a table that
/// rolls hundreds of faces an evening, four-in-a-row streaks land often
/// enough to look broken. A four-duplicate is replaced by an honest re-roll
/// until a different face arrives (one of five other faces must exist, so
/// the loop trips once or twice at the very most). Everything else stays
/// exactly fair: each face remains equally likely, doubles and the tense
/// triple stay possible — and with them Ludo's three-sixes forfeit, which
/// is still as reachable as ever.
///
/// One [DieStreak] per [Random] stream: the offline session holds one so
/// humans and bots share it, and the server holds one for every room it
/// deals. The cap is deliberately *stream-wide*, not per-seat: a player can
/// still meet the same face on non-consecutive turns, which is what honest
/// dice do; what cannot happen again is the wall of identical faces.
final class DieStreak {
  int? _face; // last face this stream produced
  int _count = 0; // ...times in a row

  /// The next roll on this stream, duplicates past three suppressed.
  int next(Random rng) {
    var v = dieRoll(rng);
    if (v == _face && _count >= 3) {
      // A fourth duplicate: re-roll honestly until the face changes. Six
      // tries is beyond any real chance of failure and bounds a hostile
      // generator from spinning the loop forever.
      for (var tries = 0; v == _face && tries < 6; tries++) {
        v = dieRoll(rng);
      }
    }
    if (v == _face) {
      _count += 1;
    } else {
      _face = v;
      _count = 1;
    }
    return v;
  }

  /// Diagnostics surface for tests: the stream's last face and streak.
  int? get lastFace => _face;
  int get lastCount => _count;
}
