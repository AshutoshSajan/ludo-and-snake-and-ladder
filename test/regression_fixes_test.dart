/// Regression tests for every bug fixed during development:
///
/// 1. Clockwise track + start cells beside their own yard
/// 2. Safe star cells exactly 8 steps after each start
/// 3. Home columns branch from the owner's arm and end on the owner's
///    center triangle (no color mismatch)
/// 4. Finished pieces rest inside the center on their OWN color side,
///    never back in a yard
/// 5. Turn order runs clockwise regardless of seat fill order
///    (seat sorting in LudoSession)
/// 6. Mid-game addPlayer keeps clockwise order, stable turn index and
///    aligned token blocks; removePlayer cancels pending rolls
/// 7. rollSeq increments on every roll — dice tumbles even when the same
///    number repeats
/// 8. Autoplay: human seats roll and move by themselves; stops when off
/// 9. Per-step move sounds: one tick per hop of the walk animation
library;

import 'package:fake_async/fake_async.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:game_club/controllers/ludo_session.dart';
import 'package:game_club/engine/ludo/ludo_board.dart';
import 'package:game_club/engine/ludo/ludo_models.dart';
import 'package:game_club/engine/ludo/ludo_rules.dart';
import 'package:game_club/providers/app_providers.dart';
import 'package:game_club/services/sound_service.dart';

/// HapticFeedback fires real platform channels during gameplay; mock them
/// so tests never hit MissingPluginException from unawaited calls.
void _mockPlatformChannels() {
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(SystemChannels.platform, (call) async => null);
}

/// Sound stub that counts calls instead of touching audio channels.
class _CountingSound extends SoundService {
  int diceCount = 0,
      steps = 0,
      moves = 0,
      safeCount = 0,
      homes = 0,
      captures = 0,
      champions = 0;

  @override
  Future<void> dice() async => diceCount++;
  @override
  Future<void> step() async => steps++;
  @override
  Future<void> move() async => moves++;
  @override
  Future<void> safe() async => safeCount++;
  @override
  Future<void> home() async => homes++;
  @override
  Future<void> capture() async => captures++;
  @override
  Future<void> champion() async => champions++;
}

LudoPlayer _seat(LudoColor c, {bool ai = false}) => LudoPlayer(
      id: 'id-${c.name}',
      name: c.label,
      color: c,
      isAI: ai,
    );

LudoState _state({int players = 4}) => createLudoState(
    [for (final c in LudoBoard.colorOrder.take(players)) _seat(c)]);

/// Distance from [v] to the inclusive range [lo, lo+size-1].
int _rectDist(int v, int lo, int size) =>
    v < lo ? lo - v : (v >= lo + size ? v - (lo + size - 1) : 0);

