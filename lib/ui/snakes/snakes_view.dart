import '../page_app_bar.dart';
import 'dart:async';
import 'dart:math' show Random;
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../controllers/ludo_session.dart';
import '../../controllers/snakes_session.dart';
import '../../engine/core/player_profiles.dart';
import '../../engine/snakes/snakes_engine.dart';
import '../../providers/app_providers.dart';
import '../../services/saved_game.dart';
import '../shared/dice_widget.dart';
import '../shared/victory_dialog.dart';
import '../theme.dart';
import 'snakes_board_painter.dart';
import 'snakes_stage.dart';
import 'snakes_overlays.dart';
import '../shared/sound_toggle_button.dart';
import '../shared/pulse.dart';
import '../shared/bug_report_sheet.dart';
import '../../services/server_url.dart';

/// Full Snakes & Ladders game screen (2..10 players, human or bot seats).
class SnakesGameView extends ConsumerStatefulWidget {
  const SnakesGameView({
    super.key,
    required this.seats,
    this.rng,
    this.savedGame,
  });

  final List<SeatSetup> seats;

  /// A game to pick up rather than a new one; replaces [seats].
  final SavedGame? savedGame;

  /// Die source. Injectable for tests, which need to control the roll: a pawn
  /// off the board can only enter on a 1, so a test about the walk out of home
  /// cannot leave the die to chance. Matches [LudoSession].
  final Random? rng;

  @override
  ConsumerState<SnakesGameView> createState() => _SnakesGameViewState();
}

class _SnakesGameViewState extends ConsumerState<SnakesGameView> {
  late SnakesSession session;
  int _animStep = 0;
  Timer? _animTimer;

  /// Ghost hop tick and dice tumble window. Both come from [SnakesAnim] so the
  /// tumble always settles while the walk is still running and the session's
  /// `totalMs` stays the single source of truth for how long a move takes.
  static const _tickMs = SnakesAnim.uiStepMs;
  static const _diceMs = SnakesAnim.diceRollMs;

  @override
  void initState() {
    super.initState();
    if (widget.savedGame != null) {
      session = SnakesSession.resume(
        stateJson: widget.savedGame!.state,
        seatNames: widget.savedGame!.seatNames,
        profiles: ref.read(profilesProvider.notifier),
        sound: ref.read(soundServiceProvider),
        onGameOver: _onGameOver,
      );
      // Started only now: a timer running from the constructor would time out
      // the turn the player inherited without ever seeing it begin.
      session.scheduleNext();
    } else {
      session = SnakesSession(
        seats: widget.seats,
        profiles: ref.read(profilesProvider.notifier),
        sound: ref.read(soundServiceProvider),
        onGameOver: _onGameOver,
        rng: widget.rng,
      );
    }
    session.addListener(_onSessionChanged);
  }

  // SAVE & RESUME — PARKED, same as LudoGameView: the store and
  // SnakesSession.resume keep their tests; the autosave surface is commented
  // until the gameplay smoothness pass ships. Uncomment everything marked
  // "SAVE & RESUME" to restore.
  /*
  /// Trailing-debounced, then flushed on dispose — see LudoGameView for why.
  static const _saveDebounce = Duration(milliseconds: 800);
  Timer? _saveTimer;

  void _scheduleSave() {
    _saveTimer?.cancel();
    _saveTimer = Timer(_saveDebounce, _saveNow);
  }

  Future<void> _saveNow() async {
    if (session.state.phase == SnakesPhase.gameOver) {
      await SavedGameStore().clear(GameKind.snakes);
      return;
    }
    await SavedGameStore().save(SavedGame(
      game: GameKind.snakes,
      state: session.state.toJson(),
      seatNames: [for (final p in session.state.players) p.name],
      savedAt: DateTime.now(),
    ));
  }
  */

  @override
  void dispose() {
    // _saveTimer?.cancel(); // SAVE & RESUME — parked.
    // unawaited(_saveNow()); // SAVE & RESUME — parked.
    _animTimer?.cancel();
    session.removeListener(_onSessionChanged);
    session.dispose();
    super.dispose();
  }

  void _onSessionChanged() {
    // _scheduleSave(); // SAVE & RESUME — parked; see the note on _saveTimer.
    final anim = session.activeAnim;
    _animTimer?.cancel();
    _animStep = 0;
    if (anim != null) {
      _animTimer = Timer.periodic(const Duration(milliseconds: _tickMs), (t) {
        if (!mounted) return t.cancel();
        setState(() => _animStep++);
        if (_animStep >= anim.waypoints.length - 1) t.cancel();
      });
    }
    // A spent roll (a pawn still off the board, anything but a 1 rolled)
    // passes the turn with no move at all, and this used to interrupt with
    // a "Needs a 1 to enter" toast on every such roll — the playtest
    // counted it as exactly the unwanted popups they asked to remove.
    // The table stays quiet now: the die keeps the face, the pass rule is
    // taught by the rules pages and the in-app tutorial instead, and the
    // turn line names the seat whose turn it is.
    if (mounted) setState(() {});
  }

