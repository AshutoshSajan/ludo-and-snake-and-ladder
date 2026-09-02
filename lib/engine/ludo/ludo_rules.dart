/// Pure rule implementation for Ludo. All functions are deterministic
/// given the supplied dice value, which makes them trivially testable and
/// reusable by a future authoritative server.
library;

import 'ludo_board.dart';
import 'ludo_models.dart';

/// Standard path length: 51 main-track steps + 5 home column + home = 57.
const int homePos = 56;

/// Create the initial state for 2-4 players (in turn order).
LudoState createLudoState(List<LudoPlayer> players) {
  assert(players.length >= 2 && players.length <= 4);
  final tokens = <LudoToken>[];
  for (final p in players) {
    for (var i = 0; i < 4; i++) {
      tokens.add(LudoToken(color: p.color, index: i));
    }
  }
  return LudoState(players: players, tokens: tokens, currentPlayerIndex: 0);
}

/// Roll the dice with an explicit value (tests pass fixed values; the
/// session controller passes a random 1..6).
void rollDice(LudoState s, int value) {
  assert(value >= 1 && value <= 6, 'dice value must be 1..6');
  if (s.phase != LudoPhase.awaitingRoll) return;
  s.lastRoll = value;
  s.eventTokenGid = null;

  if (value == 6) {
    s.consecutiveSixes += 1;
    if (s.consecutiveSixes >= 3) {
      // Three sixes in a row: turn is forfeited.
      s.lastEvent = 'tripleSix';
      _endTurn(s, extra: false);
      return;
    }
    s.lastEvent = 'six';
  } else {
    s.consecutiveSixes = 0;
    s.lastEvent = 'roll';
  }

  if (legalMoves(s).isEmpty) {
    s.lastEvent = 'skip';
    _endTurn(s, extra: false);
    return;
  }
  s.phase = LudoPhase.awaitingMove;
}

/// All legal moves for the current player given the pending roll.
List<LudoMove> legalMoves(LudoState s) {
  final roll = s.lastRoll;
  if (roll == null) return [];
  final moves = <LudoMove>[];
  final tokens = s.tokensOf(s.currentPlayerIndex);
  for (var i = 0; i < tokens.length; i++) {
    final t = tokens[i];
    if (t.isHome) continue;
    if (t.inBase) {
      if (roll == 6 && !_blockedByEnemy(s, s.currentPlayer.color, 0)) {
        moves.add(LudoMove(tokenIndex: i, from: -1, to: 0));
      }
      continue;
    }
    final target = t.pos + roll;
    if (target > homePos) continue; // must land exactly on home
    if (!_pathClear(s, s.currentPlayer.color, t.pos, target)) continue;
    moves.add(LudoMove(tokenIndex: i, from: t.pos, to: target));
  }
  return moves;
}

/// Enemy "block" (2+ tokens of one other color) occupies relative cell [r]
/// of [color]'s perspective?
bool _blockedByEnemy(LudoState s, LudoColor color, int r) {
  final abs = LudoBoard.absCell(color, r);
  final counts = <LudoColor, int>{};
  for (final t in s.tokens) {
    if (t.color == color) continue;
    if (t.pos >= 0 && t.pos <= 50 && LudoBoard.absCell(t.color, t.pos) == abs) {
      counts[t.color] = (counts[t.color] ?? 0) + 1;
    }
  }
  return counts.values.any((c) => c >= 2);
}

/// Can a token of [color] travel from [from] to [to] (relative positions)
/// without passing or landing on an enemy block?
bool _pathClear(LudoState s, LudoColor color, int from, int to) {
  final lastTrack = to <= 50 ? to : 50;
  for (var r = from + 1; r <= lastTrack; r++) {
    if (_blockedByEnemy(s, color, r)) return false;
  }
  return true;
}


/// Apply a legal move. Returns the captured token's gid, or null.
int? applyMove(LudoState s, int tokenIndex) {
  assert(s.phase == LudoPhase.awaitingMove);
  final player = s.currentPlayer;
  final tokens = s.tokensOf(s.currentPlayerIndex);
  final t = tokens[tokenIndex];
  final roll = s.lastRoll!;
  final target = t.inBase ? 0 : t.pos + roll;
  assert(target <= homePos);

  int? capturedGid;
  t.pos = target;

  // Capture check: landed on a main-track cell.
  if (target >= 0 && target <= 50) {
    final abs = LudoBoard.absCell(player.color, target);
    final isSafe = LudoBoard.safeCells.contains(abs);
    if (!isSafe) {
      for (final other in s.tokens) {
        if (other.color == player.color) continue;
        if (other.pos >= 0 &&
            other.pos <= 50 &&
            LudoBoard.absCell(other.color, other.pos) == abs) {
          other.pos = -1; // send back to base
          capturedGid = other.gid;
        }
      }
    }
  }

  if (capturedGid != null) {
    s.lastEvent = 'capture';
    s.eventTokenGid = capturedGid;
  } else if (target == homePos) {
    s.lastEvent = 'home';
    s.eventTokenGid = t.gid;
  } else {
    s.lastEvent = 'move';
    s.eventTokenGid = t.gid;
  }

  // Did the player finish?
  if (s.tokensOf(s.currentPlayerIndex).every((tk) => tk.isHome)) {
    player.finished = true;
    s.rankings.add(player.id);
    s.lastEvent = 'finished';
    s.eventTokenGid = t.gid;
  }

  // Game over when fewer than 2 unfinished players remain.
  final active = s.players.where((p) => !p.finished).length;
  if (active <= 1) {
    for (final p in s.players) {
      if (!p.finished && !s.rankings.contains(p.id)) s.rankings.add(p.id);
    }
    s.phase = LudoPhase.gameOver;
    s.lastRoll = null;
    return capturedGid;
  }

  // Extra roll: on a 6 (not the forfeiting third), a capture, or bringing a
  // token home.
  final extra = (s.lastRoll == 6 && s.consecutiveSixes < 3) ||
      capturedGid != null ||
      target == homePos;
  _endTurn(s, extra: extra);
  return capturedGid;
}

void _endTurn(LudoState s, {required bool extra}) {
  final rolledSix = s.lastRoll == 6;
  s.lastRoll = null;
  if (extra) {
    s.extraRoll = true;
    s.phase = LudoPhase.awaitingRoll;
    // The six-streak persists across an extra roll that came from rolling a
    // six; capture/home extras with a non-6 roll reset it.
    if (!rolledSix) s.consecutiveSixes = 0;
    return;
  }
  s.extraRoll = false;
  s.consecutiveSixes = 0;
  s.turnCount += 1;
  // Advance to next unfinished player.
  for (var i = 1; i <= s.players.length; i++) {
    final cand = (s.currentPlayerIndex + i) % s.players.length;
    if (!s.players[cand].finished) {
      s.currentPlayerIndex = cand;
      break;
    }
  }
  s.phase = LudoPhase.awaitingRoll;
}

/// Convenience helper used by the UI/AI: does this move capture?
bool moveCaptures(LudoState s, LudoMove m) {
  if (m.to < 0 || m.to > 50) return false;
  final abs = LudoBoard.absCell(s.currentPlayer.color, m.to);
  if (LudoBoard.safeCells.contains(abs)) return false;
  return s.tokens.any((o) =>
      o.color != s.currentPlayer.color &&
      o.pos >= 0 &&
      o.pos <= 50 &&
      LudoBoard.absCell(o.color, o.pos) == abs);
}
