/// The play-invite knock, delivered wherever the invitee happens to be.
///
/// A sent invite used to land in exactly one place — the Play invites
/// section inside the friends screen. A friend sitting anywhere else (the
/// lobby, the home screen, a game) heard nothing at all: playtest round,
/// "inviting a friend for gameplay, he is not getting any notification to
/// join, and can't join the gameplay". The invitation contract itself was
/// already right — the inviter's app opens the room first, the invite
/// carries its code, and answering joins it — so the missing piece was a
/// listener that raises an application-level dialog with a **Join game**
/// button the moment a pending invite appears.
///
/// Three surfaces feed one knock, and they share the dedupe set, so an
/// invite knocks at most once per session — the friends tray stays the
/// always-answerable home for "not now".
///
/// - an immediate pulse at start and every app-refocus — a background
///   tab's timers are throttled by the browser, and a playtest that
///   switch-tabs across waiting players must knock the instant the
///   invitee looks back;
/// - the app-level periodic poller ([InviteWatcher.poke]) on a coarse
///   cadence that matches the lobby's own badge poll, on an endpoint the
///   server deliberately does not throttle.
///
/// Joining answers `friends/invite/respond` (the server hands back the
/// room code) and walks the player into [OnlineLobbyScreen] just like the
/// answers inside the friends screen; Not now sits the invite down (it
/// stays answerable in the friends tray). Identity is the same shared
/// pair the lobby and friends screen use ([StorageService] loads), so a
/// friend code granted anywhere grants the same person.
library;

import 'dart:async';
import 'dart:collection';

import 'package:flutter/material.dart';

import '../services/friend_client.dart';
import '../services/online_client.dart';
import '../services/server_url.dart';
import '../services/storage_service.dart';
import '../ui/page_app_bar.dart';
import '../ui/theme.dart';
import 'online_lobby_screen.dart';

class InviteWatcher {
  InviteWatcher({
    this.interval = const Duration(seconds: 9),
    this.clientFactory,
    this.identityOverride,
  });

  /// The app's root navigator: the knock shows over whatever screen the
  /// invitee is on, because "wherever they are" is the entire point.
  static final GlobalKey<NavigatorState> navigatorKey =
      GlobalKey<NavigatorState>(debugLabel: 'game-club-navigator');

  final Duration interval;

  /// Test seam: builds the answers client per session. Production leaves
  /// it null and the watcher builds one against [defaultServerUrl].
  final FriendClient Function()? clientFactory;

  /// Test seam: a pre-resolved identity. Production reads storage and, on
  /// a first-time player, derives and persists the stable default name.
  final Future<({String seatId, String name})>? identityOverride;

  Timer? _poller;
  bool _started = false;

  /// Invite ids already knocked (and not left re-knockable): one knock per
  /// id per session — the friends tray remains the re-answerable home.
  final Set<int> _knocked = HashSet<int>();

  FriendClient? _client;

  /// While one knock is on screen, further feeds are parked: two surfaces
  /// racing the same second must not stack two identical dialog routes.
  bool _knocking = false;

  /// Starts the poller once. The first tick runs immediately — an invite
  /// that has been sitting pending since the app was closed must knock
  /// without waiting for the cadence. Restarting (a rebuild, a hot
  /// restart of a parent) is a no-op; a second poller would double every
  /// knock.
  void start() {
    if (_started) return;
    _started = true;
    poke();
    _poller = Timer.periodic(interval, (_) => poke());
  }

  void stop() {
    _poller?.cancel();
    _poller = null;
    _client?.close();
    _client = null;
    _started = false;
  }

  /// Runs one poll round right now. App focus (a tab the user looks at),
  /// the nav pulse and tests all drive this; a round already in flight
  /// swallows extra pokes.
  void poke() {
    if (_knocking) return;
    _knocking = true;
    _tick().whenComplete(() => _knocking = false);
  }

