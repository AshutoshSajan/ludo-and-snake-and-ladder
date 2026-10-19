/// The additive ChatLineView params built for the 1:1 friends lane:
/// the identicon avatar rides beside the bubble (left for theirs, right
/// for mine), the reply quote renders as a strip inside the bubble, and
/// a liked message carries the heart. The plain table-chat use is
/// pinned by the existing chat widgets tests; this pins only the new.
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:game_club/services/online_client.dart';
import 'package:game_club/ui/shared/chat_line_view.dart';
import 'package:game_club/ui/shared/player_avatar.dart';

Future<void> _pump(WidgetTester tester, Widget child) async {
  await tester.pumpWidget(MaterialApp(home: Scaffold(body: child)));
  await tester.pumpAndSettle();
}

Widget _avatar(String seed) =>
    PlayerAvatar(seed: seed, size: 30, circular: true);

void main() {
  testWidgets('mine: text right of theirs, avatar rides right too', (
    tester,
  ) async {
    const line = ChatLine(from: 'Swift Otter', text: 'gg wp', at: 1000);
    await _pump(
      tester,
      ChatLineView(line: line, myName: 'Swift Otter', avatar: _avatar('p1')),
    );
    final text = tester.getRect(find.text('gg wp'));
    final avatar = tester.getRect(find.byType(PlayerAvatar));
    expect(
      avatar.center.dx > text.center.dx,
      isTrue,
      reason: 'my avatar sits on my side (right)',
    );
  });

  testWidgets('theirs: avatar rides left of the text', (tester) async {
    const line = ChatLine(from: 'Small Fox', text: 'nice roll', at: 1000);
    await _pump(
      tester,
      ChatLineView(line: line, myName: 'Swift Otter', avatar: _avatar('p2')),
    );
    final text = tester.getRect(find.text('nice roll'));
    final avatar = tester.getRect(find.byType(PlayerAvatar));
    expect(
      avatar.center.dx < text.center.dx,
      isTrue,
      reason: 'their avatar sits on their side (left)',
    );
  });

  testWidgets('quote renders inside the bubble, heart only when liked', (
    tester,
  ) async {
    const line = ChatLine(from: 'Swift Otter', text: 'rolling!', at: 1000);
    await _pump(
      tester,
      ChatLineView(
        line: line,
        myName: 'Swift Otter',
        liked: true,
        quote: const Text('congrats!'),
      ),
    );
    expect(find.text('congrats!'), findsOneWidget);
    expect(find.byIcon(Icons.favorite), findsOneWidget);
  });

  testWidgets('plain table-chat use stays unchanged (no heart, no avatar)', (
    tester,
  ) async {
    const line = ChatLine(from: 'Small Fox', text: 'table talk', at: 1000);
    await _pump(tester, ChatLineView(line: line));
    expect(find.byType(PlayerAvatar), findsNothing);
    expect(find.byIcon(Icons.favorite), findsNothing);
    expect(find.text('table talk'), findsOneWidget);
  });

  // ------------------------------------------------- the author menu hook

  testWidgets('tap and long press open the author menu when wired', (
    tester,
  ) async {
    var opens = 0;
    const line = ChatLine(
      from: 'Small Fox',
      text: 'add me?',
      at: 1000,
      seatId: 'p7',
    );
    await _pump(tester, ChatLineView(line: line, onOpenMenu: () => opens++));

    await tester.tap(find.text('add me?'));
    await tester.pump();
    expect(opens, 1, reason: 'a tap is the visible affordance');

    await tester.longPress(find.text('add me?'));
    await tester.pump();
    expect(opens, 2, reason: 'long press still works for chat veterans');
  });

  testWidgets('no menu callback means the line is perfectly inert', (
    tester,
  ) async {
    const line = ChatLine(from: 'Small Fox', text: 'quiet', at: 1000);
    await _pump(tester, ChatLineView(line: line));
    // No GestureDetector in the tree: the friends 1:1 lane and any other
    // consumer that supervented no callback keeps its gesture-free bubble.
    expect(find.byType(GestureDetector), findsNothing);
  });

  test('a chat line carries its author seat id, tolerating lines without', () {
    final fromServer = ChatLine.fromJson({
      'from': 'Small Fox',
      'text': 'hi',
      'seatId': 'p7',
    });
    expect(fromServer.seatId, 'p7');

    // Older relays / tests that never had the field: the empty id simply
    // keeps the menu affordance quiet instead of addressing nobody.
    expect(ChatLine.fromJson({'from': 'A', 'text': 'x'}).seatId, '');
  });
}
