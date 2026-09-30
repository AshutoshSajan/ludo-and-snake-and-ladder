import 'dart:async';
import 'dart:math';

import 'package:flutter/foundation.dart';

import '../engine/ludo/ludo_ai.dart';
import '../engine/ludo/ludo_board.dart';
import '../engine/ludo/ludo_models.dart';
import '../engine/ludo/ludo_rules.dart';
import '../providers/app_providers.dart';
import '../services/online_client.dart';
import '../services/sound_service.dart';

/// A seat chosen on the setup screen.
class SeatSetup {
  SeatSetup({
    required this.name,
    this.profileId,
    this.isAI = false,
    this.difficulty = AIDifficulty.medium,
    this.color,
  });

  final String? profileId; // null for pure bots
  final String name;
  bool isAI;
  AIDifficulty difficulty;

  /// Corner color for Ludo (null = fall back to seat position order).
  final LudoColor? color;
}

/// A token animation in flight: the ghost token hops through [waypoints].
class MoveAnim {
  MoveAnim({
    required this.tokenGid,
    required this.waypoints,
    required this.stepMs,
    this.startInYard = false,
    this.toHome = false,
  });

  final int tokenGid;
  final List<GridPos> waypoints;
  final int stepMs;

  /// True when the first waypoint is a yard staging slot (spawn move), so
  /// the ghost's resting offset matches the settled yard token exactly.
  final bool startInYard;

  /// True when the move finishes (to == 56): the last waypoint is the
  /// color's finished triangle cell, and the ghost rests at the exact
  /// finished-slot offset so the handoff has no visible slide.
  final bool toHome;

  int get totalMs => waypoints.length * stepMs + 120;
}

/// Drives a local Ludo game: dice, AI turns, animations, sounds, and the
/// mid-game seat management (add / remove / human <-> AI swap).
class LudoSession extends ChangeNotifier {
  LudoSession({
    required List<SeatSetup> seats,
    required this.profiles,
    required this.sound,
    required this.onGameOver,
    Random? rng,
    bool skipSchedule = false,
  }) : _rng = rng ?? Random() {
    final players = <LudoPlayer>[];
    for (var i = 0; i < seats.length; i++) {
      final seat = seats[i];
      players.add(LudoPlayer(
        id: seat.profileId ?? 'bot-$i-${DateTime.now().millisecondsSinceEpoch}',
        name: seat.name,
        color: seat.color ?? LudoBoard.colorOrder[i],
        isAI: seat.isAI,
        difficulty: seat.difficulty,
      ));
    }
    // Turns always run clockwise around the board, regardless of the order
    // in which seats were filled or corners were picked on the setup screen.
    players.sort((a, b) => LudoBoard.colorOrder
        .indexOf(a.color)
        .compareTo(LudoBoard.colorOrder.indexOf(b.color)));
    state = createLudoState(players);
    if (!skipSchedule) scheduleNext();
  }

  late LudoState state;
  final ProfilesNotifier profiles;
  final SoundService sound;
  final void Function(LudoState) onGameOver;

  final Random _rng;
  Timer? _timer;
  final _stepTimers = <Timer>[];
  MoveAnim? activeAnim;
  bool _busy = false;
  bool _over = false;

  /// When true, human seats roll and move automatically (autoplay / break).
  bool autoPlay = false;

  bool get isBusy => _busy || activeAnim != null;

  // ---------------------------------------------------------------- online

  /// Attached authoritative-server client (null in local games).
  OnlineClient? online;
  String? mySeatId;

  bool get isOnline => online != null;

  /// Named constructor for online play: adopts the server snapshot and
  /// forwards intents. The server owns the dice and validation.
  factory LudoSession.online({
    required OnlineClient client,
    required String seatId,
    required ProfilesNotifier profiles,
    required SoundService sound,
    required void Function(LudoState) onGameOver,
  }) {
    final snapshot = client.state!;
    final s = LudoSession(
      seats: [
        for (final p in snapshot.players)
          SeatSetup(name: p.name, profileId: p.id, color: p.color),
      ],
      profiles: profiles,
      sound: sound,
      onGameOver: onGameOver,
      skipSchedule: true,
    );
    // Replace engine-generated state with the authoritative snapshot.
    s.state = snapshot;
    s.mySeatId = seatId;
    s.online = client;
    client.onRoll = () {
      s.sound.dice();
      Haptics.light();
    };
    // The message chime lives here, not in the chat sheet. Wired in the sheet
    // it could only fire once that sheet had been opened at least once, so a
    // message arriving before you ever tapped the icon was silent — which is
    // exactly the message you most needed to hear about.
    client.onMessageArrived = (_) => s.sound.message();
    client.onState = (old, next) => s._adoptState(old, next);
    return s;
  }

