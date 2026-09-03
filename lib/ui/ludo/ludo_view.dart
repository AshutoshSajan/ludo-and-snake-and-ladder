import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../controllers/ludo_session.dart';
import '../../engine/core/player_profiles.dart';
import '../../engine/ludo/ludo_board.dart';
import '../../engine/ludo/ludo_models.dart';
import '../../engine/ludo/ludo_rules.dart';
import '../../providers/app_providers.dart';
import '../shared/dice_widget.dart';
import '../shared/victory_dialog.dart';
import '../theme.dart';
import 'ludo_board_painter.dart';
import 'ludo_overlays.dart';
import 'ludo_token_layer.dart';

/// Full Ludo game screen: board, tokens, dice, HUD and pause menu.
class LudoGameView extends ConsumerStatefulWidget {
  const LudoGameView({super.key, required this.seats});

  final List<SeatSetup> seats;

  @override
  ConsumerState<LudoGameView> createState() => _LudoGameViewState();
}

class _LudoGameViewState extends ConsumerState<LudoGameView>
    with SingleTickerProviderStateMixin {
  late LudoSession session;
  int _animStep = 0;
  Timer? _animTimer;
  late final AnimationController _fx;
  DateTime _stepStart = DateTime.now();

  @override
  void initState() {
    super.initState();
    _fx = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1500),
    )..repeat();
    session = LudoSession(
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
    _fx.dispose();
    session.removeListener(_onSessionChanged);
    session.dispose();
    super.dispose();
  }

  void _onSessionChanged() {
    final anim = session.activeAnim;
    _animTimer?.cancel();
    _animStep = 0;
    _stepStart = DateTime.now();
    if (anim != null) {
      _animTimer = Timer.periodic(
        Duration(milliseconds: anim.stepMs),
        (t) {
          if (!mounted) return t.cancel();
          setState(() {
            _animStep++;
            _stepStart = DateTime.now();
          });
          if (_animStep >= anim.waypoints.length - 1) t.cancel();
        },
      );
    }
    if (mounted) setState(() {});
  }

  void _onGameOver(LudoState s) {
    ref
        .read(profilesProvider.notifier)
        .recordResults(GameKind.ludo, s.rankings);
    final names = [
      for (final id in s.rankings)
        s.players.where((p) => p.id == id).firstOrNull?.name ?? 'Player'
    ];
    if (!mounted) return;
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (_) => VictoryDialog(
        title: '${names.first} wins Ludo!',
        rankedNames: names,
        onRematch: () {
          Navigator.of(context).pop(); // dialog
          Navigator.of(context).pushReplacement(MaterialPageRoute(
              builder: (_) => LudoGameView(seats: widget.seats)));
        },
        onHome: () {
          Navigator.of(context).pop(); // dialog
          Navigator.of(context).popUntil((r) => r.isFirst);
        },
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final s = session.state;
    final movable = <int>{
      if (s.phase == LudoPhase.awaitingMove &&
          !session.currentIsAI &&
          !session.isBusy)
        for (final m in legalMoves(s)) m.tokenIndex
    };

    return Scaffold(
      appBar: AppBar(
        title: const Text('Ludo'),
        actions: [
          IconButton(
            icon: const Icon(Icons.pause),
            onPressed: _showPauseMenu,
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
                    final highlights = {
                      for (final m in legalMoves(s))
                        if (movable.isNotEmpty && m.to >= 0 && m.to <= 50)
                          LudoBoard.absCell(s.currentPlayer.color, m.to)
                    };
                    final playerNames = {
                      for (final p in s.players) p.color: p.name
                    };
                    // Rebuild every _fx tick: corner breathing glow, spinning
                    // rings and the per-step hop bounce all live off this.
                    return AnimatedBuilder(
                      animation: _fx,
                      builder: (context, _) {
                        final pulse =
                            0.5 + 0.5 * math.sin(_fx.value * 2 * math.pi);
                        final spin = _fx.value * 2 * math.pi;
                        final anim = session.activeAnim;
                        final bounce = anim == null
                            ? 0.0
                            : (DateTime.now()
                                    .difference(_stepStart)
                                    .inMilliseconds /
                                    anim.stepMs)
                                .clamp(0.0, 1.0);
                        return Stack(
                          children: [
                            CustomPaint(
                              size: Size.square(boardSize),
                              painter: LudoBoardPainter(
                                highlightCells: highlights,
                                playerNames: playerNames,
                                activeColor: s.currentPlayer.color,
                                pulse: pulse,
                                repaint: _fx,
                              ),
                            ),
                            LudoTokenLayer(
                              state: s,
                              boardSize: boardSize,
                              movableTokenIndices: movable,
                              onTapToken: session.tapToken,
                              anim: anim,
                              animStep: _animStep,
                              currentPlayerIndex: s.currentPlayerIndex,
                              spinAngle: spin,
                              bounce: bounce,
                            ),
                          ],
                        );
                      },
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

  // ------------------------------------------------------------------ HUD

  Widget _playerStrip(LudoState s) {
    return SizedBox(
      height: 64,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        itemCount: s.players.length,
        separatorBuilder: (_, _) => const SizedBox(width: 8),
        itemBuilder: (context, i) {
          final p = s.players[i];
          final isCurrent = i == s.currentPlayerIndex && !p.finished;
          final homeCount = s.tokensOf(i).where((t) => t.isHome).length;
          return AnimatedContainer(
            duration: const Duration(milliseconds: 250),
            padding: const EdgeInsets.symmetric(horizontal: 12),
            decoration: BoxDecoration(
              color: isCurrent
                  ? AppColors.ludo(p.color).withValues(alpha: 0.85)
                  : AppColors.feltLight,
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
                if (p.finished)
                  const Padding(
                    padding: EdgeInsets.only(left: 4),
                    child: Text('🏁', style: TextStyle(fontSize: 13)),
                  )
                else ...[
                  const SizedBox(width: 6),
                  Text('🏠$homeCount/4',
                      style: TextStyle(
                          fontSize: 12,
                          color: isCurrent ? Colors.white : Colors.white60)),
                ],
              ],
            ),
          );
        },
      ),
    );
  }

  // ------------------------------------------------------------- controls

  Widget _controls(LudoState s) {
    final humanTurn = !session.currentIsAI && s.phase != LudoPhase.gameOver;
    final canRoll =
        humanTurn && s.phase == LudoPhase.awaitingRoll && !session.isBusy;
    final subtitle = switch (s.phase) {
      LudoPhase.gameOver => 'Game over',
      LudoPhase.awaitingRoll when session.currentIsAI =>
        '${s.currentPlayer.name} is thinking…',
      LudoPhase.awaitingRoll => 'Your roll, ${s.currentPlayer.name}!',
      LudoPhase.awaitingMove => 'Pick a token to move',
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

  // ---------------------------------------------------------- pause menu

  void _showPauseMenu() => showLudoPauseMenu(context, ref, session);

}
