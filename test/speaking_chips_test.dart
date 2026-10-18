import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:game_club/ui/shared/speaking_chips.dart';

/// The speaking indicator renders exactly the talkers named to it — and
/// nothing at all when the table is quiet.
void main() {
  testWidgets('quiet tables show nothing, not an empty plate', (tester) async {
    await tester.pumpWidget(const MaterialApp(home: SpeakingChips(names: [])));
    expect(tester.takeException(), isNull);
    expect(find.byType(Wrap), findsNothing);
  });

  testWidgets('one chip per speaking seat, speaker named', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(home: SpeakingChips(names: ['You', 'Bo'])),
    );
    expect(find.text('You'), findsOneWidget);
    expect(find.text('Bo'), findsOneWidget);
    expect(find.byIcon(Icons.graphic_eq), findsNWidgets(2));
  });
}
