import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:game_club/services/online_client.dart';
import 'package:game_club/ui/shared/chat_line_view.dart';

/// The GIF bubble's loader phases.
///
/// The old builder inverted the contract: `loadingProgress == null` means
/// *the image is in* (the canonical pattern returns the child), yet the
/// code returned the spinner there — so every successfully loaded GIF sat
/// behind a felt-gray placeholder with a running spinner forever, while
/// the picker grid (a different widget, no loadingBuilder) looked fine.
/// [MemoryImage] drives the phases offline: valid bytes reach the loaded
/// branch, garbage bytes reach the error card, and a real `NetworkImage`
/// is never touched in a widget test.
void main() {
  // A known-good 1x1 PNG — content irrelevant, decode must succeed.
  final goodPng = base64Decode(
    'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8DwHwAFAAH/q842iQ'
    'AAAABJRU5ErkJggg==',
  );

  Future<void> pumpGifLine(WidgetTester tester, ImageProvider provider) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ChatLineView(
            line: ChatLine(from: 'Nova', gif: 'https://via.test/gif.gif'),
            myName: 'Rex',
            gifImageProvider: provider,
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
  }

  testWidgets('a loaded GIF renders the image — no spinner left behind', (
    tester,
  ) async {
    await pumpGifLine(tester, MemoryImage(goodPng));

    expect(find.byType(Image), findsAtLeastNWidgets(1));
    expect(find.byType(CircularProgressIndicator), findsNothing);
    expect(find.text('GIF unavailable'), findsNothing);
  });

  testWidgets('an image that fails to decode shows the GIF unavailable card', (
    tester,
  ) async {
    await pumpGifLine(tester, MemoryImage(Uint8List.fromList(const [1, 2, 3])));

    expect(find.text('GIF unavailable'), findsOneWidget);
    expect(find.byType(CircularProgressIndicator), findsNothing);
  });
}
