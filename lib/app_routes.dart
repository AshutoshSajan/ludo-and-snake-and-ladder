/// The app's route table: every URL the app can be opened at, and the one
/// parser that turns a path back into a screen description.
///
/// This file deliberately imports no screens. [app_router.dart] owns the
/// mapping from these typed routes to widgets, so a screen can name a route
/// (for the browser URL and back/forward) without pulling the router into a
/// widget test. The direct-join path is shared with the room-code card via
/// `services/join_link.dart`, so the copied link and the parsed route can
/// never disagree about casing or the spectator query.
library;

import 'services/join_link.dart';

/// Path constants and builders. Use these instead of spelling a path at a
/// call site: the parser and the pushes then agree by construction.
abstract final class AppRoutes {
  static const home = '/';
  static const online = '/online';
  static const friends = '/friends';
  static const leaderboard = '/leaderboard';
  static const settings = '/settings';
  static const rules = '/rules';
  static const contact = '/contact';
  static const playLudo = '/play/ludo';
  static const playSnakes = '/play/snakes';
  static const gameLudo = '/game/ludo';
  static const gameSnakes = '/game/snakes';
  static const admin = '/admin';
  static const adminLogin = '/admin/login';
  static const adminSignup = '/admin/signup';
  static const adminDashboard = '/admin/dashboard';

  /// The shareable room path, optionally as a spectator.
  static String join(String code, {bool watch = false}) =>
      joinPathFor(code, watch: watch);

  /// The 1:1 chat path. A seat id is optional because the chat needs a live
  /// client and peer object, so a cold load of this path lands on the
  /// friends tray instead (see [app_router.dart]).
  static String friendsChat(String? seatId) => seatId == null
      ? '/friends/chat'
      : '/friends/chat/${Uri.encodeComponent(seatId)}';
}

/// Which game a play/game route refers to.
enum PlayGame {
  ludo('ludo', AppRoutes.playLudo, AppRoutes.gameLudo),
  snakes('snakes', AppRoutes.playSnakes, AppRoutes.gameSnakes);

  const PlayGame(this.id, this.playPath, this.gamePath);

  /// The wire spelling the online client and server use.
  final String id;

  /// The setup screen for the game.
  final String playPath;

  /// The live game screen. It carries seats from the setup flow, so a cold
  /// load of this path falls back to [playPath].
  final String gamePath;
}

/// A parsed route. Screen-building code switches on the subtype; tests can
/// assert on it without pumping a widget.
sealed class AppRoute {
  const AppRoute();

  /// The canonical URL for this route. For screens that need live runtime
  /// state, this is the safe parent a cold load lands on, not a URL that
  /// pretends the state survived.
  String get location;
}

final class HomeRoute extends AppRoute {
  const HomeRoute();

  @override
  String get location => AppRoutes.home;
}

final class OnlineRoute extends AppRoute {
  const OnlineRoute();

  @override
  String get location => AppRoutes.online;
}

final class JoinRoute extends AppRoute {
  JoinRoute(String code, {this.watch = false}) : code = normalizeJoinCode(code);

  /// Canonical uppercase room code.
  final String code;

  /// Open as a spectator (`?watch=1`).
  final bool watch;

  @override
  String get location => AppRoutes.join(code, watch: watch);
}

final class FriendsRoute extends AppRoute {
  const FriendsRoute();

  @override
  String get location => AppRoutes.friends;
}

/// A cold load of a chat path has no live client or peer, so it lands on the
/// friends tray. In-app pushes still carry the live chat directly.
final class FriendsChatRoute extends AppRoute {
  const FriendsChatRoute(this.seatId);

  final String? seatId;

  @override
  String get location => AppRoutes.friends;
}

final class LeaderboardRoute extends AppRoute {
  const LeaderboardRoute();

  @override
  String get location => AppRoutes.leaderboard;
}

final class SettingsRoute extends AppRoute {
  const SettingsRoute();

  @override
  String get location => AppRoutes.settings;
}

final class RulesRoute extends AppRoute {
  const RulesRoute();

