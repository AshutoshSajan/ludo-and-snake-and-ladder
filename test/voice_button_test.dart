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
      MaterialApp(home: Scaffold(body: VoiceButton(client: client))),
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
      MaterialApp(home: Scaffold(body: VoiceButton(client: client))),
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

  testWidgets('mute is gated on joining, then toggles locally', (tester) async {
    final backend = FakeBackend();
    final client = await seatedClient(tester, backend: backend);

    await tester.pumpWidget(
      MaterialApp(home: Scaffold(body: MicButton(client: client))),
    );
    // Not joined: the mute button is inert.
    expect(
      _muteOnPressed(tester),
      isNull,
    );

    await client.joinVoice();
    await tester.pump();
    expect(
      _muteOnPressed(tester),
      isNotNull,
    );

    await tester.tap(find.byTooltip('Mute my mic'));
    await tester.pump();
    expect(client.voiceMuted, isTrue);
    expect(
      _muteOnPressed(tester, 'Unmute my mic'),
      isNotNull,
      reason: 'the tooltip flips with the state, so the control reads true',
    );
  });
}
