/// Heuristic Ludo bots.
///
/// easy   : uniformly random legal move
/// medium : capture > bring token home > leave base > random
/// hard   : full positional evaluation
library;

import 'dart:math';

import 'ludo_board.dart';
import 'ludo_models.dart';
import 'ludo_rules.dart';

LudoMove? chooseLudoMove(LudoState s, AIDifficulty difficulty, [Random? rng]) {
  final moves = legalMoves(s);
  if (moves.isEmpty) return null;
  final rand = rng ?? Random();
  switch (difficulty) {
    case AIDifficulty.easy:
      return moves[rand.nextInt(moves.length)];
    case AIDifficulty.medium:
      return _medium(s, moves, rand);
    case AIDifficulty.hard:
      return _argmaxScore(s, moves);
  }
}

LudoMove _medium(LudoState s, List<LudoMove> moves, Random rand) {
  // 1. captures, 2. reaching home, 3. leaving base, 4. random.
  for (final m in moves) {
    if (moveCaptures(s, m)) return m;
  }
  if (moves.any((m) => m.to == homePos)) {
    return moves.firstWhere((m) => m.to == homePos);
  }
  if (moves.any((m) => m.from == -1)) {
    return moves.firstWhere((m) => m.from == -1);
  }
  return moves[rand.nextInt(moves.length)];
}

LudoMove _argmaxScore(LudoState s, List<LudoMove> moves) {
  var best = moves.first;
  var bestScore = -double.infinity;
  for (final m in moves) {
    final score = _scoreMove(s, m);
    if (score > bestScore) {
      bestScore = score;
      best = m;
    }
  }
  return best;
}

double _scoreMove(LudoState s, LudoMove m) {
  final color = s.currentPlayer.color;
  final tokens = s.tokensOf(s.currentPlayerIndex);
  var score = (m.to - m.from).toDouble() * 0.5; // raw progress

  if (m.to == homePos) score += 50; // finishes a token
  if (m.to >= 51) score += 15; // safety of the home column

  if (m.from == -1) {
    score += 25; // gets a token into play
    if (tokens.where((t) => !t.inBase && !t.isHome).length <= 1) score += 15;
  }

  if (m.to <= 50) {
    final abs = LudoBoard.absCell(color, m.to);

    if (LudoBoard.safeCells.contains(abs)) score += 12; // safe rest stop

    // Captures are the most valuable play.
    for (final o in s.tokens) {
      if (o.color == color) continue;
      if (o.pos >= 0 &&
          o.pos <= 50 &&
          LudoBoard.absCell(o.color, o.pos) == abs) {
        score += 60 + o.pos * 0.4; // sending a developed token back hurts more
      }
    }

    // Forming / joining an own block.
    final ownHere = s.tokens
        .where((t) =>
            t.color == color &&
            t.pos >= 0 &&
            t.pos <= 50 &&
            LudoBoard.absCell(color, t.pos) == abs)
        .length;
    if (ownHere >= 1) score += 8;

    // Danger: is an enemy token 1..6 behind the landing cell?
    if (!LudoBoard.safeCells.contains(abs)) {
      for (final o in s.tokens) {
        if (o.color == color) continue;
        if (o.pos < 0 || o.pos > 50) continue;
        final oAbs = LudoBoard.absCell(o.color, o.pos);
        final gap = (abs - oAbs) % LudoBoard.trackLength;
        if (gap >= 1 && gap <= 6) score -= 20;
      }
    }
  }

  // Escaping danger at the origin cell is worth something.
  if (m.from >= 0 && m.from <= 50) {
    final fromAbs = LudoBoard.absCell(color, m.from);
    if (!LudoBoard.safeCells.contains(fromAbs)) {
      for (final o in s.tokens) {
        if (o.color == color) continue;
        if (o.pos < 0 || o.pos > 50) continue;
        final gap = (fromAbs - LudoBoard.absCell(o.color, o.pos)) %
            LudoBoard.trackLength;
        if (gap >= 1 && gap <= 6) {
          score += 18;
          break;
        }
      }
    }
  }

  return score;
}