  /// Whether the current seat is driven by the local AI. Never true in an
  /// online game — remote seats are driven by the server, and the server
  /// snapshot tells us when it is our turn.
  bool get currentIsAI => !isOnline && state.currentPlayer.isAI;

  /// Whether the *local* user may act now (online: it's my seat's turn).
  bool get isMyTurnNow =>
      isOnline ? state.currentPlayer.id == mySeatId : !currentIsAI;

  // ---------------------------------------------------------------- turns

  void roll() {
    if (isOnline) {
      if (isBusy || state.phase != LudoPhase.awaitingRoll || !isMyTurnNow) {
        return;
      }
      online!.sendRoll();
      return;
    }
    if (_busy || state.phase != LudoPhase.awaitingRoll || currentIsAI) return;
    _roll();
  }

  /// Toggle autoplay: human seats roll and pick moves automatically.
  ///
  /// Online, the request goes to the server and the flag is not kept locally
  /// at all: the table drives the seat from then on, so it keeps driving it
  /// when this tab closes, and a player who rejoins finds the switch exactly
  /// where they left it. Two clients must not both decide who plays a seat.
  void toggleAutoPlay({bool? on}) {
    final target = on ?? !autoPlayOn;
    if (isOnline) {
      online!.sendAutoplay(target);
      notifyListeners();
      return;
    }
    autoPlay = target;
    notifyListeners();
    scheduleNext();
  }

  /// Autoplay as the player should see it. Online this is the server's answer
  /// — a local flag could disagree with the seat the moment someone reconnects.
  bool get autoPlayOn => isOnline ? (online?.iAmAuto ?? false) : autoPlay;

  /// Walk out of an online game: tell the table, take our pieces with us, and
  /// stop listening. The remaining players get the announcement; we get out.
  Future<void> leaveOnline() async {
    final client = online;
    if (client == null) return;
    _timer?.cancel();
    for (final t in _stepTimers) {
      t.cancel();
    }
    _stepTimers.clear();
    activeAnim = null;
    await client.sendLeave();
  }

  // ------------------------------------------------------------ undo & hint

  final _undoStack = <LudoState>[];

  /// True when the last roll+move of the current human turn can be undone.
  /// Online games are server-authoritative — no local undo.
  bool get canUndo =>
      _undoStack.isNotEmpty &&
      !isBusy &&
      !autoPlay &&
      !isOnline &&
      state.phase != LudoPhase.gameOver;

  /// Undo the last roll (and any move made from it). Restores the most
  /// recent pre-roll snapshot, so moves made since — including bot moves —
  /// are rewound too. Disabled while autoplay is on or an animation runs.
  void undo() {
    if (!canUndo) return;
    _timer?.cancel();
    for (final t in _stepTimers) {
      t.cancel();
    }
    _stepTimers.clear();
    activeAnim = null;
    _busy = false;
    state = _undoStack.removeLast();
    notifyListeners();
    scheduleNext();
  }

  /// True when a hint can be requested: it's the local human's move phase
  /// and nothing is animating.
  bool get canHint =>
      !_busy &&
      !currentIsAI &&
      isMyTurnNow &&
      !autoPlay &&
      state.phase == LudoPhase.awaitingMove &&
      legalMoves(state).isNotEmpty;

  /// The AI's best move for the current human player — the hint highlight.
  /// Returns the token index (0–3) of the recommended move, or null when
  /// there is nothing to suggest (not this player's move phase).
  int? hintTokenIndex() {
    if (!canHint) {
      return null;
    }
    return chooseLudoMove(state, AIDifficulty.hard, _rng)?.tokenIndex;
  }

  void _roll() {
    // Snapshot for undo: restores the pre-roll state (roll + move both go).
    _undoStack.add(state.copy());
    if (_undoStack.length > 10) _undoStack.removeAt(0);
    rollDice(state, _rng.nextInt(6) + 1);
    sound.dice();
    Haptics.light();
    notifyListeners();
    if (state.phase == LudoPhase.awaitingMove) {
      final moves = legalMoves(state);
      if (moves.length == 1 && !currentIsAI) {
        // Forced move: play it automatically after a beat.
        _timer = Timer(const Duration(milliseconds: 700), () {
          if (state.phase == LudoPhase.awaitingMove) _playMove(moves.first);
        });
      } else {
        scheduleNext();
      }
    } else {
      scheduleNext();
    }
  }

  void tapToken(int tokenIndex) {
    if (_busy || state.phase != LudoPhase.awaitingMove) return;
    if (isOnline) {
      // Remote play: validate locally for responsiveness, but only send the
      // intent — the server is the single source of truth.
      if (!isMyTurnNow) return;
      final move = legalMoves(state)
          .where((m) => m.tokenIndex == tokenIndex)
          .firstOrNull;
      if (move == null) return;
      online!.sendMove(tokenIndex);
      return;
    }
    if (currentIsAI) return;
    final move =
        legalMoves(state).where((m) => m.tokenIndex == tokenIndex).firstOrNull;
    if (move == null) return;
    _playMove(move);
  }

