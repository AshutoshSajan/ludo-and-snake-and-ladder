/// The chat sheet shares the screen with the board instead of replacing
/// it: the sheet is capped a little over half the screen and history
/// scrolls inside that cap. It used to grow to full height on a busy table
/// — `isScrollControlled` plus a greedy column — and a player reading chat
/// watched turns pass underneath a board they could no longer see.
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:game_club/services/online_client.dart';
import 'package:game_club/ui/shared/game_chat_sheet.dart';

void main() {
  OnlineClient clientWithHistory(int count) {
    final client = OnlineClient('ws://via.test/ws', seatId: 'me', name: 'Me');
    client.chat.addAll([
      for (var i = 0; i < count; i++)
        ChatLine(from: 'Bo', text: 'message $i', seatId: 'bo'),
    ]);
    return client;
  }

  Future<void> openChat(WidgetTester tester, OnlineClient client) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Column(
            children: [
              // The board's stake-out slot: fixed at the top so its
              // visibility can be asserted against the sheet's reach.
              const SizedBox(
                height: 120,
                child: Center(child: Text('board')),
              ),
              const Spacer(),
              Builder(
                builder: (sheetContext) => TextButton(
                  onPressed: () => GameChatSheet.show(sheetContext, client),
                  child: const Text('open chat'),
                ),
              ),
            ],
          ),
        ),
      ),
    );
    await tester.tap(find.text('open chat'));
    await tester.pumpAndSettle();
  }

  double screen(WidgetTester tester, Finder anchor) =>
      MediaQuery.sizeOf(tester.element(anchor)).height;

  testWidgets('a busy table caps the sheet over the board, not on it', (
    tester,
  ) async {
    await openChat(tester, clientWithHistory(30));

    final sheet = tester.getSize(find.byType(GameChatSheet)).height;
    final screenH = screen(tester, find.text('open chat'));
    expect(sheet, lessThanOrEqualTo(screenH * 0.55 + 1),
        reason: 'the sheet must stay short of covering the board: chat '
            'answers "what did the table say", the board still answers '
            '"whose turn is it"');

    // And the cap is what bounds it — the history scrolls inside, it does
    // not stretch the sheet.
    expect(find.text('message 0'), findsNothing,
        reason: 'the oldest messages live below the fold of the cap');
    expect(find.text('message 29'), findsOneWidget,
        reason: 'the newest line still leads');
  });

  testWidgets('a quiet table keeps the sheet compact, not half-stretched', (
    tester,
  ) async {
    await openChat(tester, clientWithHistory(0));

    final sheet = tester.getSize(find.byType(GameChatSheet)).height;
    final screenH = screen(tester, find.text('open chat'));
    expect(sheet, lessThan(screenH * 0.5),
        reason: 'an empty sheet claims its content (the invitation to say '
            'hello), never the allowed maximum — the cap is a ceiling, '
            'not a target');
  });
}
