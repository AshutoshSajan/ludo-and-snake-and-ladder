import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../engine/snakes/snakes_engine.dart';
import '../page_app_bar.dart' show kContentMaxWidth;
import '../shared/pulse.dart';
import '../theme.dart';

/// The Snakes table's shared geometry: one square board and one home area.
///
/// Playtest round: "snake board is too small, move the home area to the left
/// side and make its size as big as possible as per the header width." The
/// old stage always reserved a 76px strip under the board, so the board lost
/// that height on every window. The home area now moves beside the board
/// whenever that makes the board bigger — a desktop window gets the full
/// column height and the board meets the 720px page column; a narrow phone,
/// where the strip costs less than a rail, keeps the strip under the board.
///
/// Second playtest round, on a 781x768 browser window: centring the board
/// alone let the 96px rail hang left of the page column and left a matching
/// band of dead felt on the right. The rail, gap and board now centre as ONE
/// group, so the rail stays inside the reading width and both side margins
/// are equal. The rail orientation is unchanged; only its horizontal anchor
/// moved.
///
/// Third playtest round, on a phone-width window: the rail was 96px of a
/// 368px content column — a quarter of the screen for a column of 34px
/// chips. The rail is 64 now, so the board gains the difference wherever the
/// side layout is the one that yields the larger square.
///
/// Both the offline and online views use this one class. Their home panels,
/// pawn positions and (offline) ghost all read the same centres, so the two
/// modes cannot drift apart again.
class SnakesStageMetrics {
  SnakesStageMetrics._({
    required this.available,
    required this.boardRect,
    required this.homeRect,
    required this.players,
    required this.chipSize,
    required this.homeOnLeft,
  });

  /// The whole area the stage may occupy (the board area above the controls).
  final Size available;

  /// The board square in [available]'s coordinate space.
  final Rect boardRect;

  /// The one home panel, beside or under the board.
  final Rect homeRect;

  final int players;
  final double chipSize;
  final bool homeOnLeft;

  double get boardSize => boardRect.width;

  /// The board's top-left in stage coordinates; pawn painters add this to a
  /// [SnakesBoardPainter.squareCenter] result.
  Offset get boardOrigin => boardRect.topLeft;

  static const double homeRailWidth = 64;
  static const double homeRailGap = 10;
  static const double homePad = 8;
  static const double homeCaptionH = 20;
  static const double homeRowH = 40;
  static const double chipGap = 6;
  static const double chipMax = 34;

  /// Height of the strip under the board: a caption row plus one row of
  /// pawns, whatever the seat count.
  static const double homeStripH = homePad * 2 + homeCaptionH + homeRowH;

  /// The rail's header: the house line, then the wrapped count sentence.
  /// It is deliberately wide enough (and the rail wide enough) for the same
  /// "N of M waiting to enter" sentence the strip shows, so the wording does
  /// not change when the panel moves.
  static const double _sideHeaderH = 62;

  /// Chooses the orientation that yields the larger board, capped at the
  /// reading column so a very tall window does not grow a board wider than
  /// the page it sits under.
  factory SnakesStageMetrics.layout({
    required Size available,
    required int players,
  }) {
    final width = math.max(available.width, 0.0);
    final height = math.max(available.height, 0.0);

    final bottomBoard = math.min(
      kContentMaxWidth,
      math.min(width, math.max(height - homeStripH, 0.0)),
    );
    final sideBoard = math.min(
      kContentMaxWidth,
      math.min(
        math.max(width - homeRailWidth - homeRailGap, 0.0),
        height,
      ),
    );
    // Prefer the left rail when it is at least as good: on a window tall
    // enough to hit the 720px cap both orientations give the same board, and
    // the playtest asked for the rail on the left, not the strip below.
    final side = sideBoard > 0 && sideBoard >= bottomBoard - 0.5;
    final board = side ? sideBoard : bottomBoard;

    final Rect boardRect;
    final Rect homeRect;
    if (side) {
      // Centre the WHOLE GROUP — rail, gap, board — on the page. Centring
      // the board alone put the rail left of the page column and stranded
      // an equal band of felt on the right (the 781x768 playtest window).
      // The group always fits: the side board is capped by
      // `width - rail - gap`, so both margins are equal and non-negative.
      final groupLeft = math.max(
        (width - board - homeRailWidth - homeRailGap) / 2,
        0.0,
      );
      final left = groupLeft + homeRailWidth + homeRailGap;
      final top = math.max((height - board) / 2, 0.0);
      boardRect = Rect.fromLTWH(left, top, board, board);
      homeRect = Rect.fromLTWH(groupLeft, top, homeRailWidth, board);
    } else {
      final left = math.max((width - board) / 2, 0.0);
      final top = math.max(
        (height - board - homeStripH) / 2,
        0.0,
      );
      boardRect = Rect.fromLTWH(left, top, board, board);
      homeRect = Rect.fromLTWH(
        left,
        top + board,
        board,
        homeStripH,
      );
    }

    final n = math.max(players, 1);
    final double chip;
    if (side) {
      final room = math.max(
        homeRect.height - homePad * 2 - _sideHeaderH,
        0.0,
      );
      final fit = (room - chipGap * (n - 1)) / n;
      // Very short landscape windows still get a usable dot rather than a
      // clipped column; the strip would have been smaller, so there is no
      // better orientation at that size.
      chip = math.min(chipMax, math.max(fit, 6));
    } else {
      final room = math.max(board - homePad * 2 - chipGap * (n - 1), 0.0);
      chip = math.min(chipMax, math.max(room / n, 12));
    }

    return SnakesStageMetrics._(
      available: Size(width, height),
      boardRect: boardRect,
      homeRect: homeRect,
      players: n,
      chipSize: chip,
      homeOnLeft: side,
    );
  }

