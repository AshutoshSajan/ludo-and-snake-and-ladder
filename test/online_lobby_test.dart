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
}
