import '../page_app_bar.dart';

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
import '../shared/online_leave_pop.dart';
import '../shared/voice_button.dart';
import '../../services/saved_game.dart';
import '../../services/sound_service.dart';
import '../shared/dice_widget.dart';
import '../shared/seat_status_strip.dart';
import '../shared/table_notice.dart';
import '../shared/victory_dialog.dart';
import '../theme.dart';
import 'ludo_board_painter.dart';
import 'ludo_corner_panel.dart';
import 'ludo_overlays.dart';
import 'ludo_token_layer.dart';
import '../shared/sound_toggle_button.dart';
import '../shared/turn_countdown.dart';
import '../shared/pulse.dart';
import '../shared/game_chat_sheet.dart';
import '../shared/tablemates_sheet.dart';
import '../shared/bug_report_sheet.dart';
import '../../services/server_url.dart';

/// Full Ludo game screen: board, tokens, dice, HUD and pause menu.
class LudoGameView extends ConsumerStatefulWidget {
  const LudoGameView({
    super.key,
    this.seats = const [],
    this.onlineClient,
    this.onlineSeatId,
    this.onOnlineLeave,
    this.savedGame,
  });

  final List<SeatSetup> seats;

  /// A game to pick up rather than a new one. Replaces [seats], which stay for
  /// the normal start.
  final SavedGame? savedGame;

  /// When set, the game is driven by this authoritative-server connection
  /// (online mode): the session sends intents and adopts snapshots.
  final OnlineClient? onlineClient;
  final String? onlineSeatId;