  /// Centre of seat [slot]'s pawn while it waits at home, in stage
  /// coordinates. The chips are one centred group in the rail or the strip,
  /// so the ghost's square-0 rest position and the visible chip agree.
  Offset homeChipCenter(int slot) {
    final n = players;
    final group = n * chipSize + (n - 1) * chipGap;
    if (homeOnLeft) {
      final areaTop = homeRect.top + homePad + _sideHeaderH;
      final areaH = math.max(
        homeRect.height - homePad * 2 - _sideHeaderH,
        0.0,
      );
      final start = areaTop + math.max((areaH - group) / 2, 0.0);
      return Offset(
        homeRect.center.dx,
        start + slot * (chipSize + chipGap) + chipSize / 2,
      );
    }
    final left = homeRect.left + (homeRect.width - group) / 2;
    return Offset(
      left + slot * (chipSize + chipGap) + chipSize / 2,
      homeRect.top + homePad + homeCaptionH + homeRowH / 2,
    );
  }
}

/// The board and its one home panel in a single coordinate space.
///
/// The board and its rail are centred as one group by [SnakesStageMetrics];
/// the home panel sits beside the board on a roomy window or under it on a
/// narrow one. [overlays] are positioned by the caller in the same stage
/// coordinates (pawns, and the offline ghost).
class SnakesStage extends StatelessWidget {
  const SnakesStage({
    super.key,
    required this.metrics,
    required this.board,
    required this.home,
    this.overlays = const [],
  });

  final SnakesStageMetrics metrics;
  final Widget board;
  final Widget home;
  final List<Widget> overlays;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: metrics.available.width,
      height: metrics.available.height,
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          Positioned.fromRect(rect: metrics.boardRect, child: board),
          Positioned.fromRect(rect: metrics.homeRect, child: home),
          ...overlays,
        ],
      ),
    );
  }
}

/// The one home panel: every seat's waiting pawn, in one column beside the
/// board or one row under it.
class SnakesHomePanel extends StatelessWidget {
  const SnakesHomePanel({
    super.key,
    required this.metrics,
    required this.waiting,
    required this.totalPlayers,
    required this.activePlayerId,
    required this.gameOver,
    required this.chipBuilder,
  });

  final SnakesStageMetrics metrics;

  /// Pawns still on square 0. The offline view omits the one being animated
  /// (the ghost draws it); the online view has no ghost.
  final List<SnakesPlayer> waiting;

  final int totalPlayers;
  final String activePlayerId;
  final bool gameOver;
  final Widget Function(SnakesPlayer player, double size) chipBuilder;

  @override
  Widget build(BuildContext context) {
    final m = metrics;
    final d = m.chipSize;
    final local = m.homeRect.topLeft;
    final caption = waiting.isEmpty
        ? 'every pawn is out'
        : '${waiting.length} of $totalPlayers waiting to enter';

    return DecoratedBox(
      key: const ValueKey('home-area'),
      decoration: BoxDecoration(
        color: AppColors.feltLight.withValues(alpha: 0.55),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Colors.white24),
      ),
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          if (m.homeOnLeft)
            Positioned(
              left: 4,
              right: 4,
              top: SnakesStageMetrics.homePad,
              child: Column(
                children: [
                  // A 64px rail leaves 56px inside the panel, and the word
                  // plus the house glyph can exceed that at large text scales.
                  // Scale the lockup down rather than clipping "Home".
                  const FittedBox(
                    fit: BoxFit.scaleDown,
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(
                          Icons.home_rounded,
                          size: 15,
                          color: AppColors.gold,
                        ),
                        SizedBox(width: 5),
                        Text(
                          'Home',
                          style: TextStyle(
                            fontSize: 12,
                            fontWeight: FontWeight.w800,
                            color: AppColors.ivory,
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    caption,
                    textAlign: TextAlign.center,
                    maxLines: 3,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontSize: 10,
                      height: 1.15,
                      color: Colors.white60,
                    ),
                  ),
                ],
              ),
            )
          else
            Positioned(
              left: SnakesStageMetrics.homePad,
              right: SnakesStageMetrics.homePad,
              top: SnakesStageMetrics.homePad * 0.7,
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
                      caption,
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
              left: m.homeChipCenter(p.tokenIndex).dx - local.dx - d / 2,
              top: m.homeChipCenter(p.tokenIndex).dy - local.dy - d / 2,
              width: d,
              height: d,
              child: Pulse(
                active: p.id == activePlayerId && !gameOver,
                child: chipBuilder(p, d),
              ),
            ),
        ],
      ),
    );
  }
}
