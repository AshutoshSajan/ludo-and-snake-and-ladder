import 'package:flutter/material.dart';

import '../../engine/ludo/ludo_models.dart';
import '../../engine/snakes/snakes_engine.dart';

/// The table's one-line spoken moments, in one shared shape: a floating
/// snackbar that replaces whatever was showing. Every surface that needs to
/// *say something happened* — a spent roll, a missed turn, a walk-out —
/// uses this so tone, timing and shape stay one pattern.
void showTableNotice(
  BuildContext context,
  String text, {
  int seconds = 4,
}) {
  ScaffoldMessenger.of(context)
    ..hideCurrentSnackBar()
    ..showSnackBar(
      SnackBar(
        content: Text(text),
        behavior: SnackBarBehavior.floating,
        duration: Duration(seconds: seconds),
      ),
    );
}

/// Why a ludo turn just passed with no pawn moving: a roll with no legal
/// move — every token still in base needing a 6, a road blocked by a
/// block of two, or a home entry that must land exactly. The engine spent
/// the roll and moved on; without this the corner die shows the face and
/// otherwise nothing explains why the turn moved to the next seat.
/// (The face is always set on this path — a spent roll stores it
/// deliberately — so a null falls back to wording without the number.)
String ludoSkipNotice(LudoState s) {
  final i = s.lastRolledBy;
  final roller = (i != null && i >= 0 && i < s.players.length)
      ? s.players[i].name
      : 'A player';
  final face = s.lastRolledValue;
  return face == null
      ? '$roller rolled — nothing can move; the turn passes'
      : '$roller rolled a $face — nothing can move; the turn passes';
}

/// The snakes variant, where exactly one rule ever spends a roll this way:
/// a pawn still off the board can only enter on a 1.
String snakesSkipNotice(SnakesState s) => 'Needs a 1 to enter — the turn passes';
