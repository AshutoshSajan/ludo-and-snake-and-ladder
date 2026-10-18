import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:game_club/services/online_client.dart';
import 'package:game_club/ui/shared/game_chat_sheet.dart';

/// The chat sheet's composer row geometry.
///
/// The row's flex used to be fixed: an idle [NoteComposer] — one mic chip —
/// held a flex slot beside the `Expanded` text field, so the field took
/// half the row while the composer's half sat as dead space after Send.
/// Flex now follows state (0 idle, 1 recording), which is pinned here by
/// the idle rule the player sees every time they open the sheet: the field
/// spans the row the way every other chat bar does.
void main() {
  testWidgets('an idle composer leaves the whole row to the text field', (
    tester,
  ) async {
    // A client that never connected: history is empty, state is quiet —
    // exactly what a freshly opened sheet shows.
    final client = OnlineClient('ws://via.test/ws', seatId: 's1', name: 'Me');
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: GameChatSheet(client: client)),
      ),
    );
    await tester.pump();

    final field = find.widgetWithText(TextField, 'Message the table');
    expect(field, findsOneWidget);
    // With the row at ~768 test px and ~150 px of icons, a field below
    // 400 means a flex slot is still stealing from it; the fixed flex
    // built a field of about half the row.
    expect(tester.getSize(find.byType(TextField)).width, greaterThan(400));
  });
}
