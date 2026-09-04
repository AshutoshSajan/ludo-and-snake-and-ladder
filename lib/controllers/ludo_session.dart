import 'dart:async';
import 'dart:math';

import 'package:flutter/foundation.dart';

import '../engine/ludo/ludo_ai.dart';
import '../engine/ludo/ludo_board.dart';
import '../engine/ludo/ludo_models.dart';
import '../engine/ludo/ludo_rules.dart';
import '../providers/app_providers.dart';
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
  }) {
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
    state = createLudoState(players);
    scheduleNext();
  }

  late LudoState state;
  final ProfilesNotifier profiles;
  final SoundService sound;
  final void Function(LudoState) onGameOver;

  final _rng = Random();
  Timer? _timer;
  final _stepTimers = <Timer>[];
  MoveAnim? activeAnim;
  bool _busy = false;
  bool _over = false;

  bool get isBusy => _busy || activeAnim != null;
  bool get currentIsAI => state.currentPlayer.isAI;

  // ---------------------------------------------------------------- turns

  void roll() {
    if (_busy || state.phase != LudoPhase.awaitingRoll || currentIsAI) return;
    _roll();
  }

  void _roll() {
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
    if (_busy || currentIsAI || state.phase != LudoPhase.awaitingMove) return;
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
      if (captured != null) {
        sound.capture();
        Haptics.heavy();
      } else if (state.lastEvent == 'home' || state.lastEvent == 'finished') {
        sound.home();
        Haptics.medium();
      } else {
        // Landed on a safe (star) cell?
        final target = move.to;
        final onSafe = target >= 0 &&
            target <= 50 &&
            LudoBoard.safeCells.contains(LudoBoard.absCell(player.color, target));
        if (onSafe) {
          sound.safe();
          Haptics.light();
        } else {
          sound.move();
          Haptics.light();
        }
      }
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
    if (_over || state.phase == LudoPhase.gameOver) return;
    _timer?.cancel();
    if (!state.currentPlayer.isAI) return;
    if (state.phase == LudoPhase.awaitingRoll) {
      _timer = Timer(const Duration(milliseconds: 900), () {
        if (state.phase != LudoPhase.awaitingRoll || !state.currentPlayer.isAI) {
          return;
        }
        _roll();
      });
    } else if (state.phase == LudoPhase.awaitingMove) {
      _timer = Timer(const Duration(milliseconds: 700), () {
        if (state.phase != LudoPhase.awaitingMove || !state.currentPlayer.isAI) {
          return;
        }
        final move = chooseLudoMove(state, state.currentPlayer.difficulty, _rng);
        if (move != null) _playMove(move);
      });
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
    state.players.add(LudoPlayer(
      id: profileId ?? 'bot-${DateTime.now().millisecondsSinceEpoch}',
      name: name,
      color: color,
      isAI: false,
    ));
    for (var i = 0; i < 4; i++) {
      state.tokens.add(LudoToken(color: color, index: i));
    }
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
