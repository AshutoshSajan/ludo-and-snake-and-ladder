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

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'color': color.name,
        'isAI': isAI,
        'difficulty': difficulty.name,
        'finished': finished,
      };

  static LudoPlayer fromJson(Map<String, dynamic> j) => LudoPlayer(
        id: j['id'] as String,
        name: j['name'] as String,
        color: LudoColor.values.byName(j['color'] as String),
        isAI: j['isAI'] as bool? ?? false,
        difficulty:
            AIDifficulty.values.byName(j['difficulty'] as String? ?? 'medium'),
        finished: j['finished'] as bool? ?? false,
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

  Map<String, dynamic> toJson() => {'c': color.name, 'i': index, 'p': pos};

  static LudoToken fromJson(Map<String, dynamic> j) => LudoToken(
        color: LudoColor.values.byName(j['c'] as String),
        index: j['i'] as int,
        pos: j['p'] as int,
      );
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

  Map<String, dynamic> toJson() => {
        'players': [for (final p in players) p.toJson()],
        'tokens': [for (final t in tokens) t.toJson()],
        'cur': currentPlayerIndex,
        'phase': phase.name,
        'roll': lastRoll,
        'sixes': consecutiveSixes,
        'extra': extraRoll,
        'rankings': rankings,
        'event': lastEvent,
        'eventGid': eventTokenGid,
        'turns': turnCount,
        'rollSeq': rollSeq,
      };

  static LudoState fromJson(Map<String, dynamic> j) => LudoState(
        players: [
          for (final p in j['players'] as List)
            LudoPlayer.fromJson(Map<String, dynamic>.from(p as Map))
        ],
        tokens: [
          for (final t in j['tokens'] as List)
            LudoToken.fromJson(Map<String, dynamic>.from(t as Map))
        ],
        currentPlayerIndex: j['cur'] as int,
        phase: LudoPhase.values.byName(j['phase'] as String),
        lastRoll: j['roll'] as int?,
        consecutiveSixes: j['sixes'] as int? ?? 0,
        extraRoll: j['extra'] as bool? ?? false,
        rankings: [...(j['rankings'] as List? ?? []).cast<String>()],
        lastEvent: j['event'] as String?,
        eventTokenGid: j['eventGid'] as int?,
        turnCount: j['turns'] as int? ?? 0,
        rollSeq: j['rollSeq'] as int? ?? 0,
      );
}
