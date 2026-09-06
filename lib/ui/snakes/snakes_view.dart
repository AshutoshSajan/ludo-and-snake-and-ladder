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
      _animTimer = Timer.periodic(const Duration(milliseconds: 240), (t) {
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
        s.players.where((p) => p.id == id).firstOrNull?.name ?? 'Player'
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
          Navigator.of(context).pushReplacement(MaterialPageRoute(
              builder: (_) => SnakesGameView(seats: widget.seats)));
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
      final winner =
          s.players.reduce((a, b) => a.square >= b.square ? a : b);
      return 'Game over. ${winner.name} won with square ${winner.square}.';
    }
    final lead = s.players.reduce((a, b) => a.square >= b.square ? a : b);
    return '${s.currentPlayer.name} to roll. '
        '${lead.name} leads on square ${lead.square} of 100.';
  }

  // ------------------------------------------------------------------ HUD

  Widget _playerStrip(SnakesState s) {
    return SizedBox(
      height: 64,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        itemCount: s.players.length,
        separatorBuilder: (_, _) => const SizedBox(width: 8),
        itemBuilder: (context, i) {
          final p = s.players[i];
          final isCurrent = i == s.currentPlayerIndex;
          final color = AppColors.snakesColors[p.tokenIndex];
          return AnimatedContainer(
            duration: const Duration(milliseconds: 250),
            padding: const EdgeInsets.symmetric(horizontal: 12),
            decoration: BoxDecoration(
              color: isCurrent ? color.withValues(alpha: 0.85) : AppColors.feltLight,
              borderRadius: BorderRadius.circular(14),
              border: Border.all(
                color: isCurrent ? AppColors.gold : Colors.white24,
                width: isCurrent ? 2 : 1,
              ),
            ),
            child: Row(
              children: [
                Icon(p.isAI ? Icons.smart_toy : Icons.person,
                    size: 18,
                    color: isCurrent ? Colors.white : Colors.white70),
                const SizedBox(width: 6),
                Text(p.name,
                    style: TextStyle(
                      color: isCurrent ? Colors.white : AppColors.ivory,
                      fontWeight: FontWeight.w700,
                      fontSize: 13,
                    )),
                const SizedBox(width: 6),
                Text(p.square == 0 ? 'start' : '#${p.square}',
                    style: TextStyle(
                        fontSize: 12,
                        color: isCurrent ? Colors.white : Colors.white60)),
              ],
            ),
          );
        },
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final s = session.state;
    final movingToken = session.activeAnim?.tokenIndex;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Snakes & Ladders'),
        actions: [
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
            _playerStrip(s),
            Expanded(
              child: Center(
                child: AspectRatio(
                  aspectRatio: 1,
                  child: LayoutBuilder(builder: (context, cons) {
                    final boardSize = cons.biggest.width;
                    return Stack(
                      children: [
                        Semantics(
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
                        ..._pawnWidgets(boardSize, s, movingToken),
                        if (session.activeAnim != null) _ghost(boardSize),
                      ],
                    );
                  }),
                ),
              ),
            ),
            _controls(s),
          ],
        ),
      ),
    );
  }

  // ---------------------------------------------------------------- pawns

  List<Widget> _pawnWidgets(
      double boardSize, SnakesState s, int? movingToken) {
    final cell = boardSize / 10;
    final grouped = <int, List<SnakesPlayer>>{};
    for (final p in s.players) {
      if (p.tokenIndex == movingToken) continue;
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
            child: _pawnDot(p, cell),
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
    final c = SnakesBoardPainter.squareCenter(sq, Size.square(boardSize));
    final color =
        AppColors.snakesColors[anim.tokenIndex % AppColors.snakesColors.length];
    return Positioned(
      left: c.dx - cell * 0.31,
      top: c.dy - cell * 0.31,
      child: Container(
        width: cell * 0.62,
        height: cell * 0.62,
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
    final canRoll = !session.currentIsAI &&
        s.phase == SnakesPhase.awaitingRoll &&
        session.activeAnim == null;
    final subtitle = switch (s.phase) {
      SnakesPhase.gameOver => 'Game over',
      SnakesPhase.awaitingRoll when session.currentIsAI =>
        '${s.currentPlayer.name} is rolling…',
      SnakesPhase.awaitingRoll => 'Your roll, ${s.currentPlayer.name}!',
      SnakesPhase.awaitingMove => 'Moving…',
    };
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 12),
      child: Column(
        children: [
          Text(subtitle,
              style: const TextStyle(fontSize: 14, color: Colors.white70)),
          const SizedBox(height: 6),
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              DiceWidget(
                value: s.lastRoll,
                rolling: false,
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