  @override
  String get location => AppRoutes.rules;
}

final class ContactRoute extends AppRoute {
  const ContactRoute();

  @override
  String get location => AppRoutes.contact;
}

/// The setup screen for [game].
final class PlayRoute extends AppRoute {
  const PlayRoute(this.game);

  final PlayGame game;

  @override
  String get location => game.playPath;
}

/// A live game. Its seats are runtime state, so [location] names the setup
/// screen a cold load returns to.
final class GameRoute extends AppRoute {
  const GameRoute(this.game);

  final PlayGame game;

  @override
  String get location => game.playPath;
}

/// The /admin entry: the server's state decides what opens here, so the
/// URL stays mode-neutral and the auth gate hands off (see
/// [app_router.dart]).
final class AdminRoute extends AppRoute {
  const AdminRoute();

  @override
  String get location => AppRoutes.admin;
}

/// The sign-in screen, at its own URL. A cold load is honest about the
/// mode it serves and re-checks the server on mount; if the mode is stale
/// the screen moves to the matching URL instead of fighting the server.
final class AdminLoginRoute extends AppRoute {
  const AdminLoginRoute();

  @override
  String get location => AppRoutes.adminLogin;
}

/// First-run setup (creating the club's first admin), as its own URL.
final class AdminSignupRoute extends AppRoute {
  const AdminSignupRoute();

  @override
  String get location => AppRoutes.adminSignup;
}

/// The signed-in dashboard. It needs a live [AdminClient], so a cold load
/// returns to the sign-in screen.
final class AdminDashboardRoute extends AppRoute {
  const AdminDashboardRoute();

  @override
  String get location => AppRoutes.admin;
}

/// A path the table does not know. The navigator answers with home.
final class UnknownRoute extends AppRoute {
  const UnknownRoute(this.path);

  final String path;

  @override
  String get location => path;
}

final _roomCode = RegExp(r'^[A-Z0-9]{4}$');

/// Parses a path plus query into a typed route.
///
/// Path matching is case-insensitive (people type URLs); the room code is
/// canonicalized to uppercase because the server and the load balancer key
/// rooms by that spelling. Anything unknown — an extra segment, a missing
/// code, a non-code join path — answers [UnknownRoute] and the navigator
/// falls back to home.
AppRoute parseAppRoute(Uri uri) {
  final parts = [
    for (final part in uri.pathSegments)
      if (part.isNotEmpty) part.toLowerCase(),
  ];
  if (parts.isEmpty) return const HomeRoute();

  return switch (parts) {
    ['online'] => const OnlineRoute(),
    ['friends'] => const FriendsRoute(),
    ['friends', 'chat'] => const FriendsChatRoute(null),
    ['friends', 'chat', final seatId] => FriendsChatRoute(seatId),
    ['leaderboard'] => const LeaderboardRoute(),
    ['settings'] => const SettingsRoute(),
    ['rules'] => const RulesRoute(),
    ['contact'] => const ContactRoute(),
    ['play', 'ludo'] => const PlayRoute(PlayGame.ludo),
    ['play', 'snakes'] => const PlayRoute(PlayGame.snakes),
    ['game', 'ludo'] => const GameRoute(PlayGame.ludo),
    ['game', 'snakes'] => const GameRoute(PlayGame.snakes),
    ['admin'] => const AdminRoute(),
    ['admin', 'login'] => const AdminLoginRoute(),
    ['admin', 'signup'] => const AdminSignupRoute(),
    ['admin', 'dashboard'] => const AdminDashboardRoute(),
    ['join', final code] when _roomCode.hasMatch(code.toUpperCase()) =>
      JoinRoute(code, watch: _wantsWatch(uri)),
    _ => UnknownRoute(uri.hasQuery ? '${uri.path}?${uri.query}' : uri.path),
  };
}

/// `?watch=1` is the spectator spelling the invite link shares; `true` is
/// accepted too because a hand-typed URL should not need the exact digit.
bool _wantsWatch(Uri uri) {
  final value = uri.queryParameters['watch']?.toLowerCase();
  return value == '1' || value == 'true';
}
