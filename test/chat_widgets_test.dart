/// Widget tests for the shared chat surfaces:
///
/// 1. [ChatLineView] — a plain line, an inline GIF, and the dead-GIF fallback
/// 2. [GifPickerSheet] — the paste-a-link path and its validation
///
/// The picker's search path is covered end-to-end at the service level
/// (test/tenor_gif_test.dart); here the network is injected as a mock so the
/// picker can be driven deterministically without dialing Tenor.
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:game_club/services/online_client.dart';
import 'package:game_club/ui/shared/chat_line_view.dart';
import 'package:game_club/ui/shared/gif_picker_sheet.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

Future<void> openPicker(
  WidgetTester tester, {
  required String serverUrl,
  required void Function(String url) onPick,
  http.Client? httpClient,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: Center(
          child: Builder(
            builder: (context) => TextButton(
              // The sheet is presented over a route, exactly as the chat
              // surfaces show it.
              onPressed: () => GifPickerSheet.show(
                context,
                serverUrl: serverUrl,
                onPick: onPick,
                httpClient: httpClient,
              ),
              child: const Text('open picker'),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('open picker'));
  await tester.pumpAndSettle();
  expect(find.byType(GifPickerSheet), findsOneWidget);
}

/// The sheet has two fields in build order: the search box, then the
/// paste-a-link box underneath the divider.
Finder get searchField => find.byType(TextField).first;
Finder get linkField => find.byType(TextField).last;

void main() {
  group('ChatLineView', () {
    testWidgets('a line bubbles up: avatar chip, name, body', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: ListView(children: [
              const ChatLineView(line: ChatLine(from: 'Ana', text: 'hi')),
            ]),
          ),
        ),
      );
      // The byline is its own row now — name and body are separate texts.
      expect(find.text('Ana'), findsOneWidget);
      expect(find.text('hi'), findsOneWidget);
      // The avatar chip carries the sender's initial.
      expect(find.text('A'), findsOneWidget);
      expect(find.byType(Image), findsNothing);
    });

    testWidgets('my own line renders the same way (right side, gold)', (
      tester,
    ) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: ListView(children: [
              const ChatLineView(line: ChatLine(from: 'Ana', text: 'hey'), myName: 'Ana'),
            ]),
          ),
        ),
      );
      expect(find.text('Ana'), findsOneWidget);
      expect(find.text('hey'), findsOneWidget);
    });

    testWidgets('a timestamp rides the byline when the line has one', (
      tester,
    ) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: ListView(children: [
              // at: 1 — the wall clock of a fixed epoch; the exact digits
              // depend on the runner's timezone, the shape does not.
              const ChatLineView(line: ChatLine(from: 'Ana', text: 'hi', at: 1)),
            ]),
          ),
        ),
      );
      final texts = tester
          .widgetList<Text>(find.byType(Text))
          .map((t) => t.data ?? '');
      expect(
        texts.any((s) => RegExp(r'^\d\d:\d\d$').hasMatch(s)),
        isTrue,
        reason: 'the byline shows one HH:MM clock',
      );
    });

    testWidgets('a GIF line shows the image and its caption', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: ListView(children: [
              const ChatLineView(
                line: ChatLine(
                  from: 'Bo',
                  text: 'look at this',
                  gif: 'https://media.tenor.com/x/abc.gif',
                ),
              ),
            ]),
          ),
        ),
      );
      expect(find.text('Bo'), findsOneWidget);
      expect(find.text('look at this'), findsOneWidget);
      expect(find.byType(Image), findsOneWidget);
    });

    testWidgets('a GIF-only line needs no caption', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: ListView(children: [
              const ChatLineView(
                line: ChatLine(from: 'Bo', gif: 'https://media.tenor.com/g'),
              ),
            ]),
          ),
        ),
      );
      expect(find.text('Bo'), findsOneWidget);
      expect(find.byType(Image), findsOneWidget);
      // A lone GIF has nothing to say: no filler body text in the bubble.
      expect(find.text('sent a GIF'), findsNothing);
    });

    testWidgets('a dead GIF degrades to a note, not an empty gap', (
      tester,
    ) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: ListView(children: [
              const ChatLineView(
                line: ChatLine(from: 'Bo', gif: 'https://gone.example/x'),
              ),
            ]),
          ),
        ),
      );
      // The test binding answers network images with an immediate failure;
      // let the load fail and the errorBuilder replace the spinner.
      await tester.pumpAndSettle();
      expect(find.text('GIF unavailable'), findsOneWidget);
    });

    testWidgets('a voice note renders as a playable pill (static)', (
      tester,
    ) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: ListView(children: [
              const ChatLineView(
                line: ChatLine(from: 'Ana', note: VoiceNote(url: 'http://x/v', durMs: 7000)),
              ),
            ]),
          ),
        ),
      );
      // The pill shows the clip's length; playback itself is not tapped
      // here — audioplayers has no plugin in widget tests — only that the
      // pill and its play control exist.
      expect(find.text('0:07'), findsOneWidget);
      expect(find.byTooltip('Play voice note'), findsOneWidget);
    });

    testWidgets('a note with a caption keeps both in the bubble', (
      tester,
    ) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: ListView(children: [
              const ChatLineView(
                line: ChatLine(
                  from: 'Ana',
                  text: 'listen to this',
                  note: VoiceNote(url: 'http://x/v', durMs: 1200),
                ),
              ),
            ]),
          ),
        ),
      );
      expect(find.text('0:01'), findsOneWidget);
      expect(find.text('listen to this'), findsOneWidget);
    });
  });

  group('GifPickerSheet', () {
    testWidgets('pasting an https link sends it', (tester) async {
      String? picked;
      await openPicker(tester, serverUrl: 'ws://test/ws', onPick: (url) {
        picked = url;
      });

      await tester.enterText(
        linkField,
        'https://media.tenor.com/z/ghi.gif',
      );
      await tester.pump();

      await tester.tap(find.byTooltip('Send GIF'));
      await tester.pumpAndSettle();
      expect(picked, 'https://media.tenor.com/z/ghi.gif');
    });

    testWidgets('a non-https link stays disabled', (tester) async {
      String? picked;
      await openPicker(tester, serverUrl: 'ws://test/ws', onPick: (url) {
        picked = url;
      });

      await tester.enterText(
        linkField,
        'http://insecure.example/x.gif',
      );
      await tester.pump();

      final button = tester.widget<IconButton>(
        find.ancestor(
          of: find.byTooltip('Send GIF'),
          matching: find.byType(IconButton),
        ),
      );
      expect(button.onPressed, isNull);

      await tester.tap(find.byTooltip('Send GIF'));
      await tester.pump();
      expect(picked, isNull);
    });

    testWidgets('an empty link field cannot be sent', (tester) async {
      String? picked;
      await openPicker(tester, serverUrl: 'ws://test/ws', onPick: (url) {
        picked = url;
      });

      final button = tester.widget<IconButton>(
        find.ancestor(
          of: find.byTooltip('Send GIF'),
          matching: find.byType(IconButton),
        ),
      );
      expect(button.onPressed, isNull);
      expect(picked, isNull);
    });

    testWidgets('search failure surfaces the paste-path message', (
      tester,
    ) async {
      await openPicker(
        tester,
        serverUrl: 'ws://test/ws',
        onPick: (_) {},
        httpClient: MockClient(
          (_) async => http.Response(
            '{"ok":false,"text":"GIF search is not configured"}',
            503,
            headers: {'content-type': 'application/json'},
          ),
        ),
      );

      await tester.enterText(searchField, 'dog');
      await tester.tap(find.byTooltip('Search'));
      await tester.pumpAndSettle();

      expect(
        find.text('GIF search is not configured'),
        findsOneWidget,
        reason: 'the sheet repeats the server reason, pointing at the link path',
      );
    });

    testWidgets('a configured search shows a tappable grid', (tester) async {
      String? picked;
      await openPicker(
        tester,
        serverUrl: 'wss://game.example/ws',
        onPick: (url) {
          picked = url;
        },
        httpClient: MockClient(
          (req) => Future.value(
            http.Response(
              '{"ok":true,"gifs":[{"url":"https://media.tenor.com/a/full.gif",'
              '"preview":"https://media.tenor.com/a/tiny.gif",'
              '"desc":"celebration"}]}',
              200,
              headers: {'content-type': 'application/json'},
            ),
          ),
        ),
      );

      await tester.enterText(searchField, 'party');
      await tester.tap(find.byTooltip('Search'));
      await tester.pumpAndSettle();

      expect(find.text('celebration'), findsOneWidget);
      await tester.tap(find.text('celebration'));
      await tester.pumpAndSettle();
      expect(
        picked,
        'https://media.tenor.com/a/full.gif',
        reason: 'tapping a result sends the full-resolution url',
      );
    });
  });
}
