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
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

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
          home: Scaffold(body: Center(child: RoomCodeCard(code: 'LK2X'))),
        ),
      );

      await tester.tap(find.byTooltip('Copy room code'));
      await tester.pump();

      expect(copied, ['LK2X']);
      expect(find.text('LK2X copied — send it to your friends'), findsOneWidget);
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
      expect(find.byType(FilledButton), findsNothing,
          reason: 'a friend needs no action; the chip is the whole row');
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

    testWidgets('an incoming request turns the row into Accept', (tester) async {
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
      expect(accepted, 1,
          reason: 'the tray asked me at the table, the tap answers right here');
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
        find.ancestor(of: find.text('+ Add'), matching: find.byType(FilledButton)),
      );
      expect(button.onPressed, isNull,
          reason: 'one slow link must not fire a request twice');
      await tester.tap(find.text('+ Add'));
      await tester.pump();
      expect(added, isZero);
    });
  });
}
