/// Pure-Dart Snakes & Ladders engine — 100 squares, 2..10 players.
library;

import 'dart:math';

/// Classic Chutes & Ladders style jump map: square -> destination.
const Map<int, int> kSnakesLaddersJumps = {
  // Ladders
  1: 38, 4: 14, 9: 31, 21: 42, 28: 84, 36: 44, 51: 67, 71: 91, 80: 100,
  // Snakes
  16: 6, 47: 26, 49: 11, 56: 53, 62: 19, 64: 60, 87: 24, 93: 73, 95: 75,
  98: 78,
};

const int kWinSquare = 100;

class SnakesPlayer {
  SnakesPlayer({
    required this.id,
    required this.name,
    required this.tokenIndex,
    this.isAI = false,
    this.square = 0,
    this.finished = false,
  });

  final String id;
  final String name;

  /// 0..9 — which pawn color/shape this seat uses on the board.
  final int tokenIndex;
  bool isAI;
  int square;
  bool finished;

  SnakesPlayer copy() => SnakesPlayer(
        id: id,
        name: name,
        tokenIndex: tokenIndex,
        isAI: isAI,
        square: square,
        finished: finished,
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        't': tokenIndex,
        'ai': isAI,
        'sq': square,
        'fin': finished,
      };

  static SnakesPlayer fromJson(Map<String, dynamic> j) => SnakesPlayer(
        id: j['id'] as String,
        name: j['name'] as String? ?? 'Player',
        tokenIndex: j['t'] as int? ?? 0,
        isAI: j['ai'] as bool? ?? false,
        square: j['sq'] as int? ?? 0,
        finished: j['fin'] as bool? ?? false,
      );
}

enum SnakesPhase { awaitingRoll, awaitingMove, gameOver }

class SnakesState {
  SnakesState({
    required this.players,
    required this.currentPlayerIndex,
    this.phase = SnakesPhase.awaitingRoll,
    this.lastRoll,
    this.lastEvent,
    this.eventFrom,
    this.eventTo,
    List<String>? rankings,
  }) : rankings = rankings ?? [];

  final List<SnakesPlayer> players; // 2..10, in turn order
  int currentPlayerIndex;
  SnakesPhase phase;
  int? lastRoll;
  String? lastEvent; // 'roll','ladder','snake','home','skip'
  int? eventFrom;
  int? eventTo;
  final List<String> rankings;

  SnakesPlayer get currentPlayer => players[currentPlayerIndex];

  SnakesState copy() => SnakesState(
        players: players.map((p) => p.copy()).toList(),
        currentPlayerIndex: currentPlayerIndex,
        phase: phase,
        lastRoll: lastRoll,
        lastEvent: lastEvent,
        eventFrom: eventFrom,
        eventTo: eventTo,
        rankings: [...rankings],
      );

  /// Wire format for server snapshots (mirrors `LudoState.toJson`).
  Map<String, dynamic> toJson() => {
        'players': [for (final p in players) p.toJson()],
        'cur': currentPlayerIndex,
        'phase': phase.name,
        if (lastRoll != null) 'roll': lastRoll,
        if (lastEvent != null) 'event': lastEvent,
        if (eventFrom != null) 'from': eventFrom,
        if (eventTo != null) 'to': eventTo,
        'rankings': [...rankings],
      };

  static SnakesState fromJson(Map<String, dynamic> j) => SnakesState(
        players: [
          for (final p in (j['players'] as List? ?? []))
            SnakesPlayer.fromJson(Map<String, dynamic>.from(p as Map)),
        ],
        currentPlayerIndex: j['cur'] as int? ?? 0,
        phase: SnakesPhase.values.firstWhere(
          (p) => p.name == j['phase'],
          orElse: () => SnakesPhase.awaitingRoll,
        ),
        lastRoll: j['roll'] as int?,
        lastEvent: j['event'] as String?,
        eventFrom: j['from'] as int?,
        eventTo: j['to'] as int?,
        rankings: [
          for (final r in (j['rankings'] as List? ?? [])) r as String,
        ],
      );
}

