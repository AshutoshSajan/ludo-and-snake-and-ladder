/// Builds the screens behind route names, and the web router that keeps the
/// browser's address bar and history in step with them.
///
/// This is the only file that knows both the route table and the widgets, so
/// [app_routes.dart] stays importable from screens and tests without a
/// screen-import cycle. Cold loads and deep links come through the delegate's
/// page stack; screens push through [pushAppScreen] / [replaceAppScreen] /
/// [resetAppScreen], which record the entry with the app's URL set — the
/// address bar moves on push, browser back returns to the previous screen,
/// and browser forward returns to the pushed one. In widget tests (a plain
/// Navigator with no router around it) the same helpers fall back to the
/// ordinary `MaterialPageRoute` push, so tests exercise the same widgets
/// through the same buttons.
library;

import 'dart:async' show Completer;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show SystemNavigator;

import 'app_routes.dart';
import 'engine/core/player_profiles.dart';
import 'screens/admin/admin_gate.dart';
import 'screens/admin/admin_login_screen.dart'
    if (dart.library.io) 'screens/admin/admin_login_stub.dart';
import 'screens/contact_screen.dart';
import 'screens/friends_screen.dart';
import 'screens/home_screen.dart';
import 'screens/invite_watcher.dart';
import 'screens/online_lobby_screen.dart';
import 'screens/rules_screen.dart';
import 'screens/scoreboard_screen.dart';
import 'screens/settings_screen.dart';
import 'screens/setup_screen.dart';
import 'services/server_url.dart';

/// The screen and the canonical URL for one parsed route.
typedef _Target = ({Widget screen, String location});

/// Builds a screen for a route name, or null when the path is not ours.
///
/// Returning null lets callers drop an incomplete prefix such as `/join`
/// while keeping home below. A runtime `pushNamed` of an unknown path is
/// answered by home through the same fallback the material world had.
Route<dynamic>? appRouteBuilder(RouteSettings settings) {
  final route = parseAppRoute(Uri.parse(settings.name ?? AppRoutes.home));
  final target = _targetFor(route);
  if (target == null) return null;
  return MaterialPageRoute<dynamic>(
    // Keep the canonical spelling in the address bar: `/join/abcd?watch=true`
    // becomes `/join/ABCD?watch=1` once the lobby is open.
    settings: RouteSettings(name: target.location),
    builder: (_) => target.screen,
  );
}

/// The fallback for a URL the table does not know: home, never a blank page.
Route<dynamic> appUnknownRoute(RouteSettings settings) =>
    MaterialPageRoute<dynamic>(
      settings: const RouteSettings(name: AppRoutes.home),
      builder: (_) => const HomeScreen(),
    );

/// Builds the first stack from the URL the browser opened.
///
/// Home always sits at the bottom so back leaves the deep-linked screen
/// instead of leaving the app, and the deep-linked screen has no duplicate
/// parents: `/friends/chat/<id>` opens the friends tray once, not a tray for
/// every path prefix. Screens that need live objects land on their safe
/// parent — the setup screen for a game, the sign-in screen for the admin
/// dashboard — because those objects cannot survive a page reload.
List<Route<dynamic>> appInitialRoutes(String initialRouteName) {
  final home = appRouteBuilder(const RouteSettings(name: AppRoutes.home))!;
  final requested = appRouteBuilder(RouteSettings(name: initialRouteName));
  if (requested == null || requested.settings.name == AppRoutes.home) {
    return [home];
  }
  return [home, requested];
}

// ---------------------------------------------------------------------------
// The web router
// ---------------------------------------------------------------------------

/// One screen on the router's stack: the canonical URL it represents and the
/// screen widget it shows. Live screens (a connected client, a roster of
/// seats) build their runtime state on the spot; the URL records the *path*
/// the screen sits at, which on a reload degrades to the safe parent
/// ([parseAppRoute] → [AppRoute.location]).
final class _StackEntry {
  _StackEntry(this.name, this.builder) : id = Object();

  final String name;
  final WidgetBuilder builder;
  final Object id;

  final Completer<Object?> _popped = Completer<Object?>();

  /// The pop result for a screen that awaits its future.
  Future<Object?> get popped => _popped.future;

  void _close([Object? result]) {
    if (_popped.isCompleted) return;
    _popped.complete(result);
  }
}

