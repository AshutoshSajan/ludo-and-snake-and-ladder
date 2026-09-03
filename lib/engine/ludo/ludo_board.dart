/// Static board geometry for the classic 15x15 Ludo board.
///
/// Track cells are listed clockwise.
/// Index 0 is the left-arm edge cell (8,0). Each color's start cell sits
/// directly beside its own yard: red (13,6), green (6,1), yellow (1,8),
/// blue (8,13). Start offsets: green 3, yellow 16, blue 29, red 42.
library;

import 'ludo_models.dart';

class GridPos {
  const GridPos(this.row, this.col);
  final int row;
  final int col;

  @override
  bool operator ==(Object other) =>
      other is GridPos && other.row == row && other.col == col;

  @override
  int get hashCode => Object.hash(row, col);

  @override
  String toString() => '($row,$col)';
}

class LudoBoard {
  LudoBoard._();

  /// 52 main-track cells clockwise, starting at the left-arm edge cell
  /// (8,0). Direction: up the left arm, across the top, down the right
  /// arm, along the bottom.
  static const List<GridPos> track = [
    // Left arm going up: (8,0), (7,0), then row 6, cols 0..5 (6 cells).
    GridPos(8, 0),
    GridPos(7, 0),
    GridPos(6, 0), GridPos(6, 1), GridPos(6, 2), GridPos(6, 3),
    GridPos(6, 4), GridPos(6, 5),
    // Top arm, col 6, rows 5..0 (6 cells)
    GridPos(5, 6), GridPos(4, 6), GridPos(3, 6), GridPos(2, 6),
    GridPos(1, 6), GridPos(0, 6),
    GridPos(0, 7),
    // Top arm, col 8, rows 0..5 (6 cells)
    GridPos(0, 8), GridPos(1, 8), GridPos(2, 8), GridPos(3, 8),
    GridPos(4, 8), GridPos(5, 8),
    // Right arm, row 6, cols 9..14 (6 cells)
    GridPos(6, 9), GridPos(6, 10), GridPos(6, 11), GridPos(6, 12),
    GridPos(6, 13), GridPos(6, 14),
    GridPos(7, 14),
    // Right arm, row 8, cols 14..9 (6 cells)
    GridPos(8, 14), GridPos(8, 13), GridPos(8, 12), GridPos(8, 11),
    GridPos(8, 10), GridPos(8, 9),
    // Bottom arm, col 8, rows 9..14 (6 cells)
    GridPos(9, 8), GridPos(10, 8), GridPos(11, 8), GridPos(12, 8),
    GridPos(13, 8), GridPos(14, 8),
    GridPos(14, 7),
    // Bottom arm, col 6, rows 14..9 (6 cells)
    GridPos(14, 6), GridPos(13, 6), GridPos(12, 6), GridPos(11, 6),
    GridPos(10, 6), GridPos(9, 6),
    // Left arm, row 8, cols 5..1 (5 cells)
    GridPos(8, 5), GridPos(8, 4), GridPos(8, 3), GridPos(8, 2),
    GridPos(8, 1),
  ];

  static const int trackLength = 52;

  /// Absolute main-track index where each color enters. Each start cell is
  /// adjacent to that color's own yard: green (6,1), yellow (1,8),
  /// blue (8,13), red (13,6).
  static const Map<LudoColor, int> startIndex = {
    LudoColor.red: 42,
    LudoColor.green: 3,
    LudoColor.yellow: 16,
    LudoColor.blue: 29,
  };

  /// Star (safe) cells on the main track, in absolute track indices
  /// (each start cell plus the cell 8 steps ahead of it).
  static const Set<int> safeCells = {3, 11, 16, 24, 29, 37, 42, 50};

  /// Turn order.
  static const List<LudoColor> colorOrder = [
    LudoColor.red,
    LudoColor.green,
    LudoColor.yellow,
    LudoColor.blue,
  ];

  /// Home column cells (r = 1..5 mapped to 51..55) per color. Each color
  /// leaves the main track at the edge cell of its own arm and walks inward.
  static const Map<LudoColor, List<GridPos>> homeColumns = {
    LudoColor.red: [
      GridPos(13, 7), GridPos(12, 7), GridPos(11, 7), GridPos(10, 7),
      GridPos(9, 7)
    ],
    LudoColor.green: [
      GridPos(7, 1), GridPos(7, 2), GridPos(7, 3), GridPos(7, 4), GridPos(7, 5)
    ],
    LudoColor.yellow: [
      GridPos(1, 7), GridPos(2, 7), GridPos(3, 7), GridPos(4, 7), GridPos(5, 7)
    ],
    LudoColor.blue: [
      GridPos(7, 13), GridPos(7, 12), GridPos(7, 11), GridPos(7, 10),
      GridPos(7, 9)
    ],
  };

  /// Yard (base) anchor: top-left cell of each color's 6x6 yard and its
  /// color. Yards: top-left green, top-right yellow, bottom-right blue,
  /// bottom-left red.
  static const Map<LudoColor, GridPos> yardOrigin = {
    LudoColor.red: GridPos(9, 0),
    LudoColor.green: GridPos(0, 0),
    LudoColor.yellow: GridPos(0, 9),
    LudoColor.blue: GridPos(9, 9),
  };

  /// Slot centers inside a yard for the 4 tokens (offsets in cells).
  static const List<GridPos> yardSlotOffsets = [
    GridPos(2, 2), GridPos(2, 4), GridPos(4, 2), GridPos(4, 4),
  ];

  static const GridPos center = GridPos(7, 7);

  /// Absolute track index for a token's relative position (0..50).
  static int absCell(LudoColor color, int r) =>
      (startIndex[color]! + r) % trackLength;

  /// Board coordinates for a token at relative position [r]
  /// (r must be 0..56; 56 maps to board center).
  static GridPos coordFor(LudoColor color, int r, int stackIndex, int stackSize) {
    if (r == -1) return yardSlot(color, stackIndex);
    if (r == 56) return center;
    if (r <= 50) {
      return track[absCell(color, r)];
    }
    return homeColumns[color]![r - 51];
  }

  /// Yard staging slot for a token: its resting spot while waiting in base
  /// and its permanent corner spot once it finishes (pos 56).
  static GridPos yardSlot(LudoColor color, int tokenIndex) {
    final origin = yardOrigin[color]!;
    final off = yardSlotOffsets[tokenIndex.clamp(0, 3)];
    return GridPos(origin.row + off.row, origin.col + off.col);
  }

  /// Human-readable cell name for debugging.
  static String nameFor(LudoColor color, int r) {
    if (r == -1) return '${color.label} base';
    if (r == 56) return 'home';
    if (r <= 50) return 'track${absCell(color, r)}';
    return '${color.label} home col ${r - 50}';
  }
}
