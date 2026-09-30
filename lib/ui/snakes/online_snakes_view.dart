import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../engine/snakes/snakes_engine.dart';
import '../../providers/app_providers.dart';
import '../../services/online_client.dart';
import '../../services/sound_service.dart';
import '../shared/dice_widget.dart';
import '../shared/seat_status_strip.dart';
import '../theme.dart';
import 'snakes_board_painter.dart';
import '../shared/sound_toggle_button.dart';
import '../shared/pulse.dart';

/// Online Snakes & Ladders game view: renders the authoritative server
/// snapshots ([OnlineClient.snakesState]) and forwards intents.
///
/// The roll leads to exactly one move; when it is this player's turn the
/// move intent is sent automatically after a short beat (so the roll stays
/// visible) — the server resolves the pending move and broadcasts the new
/// snapshot to everyone.
class OnlineSnakesView extends StatefulWidget {
  const OnlineSnakesView({
    super.key,
    required this.client,
    required this.onLeave,
  });

  final OnlineClient client;
  final VoidCallback onLeave;

  @override
  State<OnlineSnakesView> createState() => _OnlineSnakesViewState();
}

class _OnlineSnakesViewState extends State<OnlineSnakesView> {
  /// Guards the one-shot auto move intent per (player, roll, square).
  String? _autoMoveKey;

  /// Guards the game-over dialog.
  bool _gameOverShown = false;

  /// Whether the die is tumbling. The offline view reads this off the
  /// session's animation timeline; online there is no session, so the roll is
  /// timed here instead. The `rolling` flag was hardcoded false, which is why
  /// the online die never tumbled and simply snapped to its new face while the
  /// offline one rolled.
  bool _rolling = false;
  Timer? _rollTimer;

  /// The phase last seen, so a roll can be told apart from a plain re-render:
  /// awaitingRoll -> awaitingMove is exactly when the server has accepted a
  /// roll and published its value.
  SnakesPhase? _lastPhase;

  /// How long the die tumbles. Matches the online Ludo view, and fits inside
  /// the 700ms beat before the forced move is sent, so the roll is seen before
  /// the pawn moves.
  static const _rollMs = 600;

  @override
  void initState() {
    super.initState();
    widget.client.addListener(_onClientUpdate);
    // Online Snakes was the only game view that never made a sound: the Ludo
    // view gets its dice sound through LudoSession, and this view has no
    // session, so nothing was ever wired to the client's roll callback and a
    // whole game played in silence. Wired here, from the same provider the
    // local view uses, and detached again on dispose.
    widget.client.onRoll = _onRoll;
    _onClientUpdate();
  }

  void _onRoll() {
    ProviderScope.containerOf(
      context,
      listen: false,
    ).read(soundServiceProvider).dice();
    Haptics.light();
  }