/// A pushed screen, returned from the push helpers so callers can close it
/// themselves (the hand-off pattern: push first, connect, pop again when the
/// connect fails) or await [popped] like the route a push used to return.
final class AppHandle<T> {
  AppHandle._(this._entry, this._stack, this._route);

  final _StackEntry? _entry;
  final _AppStack? _stack;
  final Route<T>? _route;

  /// Whether this entry is the screen currently on top of the stack.
  bool get isCurrent {
    final stack = _stack;
    final entry = _entry;
    if (stack != null && entry != null) return stack._isTop(entry);
    return _route?.isCurrent ?? false;
  }

  /// Removes this screen, carrying [result] back to whoever awaited the push.
  void pop([T? result]) {
    final stack = _stack;
    final entry = _entry;
    if (stack != null && entry != null) {
      stack._closeExact(entry, result);
      return;
    }
    _route?.navigator?.pop(result);
  }

  /// The result of the eventual pop, like the future a route push returns.
  Future<T?> get popped {
    final stack = _stack;
    final entry = _entry;
    if (stack != null && entry != null) {
      return stack._awaitEntry(entry) as Future<T?>;
    }
    return _route?.popped ?? Future<T?>.value();
  }
}

/// A handle over the app's screen stack while the web Router is mounted.
///
/// Provided above the Navigator, so any context inside the screens — and the
/// app's own navigator-owned listener for invites — can find it.
final class _AppStackScope extends InheritedWidget {
  const _AppStackScope({required this.stack, required super.child});

  final _AppStack stack;

  static _AppStack? maybeOf(BuildContext context) {
    final scope = context.dependOnInheritedWidgetOfExactType<_AppStackScope>();
    return scope?.stack;
  }

  @override
  bool updateShouldNotify(_AppStackScope oldWidget) => false;
}

/// The runtime stack behind the app's [Router]: material pages built from
/// [_StackEntry]s whose names are always real URLs.
final class _AppStack extends RouterDelegate<Object>
    with ChangeNotifier, PopNavigatorRouterDelegateMixin<Object> {
  @override
  final GlobalKey<NavigatorState> navigatorKey = InviteWatcher.navigatorKey;

  _AppStack(Uri initialUri) {
    // Seed from the browser URL before the provider's value lands, so the
    // first frame already shows the deep-linked screen on a cold load. The
    // provider overrides this with the same answer moments later — and on
    // native, where Uri.base is a file path, the seed simply resolves home.
    _resetFromPath(initialUri);
  }

  final List<_StackEntry> _entries = [];

  bool _isTop(_StackEntry entry) =>
      _entries.isNotEmpty && _entries.last.id == entry.id;

  Future<Object?> _awaitEntry(_StackEntry entry) => entry.popped;

  _StackEntry get _home => _entryFor(const HomeRoute());

  _StackEntry _entryFor(AppRoute route) {
    final target = _targetFor(route);
    return _StackEntry(
      target?.location ?? AppRoutes.home,
      (_) => target?.screen ?? const HomeScreen(),
    );
  }

  /// Home + the URL the browser opened; unknown paths are just home.
  void _resetFromPath(Uri uri) {
    final route = parseAppRoute(uri);
    final entries = [_home];
    if (_targetFor(route) != null && route.location != AppRoutes.home) {
      entries.add(_entryFor(route));
    }
    _entries
      ..clear()
      ..addAll(entries);
  }

  @override
  Object? get currentConfiguration {
    if (_entries.isEmpty) return const HomeRoute();
    return parseAppRoute(Uri.parse(_entries.last.name));
  }

  @override
  Future<void> setNewRoutePath(Object? configuration) {
    // Typed URLs, browser back and browser forward all arrive here. The
    // stack is rebuilt from the parsed route — live screens degrade to
    // their safe parent, which is the honest answer for a restart anyway.
    final route = configuration is AppRoute ? configuration : null;
    _resetFromPath(route == null ? Uri() : Uri.parse(route.location));
    notifyListeners();
    return SynchronousFuture<void>(null);
  }

  /// Mutates the stack for one push/replace/reset and returns the entry the
  /// handle keeps so it can later close itself.
  _StackEntry _book(
    WidgetBuilder builder,
    String name, {
    bool replace = false,
    bool toRoot = false,
  }) {
    final entry = _StackEntry(name, builder);
    if (toRoot) {
      _entries
        ..clear()
        ..add(entry);
    } else {
      if (replace && _entries.length > 1) _entries.removeLast();
      _entries.add(entry);
    }
    notifyListeners();
    return entry;
  }

  void _closeExact(_StackEntry entry, [Object? result]) {
    // A back swipe can pop the entry through the navigator first; the entry
    // id match keeps the bookkeeping to exactly once either way.
    if (!_isTop(entry)) return;
    _entries.removeLast()._close(result);
    notifyListeners();
  }

  @override
  Widget build(BuildContext context) {
    return _AppStackScope(
      stack: this,
      child: Navigator(
        key: navigatorKey,
        pages: [
          for (final entry in _entries)
            MaterialPage<Object?>(
              key: ValueKey(entry.id),
              name: entry.name,
              child: Builder(builder: entry.builder),
            ),
        ],
        onDidRemovePage: (page) {
          final key = page.key;
          if (key is! ValueKey<Object>) return;
          final at = _entries.indexWhere((e) => e.id == key.value);
          // Page removals only belong to this router's own bookkeeping;
          // pageless dialogs never report here.
          if (at <= 0) return;
          _entries[at]._close();
          _entries.removeAt(at);
          notifyListeners();
        },
        // Named pushes that are not the router's own stack (a legacy caller
        // or a test) still land on a real screen: known paths open their
        // page, unknown paths fall back to home. This never runs for the
        // app's own navigation — that goes through the URL helpers above.
        onGenerateRoute: appRouteBuilder,
        onUnknownRoute: appUnknownRoute,
      ),
    );
  }

  @override
  Future<bool> popRoute() {
    final navigator = navigatorKey.currentState;
    if (navigator == null) return SynchronousFuture<bool>(false);
    if (!navigator.canPop()) {
      // At the root: the browser tab closes (web) or the app exits (native).
      return SystemNavigator.pop().then((_) => false);
    }
    return navigator.maybePop().then((_) => _entries.length > 1);
  }
}

