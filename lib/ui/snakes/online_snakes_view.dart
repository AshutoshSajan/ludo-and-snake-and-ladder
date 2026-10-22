import '../page_app_bar.dart';

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../engine/snakes/snakes_engine.dart';
import '../../providers/app_providers.dart';
import '../../services/online_client.dart';
import '../shared/online_leave_pop.dart';
import '../shared/voice_button.dart';
import '../../services/sound_service.dart';
import '../shared/dice_widget.dart';
import '../shared/seat_status_strip.dart';
import '../shared/table_alert.dart';
import '../theme.dart';
import 'snakes_board_painter.dart';
import 'snakes_stage.dart';
import 'snakes_turn_hud.dart';
import '../shared/sound_toggle_button.dart';
import '../shared/pulse.dart';
import '../shared/tablemates_sheet.dart';
import '../shared/bug_report_sheet.dart';

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
    // The chime is wired from the view, not from the chat sheet: from the sheet
    // it could only fire after that sheet had been opened once, so the first
    // messages of a game — the ones you most want to hear — arrived silently.
    widget.client.onMessageArrived = (_) => ProviderScope.containerOf(
      context,
      listen: false,
    ).read(soundServiceProvider).message();
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
      if (oldWidget.client.onMessageArrived != null) {
        oldWidget.client.onMessageArrived = null;
      }
      widget.client.addListener(_onClientUpdate);
      widget.client.onRoll = _onRoll;
      widget.client.onMessageArrived = (_) => ProviderScope.containerOf(
        context,
        listen: false,
      ).read(soundServiceProvider).message();
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
    if (widget.client.mySeatEvicted) {
      // The server walked this seat out mid-game (five silent turns), and
      // the final state never reaches this client — the seat is already off
      // the room's roster before the gameOver snapshot goes out. The removal
      // itself IS the end screen: a banner that says what happened plus the
      // one way out, instead of a toast that scrolls away above a board
      // frozen forever. Both flags are consumed BEFORE scheduling:
      // clearLeftNotice re-enters this listener, and an unconsumed eviction
      // would stack the card.
      widget.client.clearMySeatEviction();
      widget.client.clearLeftNotice();
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        showDialog<void>(
          context: context,
          barrierDismissible: false,
          builder: (dialogContext) => AlertDialog(
            // Same card family as the win podium (460 wide) — see the
            // ludo seat's copy of this dialog.
            constraints: const BoxConstraints(maxWidth: 460),
            title: const Text('You were removed'),
            content: const Text(
              'Five turns in a row were missed, so the table carried on '
              'without your seat. The result counts as a loss for you.',
            ),
            actions: [
              FilledButton(
                onPressed: () {
                  Navigator.of(dialogContext).pop();
                  widget.onLeave();
                },
                child: const Text('Back to lobby'),
              ),
            ],
          ),
        );
      });
    } else {
      final notice = widget.client.leftNotice;
      if (notice != null) {
        // Read before the clear: leftExit dies with leftNotice.
        final removed = widget.client.leftExit == SeatExitKind.removed;
        widget.client.clearLeftNotice();
        // A seat can be announced mid-frame; an alert has to wait for the
        // frame (its own insert waits one more, so geometry is valid).
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) _showNotice(notice, removed: removed);
        });
      }
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
        // Deferred to the frame: this path also runs from initState for a
        // player who (re)joins an already-finished table, and a route push
        // while the first frame is still assembling throws instead of
        // opening the end screen.
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) _showGameOver(s);
        });
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

  /// A witness line that a seat is gone from the table, on the top-right
  /// table alert (this view's own snackbar went with the chatter cuts).
  /// The glyph matches how the seat left — carried off by the five missed
  /// turns, or a walk-out chosen by hand. The removed seat's own end card
  /// is the dialog above; this notice is only for the table that stays.
  void _showNotice(String notice, {required bool removed}) {
    showTableAlert(
      context,
      notice,
      icon: removed ? Icons.person_remove_outlined : Icons.logout,
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
      // The table has not spoken yet, but the socket is live — leaving here
      // is still a walk-out that must be said out loud, not a silent pop.
      return OnlineLeavePop(
        active: true,
        onLeave: _leave,
        child: const Center(child: CircularProgressIndicator()),
      );
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

    return OnlineLeavePop(
      active: true,
      onLeave: _leave,
      child: Scaffold(
        // The online dock owns the keyboard inset in the lobby Scaffold
        // above; subtracting it here as well would shrink the board twice.
        resizeToAvoidBottomInset: false,
        appBar: PageAppBar(
          title: const Text('Snakes & Ladders'),
          actions: [
            const SoundToggleButton(),
            // No chat icon here: the screen-level ResponsiveChatDock owns the
            // table chat now — docked on wide windows, overlaid from its own
            // launcher on phones. One entry point, one unread count.
            IconButton(
              icon: const Icon(Icons.group_add_outlined),
              tooltip: 'Players at this table',
              onPressed: () =>
                  TablematesSheet.show(context, client: widget.client),
            ),
            // Voice is seated-only; a spectator has no seat for the mesh.
            if (!widget.client.isSpectator) ...[
              VoiceButton(client: widget.client),
              MicButton(client: widget.client),
            ],
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
            IconButton(
              icon: const Icon(Icons.bug_report_outlined),
              tooltip: 'Report an issue',
              onPressed: () => BugReportSheet.show(
                context,
                serverUrl: widget.client.serverUrl,
              ),
            ),
          ],
        ),
        body: SafeArea(
          child: Column(
            children: [
              // Transport banners: the ludo table shows them; snakes went
              // without — a dropped socket sat on a frozen board the
              // playtest round read as "the other player is still there in
              // the game". Same two states, same two outs.
              if (widget.client.status == OnlineStatus.reconnecting)
                Material(
                  color: AppColors.danger,
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                      vertical: 6,
                      horizontal: 12,
                    ),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        const SizedBox(
                          width: 14,
                          height: 14,
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            color: Colors.white,
                          ),
                        ),
                        const SizedBox(width: 10),
                        Text(
                          'Connection lost — reconnecting…',
                          style: TextStyle(
                            color: Colors.white.withAlpha(230),
                            fontSize: 13,
                          ),
                        ),
                      ],
                    ),
                  ),
                )
              else if (widget.client.status == OnlineStatus.error)
                Material(
                  color: AppColors.danger,
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                      vertical: 6,
                      horizontal: 12,
                    ),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Expanded(
                          child: Text(
                            widget.client.errorText ??
                                'Connection lost — could not reach the '
                                    'server.',
                            textAlign: TextAlign.center,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              color: Colors.white.withAlpha(230),
                              fontSize: 13,
                            ),
                          ),
                        ),
                        TextButton(
                          onPressed: widget.client.retry,
                          style: TextButton.styleFrom(
                            foregroundColor: Colors.white,
                          ),
                          child: const Text('Retry'),
                        ),
                        TextButton(
                          onPressed: _leave,
                          style: TextButton.styleFrom(
                            foregroundColor: Colors.white,
                          ),
                          child: const Text('Leave'),
                        ),
                      ],
                    ),
                  ),
                ),
              SeatStatusStrip(
                seats: widget.client.lobbySeats,
                mySeatId: widget.client.seatId,
              ),
              // Whose turn and how long are the two things a player looks
              // for, so they sit above the board instead of below it under
              // the dice (the playtest could not find them there).
              SnakesTurnHud(client: widget.client, state: s, status: status),
              // Voice's speaking state lives on the mic button itself (see the
              // ludo board) — nothing wedged between the seats and the board,
              // so talk never moves the board underneath the players.
              Expanded(
                child: LayoutBuilder(
                  builder: (context, cons) {
                    // Same stage as the offline view: one square board and one
                    // home panel, in one coordinate space. The stage puts the
                    // panel beside the board on a roomy window and under it
                    // when that leaves a bigger board.
                    final metrics = SnakesStageMetrics.layout(
                      available: cons.biggest,
                      players: s.players.length,
                    );
                    return SnakesStage(
                      metrics: metrics,
                      board: CustomPaint(
                        painter: SnakesBoardPainter(
                          highlightSquare: s.phase == SnakesPhase.awaitingMove
                              ? pendingMove(s).to
                              : null,
                        ),
                      ),
                      home: _homeArea(metrics, s),
                      overlays: _pawnWidgets(s, metrics),
                    );
                  },
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 4, 16, 12),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    // Takes the corner colour of whoever is on turn, and
                    // breathes while it is your turn, so the die says whose move
                    // it is. It was gold for every seat and never pulsed.
                    Pulse(
                      active: _isMyTurn(s),
                      child: DiceWidget(
                        value: s.lastRoll,
                        rolling: _rolling,
                        enabled: canRoll,
                        onTap: widget.client.sendRoll,
                        accent:
                            AppColors.snakesColors[s.currentPlayer.tokenIndex
                                .clamp(0, 9)],
                      ),
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
      ),
    );
  }

  // ------------------------------------------------------------- home area

  /// The one home panel. [SnakesStageMetrics] owns the geometry, so the
  /// online table lays out exactly like the offline one; this method only
  /// decides who is still waiting and paints them.
  Widget _homeArea(SnakesStageMetrics metrics, SnakesState s) {
    final waiting = [
      for (final p in s.players)
        if (p.square == 0) p,
    ];
    return SnakesHomePanel(
      metrics: metrics,
      waiting: waiting,
      totalPlayers: s.players.length,
      activePlayerId: s.currentPlayer.id,
      gameOver: s.phase == SnakesPhase.gameOver,
      chipBuilder: _pawnDot,
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

  List<Widget> _pawnWidgets(SnakesState s, SnakesStageMetrics metrics) {
    final cell = metrics.boardSize / 10;
    final bySquare = <int, List<SnakesPlayer>>{};
    for (final p in s.players) {
      // Square 0 has no board cell; those pawns live in the home strip, and
      // drawing them here too would put them on top of square 10.
      if (p.square == 0) continue;
      bySquare.putIfAbsent(p.square, () => []).add(p);
    }
    final widgets = <Widget>[];
    for (final entry in bySquare.entries) {
      final c =
          metrics.boardOrigin +
          SnakesBoardPainter.squareCenter(
            entry.key,
            Size.square(metrics.boardSize),
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
