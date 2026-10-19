import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:game_club/engine/core/dice.dart';

/// Statistical evidence for the dice: the algorithm every roll in the game
/// goes through ([dieRoll] = `Random.nextInt(6) + 1` on a long-lived
/// generator) is uniform and free of structured repeats.
///
/// "Same number twice" being *possible* is built in — a fair six-sided die
/// repeats its previous face exactly 1 in 6 of the time. What the test pins
/// is that the *pattern* of results matches chance: each face in fair share,
/// and repeat runs of the length a fair die produces. The seed is fixed, so
/// these assertions are exact observations of one known sequence, not
/// tolerance gambling that could flake.
///
/// Variance numbers to judge 120,000 draws against: with n = 20000 expected
/// per face, a fair binomial draw lands within ±~2.2% (3σ) of target, and
/// the longest run of identical faces over 120k rolls reliably reaches
/// 8-12. The chosen window sits well outside both ends of chance.
void main() {
  test('each face lands within a fair share over a long, seeded session',
      () {
    final rng = Random(2026);
    const draws = 120000;
    final counts = List.filled(7, 0); // index 1..6
    for (var i = 0; i < draws; i++) {
      counts[dieRoll(rng)]++;
    }
    for (var face = 1; face <= 6; face++) {
      expect(
        counts[face],
        inInclusiveRange(19400, 20600), // 20000 ± 3%
        reason:
            'face $face drew ${counts[face]} of 120000 — outside chance',
      );
    }
  });

  test('repeat runs match a fair die (visible clusters, no hidden streaks)',
      () {
    final rng = Random(2026);
    const draws = 120000;
    var longestRun = 1;
    var run = 1;
    var repeats = 0; // consecutive same-face pairs
    var previous = 0;
    for (var i = 0; i < draws; i++) {
      final v = dieRoll(rng);
      if (v == previous) {
        repeats++;
        run++;
        if (run > longestRun) longestRun = run;
      } else {
        run = 1;
      }
      previous = v;
    }
    // A fair die repeats the last face 1/6 of the time: ~20000 ± 3σ.
    expect(
      repeats,
      inInclusiveRange(18400, 21600),
      reason:
          'the die repeated its previous face $repeats of 120000 — a fair '
          'generator lands near 1 in 6',
    );
    // Clusters of the same face are normal (sixes feel special because the
    // rules reward them), but an *infinite-looking* streak is not.
    expect(
      longestRun,
      inInclusiveRange(5, 20), // fair sequences peak near 8-12 by 120k draws
      reason:
          'longest run of one face was $longestRun — outside what a fair '
          'die produces',
    );
  });

  test('every roll is its generator draw mapped onto 1..6, never nudged', () {
    // The script feeds the *generator's* outputs (what nextInt(6) returns).
    final script = [2, 5, 0, 1, 4, 3, 0, 0, 5];
    final expected = script.map((v) => v + 1).toList(); // faces 1..6
    final rng = _ScriptedRandom(script);
    final rolled = [for (var i = 0; i < script.length; i++) dieRoll(rng)];
    expect(rolled, expected,
        reason: 'dieRoll applies its generator result verbatim — no '
            'post-hoc scaling, rerolls or face steering of values');
  });
}

/// A generator with a fixed script, so "does [dieRoll] interfere with its
/// source?" is answered by observation rather than trust.
class _ScriptedRandom implements Random {
  _ScriptedRandom(this._script);
  final List<int> _script;
  int _at = 0;

  @override
  bool nextBool() => nextInt(2) == 0;

  @override
  double nextDouble() => nextInt(1 << 32) / (1 << 32);

  @override
  int nextInt(int max) {
    final v = _script[_at % _script.length];
    _at++;
    return v.clamp(0, max - 1);
  }
}
