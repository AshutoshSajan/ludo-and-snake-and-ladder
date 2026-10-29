/// Quitting a running local game ends it for good — the match lives only in
/// memory — so both exits (the pause menu's "Quit to home" and the system
/// back gesture) must ask first, and a confirmed quit must actually reach
/// home. Here: every path asks, Stay keeps the table, Quit walks out.
///
/// The route stack mirrors production: the game is pushed above a home
/// screen, so a confirmed quit lands on a screen the test can actually see.
/// Frames are pumped by hand — pumpAndSettle can never settle over the ludo
/// board's glow controller, which repeats forever.
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:game_club/controllers/ludo_session.dart' show SeatSetup;
import 'package:game_club/engine/ludo/ludo_models.dart';
import 'package:game_club/providers/app_providers.dart';
import 'package:game_club/services/sound_service.dart';
import 'package:game_club/ui/ludo/ludo_view.dart';
import 'package:game_club/ui/snakes/snakes_view.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Haptics fire real platform channels; swallow them so no
/// MissingPluginException escapes from an unawaited call.
void _mockPlatformChannels() {
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(SystemChannels.platform, (call) async => null);
}

/// Sound stub: real playback would leave platform-channel work pending.
class _SilentSound extends SoundService {
  @override
  Future<void> dice() async {}
  @override
  Future<void> step() async {}
  @override
  Future<void> move() async {}
  @override
  Future<void> snake() async {}
  @override
  Future<void> ladder() async {}
  @override
  Future<void> home() async {}
  @override
  Future<void> win() async {}
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  _mockPlatformChannels();

  Widget harness({required WidgetBuilder game}) => ProviderScope(
    overrides: [soundServiceProvider.overrideWithValue(_SilentSound())],
    child: MaterialApp(
      initialRoute: '/game',
      routes: {
        '/': (ctx) => Scaffold(
          appBar: AppBar(title: const Text('Home')),
          body: const Center(child: Text('HOME SWEET HOME')),
        ),
        '/game': game,
      },
    ),
  );

  Future<void> pumpLudo(WidgetTester tester) async {
    SharedPreferences.setMockInitialValues({});
    await tester.pumpWidget(
      harness(
        game: (ctx) => LudoGameView(
          seats: [
            SeatSetup(name: 'R', color: LudoColor.red),
            SeatSetup(name: 'G', color: LudoColor.green),
          ],
        ),
      ),
    );
    await tester.pump();
    await tester.pump();
  }

  Future<void> pumpSnakes(WidgetTester tester) async {
    SharedPreferences.setMockInitialValues({});
    await tester.pumpWidget(
      harness(
        game: (ctx) => SnakesGameView(
          seats: [
            SeatSetup(name: 'P0'),
            SeatSetup(name: 'P1'),
          ],
        ),
      ),
    );
    await tester.pump();
    await tester.pump();
  }

  /// The system back gesture, exactly as a device delivers it.
  Future<void> pressBack(WidgetTester tester) async {
    final navigator = tester.state<NavigatorState>(
      find.byType(Navigator).first,
    );
    await navigator.maybePop();
    await tester.pump();
  }

  /// Drains sheet and dialog transitions — and cannot hang: the ludo board's
  /// glow controller never settles, so pumpAndSettle is off the table.
  Future<void> settle(WidgetTester tester) async {
    await tester.pump(const Duration(milliseconds: 250));
    await tester.pump(const Duration(milliseconds: 250));
  }

  group('pause menu', () {
    testWidgets('ludo quit asks first, and Stay keeps the table', (
      tester,
    ) async {
      await pumpLudo(tester);

      await tester.tap(find.byIcon(Icons.pause));
      await settle(tester);
      await tester.tap(find.text('Quit to home'));
      await settle(tester);

      expect(find.text('Quit the game?'), findsOneWidget);
      expect(
        find.text('The match ends when you leave. Nothing is saved.'),
        findsOneWidget,
      );

      await tester.tap(find.widgetWithText(TextButton, 'Stay'));
      await settle(tester);

      expect(find.text('Ludo'), findsOneWidget);
      expect(find.text('HOME SWEET HOME'), findsNothing);
    });

    testWidgets('ludo quit carries the player home when confirmed', (
      tester,
    ) async {
      await pumpLudo(tester);

      await tester.tap(find.byIcon(Icons.pause));
      await settle(tester);
      await tester.tap(find.text('Quit to home'));
      await settle(tester);
      await tester.tap(find.widgetWithText(FilledButton, 'Quit'));
      await settle(tester);

      expect(find.text('HOME SWEET HOME'), findsOneWidget);
    });

    testWidgets('snakes quit asks first, and Stay keeps the table', (
      tester,
    ) async {
      await pumpSnakes(tester);

      await tester.tap(find.byIcon(Icons.pause));
      await settle(tester);
      await tester.tap(find.text('Quit to home'));
      await settle(tester);

      expect(find.text('Quit the game?'), findsOneWidget);
      expect(
        find.text('The match ends when you leave. Nothing is saved.'),
        findsOneWidget,
      );

      await tester.tap(find.widgetWithText(TextButton, 'Stay'));
      await settle(tester);

      expect(find.text('Snakes & Ladders'), findsOneWidget);
      expect(find.text('HOME SWEET HOME'), findsNothing);
    });

    testWidgets('snakes quit carries the player home when confirmed', (
      tester,
    ) async {
      await pumpSnakes(tester);

      await tester.tap(find.byIcon(Icons.pause));
      await settle(tester);
      await tester.tap(find.text('Quit to home'));
      await settle(tester);
      await tester.tap(find.widgetWithText(FilledButton, 'Quit'));
      await settle(tester);

      expect(find.text('HOME SWEET HOME'), findsOneWidget);
    });
  });

  group('back gesture', () {
    testWidgets('snakes back asks before the match is thrown away', (
      tester,
    ) async {
      await pumpSnakes(tester);

      await pressBack(tester);
      await settle(tester);
      expect(find.text('Quit the game?'), findsOneWidget);
      expect(find.text('HOME SWEET HOME'), findsNothing);

      await tester.tap(find.widgetWithText(TextButton, 'Stay'));
      await settle(tester);
      expect(find.text('Snakes & Ladders'), findsOneWidget);
    });

    testWidgets('snakes back walks home when confirmed', (tester) async {
      await pumpSnakes(tester);

      await pressBack(tester);
      await settle(tester);
      await tester.tap(find.widgetWithText(FilledButton, 'Quit'));
      await settle(tester);

      expect(find.text('HOME SWEET HOME'), findsOneWidget);
    });

    testWidgets('ludo back asks before the match is thrown away', (
      tester,
    ) async {
      await pumpLudo(tester);

      await pressBack(tester);
      await settle(tester);
      expect(find.text('Quit the game?'), findsOneWidget);
      expect(find.text('HOME SWEET HOME'), findsNothing);

      await tester.tap(find.widgetWithText(TextButton, 'Stay'));
      await settle(tester);
      expect(find.text('Ludo'), findsOneWidget);
    });

    testWidgets('ludo back walks home when confirmed', (tester) async {
      await pumpLudo(tester);

      await pressBack(tester);
      await settle(tester);
      await tester.tap(find.widgetWithText(FilledButton, 'Quit'));
      await settle(tester);

      expect(find.text('HOME SWEET HOME'), findsOneWidget);
    });
  });
}
