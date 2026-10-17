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
}