  Future<void> _tick() async {
    if (navigatorKey.currentContext == null) return;
    try {
      await _poll();
    } on FriendException {
      // Worded server answer (rate limit, banned seat) — silence; the
      // next poll may simply succeed, and the friends screen reports
      // steady-state failures loudly already.
    } catch (_) {
      // Network noise while a player is anywhere in the app is not a
      // story this watcher tells; the screens that talk those endpoints
      // own their error accounts.
    }
  }

  Future<void> _poll() async {
    final identity = await _loadIdentity();
    if (identity.seatId.isEmpty) return; // No online session yet.

    final factory = clientFactory;
    final answers = _client ??= factory != null
        ? factory()
        : FriendClient(serverUrl: defaultServerUrl());
    final state = await answers.state(
      seatId: identity.seatId,
      name: identity.name,
    );
    await seeInvites(
      identity: identity,
      invites: state.invites,
      answers: answers,
    );
  }

  /// Knocks every pending invite this session has not already surfaced.
  /// The app poller feeds it what its own poll fetched; tests feed rows
  /// directly. One dedupe set guards every caller, so an invite can never
  /// knock twice on screen.
  Future<void> seeInvites({
    required ({String seatId, String name}) identity,
    required Iterable<FriendInviteView> invites,
    required FriendClient answers,
  }) async {
    for (final invite in invites) {
      if (!invite.pending || _knocked.contains(invite.id)) continue;
      _knocked.add(invite.id);
      final answer = await _showKnock(invite);
      if (answer != true) continue;
      String? code;
      try {
        code = await answers.respondInvite(
          seatId: identity.seatId,
          id: invite.id,
          accept: true,
        );
      } catch (e) {
        // The answer failed to reach the table: leave the invite un-knockable
        // until the next poll brings it back, and say where to try again.
        _knocked.remove(invite.id);
        final place = navigatorKey.currentContext;
        if (place != null && place.mounted) {
          showSnackInColumn(
            place,
            'Could not reach their table — the invite stays open in '
            'your friends tray',
          );
        }
        continue;
      }
      final next = navigatorKey.currentContext;
      if (next == null || !next.mounted) return;
      if (code == null || code.isEmpty) {
        showSnackInColumn(
          next,
          'Their table is not ready — they may have left before you answered',
        );
        continue;
      }
      await Navigator.of(next).push(
        MaterialPageRoute(
          builder: (_) =>
              OnlineLobbyScreen(startup: OnlineStartup(joinCode: code)),
        ),
      );
    }
  }

  Future<({String seatId, String name})> _loadIdentity() async {
    final override = identityOverride;
    if (override != null) return override;
    final storage = StorageService();
    final id = await storage.loadOnlinePlayerId();
    var name = await storage.loadOnlineName();
    if (name.isEmpty) {
      // A first-time player never typed a name: derive the same stable
      // name the lobby would offer, so the state poll answers with a
      // profile instead of a 400, and the friend lanes point at ONE id.
      name = DefaultNames.unique(playerId: id);
      await storage.saveOnlineName(name);
    }
    return (seatId: id, name: name);
  }

  /// The knock: one popup, the app's standard dialog card, with the two
  /// answers the invitation contract has. Not now does not answer the
  /// server — the invite stays pending in the friends tray.
  Future<bool?> _showKnock(FriendInviteView invite) {
    // Fresh at use time: the context is resolved after every await, so no
    // stale BuildContext ever crosses an async gap.
    final context = navigatorKey.currentContext;
    if (context == null) return Future.value(null);
    return showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (_) => AlertDialog(
        icon: const Icon(Icons.sports_esports, color: AppColors.gold),
        title: const Text('Play invite'),
        content: Text(
          '${invite.name} invites you to '
          '${invite.game == 'snakes' ? 'Snakes & Ladders' : 'Ludo'}',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Not now'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Join game'),
          ),
        ],
      ),
    );
  }
}
