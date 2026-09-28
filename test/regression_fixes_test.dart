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
/// 10. DiceWidget's spin-down really stops painting once it has settled
/// 11. The dice tumbles on EVERY roll — a skipped turn and the triple-six
///     forfeit included — not only on rolls that keep the turn
library;

import 'dart:async';

import 'package:fake_async/fake_async.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:game_club/controllers/ludo_session.dart';
import 'package:game_club/engine/core/player_profiles.dart';
import 'package:game_club/engine/ludo/ludo_board.dart';
import 'package:game_club/engine/ludo/ludo_models.dart';
import 'package:game_club/engine/ludo/ludo_rules.dart';
import 'package:game_club/providers/app_providers.dart';
import 'package:game_club/screens/online_lobby_screen.dart';
import 'package:game_club/services/sound_service.dart';
import 'package:game_club/services/storage_service.dart';
import 'package:game_club/ui/ludo/ludo_view.dart';
import 'package:game_club/ui/shared/dice_widget.dart';
import 'package:shared_preferences/shared_preferences.dart';

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

/// A storage that never answers. Reading `profilesProvider` makes its `build`
/// kick off a load, and a load that never completes can neither reach
/// SharedPreferences nor overwrite the profiles these tests build by hand.
class _InertStorage extends StorageService {
  @override
  Future<PlayerRegistry> loadProfiles() => Completer<PlayerRegistry>().future;
  @override
  Future<void> saveProfiles(PlayerRegistry registry) async {}
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  _mockPlatformChannels();

  late ProviderContainer container;
  late ProfilesNotifier profiles;

