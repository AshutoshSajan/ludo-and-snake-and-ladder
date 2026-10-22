/// The route table and the cold-load paths.
///
/// Two layers are pinned here: [parseAppRoute] turns every URL the app can
/// be opened at into a typed route (including the `?watch=1` join variant
/// and the incomplete-URL fallbacks), and [appInitialRoutes] builds the
/// first stack so the browser's address is honored without duplicating
/// parent screens.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:game_club/app_router.dart';
import 'package:game_club/app_routes.dart';
import 'package:game_club/main.dart';
import 'package:game_club/screens/home_screen.dart';
import 'package:game_club/screens/online_lobby_screen.dart';
import 'package:game_club/services/join_link.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('parseAppRoute', () {
    test('the root is home', () {
      expect(parseAppRoute(Uri.parse('/')), isA<HomeRoute>());
      expect(parseAppRoute(Uri.parse('')), isA<HomeRoute>());
    });

    test('the single-segment pages map to their routes', () {
      final routes = <String, Matcher>{
        '/online': isA<OnlineRoute>(),
        '/friends': isA<FriendsRoute>(),
        '/leaderboard': isA<LeaderboardRoute>(),
        '/settings': isA<SettingsRoute>(),
        '/rules': isA<RulesRoute>(),
        '/contact': isA<ContactRoute>(),
        '/admin': isA<AdminRoute>(),
        '/admin/dashboard': isA<AdminDashboardRoute>(),
      };
      for (final entry in routes.entries) {
        expect(
          parseAppRoute(Uri.parse(entry.key)),
          entry.value,
          reason: entry.key,
        );
      }
    });

    test('play and live-game paths carry the game', () {
      expect(
        (parseAppRoute(Uri.parse('/play/ludo')) as PlayRoute).game,
        PlayGame.ludo,
      );
      expect(
        (parseAppRoute(Uri.parse('/play/snakes')) as PlayRoute).game,
        PlayGame.snakes,
      );
      expect(
        (parseAppRoute(Uri.parse('/game/ludo')) as GameRoute).game,
        PlayGame.ludo,
      );
      expect(
        (parseAppRoute(Uri.parse('/game/snakes')) as GameRoute).game,
        PlayGame.snakes,
      );
    });

    test('a join code is canonicalized uppercase', () {
      final route = parseAppRoute(Uri.parse('/join/abcd')) as JoinRoute;
      expect(route.code, 'ABCD');
      expect(route.watch, isFalse);
      expect(route.location, '/join/ABCD');
    });

    test('the join query carries spectator intent', () {
      final one = parseAppRoute(Uri.parse('/join/ABCD?watch=1')) as JoinRoute;
      expect(one.watch, isTrue);
      expect(one.location, '/join/ABCD?watch=1');

      final spelled =
          parseAppRoute(Uri.parse('/join/ABCD?watch=true')) as JoinRoute;
      expect(spelled.watch, isTrue);

      final off = parseAppRoute(Uri.parse('/join/ABCD?watch=0')) as JoinRoute;
      expect(off.watch, isFalse);
    });

    test('path names are case-insensitive and tolerate a trailing slash', () {
      expect(parseAppRoute(Uri.parse('/ONLINE/')), isA<OnlineRoute>());
      expect(parseAppRoute(Uri.parse('/Play/Ludo')), isA<PlayRoute>());
    });

    test('incomplete and unknown paths fall back to UnknownRoute', () {
      for (final path in const [
        '/join',
        '/join/AB',
        '/join/ABCDE',
        '/join/ABCD/extra',
        '/does-not-exist',
        '/friends/unknown',
      ]) {
        expect(
          parseAppRoute(Uri.parse(path)),
          isA<UnknownRoute>(),
          reason: path,
        );
      }
    });

    test('a chat path knows it is a cold-load parent route', () {
      final route = parseAppRoute(
        Uri.parse('/friends/chat/seat%201'),
      ) as FriendsChatRoute;
      expect(route.seatId, 'seat 1');
      expect(
        route.location,
        AppRoutes.friends,
        reason: 'a chat cannot rebuild without its live client',
      );
    });
  });

  group('join links', () {
    test('resolve from the site root with a canonical code', () {
      expect(
        joinLinkFor(
          ' abcd ',
          base: Uri.parse('https://game.club/some/page?x=1'),
        ),
        'https://game.club/join/ABCD',
      );
    });

    test('keep a nonstandard port from the page origin', () {
      expect(
        joinLinkFor('LK2X', base: Uri.parse('http://localhost:3000/')),
        'http://localhost:3000/join/LK2X',
      );
    });

    test('carry the spectator query when asked', () {
      expect(
        joinLinkFor('LK2X', base: Uri.parse('https://game.club/'), watch: true),
        'https://game.club/join/LK2X?watch=1',
      );
    });
  });

  group('appInitialRoutes', () {
    test('home sits under a deep link, with no duplicate parents', () {
      List<String?> names(String path) =>
          appInitialRoutes(path).map((r) => r.settings.name).toList();

      expect(names('/join/ABCD'), ['/', '/join/ABCD']);
      expect(names('/friends/chat/seat-1'), [
        '/',
        '/friends',
      ], reason: 'the chat and its tray are one parent, not two');
      expect(names('/game/ludo'), [
        '/',
        '/play/ludo',
      ], reason: 'a live game needs seats; the setup screen rebuilds them');
    });

    test('unknown and incomplete paths start at home only', () {
      expect(appInitialRoutes('/does-not-exist').map((r) => r.settings.name), [
        '/',
      ]);
      expect(appInitialRoutes('/join').map((r) => r.settings.name), ['/']);
    });

    test('the admin routes are unregistered off the hosted web app', () {
      // flutter test runs on the VM, so isAdminUiAvailable is false.
      expect(appRouteBuilder(const RouteSettings(name: '/admin')), isNull);
      expect(
        appRouteBuilder(const RouteSettings(name: '/admin/dashboard')),
        isNull,
      );
      expect(appInitialRoutes('/admin').map((r) => r.settings.name), ['/']);
    });
  });

  group('cold browser URLs', () {
    testWidgets('/join/ABCD opens the lobby with the code, no socket', (
      tester,
    ) async {
      SharedPreferences.setMockInitialValues({'gc.tutorialAsked': true});
      tester.binding.platformDispatcher.defaultRouteNameTestValue =
          '/join/ABCD';
      addTearDown(
        tester.binding.platformDispatcher.clearDefaultRouteNameTestValue,
      );

      await tester.pumpWidget(const ProviderScope(child: GameClubApp()));
      await tester.pumpAndSettle();

      expect(find.byType(OnlineLobbyScreen), findsOneWidget);
      final lobby = tester.widget<OnlineLobbyScreen>(
        find.byType(OnlineLobbyScreen),
      );
      expect(lobby.startup?.joinCode, 'ABCD');
      expect(lobby.startup?.watch, isFalse);
      // First visit, no stored name: the invite card waits for an answer
      // instead of dialing a room under a generated name.
      expect(find.byKey(const Key('invite-card')), findsOneWidget);
      expect(find.text("You're invited to room ABCD"), findsOneWidget);
      expect(find.byType(HomeScreen), findsNothing);
    });

    testWidgets('/join/ABCD?watch=1 remembers the spectator intent', (
      tester,
    ) async {
      SharedPreferences.setMockInitialValues({'gc.tutorialAsked': true});
      tester.binding.platformDispatcher.defaultRouteNameTestValue =
          '/join/ABCD?watch=1';
      addTearDown(
        tester.binding.platformDispatcher.clearDefaultRouteNameTestValue,
      );

      await tester.pumpWidget(const ProviderScope(child: GameClubApp()));
      await tester.pumpAndSettle();

      final lobby = tester.widget<OnlineLobbyScreen>(
        find.byType(OnlineLobbyScreen),
      );
      expect(lobby.startup?.joinCode, 'ABCD');
      expect(lobby.startup?.watch, isTrue);
      expect(find.text("You're invited to watch room ABCD"), findsOneWidget);
    });

    testWidgets('a mistyped URL is still the home screen', (tester) async {
      SharedPreferences.setMockInitialValues({'gc.tutorialAsked': true});
      tester.binding.platformDispatcher.defaultRouteNameTestValue = '/nope';
      addTearDown(
        tester.binding.platformDispatcher.clearDefaultRouteNameTestValue,
      );

      await tester.pumpWidget(const ProviderScope(child: GameClubApp()));
      await tester.pumpAndSettle();

      expect(find.byType(HomeScreen), findsOneWidget);
      expect(find.text('Ludo'), findsOneWidget);
      expect(find.byType(OnlineLobbyScreen), findsNothing);
    });
  });
}
