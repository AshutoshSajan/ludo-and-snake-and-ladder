/// The back gesture on a running game routes through the screen's leave
/// flow instead of popping raw — a raw pop only drops the socket (the server
/// reads that silence as "might be back soon" and seats a ghost) or simply
/// erases the in-memory match on a local board. Here: does the gesture reach
/// the flow, does a confirmed leave carry the flow through both of its
/// phases, and does a board with nothing at stake pass the back press
/// straight through.
///
/// One boundary by design: the interceptor never pops the route itself —
/// the screen owns its exit (the online lobby swaps its body for the
/// connect form; a pushed page pops). The widget only gates the gesture.
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:game_club/ui/shared/leave_guard.dart';

void main() {
  final key = GlobalKey<NavigatorState>();

  /// Two routes: a placeholder beneath, and the table route carrying the
  /// interceptor. A system back (`handlePopRoute`) targets the top route,
  /// which is exactly the Android-back situation this guards.
  Widget subject({required bool active, required List<String> calls}) =>
      MaterialApp(
        navigatorKey: key,
        initialRoute: '/table',
        routes: {
          '/': (_) => const Scaffold(body: Text('home')),
          '/table': (_) => LeaveGuard(
            active: active,
            // Mirrors the screens' `_leave`: confirm first, then do the leave
            // work. Recording 'left' is the flow's second phase landing.
            onLeave: () async {
              calls.add('leave-asked');
              final sure = await showDialog<bool>(
                context: key.currentState!.context,
                builder: (ctx) => AlertDialog(
                  title: const Text('Leave the game?'),
                  actions: [
                    TextButton(
                      onPressed: () => Navigator.pop(ctx, false),
                      child: const Text('Stay'),
                    ),
                    FilledButton(
                      onPressed: () => Navigator.pop(ctx, true),
                      child: const Text('Leave'),
                    ),
                  ],
                ),
              );
              if (sure != true) return;
              calls.add('left');
            },
            child: const Scaffold(body: Text('table')),
          ),
        },
      );

  testWidgets('back on an active table reaches the leave flow, not the route', (
    tester,
  ) async {
    final calls = <String>[];
    await tester.pumpWidget(subject(active: true, calls: calls));

    await tester.binding.handlePopRoute();
    await tester.pump();
    await tester.pump();

    expect(
      calls,
      ['leave-asked'],
      reason:
          'the gesture must be handed to the confirm flow — the pop '
          'decision is the dialog\'s, because a silent drop reads as a '
          'dead link at the other end of the table',
    );
    expect(
      find.text('table'),
      findsOneWidget,
      reason:
          'nothing was confirmed: the game screen stays, and the.Exit '
          'belongs to the screen after the flow says so',
    );
  });

  testWidgets('a confirmed leave carries the flow through both phases', (
    tester,
  ) async {
    final calls = <String>[];
    await tester.pumpWidget(subject(active: true, calls: calls));

    await tester.binding.handlePopRoute();
    await tester.pump();
    expect(find.byType(AlertDialog), findsOneWidget);
    await tester.tap(find.widgetWithText(FilledButton, 'Leave'));
    // The dialog's exit animation must actually run: the confirm value is
    // resolved at didPop, but the flow's awaits (and any teardown behind
    // them) only resume as the dialog leaves.
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pump();

    expect(
      calls,
      ['leave-asked', 'left'],
      reason:
          'a confirmed back press runs the same two phases as the '
          'leave button: ask, then do',
    );
  });

  testWidgets('the flow\'s Stay leaves the table untouched', (tester) async {
    final calls = <String>[];
    await tester.pumpWidget(subject(active: true, calls: calls));

    await tester.binding.handlePopRoute();
    await tester.pump();
    await tester.tap(find.widgetWithText(TextButton, 'Stay'));
    await tester.pump(const Duration(milliseconds: 300));

    expect(calls, ['leave-asked'], reason: 'a changed mind forfeits nothing');
    expect(find.text('table'), findsOneWidget);
  });

  testWidgets('an offline board passes the back press straight through', (
    tester,
  ) async {
    final calls = <String>[];
    await tester.pumpWidget(subject(active: false, calls: calls));

    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();

    expect(
      calls,
      isEmpty,
      reason: 'offline nobody holds a seat — back is plain navigation',
    );
    expect(find.text('table'), findsNothing);
  });
}
