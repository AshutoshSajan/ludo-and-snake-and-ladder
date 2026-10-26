/// Widget tests for the online lobby's connect form and room-code card:
///
/// 1. the table-size picker the host chooses before creating a room
/// 2. the one-tap room-code copy, which mobile browsers must be able to
///    perform without relying on (unreliable) long-press text selection
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:game_club/screens/online_lobby_screen.dart';
import 'package:game_club/services/friend_client.dart';
import 'package:game_club/services/friend_signals.dart';
import 'package:game_club/services/online_client.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'fake_channel.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('connect form', () {
    testWidgets('names nothing about the server — the target is internal', (
      tester,
    ) async {
      // The connect form asked players for the server URL to connect to;
      // a player pasting a listener's form field exported games to it.
      // The target is a build-time fact now, so the field must be gone
      // and the rest of the form still reads.
      SharedPreferences.setMockInitialValues({});
      await tester.pumpWidget(
        const ProviderScope(child: MaterialApp(home: OnlineLobbyScreen())),
      );
      await tester.pumpAndSettle();

      expect(find.text('Server URL'), findsNothing);
      expect(
        find.text('Your name'),
        findsOneWidget,
        reason: 'the form still asks its one real question: the name',
      );
    });

    testWidgets('the player id is tap-to-copy, with a corner confirmation', (
      tester,
    ) async {
      SharedPreferences.setMockInitialValues({
        'gc.onlinePlayerId': 'p123stable',
        'gc.onlineName': 'Asha',
      });
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

      await tester.pumpWidget(
        const ProviderScope(child: MaterialApp(home: OnlineLobbyScreen())),
      );
      await tester.pumpAndSettle();

      expect(find.textContaining('Player ID p123stable'), findsOneWidget);
      await tester.tap(find.byKey(const Key('copy-player-id')));
      await tester.pumpAndSettle();

      expect(copied, ['p123stable']);
      expect(
        find.textContaining('Player ID p123stable copied'),
        findsOneWidget,
        reason: 'the same top-right card confirms the copy',
      );
    });
  });

  testWidgets('the lobby friends badge follows the shared watcher count', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({
      'gc.onlinePlayerId': 'me',
      'gc.onlineName': 'Me',
    });
    friendSignals.reset();
    friendSignals.incomingRequests.value = 2;
    addTearDown(friendSignals.reset);

    final adopted = OnlineClient('ws://via.test/ws', seatId: 'me', name: 'Me');
    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          home: OnlineLobbyScreen(
            startup: OnlineStartup(adoptedClient: adopted),
          ),
        ),
      ),
    );
    await tester.pump();

    final badge = find.byKey(const Key('lobby-friends-badge'));
    expect(badge, findsOneWidget);
    expect(
      tester.widget<Badge>(badge).isLabelVisible,
      isTrue,
      reason: 'the app-level watcher read the request before the tray poll',
    );
    expect(find.byTooltip('Friends (2 requests waiting)'), findsOneWidget);

    friendSignals.incomingRequests.value = 0;
    await tester.pump();
    expect(tester.widget<Badge>(badge).isLabelVisible, isFalse);
  });

  group('table size picker', () {
    testWidgets('offers 2–4 with four seats selected by default', (
      tester,
    ) async {
      SharedPreferences.setMockInitialValues({});
      // The lobby bar is a ConsumerWidget (it carries the admin identity),
      // so the app shell's ProviderScope is required here too.
      await tester.pumpWidget(
        const ProviderScope(child: MaterialApp(home: OnlineLobbyScreen())),
      );
      await tester.pumpAndSettle();

      expect(find.text('Players at the table'), findsOneWidget);
      for (final n in const ['2', '3', '4']) {
        expect(find.text(n), findsOneWidget);
      }

      bool selected(int n) => tester
          .widget<ChoiceChip>(
            find.ancestor(
              of: find.text('$n'),
              matching: find.byType(ChoiceChip),
            ),
          )
          .selected;
      expect(
        selected(4),
        isTrue,
        reason: 'the default keeps the open four-seat table',
      );
      for (final n in const [2, 3]) {
        expect(selected(n), isFalse);
      }

      await tester.tap(find.text('2'));
      await tester.pumpAndSettle();
      expect(selected(2), isTrue);
      expect(
        selected(4),
        isFalse,
        reason: 'the chips switch like the offline setup screen',
      );
    });
  });

  group('room code card', () {
    testWidgets('copies the code through the clipboard channel', (
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

      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: Center(child: RoomCodeCard(code: 'LK2X')),
          ),
        ),
      );

      await tester.tap(find.byTooltip('Copy room code'));
      // The page toast is the top-right overlay card now: its insert waits
      // one frame and then slides in, so settle the slide before finding it.
      await tester.pumpAndSettle();

      expect(copied, ['LK2X']);
      expect(
        find.text('LK2X copied — send it to your friends'),
        findsOneWidget,
      );
    });

    testWidgets('is disabled before the room exists', (tester) async {
      final copied = <String>[];
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(SystemChannels.platform, (call) async {
            if (call.method == 'Clipboard.setData') {
              copied.add(call.arguments['text'] as String);
            }
            return null;
          });

      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(body: Center(child: RoomCodeCard(code: null))),
        ),
      );

      final button = tester.widget<IconButton>(
        find.ancestor(
          of: find.byTooltip('Copy room code'),
          matching: find.byType(IconButton),
        ),
      );
      expect(button.onPressed, isNull);

      // Tapping a disabled control must not crash or copy.
      await tester.tap(find.byTooltip('Copy room code'));
      await tester.pump();
      expect(copied, isEmpty);
      expect(find.byType(SnackBar), findsNothing);
    });

    testWidgets('copies a direct-join link built from the page origin', (
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

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Center(
              child: RoomCodeCard(
                // Lowercase in, canonical uppercase out; the origin is
                // injected because the test VM has no page origin.
                code: 'lk2x',
                base: Uri.parse('https://game.club/some/page?invite=1'),
              ),
            ),
          ),
        ),
      );

      expect(find.text('LK2X'), findsOneWidget);
      expect(
        find.text('https://game.club/join/LK2X'),
        findsOneWidget,
        reason: 'the link is visible, so it can also be selected by hand',
      );

      await tester.tap(find.byKey(const Key('copy-join-link')));
      await tester.pumpAndSettle();

      expect(copied, ['https://game.club/join/LK2X']);
      expect(
        find.text('Join link copied — send it to your friends'),
        findsOneWidget,
        reason: 'the gold top-right card confirms the copy',
      );
      expect(
        find.byType(SnackBar),
        findsNothing,
        reason: 'the app never uses a bottom snackbar for this',
      );
    });

    testWidgets('share falls back to copying where the API is absent', (
      tester,
    ) async {
      // `flutter test` is the non-web half, so shareJoinLink is the stub that
      // answers false; the card must then copy instead of doing nothing.
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

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Center(
              child: RoomCodeCard(
                code: 'LK2X',
                base: Uri.parse('https://game.club/'),
              ),
            ),
          ),
        ),
      );

      await tester.tap(find.byTooltip('Share join link'));
      await tester.pumpAndSettle();

      expect(copied, ['https://game.club/join/LK2X']);
      expect(
        find.text('Join link copied — send it to your friends'),
        findsOneWidget,
      );
      expect(find.byType(SnackBar), findsNothing);
    });
  });

  group('deep-link invitee', () {
    Widget lobby({
      required FakeChannelFactory factory,
      required OnlineStartup startup,
    }) => ProviderScope(
      child: MaterialApp(
        home: OnlineLobbyScreen(
          startup: startup,
          clientBuilder:
              ({
                required String serverUrl,
                required String seatId,
                required String name,
                String credential = '',
                required String gameType,
                required int capacity,
              }) => OnlineClient(
                serverUrl,
                seatId: seatId,
                name: name,
                credential: credential,
                gameType: gameType,
                capacity: capacity,
                channelFactory: factory.create,
              ),
        ),
      ),
    );

    testWidgets('a first-time invitee picks a name, then joins', (
      tester,
    ) async {
      SharedPreferences.setMockInitialValues({});
      final factory = FakeChannelFactory();
      await tester.pumpWidget(
        lobby(
          factory: factory,
          startup: const OnlineStartup(joinCode: 'abcd'),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('invite-card')), findsOneWidget);
      expect(find.text("You're invited to room ABCD"), findsOneWidget);
      expect(
        find.text('Join room ABCD'),
        findsOneWidget,
        reason: 'the invite card carries the prefilled code',
      );
      expect(
        factory.channels,
        isEmpty,
        reason: 'the room waits for the player to choose a name',
      );

      await tester.enterText(
        find.byKey(const Key('online-name-field')),
        'Asha',
      );
      await tester.tap(find.byKey(const Key('join-invited-room')));
      await tester.pump();

      expect(factory.channels, hasLength(1));
      final hello = factory.last.sent.first;
      expect(hello['type'], 'hello');
      expect(hello['code'], 'ABCD');
      expect(hello['name'], 'Asha');
    });

    testWidgets('a returning invitee joins without tapping Join', (
      tester,
    ) async {
      SharedPreferences.setMockInitialValues({
        'gc.onlinePlayerId': 'p1',
        'gc.onlineName': 'Asha',
      });
      final factory = FakeChannelFactory();
      await tester.pumpWidget(
        lobby(
          factory: factory,
          startup: const OnlineStartup(joinCode: 'abcd'),
        ),
      );
      // The connecting spinner never settles; two pumps flush storage and
      // the synchronous socket open that follows it.
      await tester.pump();
      await tester.pump();

      expect(find.byKey(const Key('invite-card')), findsNothing);
      expect(factory.channels, hasLength(1));
      final hello = factory.last.sent.first;
      expect(hello['code'], 'ABCD');
      expect(hello['name'], 'Asha');
      expect(hello['spectate'], isNull, reason: 'a plain join takes a seat');
    });

    testWidgets('a watch link joins the room as a spectator', (tester) async {
      SharedPreferences.setMockInitialValues({
        'gc.onlinePlayerId': 'p1',
        'gc.onlineName': 'Asha',
      });
      final factory = FakeChannelFactory();
      await tester.pumpWidget(
        lobby(
          factory: factory,
          startup: const OnlineStartup(joinCode: 'ABCD', watch: true),
        ),
      );
      await tester.pump();
      await tester.pump();

      expect(factory.channels, hasLength(1));
      expect(factory.last.sent.first['spectate'], isTrue);
    });
  });

  group('seat friend control', () {
    /// The tray view of one table: Ana is a friend, a request to Bo is
    /// pending, Ky sent me one, and Cleo is a stranger at the table.
    FriendState tray() => FriendState(
      me: FriendProfile(seatId: 'me', name: 'Me', code: 'MECODE'),
      friends: [
        FriendEntry(
          profile: FriendProfile(seatId: 'ana', name: 'Ana', code: 'ANACDE'),
          sinceMs: 1,
          latest: 0,
        ),
      ],
      incoming: [
        FriendRequestView(id: 7, seatId: 'ky', name: 'Ky', sinceMs: 2),
      ],
      outgoing: [
        FriendRequestView(id: 9, seatId: 'bo', name: 'Bo', sinceMs: 3),
      ],
      invites: const [],
      blocked: [],
    );

    SeatFriendControl control({FriendState? state}) => SeatFriendControl(
      state: state,
      peerSeatId: 'cleo',
      peerName: 'Cleo',
      busy: false,
      onAdd: () {},
      onAccept: () {},
    );

    Widget host(SeatFriendControl child) => MaterialApp(
      home: Scaffold(body: Center(child: child)),
    );

    testWidgets('a stranger at the table gets the one-tap add', (tester) async {
      // Before the first poll lands, the row still offers the add: the
      // endpoint is idempotent and a missing tray must not hide it.
      await tester.pumpWidget(host(control()));
      expect(find.text('+ Add'), findsOneWidget);

      await tester.pumpWidget(host(control(state: tray())));
      expect(find.text('+ Add'), findsOneWidget);
      expect(find.text('Friends'), findsNothing);
      expect(find.text('Sent'), findsNothing);
    });

    testWidgets('a friend reads as the end state, with no button to press', (
      tester,
    ) async {
      // Same rows as the tray, but this row is Ana's.
      final ana = SeatFriendControl(
        state: tray(),
        peerSeatId: 'ana',
        peerName: 'Ana',
        busy: false,
        onAdd: () {},
        onAccept: () {},
      );
      await tester.pumpWidget(host(ana));
      expect(find.text('Friends'), findsOneWidget);
      expect(
        find.byType(FilledButton),
        findsNothing,
        reason: 'a friend needs no action; the chip is the whole row',
      );
    });

    testWidgets('my pending request shows Sent, and Add is gone', (
      tester,
    ) async {
      final bo = SeatFriendControl(
        state: tray(),
        peerSeatId: 'bo',
        peerName: 'Bo',
        busy: false,
        onAdd: () {},
        onAccept: () {},
      );
      await tester.pumpWidget(host(bo));
      expect(find.text('Sent'), findsOneWidget);
      expect(find.text('+ Add'), findsNothing);
    });

    testWidgets('an incoming request turns the row into Accept', (
      tester,
    ) async {
      var accepted = 0;
      final ky = SeatFriendControl(
        state: tray(),
        peerSeatId: 'ky',
        peerName: 'Ky',
        busy: false,
        onAdd: () {},
        onAccept: () => accepted++,
      );
      await tester.pumpWidget(host(ky));
      await tester.tap(find.text('Accept'));
      await tester.pump();
      expect(
        accepted,
        1,
        reason: 'the tray asked me at the table, the tap answers right here',
      );
    });

    testWidgets('a row sleeps while its request is in flight', (tester) async {
      var added = 0;
      final cleo = SeatFriendControl(
        state: tray(),
        peerSeatId: 'cleo',
        peerName: 'Cleo',
        busy: true,
        onAdd: () => added++,
        onAccept: () {},
      );
      await tester.pumpWidget(host(cleo));
      final button = tester.widget<FilledButton>(
        find.ancestor(
          of: find.text('+ Add'),
          matching: find.byType(FilledButton),
        ),
      );
      expect(
        button.onPressed,
        isNull,
        reason: 'one slow link must not fire a request twice',
      );
      await tester.tap(find.text('+ Add'));
      await tester.pump();
      expect(added, isZero);
    });
  });
}
