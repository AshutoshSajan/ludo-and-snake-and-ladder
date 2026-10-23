import 'package:flutter/material.dart';

import '../ui/club_widgets.dart';
import '../ui/page_app_bar.dart';
import '../ui/theme.dart';

/// The rule book, reachable from Settings.
///
/// A reading page, not a spec: every mechanic stated here was verified
/// against the engines and the online server (a six to come out in Ludo, a
/// 1 to enter in Snakes, exact-landing finishes, the thirty-second turn
/// clock, the five-miss removal) so a player can trust it instead of the
/// playtest confusion that asked for it. The content lives next to the
/// screen as a light model ([RulesContent]) so the builder stays dumb.
class RulesScreen extends StatefulWidget {
  const RulesScreen({super.key});

  @override
  State<RulesScreen> createState() => _RulesScreenState();
}

class _RulesScreenState extends State<RulesScreen> {
  /// ['ludo', 'snakes'] — the same values the Play Online lobby's
  /// Ludo/Snakes toggle uses, for one shared vocabulary.
  String _game = 'ludo';

  @override
  Widget build(BuildContext context) {
    final content = _game == 'ludo' ? ludoRulesContent : snakesRulesContent;
    return Scaffold(
      appBar: PageAppBar(title: 'How to play'),
      body: ClubBackground(
        child: SafeArea(
          child: ContentColumn(
            child: ListView(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 28),
              children: [
                ClubCard(
                  accent: true,
                  padding: const EdgeInsets.fromLTRB(17, 18, 17, 16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const ClubPageHeader(
                        eyebrow: 'The rule book',
                        title: 'Everything the table expects.',
                        icon: Icons.menu_book_outlined,
                        subtitle:
                            'The short rules first, then the house rules that '
                            'keep an online table fair.',
                      ),
                      const SizedBox(height: 15),
                      // The same Ludo/Snakes vocabulary the lobby uses, so
                      // switching games never has to be learned twice.
                      SegmentedButton<String>(
                        segments: const [
                          ButtonSegment(
                            value: 'ludo',
                            label: Text('Ludo'),
                            icon: Icon(Icons.casino_outlined),
                          ),
                          ButtonSegment(
                            value: 'snakes',
                            label: Text('Snakes'),
                            icon: Icon(Icons.grid_on_outlined),
                          ),
                        ],
                        selected: {_game},
                        onSelectionChanged: (sel) =>
                            setState(() => _game = sel.first),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 14),
                ClubCard(
                  padding: const EdgeInsets.fromLTRB(20, 20, 20, 22),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        content.lead,
                        style: const TextStyle(
                          fontFamily: AppFonts.display,
                          color: AppColors.ink,
                          fontSize: 20,
                          fontWeight: FontWeight.w600,
                          height: 1.38,
                          letterSpacing: -0.1,
                        ),
                      ),
                      const SizedBox(height: 6),
                      Container(
                        width: 52,
                        height: 2,
                        color: AppColors.gold.withValues(alpha: 0.85),
                      ),
                      for (final section in content.sections) _section(section),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _section(RulesSection section) {
    return Padding(
      padding: const EdgeInsets.only(top: 20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            height: 1,
            margin: const EdgeInsets.only(bottom: 14),
            color: AppColors.ink.withValues(alpha: 0.09),
          ),
          Text(
            section.heading,
            style: const TextStyle(
              fontFamily: AppFonts.display,
              color: AppColors.brassDeep,
              fontSize: 18,
              fontWeight: FontWeight.w600,
              height: 1.35,
            ),
          ),
          for (final line in section.lines) _line(line),
        ],
      ),
    );
  }

  Widget _line(RulesLine line) {
    final text = Text(
      line.text,
      style: const TextStyle(
        fontFamily: AppFonts.body,
        color: AppColors.ink,
        fontSize: 14.5,
        height: 1.58,
      ),
    );
    // Bullets get a hanging dot via a baseline-aligned row; paragraphs just
    // flow. Rows keep inside the reading column because they are an
    // Expanded inside the ContentColumn's constraint — the width test pins
    // exactly that.
    if (!line.bullet) {
      return Padding(padding: const EdgeInsets.only(top: 6), child: text);
    }
    return Padding(
      padding: const EdgeInsets.only(top: 7),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 5,
            height: 5,
            margin: const EdgeInsets.only(top: 8),
            decoration: const BoxDecoration(
              color: AppColors.brass,
              shape: BoxShape.circle,
            ),
          ),
          const SizedBox(width: 10),
          Expanded(child: text),
        ],
      ),
    );
  }
}

/// One line of the rule book: a plain paragraph or a bullet.
class RulesLine {
  const RulesLine.paragraph(this.text) : bullet = false;
  const RulesLine.bullet(this.text) : bullet = true;

  final String text;
  final bool bullet;
}

/// A heading and its short lines.
class RulesSection {
  const RulesSection(this.heading, this.lines);

  final String heading;
  final List<RulesLine> lines;
}

/// One game's readable rule book.
class RulesContent {
  const RulesContent({required this.lead, required this.sections});

  final String lead;
  final List<RulesSection> sections;
}

/// The online parts both games share (the server rules the table, not the
/// game): the turn clock, rooms and spectators, walk-outs, the chat and
/// voice surfaces, and the Settings screen that ties it together.
final List<RulesSection> _sharedSections = [
  RulesSection('The turn clock (online)', [
    // The window is one 30s arm per phase of the turn, and only the seat on
    // turn (game_server.dart: turnTimer, _armTurnTimer). Misses are
    // consecutive — acting clears them (_applyGameIntent), and _onTurnTimeout
    // hands the seat to _forfeitSeat at maxTurnMisses.
    const RulesLine.bullet(
      'At an online table the seat on turn has thirty seconds: time to '
      'roll, or to move with the roll already in hand. A countdown plate '
      'beside the turn subtitle shows what is left.',
    ),
    const RulesLine.bullet(
      'Let the clock run out and your turn is skipped for you — a miss is '
      'counted for your seat. Acting on your own turn resets the count, so '
      'it is a streak, not a lifetime total.',
    ),
    const RulesLine.bullet(
      'Five misses in a row drop your seat from the table, exactly like a '
      'walk-out: your pieces come off the board, the others are told why, '
      'and a two-player game ends right there.',
    ),
    const RulesLine.bullet(
      'Nobody is timed against an empty table, and a seat playing on '
      'autoplay is driven by the table itself, so it never meets the clock.',
    ),
  ]),
  RulesSection('Playing online', [
    // Rooms carry a generated 4-char code (game_server _newCode); the room
    // size is picked at creation (lobby ChoiceChips 2..4) and a join
    // inherits it; start is the first seated member's ('start' handler);
    // invites carry the room code (friends_screen); spectators are
    // read-only (online_client) with no voice (joinVoice returns false); a
    // dropped link reclaims the seat (rejoinRoom) while a walk-out may not.
    const RulesLine.bullet(
      'Tables are rooms with a short code: share it, friends join until '
      'the seats fill, and the host starts the game.',
    ),
    const RulesLine.bullet(
      'Invites skip the code: invite someone from your friends list and '
      'their tap on the invite drops them straight at your table.',
    ),
    const RulesLine.bullet(
      'Anyone can come and watch. Spectators see the board and the chat '
      'but can never roll, move, take a seat, or use table voice.',
    ),
    const RulesLine.bullet(
      'A dropped connection is not the end — come back and your seat is '
      'still yours, game intact, no matter when the link fell. Only '
      'walking out gives a seat away.',
    ),
  ]),
  RulesSection('Fair play', [
    // removeSeatFromGame: a two-player game ends on the spot, winner first
    // and the departed seat recorded last; bigger tables carry on without
    // the seat. The five-miss rule reuses the same path (reason: 'timeout').
    const RulesLine.bullet(
      'Leaving a game you are still part of is a walk-out. Your pieces '
      'come off the board, the table is told, and at a two-player game the '
      'other player wins on the spot.',
    ),
    const RulesLine.bullet(
      'The turn clock walks the same line: five missed turns in a row take '
      'your seat off the board, and at a two-player table that is recorded '
      'as a loss for you.',
    ),
  ]),
  RulesSection('Talking at the table', [
    // game_chat_sheet: text, GIFs (gif picker) and voice notes
    // (note_composer); friends_screen: the 1:1 thread with unread read
    // markers; VoiceButton asks for the mic and explains the refusal as a
    // permission answer.
    const RulesLine.bullet(
      'Every table has chat: text, GIFs and recorded voice notes. Between '
      'friends there is a private one-to-one chat, with unread dots for '
      'what you have not read yet.',
    ),
    const RulesLine.bullet(
      'Table voice is one button away. The first tap asks for your '
      'microphone permission — allow it and you can talk with everyone at '
      'the table, and mute yourself any time. Spectators cannot join.',
    ),
  ]),
  RulesSection('Settings', [
    // settings_screen: three persisted toggles (sound, haptics, animations),
    // plus the parallel-built "Replay tutorial" tile — worded so it stays
    // true whatever that tile finally says.
    const RulesLine.bullet(
      'Sound effects, haptics (vibrate on rolls and moves) and board '
      'animations are toggles in Settings. Turning the animations off '
      'saves battery — dice and hops still animate.',
    ),
    const RulesLine.bullet(
      'Autoplay is not in Settings: it lives at the table. Tap the '
      'circular-arrows button in a game and it plays your turns for you — '
      'online, the server drives them even if you close the app.',
    ),
    const RulesLine.bullet(
      'The tutorial replay and this rules page live in Settings too, so '
      'the how-to-play help is always one tap from the same place they are.',
    ),
    const RulesLine.bullet(
      "Local play saves each player's wins and win rate on this device "
      'only. Online games write to the server-wide leaderboard — the '
      'trophy button on the home screen — which shows first places, games '
      'played and your average finishing position.',
    ),
  ]),
];

/// Ludo, verified against `lib/engine/ludo/ludo_rules.dart` and
/// `ludo_board.dart`: four tokens, a 6 to leave the base, the extra-roll
/// rule, three-six forfeit, safe cells, 2-token blocks, exact home entry.
final RulesContent ludoRulesContent = RulesContent(
  lead:
      'The classic race around the board: bring your four pieces out of '
      'the yard, walk them once around the track, and settle every one of '
      'them into the center home before anyone else does.',
  sections: [
    RulesSection('The goal', [
      const RulesLine.bullet(
        'Finish first: the player who gets all four pieces home wins, and '
        'everyone else is ranked in the order they finished. The game '
        'ends when only one player is still racing.',
      ),
    ]),
    RulesSection('A turn', [
      const RulesLine.bullet(
        'Your turn is one roll of the dice and up to one move with it. If '
        'no piece of yours can use the number, the turn simply passes on.',
      ),
      const RulesLine.bullet(
        'Rolling a 6 lets you move and roll again; capturing an enemy '
        'piece or bringing one home earns an extra roll the same way.',
      ),
      const RulesLine.bullet(
        'Three 6s in a row close the turn unused — before you move, the '
        'third six takes your roll back and play moves on.',
      ),
    ]),
    RulesSection('Coming out and going home', [
      const RulesLine.bullet(
        'A piece needs a 6 to leave its yard, and it steps straight onto '
        'your start cell when it does.',
      ),
      const RulesLine.bullet(
        'The last stretch is exact: a piece must land on home with the '
        'precise count — over-rolling is not a move, so the piece waits '
        'for a smaller number.',
      ),
    ]),
    RulesSection('Safe cells and blocks', [
      // 8 safe cells = the start cell of each color + the star cell eight
      // steps ahead (safeCells); two enemy tokens of one color block both
      // landing and passing; a captured token goes back to base (pos -1).
      const RulesLine.bullet(
        'Eight track cells are safe — every color\'s start cell and the '
        'star cell eight steps ahead of it. A piece standing on one can '
        'never be captured.',
      ),
      const RulesLine.bullet(
        'Two pieces of one color standing together form a block: '
        'opponents can neither land on it nor walk past it.',
      ),
      const RulesLine.bullet(
        'A lone enemy piece on a plain cell is fair game — land on it and '
        'it goes all the way back to the yard it came from.',
      ),
    ]),
    ..._sharedSections,
  ],
);

/// Snakes & Ladders, verified against `lib/engine/snakes/snakes_engine.dart`:
/// a 1 to enter (square 1 = the foot of a ladder), the classic jump map,
/// pawns coexisting, exact 100 with bounce-back, first-to-finish ranking.
final RulesContent snakesRulesContent = RulesContent(
  lead:
      'The purest dice game there is: roll, move straight ahead, climb the '
      'ladders, survive the snakes, and be the first pawn to reach square '
      '100.',
  sections: [
    RulesSection('The goal', [
      // applyMove: the first pawn on 100 ends the game at once and the
      // rest are ranked by square, descending.
      const RulesLine.bullet(
        'Be the first pawn to reach square 100. The game ends the moment '
        'someone does, and everyone else is ranked by how far up the '
        'board their pawn is.',
      ),
    ]),
    RulesSection('A turn', [
      const RulesLine.bullet(
        'Your turn is one roll and one automatic move: your pawn always '
        'walks exactly the number you rolled. There are no choices to '
        'think about — the board decides the rest.',
      ),
      const RulesLine.bullet(
        'Ladders carry you up and snakes slide you down the moment you '
        'land on their square; the jump happens on its own.',
      ),
      const RulesLine.bullet(
        'Pawns share a square freely: nobody captures anyone, so this '
        'game is climbed by dice luck alone.',
      ),
    ]),
    RulesSection('Coming in and finishing', [
      const RulesLine.bullet(
        'A pawn still off the board needs a 1 to enter — and entering '
        'lands you on square 1, the foot of a ladder, so your very first '
        'roll can climb to square 38.',
      ),
      const RulesLine.bullet(
        'Square 100 must be reached exactly: any roll that would take you '
        'past it bounces your pawn back for the overflow.',
      ),
    ]),
    ..._sharedSections,
  ],
);
