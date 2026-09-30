import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../controllers/ludo_session.dart';
import '../../controllers/snakes_session.dart';
import '../../engine/core/player_profiles.dart';
import '../../engine/snakes/snakes_engine.dart';
import '../../providers/app_providers.dart';
import '../shared/dice_widget.dart';
import '../shared/victory_dialog.dart';
import '../theme.dart';
import 'snakes_board_painter.dart';
import 'snakes_overlays.dart';
import '../shared/sound_toggle_button.dart';
import '../shared/pulse.dart';

/// Full Snakes & Ladders game screen (2..10 players, human or bot seats).
class SnakesGameView extends ConsumerStatefulWidget {
  const SnakesGameView({super.key, required this.seats});

  final List<SeatSetup> seats;

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
    session = SnakesSession(
      seats: widget.seats,
      profiles: ref.read(profilesProvider.notifier),
      sound: ref.read(soundServiceProvider),
      onGameOver: _onGameOver,
    );
    session.addListener(_onSessionChanged);
  }

  @override
  void dispose() {
    _animTimer?.cancel();
    session.removeListener(_onSessionChanged);
    session.dispose();
    super.dispose();
  }

  void _onSessionChanged() {
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
      appBar: AppBar(
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
        ],
      ),
      body: SafeArea(
        child: Column(
          children: [
            Expanded(
              child: LayoutBuilder(
                builder: (context, cons) {
                  // The board keeps its square shape and the home area sits
                  // directly under it — inside the SAME Stack. A pawn leaving
                  // home is drawn by the ghost hop, so the home area and the
                  // ghost must share one coordinate space or the pawn would
                  // appear to start from nowhere.
                  final homeH = _homeStripH;
                  final boardSize = math.min(
                    cons.biggest.width,
                    math.max(cons.biggest.height - homeH, 0.0),
                  );
                  return Center(
                    child: SizedBox(
                      width: boardSize,
                      height: boardSize + homeH,
                      child: Stack(
                        clipBehavior: Clip.none,
                        children: [
                          Positioned(
                            left: 0,
                            top: 0,
                            child: Semantics(
                              label: _boardSemanticLabel(s),
                              liveRegion: true,
                              child: CustomPaint(
                                size: Size.square(boardSize),
                                painter: SnakesBoardPainter(
                                  highlightSquare:
                                      s.phase == SnakesPhase.awaitingMove
                                      ? _pendingTarget()
                                      : null,
                                ),
                              ),
                            ),
                          ),
                          ..._pawnWidgets(boardSize, s, movingToken),
                          _homeArea(boardSize, s, movingToken),
                          if (session.activeAnim != null) _ghost(boardSize),
                        ],
                      ),
                    ),
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

  /// One home area for the whole table: every player starts here, in a single
  /// panel under the board instead of a separate garage per seat. Fixed sizes
  /// so the painted pawns and the ghost's square-0 rest position come out of
  /// one formula.
  static const double _homePad = 8;
  static const double _homeCaptionH = 20;
  static const double _homeRowH = 40;
  static const double _chipGap = 6;
  static const double _chipMax = 34;

  /// Height reserved for the home area: a caption row plus one row of pawns,
  /// whatever the seat count — ten seats share the panel by shrinking their
  /// chips, never by growing a second area.
  static const double _homeStripH = _homePad * 2 + _homeCaptionH + _homeRowH;

  /// Diameter of a pawn chip, shrunk so every seat fits the panel's width.
  static double _chipSize(double boardSize, int players) {
    final n = math.max(players, 1);
    final avail = boardSize - _homePad * 2 - _chipGap * (n - 1);
    return math.min(_chipMax, math.max(avail / n, 12));
  }

  /// Centre of seat [slot]'s pawn while it waits at home, in the coordinate
  /// space it shares with the board. The chips are centred as one row, so the
  /// same call places the ghost that hops out of the panel.
  static Offset _chipCenter(double boardSize, int slot, int players) {
    final d = _chipSize(boardSize, players);
    final left = (boardSize - (players * d + (players - 1) * _chipGap)) / 2;
    return Offset(
      left + slot * (d + _chipGap) + d / 2,
      boardSize + _homePad + _homeCaptionH + _homeRowH / 2,
    );
  }

  /// The home area: ONE panel for the whole table, drawn directly under the
  /// board in the same coordinate space as the board and the ghost hop. Every
  /// pawn starts off-board at square 0 — the board itself numbers 1..100, so
  /// square 0 has no cell and used to render the starting pawns outside the
  /// board where they were clipped and invisible. Every seat's pawn waits
  /// here as its own colour chip; a pawn that has left is simply gone from the
  /// panel, and the pawn being animated is omitted because the ghost draws it.
  Widget _homeArea(double boardSize, SnakesState s, int? movingToken) {
    final waiting = [
      for (final p in s.players)
        if (p.square == 0 && p.tokenIndex != movingToken) p,
    ];
    final chip = _chipSize(boardSize, s.players.length);
    return Positioned(
      key: const ValueKey('home-area'),
      left: 0,
      top: boardSize,
      width: boardSize,
      height: _homeStripH,
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: AppColors.feltLight.withValues(alpha: 0.55),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: Colors.white24),
        ),
        child: Stack(
          clipBehavior: Clip.none,
          children: [
            Positioned(
              left: _homePad,
              right: _homePad,
              top: _homePad * 0.7,
              child: Row(
                children: [
                  const Icon(
                    Icons.home_rounded,
                    size: 15,
                    color: AppColors.gold,
                  ),
                  const SizedBox(width: 5),
                  const Text(
                    'Home',
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w800,
                      color: AppColors.ivory,
                    ),
                  ),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      waiting.isEmpty
                          ? 'every pawn is out'
                          : '${waiting.length} of ${s.players.length} waiting to enter',
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontSize: 11,
                        color: Colors.white60,
                      ),
                    ),
                  ),
                ],
              ),
            ),
            for (final p in waiting)
              // `_chipCenter` is in board space; the panel's own Stack starts
              // at the panel, so shift it up by the board's height.
              Positioned(
                key: ValueKey('home-pawn-${p.tokenIndex}'),
                left:
                    _chipCenter(boardSize, p.tokenIndex, s.players.length).dx -
                    chip / 2,
                top:
                    _chipCenter(boardSize, p.tokenIndex, s.players.length).dy -
                    boardSize -
                    chip / 2,
                child: Pulse(
                  active:
                      p.id == s.currentPlayer.id &&
                      s.phase != SnakesPhase.gameOver,
                  child: _pawnChip(p, chip),
                ),
              ),
          ],
        ),
      ),
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

  List<Widget> _pawnWidgets(double boardSize, SnakesState s, int? movingToken) {
    final cell = boardSize / 10;
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
        final c = SnakesBoardPainter.squareCenter(sq, Size.square(boardSize));
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

  Widget _ghost(double boardSize) {
    final anim = session.activeAnim!;
    final step = _animStep.clamp(0, anim.waypoints.length - 1);
    final sq = anim.waypoints[step];
    final cell = boardSize / 10;
    // Waypoint 0 is "still at home": rest on that seat's chip in the shared
    // home area, so the walk visibly starts from home.
    final atHome = sq <= 0;
    final players = session.state.players.length;
    final c = atHome
        ? _chipCenter(boardSize, anim.tokenIndex, players)
        : SnakesBoardPainter.squareCenter(sq, Size.square(boardSize));
    final size = atHome ? _chipSize(boardSize, players) : cell * 0.62;
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
