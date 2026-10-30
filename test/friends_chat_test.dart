/// The 1:1 DM screen: WhatsApp-style bubble sides (mine right, theirs
/// left) with circular identicons, double-tap liking with the full
/// round-trip, and the read marker being stamped persistently on load.
library;

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show SystemChannels;
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:game_club/providers/app_providers.dart';
import 'package:game_club/screens/friends_screen.dart';
import 'package:game_club/services/friend_client.dart';
import 'package:game_club/services/sound_service.dart';
import 'package:game_club/ui/shared/chat_input_behavior.dart';
import 'package:game_club/ui/shared/player_avatar.dart';

const serverUrl = 'wss://chat.test/ws';

/// The invited peer as the server prints its row.
FriendEntry _peer() => FriendEntry.fromJson({
  'seatId': 'p2',
  'name': 'Small Fox',
  'code': 'FOXCDE',
  'latest': 2,
});

http.Response ok(Object body) => http.Response(
  jsonEncode(body),
  200,
  headers: {'content-type': 'application/json'},
);

Future<void> _pump(
  WidgetTester tester,
  FriendClient client, {
  SoundService? sound,
}) async {
  SharedPreferences.setMockInitialValues({});
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        if (sound != null) soundServiceProvider.overrideWithValue(sound),
      ],
      child: MaterialApp(
        home: FriendsChatScreen(
          client: client,
          me: 'p1',
          myName: 'Swift Otter',
          peer: _peer(),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

/// Sound stub that counts calls instead of touching audio channels, so a
/// test can prove the chime fired without speakers.
class _CountingSound extends SoundService {
  int messages = 0;

  @override
  Future<void> message() async => messages++;
}

/// Two taps inside the double-tap window: the test framework's clock
/// advances per pump, so both land as one double-tap.
Future<void> _doubleTap(WidgetTester tester, Finder finder) async {
  final center = tester.getCenter(finder);
  final first = await tester.startGesture(center);
  await first.up();
  await tester.pump(const Duration(milliseconds: 120));
  final second = await tester.startGesture(center);
  await second.up();
  await tester.pump();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('the peer row parses from server-shaped JSON', () {
    final p = _peer();
    expect(p.seatId, 'p2');
    expect(p.name, 'Small Fox');
  });

  testWidgets('bubbles side correctly with identicons', (tester) async {
    await _pump(
      tester,
      FriendClient(
        serverUrl: serverUrl,
        credential: 'test-credential',
        httpClient: MockClient(
          (_) async => ok({
            'ok': true,
            'messages': [
              {
                'id': 1,
                'from': 'p2',
                'to': 'p1',
                'body': 'your move yet?',
                'liked': false,
                'createdAt': 1000,
              },
              {
                'id': 2,
                'from': 'p1',
                'to': 'p2',
                'body': 'finishing now!',
                'liked': false,
                'createdAt': 1001,
              },
            ],
            'latest': 2,
          }),
        ),
      ),
    );
    expect(find.byType(PlayerAvatar), findsNWidgets(2));
    final theirs = tester.getRect(find.text('your move yet?'));
    final mine = tester.getRect(find.text('finishing now!'));
    expect(
      mine.center.dx > theirs.center.dx,
      isTrue,
      reason: 'my bubble renders right of theirs, WhatsApp-style',
    );
  });

  testWidgets('double-tap likes, and double-tapping again unlikes', (
    tester,
  ) async {
    var serverLiked = false;
    await _pump(
      tester,
      FriendClient(
        serverUrl: serverUrl,
        credential: 'test-credential',
        httpClient: MockClient((req) async {
          if (req.url.path == '/friends/chat/like') {
            serverLiked = jsonDecode(req.body)['liked'] as bool;
            return ok({'ok': true, 'liked': serverLiked});
          }
          return ok({
            'ok': true,
            'messages': [
              {
                'id': 1,
                'from': 'p2',
                'to': 'p1',
                'body': 'your move yet?',
                'liked': serverLiked,
                'createdAt': 1000,
              },
            ],
            'latest': 1,
          });
        }),
      ),
    );
    expect(find.byIcon(Icons.favorite), findsNothing);
    await _doubleTap(tester, find.text('your move yet?'));
    await tester.pumpAndSettle();
    expect(find.byIcon(Icons.favorite), findsOneWidget);
    // Double-tap again un-likes.
    await _doubleTap(tester, find.text('your move yet?'));
    await tester.pumpAndSettle();
    expect(find.byIcon(Icons.favorite), findsNothing);
  });

  testWidgets('reading the chat stamps the persisted read marker', (
    tester,
  ) async {
    await _pump(
      tester,
      FriendClient(
        serverUrl: serverUrl,
        credential: 'test-credential',
        httpClient: MockClient(
          (_) async => ok({
            'ok': true,
            'messages': [
              {
                'id': 1,
                'from': 'p2',
                'to': 'p1',
                'body': 'your move yet?',
                'liked': false,
                'createdAt': 1000,
              },
            ],
            'latest': 1,
          }),
        ),
      ),
    );
    final sp = await SharedPreferences.getInstance();
    final raw = sp.getString('gc.friendRead');
    expect(raw, isNotNull);
    expect(jsonDecode(raw!)['p2'], 1, reason: 'marker records the latest id');
  });

  testWidgets('Enter sends on the desktop grammar instead of a newline', (
    tester,
  ) async {
    // Tests default to Android, where the grammar is still "Send button
    // replies"; the override is exactly how the desktop path is exercised.
    chatEnterSendsOverride = true;
    addTearDown(() => chatEnterSendsOverride = false);
    Map<String, dynamic>? sent;
    await _pump(
      tester,
      FriendClient(
        serverUrl: serverUrl,
        credential: 'test-credential',
        httpClient: MockClient((req) async {
          if (req.url.path == '/friends/chat/send') {
            sent = jsonDecode(req.body) as Map<String, dynamic>;
            return ok({
              'ok': true,
              'message': {
                'id': 3,
                'from': 'p1',
                'to': 'p2',
                'body': sent!['body'],
                'liked': false,
                'createdAt': 2000,
              },
            });
          }
          return ok({'ok': true, 'messages': [], 'latest': 0});
        }),
      ),
    );
    await tester.enterText(find.byType(TextField), 'join me in GQ2K\n');
    await tester.pumpAndSettle();
    expect(
      sent!['body'],
      'join me in GQ2K',
      reason: 'the trailing newline the IME delivered never reaches the wire',
    );
    final field = tester.widget<TextField>(find.byType(TextField));
    expect(
      field.controller!.text,
      isEmpty,
      reason: 'the composer is emptied by the send, not stranded with one',
    );
  });

  testWidgets('a confirmed send plays the chat chime', (tester) async {
    final sound = _CountingSound();
    var sends = 0;
    await _pump(
      tester,
      FriendClient(
        serverUrl: serverUrl,
        credential: 'test-credential',
        httpClient: MockClient((req) async {
          if (req.url.path == '/friends/chat/send') sends++;
          return ok({
            'ok': true,
            'message': {
              'id': 3,
              'from': 'p1',
              'to': 'p2',
              'body': 'gg well played',
              'liked': false,
              'createdAt': 2000,
            },
          });
        }),
      ),
      sound: sound,
    );
    expect(sound.messages, 0, reason: 'nothing plays before anything sends');
    await tester.enterText(find.byType(TextField), 'gg well played');
    await tester.tap(find.byIcon(Icons.send));
    await tester.pumpAndSettle();
    expect(sends, 1);
    expect(
      sound.messages,
      1,
      reason: 'the chime is the acknowledgment on a confirmed send only',
    );
  });

  testWidgets('a room code in a bubble carries a tap-to-copy chip', (
    tester,
  ) async {
    final copied = <String>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, (call) async {
          if (call.method == 'Clipboard.setData') {
            copied.add(call.arguments['text'] as String);
          }
          return null;
        });
    addTearDown(
      () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(SystemChannels.platform, null),
    );
    await _pump(
      tester,
      FriendClient(
        serverUrl: serverUrl,
        credential: 'test-credential',
        httpClient: MockClient(
          (_) async => ok({
            'ok': true,
            'messages': [
              {
                'id': 1,
                'from': 'p2',
                'to': 'p1',
                'body': 'GQ2K',
                'liked': false,
                'createdAt': 1000,
              },
            ],
            'latest': 1,
          }),
        ),
      ),
    );
    await tester.tap(find.byTooltip('Copy room code GQ2K'));
    // The bubble carries a double-tap-to-like detector, whose first-tap
    // window holds the gesture arena; a bare pumpAndSettle exits before it
    // elapses because nothing schedules a frame in the meantime. Advancing
    // past that window is what lets the chip's tap win.
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pumpAndSettle();
    expect(copied, ['GQ2K']);
    expect(
      find.text('Room code GQ2K copied — enter it in the online lobby.'),
      findsOneWidget,
      reason: 'the confirmation carries the next step, not just done-ness',
    );
  });
}
