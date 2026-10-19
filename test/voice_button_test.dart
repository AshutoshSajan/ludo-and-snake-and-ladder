/// Widget tests for the table-voice controls ([VoiceButton], [MicButton]).
///
/// The buttons are pure drivers of the [OnlineClient]'s voice state — the
/// state machine itself is covered in test/voice_room_test.dart and the
/// socket frames in test/online_client_reconnect_test.dart. Here the
/// questions are: does a tap join (or report a denied mic), does the state
/// repaint, and does mute stay reachable only while joined.
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:game_club/services/online_client.dart';
import 'package:game_club/ui/shared/voice_button.dart';
import 'package:game_club/ui/theme.dart';

import 'fake_channel.dart';
import 'voice_fakes.dart';

/// The IconButton that owns [tooltip] — `byTooltip` matches the Tooltip
/// itself, so climb to the button around it.
Object? _muteOnPressed(WidgetTester tester, [String tooltip = 'Mute my mic']) =>
    tester
        .widget<IconButton>(
          find.ancestor(
            of: find.byTooltip(tooltip),
            matching: find.byType(IconButton),
          ),
        )
        .onPressed;

void main() {
  Future<OnlineClient> seatedClient(
    WidgetTester tester, {
    required FakeBackend backend,
  }) async {
    final factory = FakeChannelFactory();
    final client = OnlineClient(
      'ws://test/ws',
      seatId: 'p1',
      name: 'A',
      voiceBackend: backend,
      channelFactory: factory.create,
    );
    client.connect();
    await tester.pump();
    factory.last.serverAdd({'type': 'joined', 'code': 'CODE', 'color': 'red'});
    factory.last.serverAdd({
      'type': 'lobby',
      'code': 'CODE',
      'started': false,
      'seats': [
        {'name': 'A', 'color': 'red', 'seatId': 'p1'},
        {'name': 'B', 'color': 'blue', 'seatId': 'p2'},
      ],
      'spectators': [],
    });
    await tester.pump();
    return client;
  }

  testWidgets('joining voice flips the button and arms the mic', (
    tester,
  ) async {
    final backend = FakeBackend();
    final client = await seatedClient(tester, backend: backend);

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: VoiceButton(client: client)),
      ),
    );
    expect(find.byTooltip('Join table voice'), findsOneWidget);
    expect(client.voiceJoined, isFalse);

    await tester.tap(find.byTooltip('Join table voice'));
    await tester.pump();

    expect(client.voiceJoined, isTrue);
    expect(find.byTooltip('Leave table voice'), findsOneWidget);
  });

  testWidgets('a denied mic answers with a how-to snackbar, not silence', (
    tester,
  ) async {
    final backend = FakeBackend()..denyMic = true;
    final client = await seatedClient(tester, backend: backend);

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: VoiceButton(client: client)),
      ),
    );
    await tester.tap(find.byTooltip('Join table voice'));
    await tester.pumpAndSettle();

    expect(client.voiceJoined, isFalse);
    expect(
      find.text('No microphone — allow mic access to use table voice'),
      findsOneWidget,
    );
    // The button still reads off: a refused call is not a connected one.
    expect(find.byTooltip('Join table voice'), findsOneWidget);
  });

  testWidgets('mute exists only once voice is joined, then toggles locally', (
    tester,
  ) async {
    final backend = FakeBackend();
    final client = await seatedClient(tester, backend: backend);

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: MicButton(client: client)),
      ),
    );
    // Not joined: there is no mute control at all — in a row with the
    // voice-note mic a visible-but-inert mute reads as a broken mic.
    expect(find.byTooltip('Mute my mic'), findsNothing);

    await client.joinVoice();
    await tester.pump();
    expect(_muteOnPressed(tester), isNotNull);

    await client.joinVoice();
    await tester.pump();
    expect(_muteOnPressed(tester), isNotNull);

    await tester.tap(find.byTooltip('Mute my mic'));
    await tester.pump();
    expect(client.voiceMuted, isTrue);
    expect(
      _muteOnPressed(tester, 'Unmute my mic'),
      isNotNull,
      reason: 'the tooltip flips with the state, so the control reads true',
    );
  });

  group('the speaking beam on the mic button', () {
    /// A joined mic, driven to "the mic hears speech" (or not).
    Future<({OnlineClient client, FakeBackend backend})> joinedMic(
      WidgetTester tester, {
      bool reduceMotion = false,
    }) async {
      final backend = FakeBackend();
      final client = await seatedClient(tester, backend: backend);
      await tester.pumpWidget(
        MaterialApp(
          home: MediaQuery(
            data: MediaQueryData(disableAnimations: reduceMotion),
            child: Scaffold(
              body: MicButton(client: client),
            ),
          ),
        ),
      );
      return (client: client, backend: backend);
    }

    testWidgets('the mic beams gold while it hears my voice', (tester) async {
      final (:client, :backend) = await joinedMic(tester);
      await client.joinVoice();
      await tester.pumpAndSettle();
      expect(find.byType(MicButton), findsOneWidget);

      // Quiet: ivoried icon, no rings — a muted mic is not a speaking one.
      final atRest = find.byIcon(Icons.mic);
      expect(atRest, findsOneWidget);
      expect(
        tester.widget<Icon>(atRest).color,
        isNot(AppColors.gold),
      );
      expect(
        find.byKey(const Key('mic-speaking-beam')),
        findsNothing,
      );

      backend.mic!.simulate(true);
      await tester.pump();
      final hot = tester.widget<Icon>(find.byIcon(Icons.mic));
      expect(hot.color, AppColors.gold,
          reason: 'the icon itself turns gold: the running truth, even '
              'with the rings off (reduced motion shrinks to this)');
      expect(
        find.byKey(const Key('mic-speaking-beam')),
        findsOneWidget,
        reason: 'the beam is the "am I live?" answer, right where the '
            'transmitting control is — no second chip row anywhere',
      );

      backend.mic!.simulate(false);
      await tester.pump();
      expect(
        tester.widget<Icon>(find.byIcon(Icons.mic)).color,
        isNot(AppColors.gold),
      );
      expect(
        find.byKey(const Key('mic-speaking-beam')),
        findsNothing,
        reason: 'the beam stops when the voice does: no ring left dangling '
            'over a quiet table',
      );
    });

    testWidgets('reduced motion keeps the truth, drops the rings', (
      tester,
    ) async {
      final (:client, :backend) = await joinedMic(tester, reduceMotion: true);
      await client.joinVoice();
      await tester.pumpAndSettle();

      backend.mic!.simulate(true);
      await tester.pump();
      expect(
        tester.widget<Icon>(find.byIcon(Icons.mic)).color,
        AppColors.gold,
      );
      expect(
        find.byKey(const Key('mic-speaking-beam')),
        findsNothing,
        reason: 'a pulsing indicator that ignores the motion setting is a '
            'winner for nobody; gold-on-rest still says live',
      );
    });

    testWidgets('mute wins over the beam: red while muted, rings gone', (
      tester,
    ) async {
      final (:client, :backend) = await joinedMic(tester);
      await client.joinVoice();
      await tester.pumpAndSettle();
      backend.mic!.simulate(true); // hot...
      await tester.pump();
      client.setVoiceMuted(true); // ...then muted
      await tester.pump();

      expect(
        tester.widget<Icon>(find.byIcon(Icons.mic_off)).color,
        Colors.redAccent,
      );
      expect(
        find.byKey(const Key('mic-speaking-beam')),
        findsNothing,
        reason: 'nothing transmits from a muted mic, so nothing beams',
      );
    });
  });
}
