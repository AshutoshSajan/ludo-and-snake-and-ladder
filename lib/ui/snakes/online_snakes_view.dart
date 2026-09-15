import 'dart:async';

import 'package:flutter/material.dart';

import '../../engine/snakes/snakes_engine.dart';
import '../../services/online_client.dart';
import '../shared/dice_widget.dart';
import '../theme.dart';
import 'snakes_board_painter.dart';

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

  @override
  void initState() {
    super.initState();
    widget.client.addListener(_onClientUpdate);
    _onClientUpdate();
  }

  @override
  void didUpdateWidget(covariant OnlineSnakesView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.client != widget.client) {
      oldWidget.client.removeListener(_onClientUpdate);
      widget.client.addListener(_onClientUpdate);
      _onClientUpdate();
    }
  }

  @override
  void dispose() {
    widget.client.removeListener(_onClientUpdate);
    super.dispose();
  }

  bool _isMyTurn(SnakesState s) =>
      !widget.client.isSpectator &&
      widget.client.started &&
      s.currentPlayer.id == widget.client.seatId;

  void _onClientUpdate() {
    if (!mounted) return;
    setState(() {});
    final s = widget.client.snakesState;
    if (s == null) return;

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
          'Final standings:\n${[
            for (var i = 0; i < s.rankings.length; i++)
              '${i + 1}. ${s.players.firstWhere(
                    (p) => p.id == s.rankings[i],
                    orElse: () => s.players.first,
                  ).name}',
          ].join('\n')}',
        ),
        actions: [
          FilledButton(
            onPressed: widget.onLeave,
            child: const Text('Back to lobby'),
          ),
        ],
      ),
    );
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
          final isMe = p.id == widget.client.seatId;
          final color = AppColors.snakesColors[p.tokenIndex];
          return AnimatedContainer(
            duration: const Duration(milliseconds: 250),
            padding: const EdgeInsets.symmetric(horizontal: 12),
            decoration: BoxDecoration(
              color: isCurrent
                  ? color.withValues(alpha: 0.85)
                  : AppColors.feltLight,
              borderRadius: BorderRadius.circular(14),
              border: Border.all(
                color: isCurrent ? AppColors.gold : Colors.white24,
                width: isCurrent ? 2 : 1,
              ),
            ),
            child: Row(
              children: [
                Icon(Icons.person,
                    size: 18,
                    color: isCurrent ? Colors.white : Colors.white70),
                const SizedBox(width: 6),
                Text(isMe ? 'You' : p.name,
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
          IconButton(
            icon: const Icon(Icons.close),
            tooltip: 'Leave and disconnect',
            onPressed: widget.onLeave,
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
                      ],
                    );
                  }),
                ),
              ),
            ),
            Text(status,
                style: const TextStyle(fontSize: 14, color: Colors.white70)),
            const SizedBox(height: 6),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 4, 16, 12),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  DiceWidget(
                    value: s.lastRoll,
                    rolling: false,
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

  List<Widget> _pawnWidgets(SnakesState s, double boardSize) {
    final cell = boardSize / 10;
    final bySquare = <int, List<SnakesPlayer>>{};
    for (final p in s.players) {
      bySquare.putIfAbsent(p.square, () => []).add(p);
    }
    final widgets = <Widget>[];
    for (final entry in bySquare.entries) {
      final c =
          SnakesBoardPainter.squareCenter(entry.key, Size.square(boardSize));
      final group = entry.value;
      for (var i = 0; i < group.length; i++) {
        final p = group[i];
        final color = AppColors.snakesColors[p.tokenIndex];
        widgets.add(
          Positioned(
            left: c.dx - cell * 0.28 + (i * 3.0),
            top: c.dy - cell * 0.28 - (i * 3.0),
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
        );
      }
    }
    return widgets;
  }
}