  void _playMove(LudoMove move) {
    _timer?.cancel();
    for (final t in _stepTimers) {
      t.cancel();
    }
    _stepTimers.clear();
    final player = state.currentPlayer;
    final tokens = state.tokensOf(state.currentPlayerIndex);
    final token = tokens[move.tokenIndex];

    // Waypoints: cell-by-cell along the path. A finishing move (to == 56)
    // walks into the color's own triangle inside the center finish square —
    // never the board center or back to the yard — and stays there.
    final startInYard = move.from == -1;
    final waypoints = <GridPos>[
      LudoBoard.coordFor(player.color, move.from, token.index, 4),
      if (move.from == -1)
        LudoBoard.coordFor(player.color, 0, token.index, 4)
      else
        for (var r = move.from + 1; r <= move.to; r++)
          r == 56
              ? LudoBoard.finishedCell(player.color)
              : LudoBoard.coordFor(player.color, r, token.index, 4),
    ];
    activeAnim = MoveAnim(
      tokenGid: token.gid,
      waypoints: waypoints,
      stepMs: move.from == -1 ? 200 : 130,
      startInYard: startInYard,
      toHome: move.to == 56,
    );
    // One tick per hop, synced to each step of the walk animation.
    final stepMs = activeAnim!.stepMs;
    for (var i = 1; i < waypoints.length; i++) {
      _stepTimers.add(Timer(Duration(milliseconds: stepMs * i), () {
        sound.step();
        Haptics.light();
      }));
    }
    _busy = true;
    notifyListeners();

    _timer = Timer(Duration(milliseconds: activeAnim!.totalMs), () {
      final captured = applyMove(state, move.tokenIndex);
      activeAnim = null;
      _busy = false;
      _playOutcome(player.color, move.to, captured != null);
      notifyListeners();

      if (state.phase == LudoPhase.gameOver) {
        _over = true;
        sound.champion(); // special winner fanfare
        onGameOver(state);
        return;
      }
      scheduleNext();
    });
  }

  /// Kick the next action: AI roll/move or wait for the human.
  void scheduleNext() {
    if (isOnline) {
      // The server drives turn flow; the client only animates snapshots.
      return;
    }
    if (_over || state.phase == LudoPhase.gameOver) return;
    _timer?.cancel();
    // AI seats always auto-play; human seats only when autoplay is on.
    final auto = state.currentPlayer.isAI || autoPlay;
    if (!auto) return;
    if (state.phase == LudoPhase.awaitingRoll) {
      _timer = Timer(const Duration(milliseconds: 900), () {
        if (state.phase != LudoPhase.awaitingRoll) return;
        if (!state.currentPlayer.isAI && !autoPlay) return;
        _roll();
      });
    } else if (state.phase == LudoPhase.awaitingMove) {
      _timer = Timer(const Duration(milliseconds: 700), () {
        if (state.phase != LudoPhase.awaitingMove) return;
        if (!state.currentPlayer.isAI && !autoPlay) return;
        final move = chooseLudoMove(state, state.currentPlayer.difficulty, _rng);
        if (move != null) _playMove(move);
      });
    }
  }

  /// Outcome sounds/haptics shared by local moves and online replays.
  void _playOutcome(LudoColor color, int to, bool captured) {
    if (captured) {
      sound.capture();
      Haptics.heavy();
    } else if (state.lastEvent == 'home' || state.lastEvent == 'finished') {
      sound.home();
      Haptics.medium();
    } else {
      // Landed on a safe (star) cell?
      final onSafe = to >= 0 &&
          to <= 50 &&
          LudoBoard.safeCells.contains(LudoBoard.absCell(color, to));
      if (onSafe) {
        sound.safe();
        Haptics.light();
      } else {
        sound.move();
        Haptics.light();
      }
    }
  }

  // ---------------------------------------------------------------- online