SnakesState createSnakesState(List<SnakesPlayer> players) {
  assert(players.length >= 2 && players.length <= 10);
  return SnakesState(players: players, currentPlayerIndex: 0);
}

/// Roll with an explicit value. In Snakes & Ladders there is exactly one
/// possible move, so the roll leads to an `awaitingMove` phase with a
/// single forced move (the UI animates it before resolving).
///
/// The one exception is a pawn that has not entered the board yet. Classic
/// rules require a 1 to come in, landing on square 1 (which on this board is
/// the foot of the ladder to 38 — so entering is immediately dramatic, and
/// that is the real game, not a bug). Any other roll cannot move a pawn that
/// is still off the board, so the turn is simply spent.
///
/// Without this, `pendingMove`'s `square + roll` let a pawn off the board move
/// to whatever was rolled, so a 5 put a starting pawn on square 5 and the
/// board opened with players scattered instead of waiting at the start.
void rollDice(SnakesState s, int value) {
  assert(value >= 1 && value <= 6);
  if (s.phase != SnakesPhase.awaitingRoll) return;
  s.lastRoll = value;
  s.lastEvent = 'roll';
  if (s.currentPlayer.square == 0 && value != 1) {
    // Cannot enter on this roll. No move, so no `awaitingMove` phase for the UI
    // to animate — the player is still where they were.
    s.lastEvent = 'skip';
    _endTurn(s);
    // _endTurn clears lastRoll, but the die is the only evidence the player
    // rolled at all. Restored so the wasted roll stays visible instead of the
    // die blanking with nothing to explain why the pawn did not move.
    s.lastRoll = value;
    return;
  }
  s.phase = SnakesPhase.awaitingMove;
}

/// The (single) pending move description, or null.
({int from, int to, String? jump}) pendingMove(SnakesState s) {
  final p = s.currentPlayer;
  final roll = s.lastRoll!;
  final raw = p.square + roll;
  var target = raw;
  String? jump;
  if (raw > kWinSquare) {
    target = kWinSquare - (raw - kWinSquare); // bounce back
  } else if (raw == kWinSquare) {
    target = kWinSquare;
  } else {
    final dest = kSnakesLaddersJumps[raw];
    if (dest != null) {
      target = dest;
      jump = dest > raw ? 'ladder' : 'snake';
    }
  }
  return (from: p.square, to: target, jump: jump);
}

/// Resolve the pending move (exactly one always exists).
void applyMove(SnakesState s) {
  assert(s.phase == SnakesPhase.awaitingMove);
  final p = s.currentPlayer;
  final mv = pendingMove(s);
  p.square = mv.to;

  if (mv.jump != null) {
    s.lastEvent = mv.jump;
    s.eventFrom = mv.from;
    s.eventTo = mv.to;
  } else if (mv.to == kWinSquare) {
    s.lastEvent = 'home';
    s.eventFrom = mv.from;
    s.eventTo = mv.to;
  } else {
    s.lastEvent = 'roll';
    s.eventFrom = mv.from;
    s.eventTo = mv.to;
  }

  if (p.square == kWinSquare) {
    p.finished = true;
    s.rankings.add(p.id);
    // Classic game: ends when the first player reaches square 100.
    for (final other in s.players) {
      if (!other.finished && !s.rankings.contains(other.id)) {
        s.rankings.add(other.id);
      }
    }
    s.rankings.sort((a, b) {
      final pa = s.players.firstWhere((e) => e.id == a);
      final pb = s.players.firstWhere((e) => e.id == b);
      return pb.square.compareTo(pa.square);
    });
    s.phase = SnakesPhase.gameOver;
    s.lastRoll = null;
    return;
  }

  _endTurn(s);
}

void _endTurn(SnakesState s) {
  s.lastRoll = null;
  s.turnPasses();
  s.phase = SnakesPhase.awaitingRoll;
}

extension on SnakesState {
  void turnPasses() {
    currentPlayerIndex = (currentPlayerIndex + 1) % players.length;
  }
}

/// Snakes & Ladders has no move choices — the "AI" is simply an auto-roll.
/// Kept for symmetry with the Ludo bot API and future rule variants.
int rollForAI(Random rng) => rng.nextInt(6) + 1;