  void _onGameOver(SnakesState s) {
    ref
        .read(profilesProvider.notifier)
        .recordResults(GameKind.snakes, s.rankings);
    final names = [
      for (final id in s.rankings)
        s.players.where((p) => p.id == id).firstOrNull?.name ?? 'Player',
    ];
    if (!mounted) return;
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (_) => VictoryDialog(
        title: '${names.first} wins Snakes & Ladders!',
        rankedNames: names,
        onRematch: () {
          Navigator.of(context).pop();
          Navigator.of(context).pushReplacement(
            MaterialPageRoute(
              builder: (_) => SnakesGameView(seats: widget.seats),
            ),
          );
        },
        onHome: () {
          Navigator.of(context).pop();
          Navigator.of(context).popUntil((r) => r.isFirst);
        },
      ),
    );
  }

  int? _pendingTarget() {
    if (session.state.lastRoll == null) return null;
    return pendingMove(session.state).to;
  }

  /// Screen-reader description of the board state (announced on change).
  String _boardSemanticLabel(SnakesState s) {
    if (s.phase == SnakesPhase.gameOver) {
      final winner = s.players.reduce((a, b) => a.square >= b.square ? a : b);
      return 'Game over. ${winner.name} won with square ${winner.square}.';
    }
    final lead = s.players.reduce((a, b) => a.square >= b.square ? a : b);
    return '${s.currentPlayer.name} to roll. '
        '${lead.name} leads on square ${lead.square} of 100.';
  }

  // ------------------------------------------------------------------ HUD

  @override
  Widget build(BuildContext context) {
    final s = session.state;
    final movingToken = session.activeAnim?.tokenIndex;

    return Scaffold(
      appBar: PageAppBar(
        title: const Text('Snakes & Ladders'),
        actions: [
          const SoundToggleButton(),
          IconButton(
            icon: Icon(
              session.autoPlay ? Icons.auto_mode : Icons.auto_mode_outlined,
            ),
            color: session.autoPlay ? AppColors.gold : null,
            tooltip: session.autoPlay
                ? 'Autoplay on — tap to take over'
                : 'Autoplay — the table plays your turns',
            onPressed: session.toggleAutoPlay,
          ),
          IconButton(
            icon: const Icon(Icons.pause),
            onPressed: () => showSnakesPauseMenu(context, ref, session),
            tooltip: 'Pause / players',
          ),
          IconButton(
            icon: const Icon(Icons.bug_report_outlined),
            tooltip: 'Report an issue',
            onPressed: () => BugReportSheet.show(
              context,
              serverUrl: defaultServerUrl(),
            ),
          ),
        ],
      ),
      body: SafeArea(
        child: Column(
          children: [
            Expanded(
              child: LayoutBuilder(
                builder: (context, cons) {
                  // The board and the single home panel share one stage, so
                  // the ghost that leaves a home chip and the chip itself use
                  // the same coordinate space. The stage chooses the side
                  // rail when that buys a larger board (desktop), and the
                  // under-board strip when it does not (narrow phone).
                  final metrics = SnakesStageMetrics.layout(
                    available: cons.biggest,
                    players: s.players.length,
                  );
                  return SnakesStage(
                    metrics: metrics,
                    board: Semantics(
                      label: _boardSemanticLabel(s),
                      liveRegion: true,
                      child: CustomPaint(
                        painter: SnakesBoardPainter(
                          highlightSquare: s.phase == SnakesPhase.awaitingMove
                              ? _pendingTarget()
                              : null,
                        ),
                      ),
                    ),
                    home: _homeArea(metrics, s, movingToken),
                    overlays: [
                      ..._pawnWidgets(metrics, s, movingToken),
                      if (session.activeAnim != null) _ghost(metrics),
                    ],
                  );
                },
              ),
            ),
            _controls(s),
          ],
        ),
      ),
    );
  }

  // ------------------------------------------------------------- home area

  /// The one home panel. [SnakesStageMetrics] owns every size and centre;
  /// this method only decides who is still waiting and paints them. The
  /// moving pawn is omitted because the ghost draws it.
  Widget _homeArea(
    SnakesStageMetrics metrics,
    SnakesState s,
    int? movingToken,
  ) {
    final waiting = [
      for (final p in s.players)
        if (p.square == 0 && p.tokenIndex != movingToken) p,
    ];
    return SnakesHomePanel(
      metrics: metrics,
      waiting: waiting,
      totalPlayers: s.players.length,
      activePlayerId: s.currentPlayer.id,
      gameOver: s.phase == SnakesPhase.gameOver,
      chipBuilder: _pawnChip,
    );
  }

  /// A player's pawn waiting at home: just the player's colour. The one house
  /// in the caption is what marks the area — no per-seat houses, no numbers.
  Widget _pawnChip(SnakesPlayer p, double size) {
    final color = AppColors.snakesColors[p.tokenIndex];
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        gradient: RadialGradient(
          colors: [color.withValues(alpha: 0.95), color],
          stops: const [0.4, 1],
        ),
        border: Border.all(color: Colors.white, width: 1.5),
      ),
    );
  }

  // ---------------------------------------------------------------- pawns

  List<Widget> _pawnWidgets(
    SnakesStageMetrics metrics,
    SnakesState s,
    int? movingToken,
  ) {
    final cell = metrics.boardSize / 10;
    final grouped = <int, List<SnakesPlayer>>{};
    for (final p in s.players) {
      if (p.tokenIndex == movingToken) continue;
      // Square 0 is off-board: those pawns live in the home garages, and the
      // board has no cell for them (squareCenter(0) falls outside the grid).
      if (p.square <= 0) continue;
      grouped.putIfAbsent(p.square, () => []).add(p);
    }
    final widgets = <Widget>[];
    grouped.forEach((sq, players) {
      for (var i = 0; i < players.length; i++) {
        final p = players[i];
        final ang = 2 * math.pi * i / math.max(players.length, 1);
        final shift = players.length > 1 ? cell * 0.16 : 0.0;
        final c =
            metrics.boardOrigin +
            SnakesBoardPainter.squareCenter(
              sq,
              Size.square(metrics.boardSize),
            );
        widgets.add(
          AnimatedPositioned(
            key: ValueKey('pawn-${p.id}'),
            duration: const Duration(milliseconds: 220),
            curve: Curves.easeInOut,
            left: c.dx - cell * 0.28 + math.cos(ang) * shift,
            top: c.dy - cell * 0.28 + math.sin(ang) * shift,
            child: Pulse(
              active:
                  p.id == s.currentPlayer.id && s.phase != SnakesPhase.gameOver,
              child: _pawnDot(p, cell),
            ),
          ),
        );
      }
    });
    return widgets;
  }

  Widget _pawnDot(SnakesPlayer p, double cell) {
    final color = AppColors.snakesColors[p.tokenIndex];
    return Container(
      width: cell * 0.56,
      height: cell * 0.56,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        gradient: RadialGradient(
          colors: [color.withValues(alpha: 0.95), color],
          stops: const [0.4, 1],
        ),
        border: Border.all(color: Colors.white, width: 1.5),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.35),
            blurRadius: 3,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      child: Center(
        child: Text(
          '${p.tokenIndex + 1}',
          style: TextStyle(
            fontSize: cell * 0.28,
            color: Colors.white,
            fontWeight: FontWeight.w800,
          ),
        ),
      ),
    );
  }

  Widget _ghost(SnakesStageMetrics metrics) {
    final anim = session.activeAnim!;
    final step = _animStep.clamp(0, anim.waypoints.length - 1);
    final sq = anim.waypoints[step];
    final cell = metrics.boardSize / 10;
    // Waypoint 0 is "still at home": rest on that seat's chip in the shared
    // home area, so the walk visibly starts from home.
    final atHome = sq <= 0;
    final c = atHome
        ? metrics.homeChipCenter(anim.tokenIndex)
        : metrics.boardOrigin +
              SnakesBoardPainter.squareCenter(
                sq,
                Size.square(metrics.boardSize),
              );
    final size = atHome ? metrics.chipSize : cell * 0.62;
    final color =
        AppColors.snakesColors[anim.tokenIndex % AppColors.snakesColors.length];
    return Positioned(
      key: const ValueKey('ghost'),
      left: c.dx - size / 2,
      top: c.dy - size / 2,
      child: Container(
        width: size,
        height: size,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: color,
          border: Border.all(color: Colors.white, width: 2),
          boxShadow: [
            BoxShadow(
              color: color.withValues(alpha: 0.6),
              blurRadius: 10,
              spreadRadius: 2,
            ),
          ],
        ),
      ),
    );
  }

  // ------------------------------------------------------------- controls

  Widget _controls(SnakesState s) {
    final canRoll =
        !session.currentIsAI &&
        s.phase == SnakesPhase.awaitingRoll &&
        session.activeAnim == null;
    final subtitle = switch (s.phase) {
      SnakesPhase.gameOver => 'Game over',
      SnakesPhase.awaitingRoll when session.currentIsAI =>
        '${s.currentPlayer.name} is thinking…',
      SnakesPhase.awaitingRoll when session.autoPlay =>
        '${s.currentPlayer.name} rolls automatically…',
      SnakesPhase.awaitingRoll => 'Your roll, ${s.currentPlayer.name}!',
      SnakesPhase.awaitingMove => 'Moving…',
    };
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 12),
      child: Column(
        children: [
          Text(
            subtitle,
            style: const TextStyle(fontSize: 14, color: Colors.white70),
          ),
          const SizedBox(height: 6),
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              DiceWidget(
                value: s.lastRoll,
                rolling:
                    session.activeAnim != null && _animStep * _tickMs < _diceMs,
                enabled: canRoll,
                onTap: session.roll,
              ),
              const SizedBox(width: 20),
              FilledButton(
                onPressed: canRoll ? session.roll : null,
                child: Text(canRoll ? 'ROLL' : '…'),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