  /// What to do once a player has walked out of an online game. The board is
  /// hosted inside the lobby screen rather than pushed as a route, so popping
  /// here would close the wrong thing — the screen that owns the socket says
  /// how to tear it down.
  final VoidCallback? onOnlineLeave;

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
    } else if (widget.savedGame != null) {
      session = LudoSession.resume(
        stateJson: widget.savedGame!.state,
        seatNames: widget.savedGame!.seatNames,
        profiles: ref.read(profilesProvider.notifier),
        sound: ref.read(soundServiceProvider),
        onGameOver: _onGameOver,
      );
      // Only now, with the inherited turn actually in view: a timer started in
      // the constructor would time out a turn the player never saw begin.
      session.scheduleNext();
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
    // A reconnect (or a rejoin after a dropped socket) can step onto a table
    // that already ended: the snapshot arrives whole, so the session's live
    // gameOver dispatch never runs (the factory assigns the state directly,
    // not through `_adoptState`). Without this the player who lost their
    // connection mid-victory comes back to a frozen board with no end
    // screen — the exact playtest report. The same one-shot end dialog a
    // live transition would open fires once the frame that can host it.
    if (widget.onlineClient != null &&
        session.state.phase == LudoPhase.gameOver) {
      final s = session.state;
      // The flag is consumed here, not in the dialog callback: a stray late
      // frame repeating the finished state must not fire a second end
      // screen while this one is still waiting for its frame.
      session.markOver();
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && session.state.phase == LudoPhase.gameOver) {
          _onGameOver(s);
        }
      });
    }
    // Don't tumble for whatever roll the session was born with — only for
    // rolls that happen from now on.
    _lastSeenSeq = session.state.rollSeq;
  }

  // ---------------------------------------------------------------- online
  // SAVE & RESUME — PARKED. Autosave is held out of the build while the
  // gameplay smoothness pass ships; LudoSession.resume and SavedGameStore
  // keep their tests, and uncommenting everything marked "SAVE & RESUME"
  // below restores the feature end to end.
  /*
  /// Autosave debounce. The session notifies on every animation tick, so the
  /// save is trailing-debounced instead of written per frame — and flushed on
  /// dispose, which is the case that actually matters: leaving is the moment a
  /// player expects their position to be kept.
  */
  // static const _saveDebounce = Duration(milliseconds: 800);
  // Timer? _saveTimer;
  /*
  void _scheduleSave() {
    if (widget.onlineClient != null) return; // the server owns online state
    _saveTimer?.cancel();
    _saveTimer = Timer(_saveDebounce, _saveNow);
  }

  Future<void> _saveNow() async {
    if (widget.onlineClient != null ||
        session.state.phase == LudoPhase.gameOver) {
      // A finished game must not offer itself for resume.
      await SavedGameStore().clear(GameKind.ludo);
      return;
    }
    await SavedGameStore().save(
      SavedGame(
        game: GameKind.ludo,
        state: session.state.toJson(),
        seatNames: [for (final p in session.state.players) p.name],
        savedAt: DateTime.now(),
      ),
    );
  }
  */

  @override
  void dispose() {
    // Flush rather than debounce: this is the "player left" moment.
    // _saveTimer?.cancel(); // SAVE & RESUME — parked.
    // unawaited(_saveNow()); // SAVE & RESUME — parked.
    _animTimer?.cancel();
    _diceTimer?.cancel();
    _fx.dispose();
    session.removeListener(_onSessionChanged);
    widget.onlineClient?.removeListener(_onClientChanged);
    session.dispose();
    super.dispose();
  }

  /// The online client notifies for transport events too (reconnecting,
  /// errors) — the banner reads its status on every rebuild. A walk-out of
  /// *our own seat* (the turn-timer eviction) is the one notification that
  /// must also end the screen: the server has already taken the seat, and a
  /// game view that keeps showing a table the player is no longer part of
  /// is a frozen game wearing the UI of a live one.
  void _onClientChanged() {
    final client = widget.onlineClient;
    if (client?.mySeatEvicted ?? false) {
      // The server walked this seat out mid-game (five silent turns). The
      // final state never reaches this client — the seat is already off the
      // room's roster before the gameOver snapshot goes out — so the removal
      // itself IS the end screen. It shows as one: a banner that says what
      // happened and an exit button on the table they were removed from,
      // instead of a toast that scrolls away above a board frozen forever.
      // Both flags are consumed BEFORE scheduling: clearLeftNotice re-enters
      // this listener, and an unconsumed eviction would stack the card.
      client!.clearMySeatEviction();
      client.clearLeftNotice();
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _showRemovalDialog();
      });
    } else {
      final notice = client?.leftNotice;
      if (notice != null) {
        client!.clearLeftNotice();
        // A seat can be announced mid-frame; a toast has to wait for the frame.
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) _showNotice(notice);
        });
      }
    }
    if (mounted) setState(() {});
  }

  /// The removed seat's end card: what happened, and the one way out. The
  /// winner's trophy belongs to the live table; this card owns the state the
  /// removed player is actually in — their seat forfeited, the result
  /// counted against them, the table moving on.
  void _showRemovalDialog() {
    showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (dialogContext) => AlertDialog(
        // The win/loss family share one card shape: the podium caps at
        // 460 so the removal card, with its own flexing content, used to
        // read wider than the trophy card above it on the same window
        // (playtest: "length, width, height is different"). One cap, one
        // family.
        constraints: const BoxConstraints(maxWidth: 460),
        title: const Text('You were removed'),
        content: const Text(
          'Five turns in a row were missed, so the table carried on without '
          'your seat. The result counts as a loss for you.',
        ),
        actions: [
          FilledButton(
            onPressed: () {
              Navigator.of(dialogContext).pop();
              final onLeave = widget.onOnlineLeave;
              if (onLeave != null) {
                onLeave();
              } else {
                Navigator.of(context).popUntil((r) => r.isFirst);
              }
            },
            child: const Text('Back to lobby'),
          ),
        ],
      ),
    );
  }

  void _showNotice(String text) {
    showTableNotice(context, text);
  }

  /// Spectators watch; they don't hand a seat to anyone, including themselves.
  bool get _canToggleAuto =>
      !(widget.onlineClient?.isSpectator ?? false) && !session.isBusy;

  /// Leaving online is a statement rather than a back press: the seat is
  /// forfeited, the pieces come off the board, and the others are told — so it
  /// asks first, because none of that can be undone by coming back.
  Future<void> _leave() async {
    final sure = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Leave the game?'),
        content: const Text(
          'Your pieces leave the board and the other players are told you '
          'went. You can\'t rejoin this game after that.',
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
    await session.leaveOnline();
    final onLeave = widget.onOnlineLeave;
    if (onLeave != null) {
      onLeave();
    } else if (mounted) {
      // The pushed-page fallback with no screen to hand the exit to: pop to
      // the first route the same way the victory dialog's Home does — and
      // past any dialog still animating its exit above us.
      Navigator.of(context).popUntil((r) => r.isFirst);
    }
  }

  void _onSessionChanged() {
    // _scheduleSave(); // SAVE & RESUME — parked; see the note on _saveTimer.
    // Kick off the 3D dice tumble whenever a fresh roll appears — tracked by
    // roll sequence, so it tumbles even when the same number comes up again.
    // Every roll animates, including the ones the engine resolves before this
    // listener runs: a roll with nothing legal to move, or the triple-six
    // forfeit, have already passed the turn and nulled `lastRoll`, so the face
    // and the seat come from lastRolledValue/lastRolledBy instead.
    if (session.state.rollSeq != _lastSeenSeq) {
      final freshRoll = session.state.rollSeq > _lastSeenSeq;
      _lastSeenSeq = session.state.rollSeq;
      _hintToken = null; // a new roll invalidates any shown hint
      if (freshRoll) {
        _diceTimer?.cancel();
        _diceRolling = true;
        _diceTimer = Timer(const Duration(milliseconds: 600), () {
          if (mounted) setState(() => _diceRolling = false);
        });
        // A spent roll must not read as a swallowed tap: when the roll had
        // no legal move the engine passed the turn right there, and the
        // only evidence left is a corner die holding the face. Say why.
        if (session.state.lastEvent == 'skip') {
          _showNotice(ludoSkipNotice(session.state));
        }
      }
      // A rewound sequence (undo, or a resync snapshot) only re-tracks the
      // sequence above — no tumble for a die that was never thrown.
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
    final mySeat = widget.onlineSeatId;
    final iWon =
        mySeat != null && s.rankings.isNotEmpty && s.rankings.first == mySeat;
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (_) => VictoryDialog(
        // Who owns the trophy is one sentence; the winner's own dialog says
        // "you", everyone else's says who the table crowned and where they
        // finished (the standings list carries the seats' order).
        title: iWon ? 'You win Ludo!' : '${names.first} wins Ludo!',
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
    final reconnecting =
        widget.onlineClient?.status == OnlineStatus.reconnecting;
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

    return OnlineLeavePop(
      active: widget.onlineClient != null,
      onLeave: _leave,
      child: Scaffold(
        appBar: PageAppBar(
          title: widget.onlineClient?.isSpectator ?? false
              ? const Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.visibility, size: 18),
                    SizedBox(width: 6),
                    Text('Ludo — watching'),
                  ],
                )
              : const Text('Ludo'),
          actions: [
            const SoundToggleButton(),
            // Chat is online-only: offline seats share a device, not a server,
            // so there is nobody on the other end to talk to. The red dot is the
            // unread count, and it clears when the sheet opens.
            if (widget.onlineClient != null)
              IconButton(
                icon: Badge(
                  isLabelVisible: (widget.onlineClient?.unreadChats ?? 0) > 0,
                  backgroundColor: Colors.redAccent,
                  smallSize: 9,
                  child: const Icon(Icons.forum_outlined),
                ),
                tooltip: (widget.onlineClient?.unreadChats ?? 0) > 0
                    ? 'Table chat (${widget.onlineClient!.unreadChats} new)'
                    : 'Table chat',
                onPressed: () =>
                    GameChatSheet.show(context, widget.onlineClient!),
              ),
            if (widget.onlineClient != null)
              IconButton(
                icon: const Icon(Icons.group_add_outlined),
                tooltip: 'Players at this table',
                onPressed: () => TablematesSheet.show(
                  context,
                  client: widget.onlineClient!,
                ),
              ),
            if (widget.onlineClient != null &&
                !(widget.onlineClient!.isSpectator)) ...[
              // Voice is seated-only: a watcher has no seat for the mesh to
              // address, so no controls rather than a control that answers
              // "no microphone" misleadingly.
              VoiceButton(client: widget.onlineClient!),
              MicButton(client: widget.onlineClient!),
            ],
            // Undo and hint are device-local conveniences for a turn nobody
            // else is watching; online play is server-authoritative, so a
            // disabled undo telling you "nothing to undo" is just clutter —
            // they only render for local tables.
            if (widget.onlineClient == null) ...[
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
                    ? () =>
                          setState(() => _hintToken = session.hintTokenIndex())
                    : null,
              ),
            ],
            IconButton(
              icon: Icon(
                session.autoPlayOn ? Icons.auto_mode : Icons.auto_mode_outlined,
              ),
              color: session.autoPlayOn ? AppColors.gold : null,
              tooltip: session.autoPlayOn
                  ? 'Autoplay on — tap to take over'
                  : 'Autoplay — the table plays your turns',
              onPressed: _canToggleAuto ? () => session.toggleAutoPlay() : null,
            ),
            if (session.isOnline)
              IconButton(
                icon: const Icon(Icons.logout),
                tooltip: 'Leave game',
                onPressed: _leave,
              ),
            IconButton(
              icon: const Icon(Icons.pause),
              onPressed: _showPauseMenu,
              tooltip: 'Pause / players',
            ),
            IconButton(
              icon: const Icon(Icons.bug_report_outlined),
              tooltip: 'Report an issue',
              onPressed: () => BugReportSheet.show(
                context,
                serverUrl: widget.onlineClient?.serverUrl ?? defaultServerUrl(),
                seatId: widget.onlineClient?.seatId,
              ),
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
              // The retry budget SPENT: without this the table went silent
              // forever — a frozen board wearing the UI of a live one, the
              // playtest round's "no popup" report from the losing seat.
              // The way back in and the way out are both one tap away.
              else if (widget.onlineClient?.status == OnlineStatus.error)
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
                            widget.onlineClient?.errorText ??
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
                          onPressed: widget.onlineClient?.retry,
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
              if (widget.onlineClient != null)
                SeatStatusStrip(
                  seats: widget.onlineClient!.lobbySeats,
                  mySeatId: widget.onlineSeatId,
                ),
              // Voice's speaking state lives on the mic button itself (a beam
              // while the mic hears speech) — a chip row here used to slide
              // the board downwards every time anyone said a word.
              Expanded(
                child: Semantics(
                  label: _boardSemanticLabel(s, movable.isNotEmpty),
                  liveRegion: true,
                  child: LayoutBuilder(
                    builder: (context, playArea) {
                      // The corner panels must sit exactly over the board's
                      // corners, so their rows are pinned to the same
                      // square the board underneath will take: the play
                      // area minus the two fixed panel rows. The dice
                      // LayoutBuilder below derives the identical square
                      // from the Expanded's own constraints, so the three
                      // stay in register on every window size.
                      const rowSlab = 46.0;
                      final boardSide = math.min(
                        playArea.maxWidth,
                        math.max(playArea.maxHeight - rowSlab * 2, 0.0),
                      );
                      final panelWidth = boardSide > 0 ? boardSide : null;
                      return Column(
                        children: [
                          // The corner identity panels live OUTSIDE the
                          // board: each corner square is covered by that
                          // corner's floating dice, so strike dots and the
                          // yard name hid behind the roll control on
                          // exactly the seat whose state the table needs
                          // to read. Top-edge yards (green, yellow) stand
                          // above the board; bottom-edge yards (red, blue)
                          // below. The 14px gap also clears the dice, which
                          // reach a few pixels beyond the board line
                          // through their felt margin. The slab width is
                          // the board's own square - panel rows used to
                          // span the whole window, hanging the top corners
                          // off the screen edges on a desktop display.
                          SizedBox(
                            height: rowSlab,
                            width: panelWidth,
                            child: Padding(
                              padding: const EdgeInsets.only(bottom: 14),
                              child: Row(children: _cornerPanels(s, top: true)),
                            ),
                          ),
                          Expanded(
                        child: Stack(
                          children: [
                            Center(
                              child: AspectRatio(
                                aspectRatio: 1,
                                child: LayoutBuilder(
                                  builder: (context, cons) {
                                    final boardSize = cons.biggest.width;
                                    // Captured for the corner dice below,
                                    // which size themselves against the
                                    // board.
                                    _lastBoardSize = boardSize;
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
                                      for (final p in s.players) p.color:
                                          p.name,
                                    };
                                    // There is no AnimatedBuilder around this
                                    // subtree any more, and that was the single
                                    // biggest mobile-web lag source: the effects
                                    // clock breathes every frame, and it used to
                                    // rebuild the board, the token layer and the
                                    // four corner dice 60 times a second even
                                    // when nothing was happening. The per-frame
                                    // pieces are scoped instead: the board
                                    // repaints via the painter's `repaint`
                                    // listenable (reading pulseAnim at paint
                                    // time), and the token layer drives only
                                    // its rings and its ghost from [fx] — the
                                    // layout above holds still.
                                    return Stack(
                                      children: [
                                        CustomPaint(
                                          size: Size.square(boardSize),
                                          painter: LudoBoardPainter(
                                            highlightCells: highlights,
                                            playerNames: playerNames,
                                            activeColor: s.currentPlayer
                                                .color,
                                            pulseAnim: _fx,
                                            repaint: _fx,
                                          ),
                                        ),
                                        LudoTokenLayer(
                                          state: s,
                                          boardSize: boardSize,
                                          movableTokenIndices: movable,
                                          onTapToken: session.tapToken,
                                          anim: session.activeAnim,
                                          animStep: _animStep,
                                          currentPlayerIndex:
                                              s.currentPlayerIndex,
                                          fx: _fx,
                                          stepStart: _stepStart,
                                          hintTokenIndex: _hintToken,
                                        ),
                                      ],
                                    );
                                  },
                                ),
                              ),
                            ),
                            // One die per player, pinned just outside the board's corners — never inside
                            // a player's yard, but close enough to reach. They used to be
                            // aligned to the corners of the play area, which on a wide
                            // window put each die ~600px of empty felt away from the
                            // board it belongs to: the roll control looked like it
                            // belonged to nothing. Snapped to the board instead.
                            LayoutBuilder(
                              builder: (context, outer) {
                                // Matches how the board above sizes itself: a
                                // square as large as the play area allows.
                                final boardSize = math.min(
                                  outer.maxWidth,
                                  outer.maxHeight,
                                );
                                // The felt margin the dice sit in, just
                                // outside the board's own square.
                                const felt = 18.0;
                                return Center(
                                  child: SizedBox.square(
                                    dimension: boardSize + felt * 2,
                                    child: Stack(
                                      children: [
                                        for (var i = 0; i < s.players.length;
                                            i++)
                                          _cornerDice(s, i),
                                      ],
                                    ),
                                  ),
                                );
                              },
                            ),
                          ],
                        ),
                      ),
                          SizedBox(
                            height: rowSlab,
                            width: panelWidth,
                            child: Padding(
                              padding: const EdgeInsets.only(top: 14),
                              child: Row(
                                children: _cornerPanels(s, top: false),
                              ),
                            ),
                          ),
                        ],
                      );
                    },
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  // ------------------------------------------------------- corner panels

  /// The corner-sided status lamps above and below the board: every
  /// seated player's color spot and strike dots, with the turn clock
  /// beside the dots on the seat that currently owns the turn. The name
  /// lives in the yard pill painted inside the corner on the board, and
  /// the phase words belong to the play surfaces (the dice, the tokens),
  /// so the lamp carries only state ("whose turn, how long, how badly
  /// hurt") — the question answered on that seat's own corner.
  List<Widget> _cornerPanels(LudoState s, {required bool top}) {
    return cornerPanels(
      top: top,
      seats: [
        for (final p in s.players)
          (
            color: p.color,
            misses: widget.onlineClient?.seatMisses[p.id] ?? 0,
            onTurn: p.id == s.currentPlayer.id,
            clock: widget.onlineClient == null
                ? null
                : (p.id == s.currentPlayer.id
                      ? TurnCountdown(client: widget.onlineClient!)
                      : null),
          ),
      ],
    );
  }

  // -------------------------------------------------- per-corner dice HUD
  /// The board's laid-out edge length, captured so the corner dice can size
  /// themselves against the board instead of the window.
  ///
  /// A field rather than a parameter because the board and the dice are built
  /// in separate branches of the same [Stack]; threading a size through would
  /// mean restructuring both. It is set during layout and only read while
  /// painting the dice, which are laid out in the same pass, so it is always
  /// current for the frame being built.
  double _lastBoardSize = 0;

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
    // The tumble belongs to the seat that rolled, which is not the current
    // seat when the roll ended the turn on the spot (skip / triple six).
    final tumbling = _diceRolling && s.lastRolledBy == i;
    final face = tumbling && !isCurrent ? s.lastRolledValue : s.lastRoll;
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
        // Ludo already tinted the die with the corner colour; added the pulse
        // so the seat on turn gets a die that breathes as well as wears its
        // colour. Driven by `isCurrent` rather than "is my turn": every corner
        // has its own die, and an AI or remote seat's corner needs the cue too.
        child: Pulse(
          active: isCurrent,
          child: DiceWidget(
            value: isCurrent || tumbling ? face : null,
            rolling: tumbling,
            enabled: canRoll,
            onTap: () {
              session.roll();
              // Online, the authoritative state takes a round trip; without
              // an answer at the tap the die reads as frozen, and the lagged
              // player taps again and again. The die tumbles at once, and
              // settles after three seconds if the server never answers — a
              // live echo re-runs this same settle with its own shorter
              // 600ms window (see _onSessionChanged), which cancels this
              // one first. Offline play animates through the engine itself
              // and needs no optimism.
              if (widget.onlineClient != null && canRoll) {
                _diceTimer?.cancel();
                _diceRolling = true;
                _diceTimer = Timer(const Duration(seconds: 3), () {
                  if (mounted) setState(() => _diceRolling = false);
                });
              }
            },
            // Sized against the board, not the window. Off the window's
            // shortestSide this clamped to its 92px maximum on any wide
            // screen, so the dice stayed large while the board they ringed
            // shrank — the felt gap between them grew with the window
            // instead of holding still. A tenth of the board keeps their
            // proportion constant from a phone to a 1900px window.
            size: (_lastBoardSize * 0.11).clamp(34.0, 72.0),
            accent: AppColors.ludo(p.color),
          ),
        ),
      ),
    );
  }

  // ------------------------------------------------------------- controls
  //
  // Intentionally empty: the phase words live on the play surfaces (the
  // dice, the tokens), and the turn clock lives on the on-turn seat's
  // corner lamp, beside its strike dots — a full-width status row used to
  // push both to a wide window's far left (playtest: they belong with the
  // corners, not half a screen away; and the spoken-phase line itself is
  // gone entirely by playtest request).

  // ---------------------------------------------------------- pause menu

  void _showPauseMenu() => showLudoPauseMenu(context, ref, session);
}
