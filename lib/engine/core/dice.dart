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