  setUpAll(() {
    // A Notifier carries its own Ref from Riverpod 3 on, so it has to come out
    // of a container instead of being built by hand with an injected one.
    container = ProviderContainer(
      overrides: [storageProvider.overrideWithValue(_InertStorage())],
    );
    profiles = container.read(profilesProvider.notifier);
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

    test('the rolled face outlives a roll that ends the turn', () {
      final s = _state();
      final roller = s.currentPlayerIndex;
      rollDice(s, 3); // nothing legal -> _endTurn nulls lastRoll right away
      expect(s.lastEvent, 'skip');
      expect(s.lastRoll, isNull, reason: 'a skipped roll grants no move');
      expect(s.lastRolledValue, 3);
      expect(s.lastRolledBy, roller);
    });

    test('the rolled face outlives a triple-six forfeit', () {
      final s = _state();
      final roller = s.currentPlayerIndex;
      rollDice(s, 6);
      applyMove(s, 0);
      rollDice(s, 6);
      applyMove(s, 1);
      expect(s.currentPlayerIndex, roller); // sixes kept the same seat
      rollDice(s, 6);
      expect(s.lastEvent, 'tripleSix');
      expect(s.lastRoll, isNull);
      expect(s.lastRolledValue, 6);
      expect(s.lastRolledBy, roller);
    });

    test('lastRolled* survive copy() and a JSON round trip', () {
      final s = _state();
      rollDice(s, 4); // skip path: lastRoll is already back to null
      expect(s.copy().lastRolledValue, 4);
      final json = LudoState.fromJson(s.toJson());
      expect(json.lastRolledValue, 4);
      expect(json.lastRolledBy, s.lastRolledBy);
    });

    test('a game that was never rolled remembers no face', () {
      final s = _state();
      expect(s.lastRolledValue, isNull);
      expect(s.lastRolledBy, isNull);
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

  /// Regression: the 3D dice spun forever when a tumble ended without a
  /// value (e.g. the view rebuilds during an opponent's turn) and the settle
  /// spin-down never ran. Observable as a fresh painter on every pumped
  /// frame even after the settle duration has passed.
  group('10. dice tumble widget', () {
    Future<void> pumpDice(WidgetTester tester) async {
      await tester.pumpWidget(DiceWidget(
        value: null,
        rolling: true,
        enabled: false,
        onTap: () {},
      ));
      await tester.pump();
      await tester.pump();
    }

    CustomPainter? painterOf(WidgetTester tester) =>
        tester.widget<CustomPaint>(find.byType(CustomPaint)).painter;

    testWidgets('dice settle spin-down stops painting after settle duration',
        (tester) async {
      await pumpDice(tester);

      // While rolling, the painter is rebuilt every frame (controller repeat).
      final a = painterOf(tester);
      await tester.pump();
      expect(painterOf(tester), isNot(same(a)));

      // Tumble ends with no value: rolling false, still no roll.
      await tester.pumpWidget(DiceWidget(
        value: null,
        rolling: false,
        enabled: false,
        onTap: () {},
      ));

      // Give the settle spin-down its full duration plus a couple of frames.
      await tester.pump(const Duration(milliseconds: 600));
      await tester.pump();
      await tester.pump();

      // After settling, no more per-frame painting: the painter instance
      // stays identical across pumped frames.
      final settled = painterOf(tester);
      await tester.pump();
      await tester.pump();
      expect(painterOf(tester), same(settled));
    });

    testWidgets('normal settle with a value also stops after settle duration',
        (tester) async {
      await pumpDice(tester);
      await tester.pumpWidget(DiceWidget(
        value: 4,
        rolling: false,
        enabled: false,
        onTap: () {},
      ));
      await tester.pump(const Duration(milliseconds: 600));
      await tester.pump();
      await tester.pump();

      final settled = painterOf(tester);
      await tester.pump();
      await tester.pump();
      expect(painterOf(tester), same(settled));
    });
  });

  group('11. the dice animates on every roll, not only on a six', () {
    // A local two-human-seat game: no AI timers, no online transport, so the
    // only thing that can move the state is the die being tapped.
    Future<void> pumpGame(WidgetTester tester) async {
      SharedPreferences.setMockInitialValues({});
      await tester.pumpWidget(ProviderScope(
        overrides: [
          soundServiceProvider.overrideWithValue(_CountingSound()),
        ],
        child: MaterialApp(
          home: LudoGameView(
            seats: [
              SeatSetup(name: 'R', color: LudoColor.red),
              SeatSetup(name: 'G', color: LudoColor.green),
            ],
          ),
        ),
      ));
      // Never pumpAndSettle here: the board glow controller repeats forever.
      await tester.pump();
      await tester.pump();
    }

    List<DiceWidget> diceOf(WidgetTester tester) =>
        tester.widgetList<DiceWidget>(find.byType(DiceWidget)).toList();

    testWidgets('the seat that rolled tumbles its own die and shows the face',
        (tester) async {
      await pumpGame(tester);
      expect(diceOf(tester), hasLength(2), reason: 'one die per seat');
      final mine = diceOf(tester).firstWhere((d) => d.enabled);
      expect(mine.rolling, isFalse);
      expect(mine.value, isNull);

      await tester.tap(find.byWidget(mine));
      await tester.pump(); // a local roll resolves inside the tap

      final tumbling = diceOf(tester).where((d) => d.rolling).toList();
      expect(tumbling, hasLength(1),
          reason: 'exactly the seat that rolled animates its own die');
      expect(tumbling.single.value, inInclusiveRange(1, 6),
          reason: 'the tumble needs a face to land on even when the roll was '
              'skipped and lastRoll is already null again');
    });

    testWidgets('the tumble ends by itself instead of spinning forever',
        (tester) async {
      await pumpGame(tester);
      final mine = diceOf(tester).firstWhere((d) => d.enabled);
      await tester.tap(find.byWidget(mine));
      await tester.pump();
      expect(diceOf(tester).any((d) => d.rolling), isTrue);

      await tester.pump(const Duration(milliseconds: 650));
      await tester.pump();
      expect(diceOf(tester).any((d) => d.rolling), isFalse);
    });
  });

  group('same-origin server URL derivation', () {
    test('keeps a nonstandard HTTPS port so WS and leaderboard work', () {
      // Page served over HTTPS on a port other than 443 (e.g. a load
      // balancer on :8443): the game WS and the leaderboard origin (which
      // is derived from the same URL via Uri.replace, preserving the
      // authority) must both target that port.
      final page = Uri.parse('https://game.example.com:8443/');
      expect(OnlineLobbyScreen.sameOriginServerUrl(page),
          'wss://game.example.com:8443/ws');

      final ws =
          Uri.parse(OnlineLobbyScreen.sameOriginServerUrl(page));
      expect(
        ws.replace(scheme: 'https', path: '/leaderboard'),
        Uri.parse('https://game.example.com:8443/leaderboard'),
      );
    });

    test('a standard HTTPS page gets no explicit port', () {
      expect(
        OnlineLobbyScreen.sameOriginServerUrl(
            Uri.parse('https://game.example.com/')),
        'wss://game.example.com/ws',
      );
    });

    test('plain http stays on the local dev server port', () {
      expect(
        OnlineLobbyScreen.sameOriginServerUrl(
            Uri.parse('http://localhost:5000/')),
        'ws://localhost:8080/ws',
      );
    });
  });
}