  @override
  void didUpdateWidget(covariant OnlineSnakesView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.client != widget.client) {
      oldWidget.client.removeListener(_onClientUpdate);
      if (oldWidget.client.onRoll == _onRoll) oldWidget.client.onRoll = null;
      widget.client.addListener(_onClientUpdate);
      widget.client.onRoll = _onRoll;
      _onClientUpdate();
    }
  }

  @override
  void dispose() {
    widget.client.removeListener(_onClientUpdate);
    _rollTimer?.cancel();
    // Only clear the hook if it is still ours: a view replaced by another
    // must not silence the one that replaced it.
    if (widget.client.onRoll == _onRoll) widget.client.onRoll = null;
    super.dispose();
  }

  bool _isMyTurn(SnakesState s) =>
      !widget.client.isSpectator &&
      widget.client.started &&
      s.currentPlayer.id == widget.client.seatId;

  void _onClientUpdate() {
    if (!mounted) return;
    setState(() {});
    final notice = widget.client.leftNotice;
    if (notice != null) {
      widget.client.clearLeftNotice();
      // A seat can be announced mid-frame; a toast has to wait for the frame.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _showNotice(notice);
      });
    }
    final s = widget.client.snakesState;
    if (s == null) return;

    if (_lastPhase == SnakesPhase.awaitingRoll &&
        s.phase == SnakesPhase.awaitingMove) {
      // The roll landed: tumble the die, then settle on the face.
      _rollTimer?.cancel();
      setState(() => _rolling = true);
      _rollTimer = Timer(const Duration(milliseconds: _rollMs), () {
        if (mounted) setState(() => _rolling = false);
      });
    } else if (_lastPhase != s.phase) {
      // A new turn (or the game ending) must never leave a die mid-tumble.
      _rollTimer?.cancel();
      if (_rolling) setState(() => _rolling = false);
    }
    _lastPhase = s.phase;

    if (s.phase == SnakesPhase.gameOver) {
      if (!_gameOverShown) {
        _gameOverShown = true;
        _showGameOver(s);
      }
      return;
    }

    // Auto-resolve my pending move (the single possible one) after a beat.
    if (s.phase == SnakesPhase.awaitingMove && _isMyTurn(s)) {
      final key =
          '${s.currentPlayerIndex}:${s.lastRoll}:${s.currentPlayer.square}';
      if (key != _autoMoveKey) {
        _autoMoveKey = key;
        Timer(const Duration(milliseconds: 700), () {
          final cur = widget.client.snakesState;
          if (cur != null &&
              cur.phase == SnakesPhase.awaitingMove &&
              _isMyTurn(cur)) {
            widget.client.sendSnakesMove();
          }
        });
      }
    }
  }

  void _showGameOver(SnakesState s) {
    if (!mounted) return;
    final winner = s.rankings.isNotEmpty ? s.rankings.first : null;
    final winnerName = winner == null
        ? '?'
        : s.players
              .firstWhere((p) => p.id == winner, orElse: () => s.players.first)
              .name;
    final iWon = winner == widget.client.seatId;
    showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (context) => AlertDialog(
        backgroundColor: AppColors.feltLight,
        title: Text(iWon ? 'You win!' : '$winnerName wins!'),
        content: Text(
          'Final standings:\n${[for (var i = 0; i < s.rankings.length; i++) '${i + 1}. ${s.players.firstWhere((p) => p.id == s.rankings[i], orElse: () => s.players.first).name}'].join('\n')}',
        ),
        actions: [
          FilledButton(
            // The dialog is not barrier-dismissible, so leaving without
            // popping it first left the player staring at "Back to lobby"
            // forever: the route underneath was gone, the dialog was not.
            onPressed: () {
              Navigator.of(context).pop();
              widget.onLeave();
            },
            child: const Text('Back to lobby'),
          ),
        ],
      ),
    );
  }

  void _showNotice(String text) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: Text(text),
          behavior: SnackBarBehavior.floating,
          duration: const Duration(seconds: 4),
        ),
      );
  }

  /// Walking out mid-game is a statement: the seat is forfeited, the pawn
  /// comes off the board, and the others are told who went — so it asks
  /// first, because none of that can be undone by coming back. Hanging up
  /// without saying so would leave the table staring at a pawn that simply
  /// stops moving, which looks exactly like a broken game.
  Future<void> _leave() async {
    final sure = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Leave the game?'),
        content: const Text(
          'Your pawn leaves the board and the other players are told you '
          "went. You can't rejoin this game after that.",
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Stay'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('Leave'),
          ),
        ],
      ),
    );
    if (sure != true || !mounted) return;
    await widget.client.sendLeave();
    widget.onLeave();
  }

  // ------------------------------------------------------------------ HUD

  @override
  Widget build(BuildContext context) {
    final s = widget.client.snakesState;
    if (s == null) {
      return const Center(child: CircularProgressIndicator());
    }
    final myTurn = _isMyTurn(s);
    final canRoll = myTurn && s.phase == SnakesPhase.awaitingRoll;
    final status = switch (s.phase) {
      SnakesPhase.gameOver => 'Game over',
      SnakesPhase.awaitingRoll when myTurn => 'Your roll!',
      SnakesPhase.awaitingRoll when widget.client.isSpectator => 'Spectating',
      SnakesPhase.awaitingRoll => '${s.currentPlayer.name} is rolling...',
      SnakesPhase.awaitingMove =>
        myTurn ? 'Moving...' : '${s.currentPlayer.name} is moving...',
    };

    return Scaffold(
      appBar: AppBar(
        title: const Text('Snakes & Ladders'),
        actions: [
          const SoundToggleButton(),
          IconButton(
            icon: Icon(
              widget.client.iAmAuto
                  ? Icons.auto_mode
                  : Icons.auto_mode_outlined,
            ),
            color: widget.client.iAmAuto ? AppColors.gold : null,
            tooltip: widget.client.isSpectator
                ? 'Spectators watch; they do not hand seats over'
                : widget.client.iAmAuto
                ? 'Autoplay on — tap to take over'
                : 'Autoplay — the table plays your turns',
            onPressed: widget.client.isSpectator
                ? null
                : () => widget.client.sendAutoplay(!widget.client.iAmAuto),
          ),
          IconButton(
            icon: const Icon(Icons.logout),
            tooltip: 'Leave game',
            onPressed: _leave,
          ),
        ],
      ),
      body: SafeArea(
        child: Column(
          children: [
            SeatStatusStrip(
              seats: widget.client.lobbySeats,
              mySeatId: widget.client.seatId,
            ),
            Expanded(
              child: Center(
                child: LayoutBuilder(
                  builder: (context, cons) {
                    // The board keeps its square shape and the home area sits
                    // directly under it, inside the same Stack — the layout
                    // the offline view already uses. Online had no home area
                    // at all: the board numbers 1..100, so square 0 has no
                    // cell, and squareCenter(0) fell through the
                    // boustrophedon maths onto square 10's cell. Every pawn
                    // still waiting to enter was drawn on top of a numbered
                    // square, which is why the home area looked missing.
                    final homeH = _homeStripH;
                    final boardSize = math.min(
                      cons.biggest.width,
                      math.max(cons.biggest.height - homeH, 0.0),
                    );
                    return SizedBox(
                      width: boardSize,
                      height: boardSize + homeH,
                      child: Stack(
                        clipBehavior: Clip.none,
                        children: [
                          CustomPaint(
                            size: Size.square(boardSize),
                            painter: SnakesBoardPainter(
                              highlightSquare:
                                  s.phase == SnakesPhase.awaitingMove
                                  ? pendingMove(s).to
                                  : null,
                            ),
                          ),
                          ..._pawnWidgets(s, boardSize),
                          _homeArea(boardSize, s),
                        ],
                      ),
                    );
                  },
                ),
              ),
            ),
            Text(
              status,
              style: const TextStyle(fontSize: 14, color: Colors.white70),
            ),
            const SizedBox(height: 6),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 4, 16, 12),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  DiceWidget(
                    value: s.lastRoll,
                    rolling: _rolling,
                    enabled: canRoll,
                    onTap: widget.client.sendRoll,
                  ),
                  const SizedBox(width: 20),
                  FilledButton(
                    onPressed: canRoll ? widget.client.sendRoll : null,
                    child: Text(canRoll ? 'ROLL' : '...'),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  // ------------------------------------------------------------- home area

  // Same geometry as the offline view, so both games lay the panel out the
  // same way and a player moving between them sees the same board furniture.

  /// One home area for the whole table, drawn directly under the board.
  /// Fixed sizes so the chips come out of one formula.
  static const double _homePad = 8;
  static const double _homeCaptionH = 20;
  static const double _homeRowH = 40;
  static const double _chipGap = 6;
  static const double _chipMax = 34;

  /// Caption row plus one row of pawns, whatever the seat count.
  static const double _homeStripH = _homePad * 2 + _homeCaptionH + _homeRowH;

  /// Diameter of a pawn chip, shrunk so every seat fits the panel's width.
  static double _chipSize(double boardSize, int players) {
    final n = math.max(players, 1);
    final avail = boardSize - _homePad * 2 - _chipGap * (n - 1);
    return math.min(_chipMax, math.max(avail / n, 12));
  }

  /// The home area: one panel for the whole table, holding every pawn that has
  /// not yet entered the board. A pawn that has left is simply gone from the
  /// panel.
  Widget _homeArea(double boardSize, SnakesState s) {
    final waiting = [
      for (final p in s.players)
        if (p.square == 0) p,
    ];
    final d = _chipSize(boardSize, s.players.length);
    final total = s.players.length * d + (s.players.length - 1) * _chipGap;
    final left = (boardSize - total) / 2;
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
              Positioned(
                key: ValueKey('home-pawn-${p.tokenIndex}'),
                left: left + p.tokenIndex * (d + _chipGap),
                top: _homePad + _homeCaptionH + (_homeRowH - d) / 2,
                width: d,
                height: d,
                child: Pulse(
                  active:
                      p.id == s.currentPlayer.id &&
                      s.phase != SnakesPhase.gameOver,
                  child: _pawnDot(p, d),
                ),
              ),
          ],
        ),
      ),
    );
  }

  /// A seat's pawn as a filled circle in its own colour.
  Widget _pawnDot(SnakesPlayer p, double d) {
    final color = AppColors.snakesColors[p.tokenIndex];
    return Container(
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        gradient: RadialGradient(
          colors: [color.withValues(alpha: 0.95), color],
          stops: const [0.4, 1],
        ),
        border: Border.all(color: Colors.white, width: 1.5),
      ),
      child: Center(
        child: Text(
          '${p.tokenIndex + 1}',
          style: TextStyle(
            fontSize: d * 0.4,
            color: Colors.white,
            fontWeight: FontWeight.w800,
          ),
        ),
      ),
    );
  }

  List<Widget> _pawnWidgets(SnakesState s, double boardSize) {
    final cell = boardSize / 10;
    final bySquare = <int, List<SnakesPlayer>>{};
    for (final p in s.players) {
      // Square 0 has no board cell; those pawns live in the home strip, and
      // drawing them here too would put them on top of square 10.
      if (p.square == 0) continue;
      bySquare.putIfAbsent(p.square, () => []).add(p);
    }
    final widgets = <Widget>[];
    for (final entry in bySquare.entries) {
      final c = SnakesBoardPainter.squareCenter(
        entry.key,
        Size.square(boardSize),
      );
      final group = entry.value;
      for (var i = 0; i < group.length; i++) {
        final p = group[i];
        final color = AppColors.snakesColors[p.tokenIndex];
        widgets.add(
          Positioned(
            // Distinct from the home strip's 'home-pawn-<n>' key, and the same
            // 'pawn-<id>' the offline view uses, so "this pawn is on the
            // board" and "this pawn is waiting at home" are separately
            // checkable rather than one overlapping set of circles.
            key: ValueKey('pawn-${p.id}'),
            left: c.dx - cell * 0.28 + (i * 3.0),
            top: c.dy - cell * 0.28 - (i * 3.0),
            child: Pulse(
              active:
                  p.id == s.currentPlayer.id && s.phase != SnakesPhase.gameOver,
              child: Container(
                width: cell * 0.56,
                height: cell * 0.56,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  gradient: RadialGradient(
                    colors: [color.withValues(alpha: 0.95), color],
                    stops: const [0.4, 1],
                  ),
                  border: Border.all(color: Colors.white, width: 1.5),
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
              ),
            ),
          ),
        );
      }
    }
    return widgets;
  }
}
