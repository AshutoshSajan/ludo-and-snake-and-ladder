/// Pure-Dart Ludo game engine — no Flutter imports, runs on every target.
///
/// Position encoding for a token (`LudoToken.pos`):
///   -1        : in base (yard)
///   0..50     : steps along the shared 52-cell main track (r=0 is own start)
///   51..55    : own home column (5 cells)
///   56        : home (finished)
library;

enum LudoColor { red, green, yellow, blue }

extension LudoColorX on LudoColor {
  String get label => switch (this) {
        LudoColor.red => 'Red',
        LudoColor.green => 'Green',
        LudoColor.yellow => 'Yellow',
        LudoColor.blue => 'Blue',
      };
}

enum AIDifficulty { easy, medium, hard }

/// One seat at the Ludo table. A seat may be driven by a human or a bot;
/// [isAI] is flipped at runtime for mid-game human <-> AI swaps.
class LudoPlayer {
  LudoPlayer({
    required this.id,
    required this.name,
    required this.color,
    this.isAI = false,
    this.difficulty = AIDifficulty.medium,
    this.finished = false,
  });

  final String id; // profile id (or synthetic id for bots)
  final String name;
  final LudoColor color;
  bool isAI;
  AIDifficulty difficulty;
  bool finished;

  LudoPlayer copy() => LudoPlayer(
        id: id,
        name: name,
        color: color,
        isAI: isAI,
        difficulty: difficulty,
        finished: finished,
      );
}

class LudoToken {
  LudoToken({required this.color, required this.index, this.pos = -1});

  final LudoColor color;
  final int index; // 0..3 within the player's set

  /// -1 = base, 0..50 = main track, 51..55 = home column, 56 = home.
  int pos;

  /// Stable global id: colorIndex * 4 + tokenIndex.
  int get gid => color.index * 4 + index;

  bool get inBase => pos == -1;
  bool get isHome => pos == 56;
  bool get inHomeColumn => pos >= 51 && pos <= 55;
}

class LudoMove {
  LudoMove({
    required this.tokenIndex,
    required this.from,
    required this.to,
    this.captures = false,
  });

  final int tokenIndex; // index within current player's 4 tokens
  final int from;
  final int to;
  final bool captures;
}

/// Phases of a turn.
enum LudoPhase {
  awaitingRoll, // current player must roll the dice
  awaitingMove, // dice rolled, player must pick a move (or auto-move)
  gameOver,
}

class LudoState {
  LudoState({
    required this.players,
    required this.tokens,
    required this.currentPlayerIndex,
    this.phase = LudoPhase.awaitingRoll,
    this.lastRoll,
    this.consecutiveSixes = 0,
    this.extraRoll = false,
    List<String>? rankings,
    this.lastEvent,
    this.eventTokenGid,
    this.turnCount = 0,
    this.rollSeq = 0,
  }) : rankings = rankings ?? [];

  final List<LudoPlayer> players; // 2..4, in turn order
  final List<LudoToken> tokens; // 4 per player, grouped by player order
  int currentPlayerIndex;
  LudoPhase phase;
  int? lastRoll; // 1..6, valid while phase == awaitingMove
  int consecutiveSixes; // consecutive sixes rolled by current player
  bool extraRoll; // current player rolls again after resolving the move
  final List<String> rankings; // player ids in finishing order
  String? lastEvent; // 'roll','move','capture','home','six','tripleSix','skip'
  int? eventTokenGid;
  int turnCount;
  int rollSeq; // increments on every successful roll — UI roll animations key off this

  LudoPlayer get currentPlayer => players[currentPlayerIndex];

  List<LudoToken> tokensOf(int playerIndex) =>
      tokens.sublist(playerIndex * 4, playerIndex * 4 + 4);

  LudoToken tokenByGid(int gid) => tokens.firstWhere((t) => t.gid == gid);

  LudoState copy() {
    final s = LudoState(
      players: players.map((p) => p.copy()).toList(),
      tokens: [
        for (final t in tokens) LudoToken(color: t.color, index: t.index, pos: t.pos)
      ],
      currentPlayerIndex: currentPlayerIndex,
      phase: phase,
      lastRoll: lastRoll,
      consecutiveSixes: consecutiveSixes,
      extraRoll: extraRoll,
      rankings: [...rankings],
      lastEvent: lastEvent,
      eventTokenGid: eventTokenGid,
      turnCount: turnCount,
      rollSeq: rollSeq,
    );
    return s;
  }
}
