import 'dart:async';
import 'dart:math';

import 'package:flutter/foundation.dart';

import '../engine/snakes/snakes_engine.dart';
import '../providers/app_providers.dart';
import '../services/sound_service.dart';
import 'ludo_session.dart'; // SeatSetup reuse

/// Pawn position for animations: square 0 means "start / off-board".
class SnakesAnim {
  SnakesAnim({
    required this.tokenIndex,
    required this.waypoints,
    this.jump,
  });

  final int tokenIndex;
  final List<int> waypoints; // squares 0..100
  final String? jump; // 'ladder' | 'snake'

  /// Milliseconds per UI hop tick. One UI hop every 120 ms (see snakes_view),
  /// so a 6-hop walk is well under a second. The view reads this to keep its
  /// ghost timer and the dice tumble window in sync with the total below.
  static const uiStepMs = 120;

  /// How long the dice keeps its tumble before settling on the rolled face.
  static const diceRollMs = 420;

  /// Settle tail after the last hop — short, so the next roll feels immediate.
  static const _tailMs = 260;

  int get totalMs => waypoints.length * uiStepMs + _tailMs;
}

/// Drives a local Snakes & Ladders game (2..10 seats, human or AI).
class SnakesSession extends ChangeNotifier {
  SnakesSession({
    required List<SeatSetup> seats,
    required this.profiles,
    required this.sound,
    required this.onGameOver,
  }) {
    final players = <SnakesPlayer>[];
    for (var i = 0; i < seats.length; i++) {
      final seat = seats[i];
      players.add(SnakesPlayer(
        id: seat.profileId ?? 'bot-$i-${DateTime.now().millisecondsSinceEpoch}',
        name: seat.name,
        tokenIndex: i,
        isAI: seat.isAI,
      ));
    }
    state = createSnakesState(players);
    scheduleNext();
  }

  late SnakesState state;
  final ProfilesNotifier profiles;
  final SoundService sound;
  final void Function(SnakesState) onGameOver;

  final _rng = Random();
  Timer? _timer;
  SnakesAnim? activeAnim;
  bool _busy = false;
  bool _over = false;

  /// When true, human seats roll automatically (autoplay / break). Set to
  /// true by pause-menu tests and the autoplay toggle.
  bool autoPlay = false;

  /// Slightly longer than the AI beat so a human still sees a beat between
  /// the automatic rolls.
  static const _autoRollDelay = Duration(milliseconds: 1100);

  bool get currentIsAI => state.currentPlayer.isAI;

  // ---------------------------------------------------------------- turns

  void roll() {
    if (_busy || state.phase != SnakesPhase.awaitingRoll || currentIsAI) return;
    _roll();
  }

  void _roll() {
    rollDice(state, _rng.nextInt(6) + 1);
    sound.dice();
    Haptics.light();
    notifyListeners();

    // Exactly one move always exists: animate it, then resolve.
    final mv = pendingMove(state);
    final waypoints = <int>[mv.from];
    if (mv.jump != null) {
      final raw = mv.from + state.lastRoll!;
      if (raw != mv.to) waypoints.add(raw); // show the landing before jump
    }
    if (mv.to != waypoints.last) waypoints.add(mv.to);

    activeAnim = SnakesAnim(
      tokenIndex: state.currentPlayer.tokenIndex,
      waypoints: waypoints,
      jump: mv.jump,
    );
    _busy = true;
    notifyListeners();

    _timer = Timer(Duration(milliseconds: activeAnim!.totalMs), () {
      final jump = pendingMove(state).jump;
      applyMove(state);
      activeAnim = null;
      _busy = false;

      if (jump == 'ladder') {
        sound.ladder();
        Haptics.medium();
      } else if (jump == 'snake') {
        sound.snake();
        Haptics.heavy();
      } else if (state.phase == SnakesPhase.gameOver) {
        sound.win();
      } else {
        sound.move();
        Haptics.light();
      }
      notifyListeners();

      if (state.phase == SnakesPhase.gameOver) {
        _over = true;
        onGameOver(state);
        return;
      }
      scheduleNext();
    });
  }

  /// Kick the next action: AI roll, an autoplay roll for a human seat, or
  /// wait for the human.
  void scheduleNext() {
    if (_over || state.phase == SnakesPhase.gameOver) return;
    // While a move is in flight the single `_timer` IS that move: it is what
    // applies it once the walk finishes. Cancelling it here — which toggling
    // autoplay or swapping a seat mid-walk used to do — would leave the pawn
    // hanging mid-board with `_busy` stuck true and no way to ever recover.
    // The resolve callback calls this again after it has applied the move.
    if (activeAnim != null) return;
    _timer?.cancel();
    final needsRoll = state.phase == SnakesPhase.awaitingRoll &&
        (state.currentPlayer.isAI || autoPlay);
    if (needsRoll) {
      final delay =
          autoPlay ? _autoRollDelay : const Duration(milliseconds: 900);
      _timer = Timer(delay, () {
        if (state.phase == SnakesPhase.awaitingRoll &&
            (state.currentPlayer.isAI || autoPlay)) {
          _roll();
        }
      });
    }
  }

  /// Toggle autoplay: human seats roll automatically. Schedule immediately;
  /// a human that was already waiting gets their roll right away.
  void toggleAutoPlay() {
    autoPlay = !autoPlay;
    notifyListeners();
    scheduleNext();
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

  bool get canAddPlayer => state.players.length < 10;

  void addPlayer({String? profileId, required String name}) {
    if (!canAddPlayer) return;
    state.players.add(SnakesPlayer(
      id: profileId ?? 'bot-${DateTime.now().millisecondsSinceEpoch}',
      name: name,
      tokenIndex: state.players.length,
    ));
    notifyListeners();
  }

  bool get canRemovePlayer => state.players.length > 2;

  void removePlayer(int playerIndex) {
    if (!canRemovePlayer) return;
    final wasCurrent = playerIndex == state.currentPlayerIndex;
    final id = state.players[playerIndex].id;
    state.players.removeAt(playerIndex);
    state.rankings.remove(id);
    // Reindex pawn colors so they stay compact and unique.
    for (var i = 0; i < state.players.length; i++) {
      // tokenIndex is final; rebuild with a copy at the same slot.
      if (state.players[i].tokenIndex != i) {
        state.players[i] = SnakesPlayer(
          id: state.players[i].id,
          name: state.players[i].name,
          tokenIndex: i,
          isAI: state.players[i].isAI,
          square: state.players[i].square,
          finished: state.players[i].finished,
        );
      }
    }
    if (state.currentPlayerIndex >= state.players.length) {
      state.currentPlayerIndex = 0;
    } else if (wasCurrent) {
      state.currentPlayerIndex %= state.players.length;
    }
    state.lastRoll = null;
    state.phase = SnakesPhase.awaitingRoll;
    notifyListeners();
    scheduleNext();
  }

  // --------------------------------------------------------------- cleanup

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }
}