/// Builds the wiring object for one [GameClubApp] instance.
///
/// The stack belongs to the app instance, not to a process-wide singleton:
/// a fresh mount starts from the URL it was opened at instead of inheriting
/// another instance's last screen. That matters for deep links and for tests
/// that pump the app more than once in a process.
RouterConfig<Object> createAppRouterConfig() {
  final initial = _initialAppUri();
  return RouterConfig<Object>(
    routerDelegate: _AppStack(initial),
    routeInformationParser: _AppRouteParser(),
    routeInformationProvider: PlatformRouteInformationProvider(
      initialRouteInformation: RouteInformation(uri: initial),
    ),
    backButtonDispatcher: RootBackButtonDispatcher(),
  );
}

/// The URL this app was opened at.
///
/// On the web that is [Uri.base] (path and query included, so
/// `/join/ABCD?watch=1` survives a refresh). Off the web — where `Uri.base`
/// is the working directory — take the platform's initial route name, which
/// is also what `flutter test` sets through `defaultRouteNameTestValue`.
Uri _initialAppUri() {
  if (!kIsWeb) {
    final name = WidgetsBinding.instance.platformDispatcher.defaultRouteName;
    if (name.startsWith('/') && name != AppRoutes.home) {
      return Uri.parse(name);
    }
  }
  return Uri.base;
}

final class _AppRouteParser extends RouteInformationParser<Object> {
  @override
  Future<Object> parseRouteInformation(RouteInformation information) {
    return SynchronousFuture<Object>(parseAppRoute(information.uri));
  }

  @override
  RouteInformation? restoreRouteInformation(Object? configuration) {
    if (configuration is! AppRoute) return null;
    return RouteInformation(uri: Uri.parse(configuration.location));
  }
}

// ---------------------------------------------------------------------------
// Screen-facing push helpers
// ---------------------------------------------------------------------------