final _refProvider = Provider<Ref>((ref) => ref);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  _mockPlatformChannels();

  late ProviderContainer container;
  late ProfilesNotifier profiles;

  setUpAll(() {
    container = ProviderContainer();
    // Built manually (never load()) so no SharedPreferences is touched.
    profiles = ProfilesNotifier(container.read(_refProvider));
  });

  tearDownAll(() => container.dispose());

  LudoSession makeSession(List<SeatSetup> seats, _CountingSound sound) =>
      LudoSession(
        seats: seats,
        profiles: profiles,
        sound: sound,
        onGameOver: (_) {},
      );

  group('1+2. clockwise track, start cells and safe stars', () {
    test('track is 52 unique, connected cells', () {
      expect(LudoBoard.track.length, 52);
      expect(LudoBoard.track.toSet().length, 52);
      for (var i = 0; i < 52; i++) {
        final a = LudoBoard.track[i];
        final b = LudoBoard.track[(i + 1) % 52];
        final d = (a.row - b.row).abs() + (a.col - b.col).abs();
        expect(d, isIn(const [1, 2]),
            reason: 'cells $i/${(i + 1) % 52} must be adjacent');
      }
    });

    test('every color starts beside its OWN yard (not another corner)', () {
      const expectedStart = {
        LudoColor.red: GridPos(13, 6),
        LudoColor.green: GridPos(6, 1),
        LudoColor.yellow: GridPos(1, 8),
        LudoColor.blue: GridPos(8, 13),
      };
      for (final c in LudoColor.values) {
        final start = LudoBoard.track[LudoBoard.startIndex[c]!];
        expect(start, expectedStart[c],
            reason: '${c.label} start cell is on the wrong arm');
        final o = LudoBoard.yardOrigin[c]!;
        final dist =
            _rectDist(start.row, o.row, 6) + _rectDist(start.col, o.col, 6);
        expect(dist, 1,
            reason: '${c.label} start must touch its own 6x6 yard');
      }
    });

    test('a spawned token lands on its own start cell', () {
      final s = _state();
      rollDice(s, 6);
      applyMove(s, 0);
      expect(LudoBoard.coordFor(LudoColor.red, 0, 0, 4),
          LudoBoard.track[LudoBoard.startIndex[LudoColor.red]!]);
    });

    test('safe star cells sit exactly 8 steps after each start', () {
      for (final c in LudoColor.values) {
        final start = LudoBoard.startIndex[c]!;
        expect(LudoBoard.safeCells.contains(start), isTrue,
            reason: '${c.label} start cell should be safe');
        expect(LudoBoard.safeCells.contains((start + 8) % 52), isTrue,
            reason: '${c.label} star must be 8 steps after its start');
        expect(LudoBoard.absCell(c, 8), (start + 8) % 52);
      }
      expect(LudoBoard.safeCells.length, 8);
    });
  });

  group('3+4. home columns and center finish colors match', () {
    test('each home column branches from its own arm', () {
      for (final c in LudoColor.values) {
        final exit = LudoBoard.track[LudoBoard.absCell(c, 50)];
        final entry = LudoBoard.homeColumns[c]!.first;
        final d = (exit.row - entry.row).abs() + (exit.col - entry.col).abs();
        expect(d, 1,
            reason: '${c.label} column must branch from its own track exit');
      }
    });

    test('each column ends on its OWN color triangle (no mismatch)', () {
      for (final c in LudoColor.values) {
        final last = LudoBoard.homeColumns[c]!.last;
        final fin = LudoBoard.finishedCell(c);
        final d = (last.row - fin.row).abs() + (last.col - fin.col).abs();
        expect(d, 1, reason: '${c.label} column must reach its own triangle');
      }
    });

    test('finished pieces rest on their own side, never back in a yard', () {
      // red bottom, blue right, yellow top, green left.
      expect(LudoBoard.finishedCell(LudoColor.red).row, greaterThan(7));
      expect(LudoBoard.finishedCell(LudoColor.blue).col, greaterThan(7));
      expect(LudoBoard.finishedCell(LudoColor.yellow).row, lessThan(7));
      expect(LudoBoard.finishedCell(LudoColor.green).col, lessThan(7));
      for (final c in LudoColor.values) {
        final f = LudoBoard.finishedCell(c);
        expect(f.row, inInclusiveRange(6, 8));
        expect(f.col, inInclusiveRange(6, 8));
        for (var i = 0; i < 4; i++) {
          expect(f, isNot(LudoBoard.yardSlot(c, i)),
              reason: 'finished cell must not be a yard staging slot');
        }
      }
    });

    test('yard slots form an even 2x2 grid centered in each yard', () {
      for (final c in LudoColor.values) {
        final o = LudoBoard.yardOrigin[c]!;
        final slots = [for (var i = 0; i < 4; i++) LudoBoard.yardSlot(c, i)];
        expect(slots.toSet().length, 4);
        final avgRow = slots.fold<int>(0, (s, p) => s + p.row) / 4;
        final avgCol = slots.fold<int>(0, (s, p) => s + p.col) / 4;
        expect(avgRow, o.row + 3);
        expect(avgCol, o.col + 3);
      }
    });
  });

  group('5. turn order is clockwise regardless of seat fill order', () {
    test('colorOrder is the clockwise circuit and evenly spaced', () {
      expect(LudoBoard.colorOrder, const [
        LudoColor.red,
        LudoColor.blue,
        LudoColor.yellow,
        LudoColor.green,
      ]);
      final gaps = <int>{};
      for (var i = 0; i < 4; i++) {
        final a = LudoBoard.startIndex[LudoBoard.colorOrder[i]]!;
        final b = LudoBoard.startIndex[LudoBoard.colorOrder[(i + 1) % 4]]!;
        gaps.add((b - a) % LudoBoard.trackLength);
      }
      expect(gaps.length, 1, reason: 'starts must be evenly spaced');
    });

    test('session sorts scrambled seats into clockwise order', () {
      final sound = _CountingSound();
      final session = makeSession([
        SeatSetup(name: 'G', color: LudoColor.green),
        SeatSetup(name: 'R', color: LudoColor.red),
        SeatSetup(name: 'B', color: LudoColor.blue),
        SeatSetup(name: 'Y', color: LudoColor.yellow),
      ], sound);
      addTearDown(session.dispose);
      expect(session.state.players.map((p) => p.color).toList(),
          LudoBoard.colorOrder);
      // Seat names travel with their seats after sorting.
      const namesByColor = {
        LudoColor.red: 'R',
        LudoColor.blue: 'B',
        LudoColor.yellow: 'Y',
        LudoColor.green: 'G',
      };
      for (var i = 0; i < 4; i++) {
        expect(session.state.players[i].name,
            namesByColor[LudoBoard.colorOrder[i]]);
        expect(
            session.state
                .tokensOf(i)
                .every((t) => t.color == session.state.players[i].color),
            isTrue);
      }
    });

    test('2-player diagonal seating survives sorting', () {
      final sound = _CountingSound();
      final session = makeSession([
        SeatSetup(name: 'Y', color: LudoColor.yellow),
        SeatSetup(name: 'R', color: LudoColor.red),
      ], sound);
      addTearDown(session.dispose);
      expect(session.state.players.map((p) => p.color).toList(),
          const [LudoColor.red, LudoColor.yellow]);
    });

    test('default (uncolored) seats follow colorOrder', () {
      final sound = _CountingSound();
      final session = makeSession([
        SeatSetup(name: 'A'),
        SeatSetup(name: 'B'),
        SeatSetup(name: 'C'),
        SeatSetup(name: 'D'),
      ], sound);
      addTearDown(session.dispose);
      expect(session.state.players.map((p) => p.color).toList(),
          LudoBoard.colorOrder);
    });
  });

  group('6. mid-game seat management', () {
    test('addPlayer inserts at the clockwise-correct position', () {
      final sound = _CountingSound();
      final session = makeSession([
        SeatSetup(name: 'R', color: LudoColor.red),
        SeatSetup(name: 'Y', color: LudoColor.yellow),
      ], sound);
      addTearDown(session.dispose);
      session.addPlayer(name: 'Blu', color: LudoColor.blue);
      expect(session.state.players.map((p) => p.color).toList(),
          const [LudoColor.red, LudoColor.blue, LudoColor.yellow]);
      expect(session.state.tokens.length, 12);
      for (var i = 0; i < 3; i++) {
        expect(
            session.state
                .tokensOf(i)
                .every((t) => t.color == session.state.players[i].color),
            isTrue,
            reason: 'tokens of player $i must belong to '
                '${session.state.players[i].color}');
      }
    });

    test('addPlayer keeps the current turn stable', () {
      final sound = _CountingSound();
      final session = makeSession([
        SeatSetup(name: 'R', color: LudoColor.red),
        SeatSetup(name: 'Y', color: LudoColor.yellow),
      ], sound);
      addTearDown(session.dispose);
      session.state.currentPlayerIndex = 1; // yellow to move
      session.addPlayer(name: 'Blu', color: LudoColor.blue);
      expect(session.state.currentPlayer.color, LudoColor.yellow);
    });

    test('removePlayer cancels a pending roll and keeps order', () {
      final sound = _CountingSound();
      final session = makeSession([
        SeatSetup(name: 'R', color: LudoColor.red),
        SeatSetup(name: 'B', color: LudoColor.blue),
        SeatSetup(name: 'Y', color: LudoColor.yellow),
      ], sound);
      addTearDown(session.dispose);
      session.state.phase = LudoPhase.awaitingMove;
      session.state.lastRoll = 3;
      session.removePlayer(1);
      expect(session.state.players.map((p) => p.color).toList(),
          const [LudoColor.red, LudoColor.yellow]);
      expect(session.state.phase, LudoPhase.awaitingRoll);
      expect(session.state.lastRoll, isNull);
      expect(session.state.currentPlayer.color, LudoColor.red);
    });

    test('freeColors reports only unused corners', () {
      final sound = _CountingSound();
      final session = makeSession([
        SeatSetup(name: 'R', color: LudoColor.red),
        SeatSetup(name: 'Y', color: LudoColor.yellow),
      ], sound);
      addTearDown(session.dispose);
      expect(session.freeColors(), const [LudoColor.blue, LudoColor.green]);
    });
  });

  group('7. rollSeq: dice tumbles on every roll', () {
    test('increments even when the same number repeats', () {
      final s = _state();
      rollDice(s, 3); // all in base -> skip
      expect(s.rollSeq, 1);
      rollDice(s, 3); // same value, new turn -> still a new roll
      expect(s.rollSeq, 2);
      expect(s.lastEvent, 'skip');
    });

    test('increments on sixes and triple-six forfeits', () {
      final s = _state();
      rollDice(s, 6);
      applyMove(s, 0); // spawn, grants extra roll
      rollDice(s, 6);
      expect(s.rollSeq, 2);
      applyMove(s, 1); // spawn again, extra roll
      rollDice(s, 6); // third six -> forfeit
      expect(s.lastEvent, 'tripleSix');
      expect(s.rollSeq, 3);
    });

    test('rollSeq survives copy()', () {
      final s = _state();
      rollDice(s, 6);
      expect(s.copy().rollSeq, s.rollSeq);
    });
  });

  group('8. autoplay (go for a break)', () {
    test('human seats roll and move by themselves while it is on', () {
      fakeAsync((async) {
        final sound = _CountingSound();
        final session = makeSession([
          SeatSetup(name: 'R', color: LudoColor.red),
          SeatSetup(name: 'Y', color: LudoColor.yellow),
        ], sound);
        final before = session.state.turnCount;
        session.toggleAutoPlay();
        expect(session.autoPlay, isTrue);
        var guard = 0;
        while (session.state.turnCount == before && guard < 40) {
          async.elapse(const Duration(seconds: 2));
          guard++;
        }
        expect(session.state.turnCount, greaterThan(before),
            reason: 'autoplay must advance turns for human seats');
        expect(sound.diceCount, greaterThan(0));
        session.dispose();
      });
    });

    test('rolls stop once autoplay is switched off', () {
      fakeAsync((async) {
        final sound = _CountingSound();
        final session = makeSession([
          SeatSetup(name: 'R', color: LudoColor.red),
          SeatSetup(name: 'Y', color: LudoColor.yellow),
        ], sound);
        session.toggleAutoPlay();
        async.elapse(const Duration(seconds: 3));
        final seq = session.state.rollSeq;
        session.toggleAutoPlay();
        expect(session.autoPlay, isFalse);
        async.elapse(const Duration(seconds: 30));
        expect(session.state.rollSeq, seq,
            reason: 'no new roll may happen after autoplay is off');
        session.dispose();
      });
    });
  });

  group('9. per-step move sounds', () {
    test('one tick per hop, synced to the walk animation', () {
      fakeAsync((async) {
        final sound = _CountingSound();
        final session = makeSession([
          SeatSetup(name: 'R', color: LudoColor.red),
          SeatSetup(name: 'Y', color: LudoColor.yellow),
        ], sound);
        // Red token #0 on the track at rel pos 5; roll 3 -> 3 hops.
        session.state.phase = LudoPhase.awaitingMove;
        session.state.lastRoll = 3;
        session.state.tokens[0].pos = 5;
        session.tapToken(0);
        expect(session.activeAnim, isNotNull);
        expect(session.activeAnim!.waypoints.length, 4);

        async.elapse(const Duration(milliseconds: 130));
        expect(sound.steps, 1);
        async.elapse(const Duration(milliseconds: 130));
        expect(sound.steps, 2);
        async.elapse(const Duration(milliseconds: 130));
        expect(sound.steps, 3);

        async.elapse(const Duration(milliseconds: 800)); // move resolves
        expect(sound.steps, 3, reason: 'no extra ticks after landing');
        expect(sound.safeCount, 1, reason: 'rel 5+3=8 -> a star cell');
        expect(session.state.tokens[0].pos, 8);
        session.dispose();
      });
    });
  });
}