  /// Adopts an authoritative snapshot from the server. When the snapshot
  /// represents a *move* on the same roll (same rollSeq) and exactly one
  /// token advanced, the move is replayed as the usual walk animation so
  /// remote turns look identical to local ones.
  void _adoptState(LudoState? old, LudoState next) {
    _timer?.cancel();
    for (final t in _stepTimers) {
      t.cancel();
    }
    _stepTimers.clear();
    activeAnim = null;
    _busy = false;
    state = next;

    MoveAnim? replay;
    LudoToken? moved;
    bool captured = false;
    if (old != null && old.rollSeq == next.rollSeq) {
      final prev = {for (final t in old.tokens) t.gid: t.pos};
      for (final t in next.tokens) {
        if (prev[t.gid] != t.pos) {
          moved = t;
          break;
        }
      }
      if (moved != null) {
        final from = prev[moved.gid]!;
        final to = moved.pos;
        final waypoints = <GridPos>[
          LudoBoard.coordFor(moved.color, from, moved.index, 4),
          if (from == -1)
            LudoBoard.coordFor(moved.color, 0, moved.index, 4)
          else
            for (var r = from + 1; r <= to; r++)
              r == 56
                  ? LudoBoard.finishedCell(moved.color)
                  : LudoBoard.coordFor(moved.color, r, moved.index, 4),
        ];
        replay = MoveAnim(
          tokenGid: moved.gid,
          waypoints: waypoints,
          stepMs: from == -1 ? 200 : 130,
          startInYard: from == -1,
          toHome: to == 56,
        );
        for (var i = 1; i < waypoints.length; i++) {
          _stepTimers.add(Timer(Duration(milliseconds: replay.stepMs * i), () {
            sound.step();
            Haptics.light();
          }));
        }
        // Capture detection: an opponent token stood on the landing cell
        // before this move and is gone (sent home) in the snapshot.
        if (moved.pos >= 0 && moved.pos <= 50) {
          final landing = LudoBoard.absCell(moved.color, moved.pos);
          captured = old.tokens.any((t) =>
              t.color != moved!.color &&
              t.pos >= 0 &&
              t.pos <= 50 &&
              LudoBoard.absCell(t.color, t.pos) == landing);
        }
      }
    }

    if (replay != null) {
      final color = moved!.color;
      final to = moved.pos;
      activeAnim = replay;
      _busy = true;
      _timer = Timer(Duration(milliseconds: replay.totalMs), () {
        activeAnim = null;
        _busy = false;
        _playOutcome(color, to, captured);
        notifyListeners();
      });
    }
    notifyListeners();

    if (state.phase == LudoPhase.gameOver && !_over) {
      _over = true;
      sound.champion();
      onGameOver(state);
    }
  }

  // ------------------------------------------------- mid-game seat control

  void swapToAI(int playerIndex) {
    final p = state.players[playerIndex];
    if (!p.isAI) {
      p.isAI = true;
      notifyListeners();
      scheduleNext();
    }
  }

  void swapToHuman(int playerIndex) {
    final p = state.players[playerIndex];
    if (p.isAI) {
      p.isAI = false;
      notifyListeners();
      scheduleNext();
    }
  }

  void setDifficulty(int playerIndex, AIDifficulty d) {
    state.players[playerIndex].difficulty = d;
    notifyListeners();
  }

  bool get canAddPlayer => state.players.length < 4;

  List<LudoColor> freeColors() => LudoBoard.colorOrder
      .where((c) => !state.players.any((p) => p.color == c))
      .toList();

  void addPlayer(
      {String? profileId, required String name, required LudoColor color}) {
    if (!canAddPlayer) return;
    final player = LudoPlayer(
      id: profileId ?? 'bot-${DateTime.now().millisecondsSinceEpoch}',
      name: name,
      color: color,
      isAI: false,
    );
    // Insert at the clockwise-correct position so turn order stays
    // red -> blue -> yellow -> green around the board.
    final insertAt = state.players
        .where((p) =>
            LudoBoard.colorOrder.indexOf(p.color) <
            LudoBoard.colorOrder.indexOf(color))
        .length;
    state.players.insert(insertAt, player);
    if (insertAt <= state.currentPlayerIndex) state.currentPlayerIndex++;
    // Tokens must land in the same slot block as the inserted player, so
    // tokensOf(playerIndex) stays aligned with players[playerIndex].
    state.tokens.insertAll(
        insertAt * 4, [for (var i = 0; i < 4; i++) LudoToken(color: color, index: i)]);
    notifyListeners();
  }

  bool get canRemovePlayer => state.players.length > 2;

  void removePlayer(int playerIndex) {
    if (!canRemovePlayer) return;
    final wasCurrent = playerIndex == state.currentPlayerIndex;
    final color = state.players[playerIndex].color;
    final id = state.players[playerIndex].id;
    state.players.removeAt(playerIndex);
    state.tokens.removeWhere((t) => t.color == color);
    state.rankings.remove(id); // no podium entry if they hadn't finished
    if (state.currentPlayerIndex >= state.players.length) {
      state.currentPlayerIndex = 0;
    } else if (wasCurrent) {
      state.currentPlayerIndex %= state.players.length;
    }
    // Cancel any pending roll that belonged to the removed seat.
    state.lastRoll = null;
    state.phase = LudoPhase.awaitingRoll;
    notifyListeners();
    scheduleNext();
  }

  // --------------------------------------------------------------- cleanup

  @override
  void dispose() {
    _timer?.cancel();
    for (final t in _stepTimers) {
      t.cancel();
    }
    _stepTimers.clear();
    super.dispose();
  }
}
