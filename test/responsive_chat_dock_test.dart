/// The table chat has one layout on every online surface:
///
/// * wide windows dock it beside the play area, reserving its width so the
///   board/lobby is narrower rather than covered;
/// * phones keep the play area full-bleed and hide the panel until a labelled
///   launcher opens it as an overlay with a close control.
///
/// The panel is one subtree in both modes, so a draft typed in the phone
/// overlay survives closing it and resizing across the breakpoint.
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:game_club/services/online_client.dart';
import 'package:game_club/ui/shared/responsive_chat_dock.dart';
import 'package:game_club/ui/theme.dart';

void main() {
  OnlineClient clientWith({List<ChatLine> lines = const []}) {
    final client = OnlineClient('ws://via.test/ws', seatId: 'me', name: 'Me');
    client.chat.addAll(lines);
    return client;
  }

  Future<void> pumpDock(
    WidgetTester tester,
    OnlineClient client,
    Size size,
  ) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.dark(),
        home: Scaffold(
          body: ResponsiveChatDock(
            client: client,
            // The friends read is an HTTP call; the layout under test does
            // not need it and a live socket is never required.
            showFriends: false,
            child: SizedBox.expand(
              child: ColoredBox(
                color: AppColors.felt,
                child: const Center(child: Text('board')),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  const panel = Key('table-chat-panel');
  const launcher = Key('table-chat-launcher');
  const composer = Key('table-chat-composer');
  const content = Key('chat-dock-content');

  testWidgets('wide: the panel docks beside the content and reserves width', (
    tester,
  ) async {
    final client = clientWith(
      lines: [
        const ChatLine(from: 'Bo', text: 'hello from the table', seatId: 'bo'),
      ],
    );
    await pumpDock(tester, client, const Size(1440, 900));

    final panelRect = tester.getRect(find.byKey(panel));
    final contentRect = tester.getRect(find.byKey(content));

    expect(panelRect.width, kChatDockWidth);
    expect(
      panelRect.left,
      greaterThanOrEqualTo(contentRect.right),
      reason: 'the docked panel must sit outside the play area, never on it',
    );
    expect(
      contentRect.width,
      lessThanOrEqualTo(1440 - kChatDockWidth),
      reason: 'the play area gives the panel its own width',
    );
    expect(
      contentRect.width,
      greaterThan(700),
      reason: 'a 1440 window still leaves a roomy board column',
    );
    expect(
      find.byKey(composer).hitTestable(),
      findsOneWidget,
      reason: 'the transcript and pinned composer are visible on the dock',
    );
    expect(find.text('hello from the table'), findsOneWidget);
    expect(
      find.byKey(launcher),
      findsNothing,
      reason: 'a docked panel has no launcher to open it',
    );
  });

  testWidgets('narrow: chat stays hidden until the labelled launcher opens it, '
      'then closes from its own control', (tester) async {
    final client = clientWith(
      lines: [const ChatLine(from: 'Bo', text: 'are you there?', seatId: 'bo')],
    );
    await pumpDock(tester, client, const Size(390, 844));

    expect(find.byKey(launcher), findsOneWidget);
    expect(find.byTooltip('Open table chat'), findsOneWidget);
    expect(
      tester.getRect(find.byKey(panel)).left,
      greaterThanOrEqualTo(390),
      reason: 'the phone keeps the whole screen for the board until asked',
    );
    expect(find.byKey(composer).hitTestable(), findsNothing);

    await tester.tap(find.byKey(launcher));
    await tester.pumpAndSettle();

    final openRect = tester.getRect(find.byKey(panel));
    expect(openRect.left, lessThan(390));
    expect(openRect.width, lessThanOrEqualTo(390 - 24));
    expect(find.byKey(composer).hitTestable(), findsOneWidget);
    expect(find.text('are you there?'), findsOneWidget);
    expect(find.byTooltip('Close chat'), findsOneWidget);

    await tester.tap(find.byKey(const Key('table-chat-close')));
    await tester.pumpAndSettle();

    expect(
      tester.getRect(find.byKey(panel)).left,
      greaterThanOrEqualTo(390),
      reason: 'the close control dismisses the overlay',
    );
    expect(find.byKey(launcher), findsOneWidget);
  });

  testWidgets('a draft survives closing the overlay and crossing the '
      'breakpoint', (tester) async {
    final client = clientWith();
    await pumpDock(tester, client, const Size(390, 844));

    await tester.tap(find.byKey(launcher));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(composer), 'draft survives');
    await tester.pump();

    await tester.tap(find.byKey(const Key('table-chat-close')));
    await tester.pumpAndSettle();
    expect(find.byKey(composer).hitTestable(), findsNothing);

    // Narrow -> wide: the same panel subtree becomes the docked panel.
    tester.view.physicalSize = const Size(1440, 900);
    await tester.pumpAndSettle();
    expect(find.byKey(composer).hitTestable(), findsOneWidget);
    expect(find.text('draft survives'), findsOneWidget);

    // Wide -> narrow: still the same controller, now behind the launcher.
    tester.view.physicalSize = const Size(390, 844);
    await tester.pumpAndSettle();
    expect(find.byKey(composer).hitTestable(), findsNothing);
    expect(find.byKey(launcher), findsOneWidget);

    await tester.tap(find.byKey(launcher));
    await tester.pumpAndSettle();
    expect(find.text('draft survives'), findsOneWidget);

    // Tidy: a focused field on a hidden panel is a test no-no; close it.
    await tester.tap(find.byKey(const Key('table-chat-close')));
    await tester.pumpAndSettle();
  });

  testWidgets('wide: the dock collapses to the launcher and keeps the draft', (
    tester,
  ) async {
    final client = clientWith();
    await pumpDock(tester, client, const Size(1440, 900));

    expect(find.byTooltip('Collapse chat'), findsOneWidget);
    final dockedContent = tester.getRect(find.byKey(content)).width;

    await tester.enterText(find.byKey(composer), 'draft while docked');
    await tester.pump();
    await tester.tap(find.byKey(const Key('table-chat-collapse')));
    await tester.pumpAndSettle();

    expect(find.byKey(launcher), findsOneWidget);
    expect(find.byTooltip('Open table chat'), findsOneWidget);
    expect(
      find.byKey(composer).hitTestable(),
      findsNothing,
      reason: 'the collapsed panel slides off the right edge',
    );
    expect(
      tester.getRect(find.byKey(content)).width,
      1440,
      reason: 'the board/lobby reclaims the reserved dock strip',
    );
    expect(
      tester.getRect(find.byKey(content)).width,
      greaterThan(dockedContent + 100),
    );

    await tester.tap(find.byKey(launcher));
    await tester.pumpAndSettle();

    expect(find.byKey(composer).hitTestable(), findsOneWidget);
    expect(
      find.text('draft while docked'),
      findsOneWidget,
      reason: 'collapsing folds the panel away; it does not rebuild its state',
    );
    expect(find.byKey(launcher), findsNothing);
    expect(find.byTooltip('Collapse chat'), findsOneWidget);
  });
}