/// Pushes a screen through the app's URL history.
///
/// [name] is the URL the screen sits at; the browser's address bar moves to
/// it, browser back returns to the previous screen with its state intact,
/// and browser forward returns here. Without a router around the context —
/// every widget test — the same happens through the plain push the screens
/// have always made, so tests drive identical buttons.
AppHandle<T> pushAppScreen<T>(
  BuildContext context, {
  required WidgetBuilder builder,
  required String name,
}) {
  final stack = _AppStackScope.maybeOf(context);
  if (stack != null) {
    final entry = stack._book(builder, name);
    return AppHandle<T>._(entry, stack, null);
  }
  final route = MaterialPageRoute<T>(
    settings: RouteSettings(name: name),
    builder: builder,
  );
  Navigator.of(context).push<T>(route);
  return AppHandle<T>._(null, null, route);
}

/// Like [pushAppScreen], but the replaced screen is gone: back skips it.
///
/// The replaced screen is never the bottom of the stack — replacing home is
/// a push — so the reading-width column beneath the game screen survives.
AppHandle<T> replaceAppScreen<T>(
  BuildContext context, {
  required WidgetBuilder builder,
  required String name,
}) {
  final stack = _AppStackScope.maybeOf(context);
  if (stack != null) {
    final entry = stack._book(builder, name, replace: true);
    return AppHandle<T>._(entry, stack, null);
  }
  final route = MaterialPageRoute<T>(
    settings: RouteSettings(name: name),
    builder: builder,
  );
  Navigator.of(context).pushReplacement<T, Object?>(route);
  return AppHandle<T>._(null, null, route);
}

/// Clears everything below the new screen — it becomes the one root.
AppHandle<T> resetAppScreen<T>(
  BuildContext context, {
  required WidgetBuilder builder,
  required String name,
}) {
  final stack = _AppStackScope.maybeOf(context);
  if (stack != null) {
    final entry = stack._book(builder, name, toRoot: true);
    return AppHandle<T>._(entry, stack, null);
  }
  final route = MaterialPageRoute<T>(
    settings: RouteSettings(name: name),
    builder: builder,
  );
  Navigator.of(context).pushAndRemoveUntil<T>(route, (_) => false);
  return AppHandle<T>._(null, null, route);
}

_Target? _targetFor(AppRoute route) {
  return switch (route) {
    HomeRoute() => (screen: const HomeScreen(), location: AppRoutes.home),
    OnlineRoute() => (
      screen: const OnlineLobbyScreen(),
      location: AppRoutes.online,
    ),
    JoinRoute(:final code, :final watch) => (
      screen: OnlineLobbyScreen(
        startup: OnlineStartup(joinCode: code, watch: watch),
      ),
      location: route.location,
    ),
    FriendsRoute() => (
      screen: const FriendsScreen(),
      location: AppRoutes.friends,
    ),
    // The chat needs a live FriendClient and the peer's entry. A cold load
    // returns to the tray that owns both.
    FriendsChatRoute() => (
      screen: const FriendsScreen(),
      location: AppRoutes.friends,
    ),
    LeaderboardRoute() => (
      screen: const ScoreboardScreen(),
      location: AppRoutes.leaderboard,
    ),
    SettingsRoute() => (
      screen: const SettingsScreen(),
      location: AppRoutes.settings,
    ),
    RulesRoute() => (screen: const RulesScreen(), location: AppRoutes.rules),
    ContactRoute() => (
      screen: ContactScreen(serverUrl: defaultServerUrl()),
      location: AppRoutes.contact,
    ),
    PlayRoute(:final game) => (
      screen: SetupScreen(game: _kind(game)),
      location: game.playPath,
    ),
    // A game's seats are runtime state; the setup screen is the parent that
    // can rebuild them.
    GameRoute(:final game) => (
      screen: SetupScreen(game: _kind(game)),
      location: game.playPath,
    ),
    AdminRoute() => _adminTarget(const AdminLoginScreen(), AppRoutes.admin),
    // The dashboard needs the signed-in client; a reload starts at sign-in.
    AdminDashboardRoute() => _adminTarget(
      const AdminLoginScreen(),
      AppRoutes.admin,
    ),
    UnknownRoute() => null,
  };
}

_Target? _adminTarget(Widget screen, String location) {
  // Native builds never compile the screens and packaged add-ons are not
  // http(s); `/admin` is a home fallback there, exactly as before.
  if (!isAdminUiAvailable) return null;
  return (screen: screen, location: location);
}

GameKind _kind(PlayGame game) => switch (game) {
  PlayGame.ludo => GameKind.ludo,
  PlayGame.snakes => GameKind.snakes,
};
