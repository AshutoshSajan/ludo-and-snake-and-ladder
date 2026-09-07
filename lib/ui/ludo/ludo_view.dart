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
import '../../services/online_client.dart';
import '../../services/sound_service.dart';
import '../shared/dice_widget.dart';
import '../shared/victory_dialog.dart';
import '../theme.dart';
import 'ludo_board_painter.dart';
import 'ludo_overlays.dart';
import 'ludo_token_layer.dart';

/// Full Ludo game screen: board, tokens, dice, HUD and pause menu.
class LudoGameView extends ConsumerStatefulWidget {
  const LudoGameView({
    super.key,
    this.seats = const [],
    this.onlineClient,
    this.onlineSeatId,
  });

  final List<SeatSetup> seats;

  /// When set, the game is driven by this authoritative-server connection
  /// (online mode): the session sends intents and adopts snapshots.
  final OnlineClient? onlineClient;
  final String? onlineSeatId;

  @override
  ConsumerState<LudoGameView> createState() => _LudoGameViewState();
}

class _LudoGameViewState extends ConsumerState<LudoGameView>
    with SingleTickerProviderStateMixin {
  late LudoSession session;
  int _animStep = 0;
  Timer? _animTimer;
  Timer? _diceTimer;
  bool _diceRolling = false;
  int _lastSeenSeq = -1;
  int? _hintToken;
  late final AnimationController _fx;
  DateTime _stepStart = DateTime.now();

  @override
  void initState() {
    super.initState();
    _fx = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1500),
    )..repeat();
    final online = widget.onlineClient;
    if (online != null) {
      session = LudoSession.online(
        client: online,
        seatId: widget.onlineSeatId!,
        profiles: ref.read(profilesProvider.notifier),
        sound: ref.read(soundServiceProvider),
        onGameOver: _onGameOver,
      );
    } else {
      session = LudoSession(
        seats: widget.seats,
        profiles: ref.read(profilesProvider.notifier),
        sound: ref.read(soundServiceProvider),
        onGameOver: _onGameOver,
      );
    }
    session.addListener(_onSessionChanged);
    widget.onlineClient?.addListener(_onClientChanged);
  }

  @override
  void dispose() {
    _animTimer?.cancel();
    _diceTimer?.cancel();
    _fx.dispose();
    session.removeListener(_onSessionChanged);
    widget.onlineClient?.removeListener(_onClientChanged);
    session.dispose();
    super.dispose();
  }

  /// The online client notifies for transport events too (reconnecting,
  /// errors) — the banner reads its status on every rebuild.
  void _onClientChanged() {
    if (mounted) setState(() {});
  }

  void _onSessionChanged() {
    // Kick off the 3D dice tumble whenever a fresh roll appears — tracked by
    // roll sequence, so it tumbles even when the same number comes up again.
    if (session.state.rollSeq != _lastSeenSeq) {
      _lastSeenSeq = session.state.rollSeq;
      _hintToken = null; // a new roll invalidates any shown hint
      _diceTimer?.cancel();
      _diceRolling = true;
      _diceTimer = Timer(const Duration(milliseconds: 600), () {
        if (mounted) setState(() => _diceRolling = false);
      });
    }
    final anim = session.activeAnim;
    _animTimer?.cancel();
    _animStep = 0;
    _stepStart = DateTime.now();
    if (anim != null) {
      _animTimer = Timer.periodic(Duration(milliseconds: anim.stepMs), (t) {
        if (!mounted) return t.cancel();
        setState(() {
          _animStep++;
          _stepStart = DateTime.now();
        });
        if (_animStep >= anim.waypoints.length - 1) t.cancel();
      });
    }
    if (mounted) setState(() {});
  }

  void _onGameOver(LudoState s) {
    // Online results belong to remote players — only local games update
    // profile streaks and leaderboards.
    if (!session.isOnline) {
      ref
          .read(profilesProvider.notifier)
          .recordResults(GameKind.ludo, s.rankings);
    }
    final names = [
      for (final id in s.rankings)
        s.players.where((p) => p.id == id).firstOrNull?.name ?? 'Player',
    ];
    if (!mounted) return;
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (_) => VictoryDialog(
        title: '${names.first} wins Ludo!',
        rankedNames: names,
        // No local rematch against a server-owned game — leave instead.
        onRematch: session.isOnline
            ? null
            : () {
                Navigator.of(context).pop(); // dialog
                Navigator.of(context).pushReplacement(
                  MaterialPageRoute(
                    builder: (_) => LudoGameView(seats: widget.seats),
                  ),
                );
              },
        onHome: () {
          Navigator.of(context).pop(); // dialog
          Navigator.of(context).popUntil((r) => r.isFirst);
        },
      ),
    );
  }

  /// Screen-reader description of the board state. CustomPaint content is
  /// invisible to assistive tech, so the view supplies the live summary.
  String _boardSemanticLabel(LudoState s, bool hasMoves) {
    final name = s.currentPlayer.name;
    return switch (s.phase) {
      LudoPhase.awaitingRoll => '$name to roll the dice.',
      LudoPhase.awaitingMove =>
        hasMoves
            ? '$name rolled ${s.lastRoll}. '
                  'Tap a highlighted pawn to move it.'
            : '$name rolled ${s.lastRoll}. No possible move.',
      LudoPhase.gameOver =>
        'Game over. '
            '${s.players.where((p) => p.finished).map((p) => p.name).join(', ')} '
            'finished.',
    };
  }

  @override
  Widget build(BuildContext context) {
    final s = session.state;
    // Online games surface transport trouble right on the board.
    final reconnecting = widget.onlineClient?.status ==
        OnlineStatus.reconnecting;
    // Battery saver: stop the continuous effects ticker when the setting is
    // off (one-shot animations — dice tumble, token hops — still play).
    final animationsOn = ref.watch(animationsEnabledProvider);
    if (animationsOn && !_fx.isAnimating) {
      _fx.repeat();
    } else if (!animationsOn && _fx.isAnimating) {
      _fx.stop();
    }
    final movable = <int>{
      if (s.phase == LudoPhase.awaitingMove &&
          !session.currentIsAI &&
          !session.isBusy)
        for (final m in legalMoves(s)) m.tokenIndex,
    };
    // A stale hint (different turn / no longer movable) clears itself.
    if (_hintToken != null && (!movable.contains(_hintToken))) {
      _hintToken = null;
    }

    return Scaffold(
      appBar: AppBar(
        title: const Text('Ludo'),
        actions: [
          IconButton(
            icon: const Icon(Icons.undo),
            tooltip: session.canUndo ? 'Undo last move' : 'Nothing to undo',
            onPressed: session.canUndo
                ? () {
                    Haptics.light();
                    setState(() => _hintToken = null);
                    session.undo();
                  }
                : null,
          ),
          IconButton(
            icon: const Icon(Icons.lightbulb_outline),
            tooltip: _hintToken == null
                ? 'Hint (best move)'
                : 'Hint shown — tap a glowing pawn',
            onPressed: session.canHint
                ? () => setState(() => _hintToken = session.hintTokenIndex())
                : null,
          ),
          if (!session.isOnline)
            IconButton(
              icon: Icon(
                session.autoPlay ? Icons.auto_mode : Icons.auto_mode_outlined,
              ),
              color: session.autoPlay ? AppColors.gold : null,
              tooltip: session.autoPlay
                  ? 'Autoplay on — tap to stop'
                  : 'Autoplay (take a break)',
              onPressed: session.toggleAutoPlay,
            ),
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
            if (reconnecting)
              Material(
                color: AppColors.danger,
                child: Padding(
                  padding:
                      const EdgeInsets.symmetric(vertical: 6, horizontal: 12),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      const SizedBox(
                        width: 14,
                        height: 14,
                        child: CircularProgressIndicator(
                            strokeWidth: 2, color: Colors.white),
                      ),
                      const SizedBox(width: 10),
                      Text('Connection lost — reconnecting…',
                          style: TextStyle(
                              color: Colors.white.withAlpha(230),
                              fontSize: 13)),
                    ],
                  ),
                ),
              ),
            Expanded(
              child: Semantics(
                label: _boardSemanticLabel(s, movable.isNotEmpty),
                liveRegion: true,
                child: Stack(
                  children: [
                    Center(
                      child: AspectRatio(
                        aspectRatio: 1,
                        child: LayoutBuilder(
                          builder: (context, cons) {
                            final boardSize = cons.biggest.width;
                            final highlights = {
                              for (final m in legalMoves(s))
                                if (movable.isNotEmpty &&
                                    m.to >= 0 &&
                                    m.to <= 50)
                                  LudoBoard.absCell(
                                    s.currentPlayer.color,
                                    m.to,
                                  ),
                            };
                            final playerNames = {
                              for (final p in s.players) p.color: p.name,
                            };
                            // Rebuild every _fx tick: corner breathing glow, spinning
                            // rings and the per-step hop bounce all live off this.
                            return AnimatedBuilder(
                              animation: _fx,
                              builder: (context, _) {
                                final pulse =
                                    0.5 +
                                    0.5 * math.sin(_fx.value * 2 * math.pi);
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
                                      hintTokenIndex: _hintToken,
                                      spinAngle: spin,
                                      bounce: bounce,
                                    ),
                                  ],
                                );
                              },
                            );
                          },
                        ),
                      ),
                    ),
                    // One die per player, pinned to the outer felt corners of the
                    // play area — outside the board, never inside a player's yard.
                    for (var i = 0; i < s.players.length; i++)
                      _cornerDice(s, i),
                  ],
                ),
              ),
            ),
            _controls(s),
          ],
        ),
      ),
    );
  }

  // -------------------------------------------------- per-corner dice HUD

  /// One small die pinned to each player's outer corner of the play area
  /// (the felt margin around the board), so every human can reach their own
  /// dice and none of them sit inside a player's yard.
  Widget _cornerDice(LudoState s, int i) {
    final p = s.players[i];
    final isCurrent = i == s.currentPlayerIndex && !p.finished;
    final canRoll =
        isCurrent &&
        !session.currentIsAI &&
        s.phase == LudoPhase.awaitingRoll &&
        !session.isBusy;
    final alignment = switch (p.color) {
      LudoColor.green => Alignment.topLeft,
      LudoColor.yellow => Alignment.topRight,
      LudoColor.red => Alignment.bottomLeft,
      LudoColor.blue => Alignment.bottomRight,
    };
    return Align(
      alignment: alignment,
      child: Padding(
        padding: const EdgeInsets.all(10),
        child: DiceWidget(
          value: isCurrent ? s.lastRoll : null,
          rolling: _diceRolling && isCurrent,
          enabled: canRoll,
          onTap: session.roll,
          size: (MediaQuery.sizeOf(context).shortestSide * 0.15).clamp(
            60.0,
            92.0,
          ),
          accent: AppColors.ludo(p.color),
        ),
      ),
    );
  }

  // ------------------------------------------------------------- controls

  Widget _controls(LudoState s) {
    final subtitle = switch (s.phase) {
      LudoPhase.gameOver => 'Game over',
      LudoPhase.awaitingRoll when session.currentIsAI =>
        '${s.currentPlayer.name} is thinking…',
      LudoPhase.awaitingRoll => 'Your roll, ${s.currentPlayer.name}!',
      LudoPhase.awaitingMove => 'Pick a token to move',
    };
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 12),
      child: Text(
        subtitle,
        style: const TextStyle(fontSize: 14, color: Colors.white70),
      ),
    );
  }

  // ---------------------------------------------------------- pause menu

  void _showPauseMenu() => showLudoPauseMenu(context, ref, session);
}
