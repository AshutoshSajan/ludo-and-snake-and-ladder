/// The play-invite knock, delivered wherever the invitee happens to be.
///
/// A sent invite used to land in exactly one place — the Play invites
/// section inside the friends screen. A friend sitting anywhere else (the
/// lobby, the home screen, a game) heard nothing at all: playtest round,
/// "inviting a friend for gameplay, he is not getting any notification to
/// join, and can't join the gameplay". The invitation contract itself was
/// already right — the inviter's app opens the room first, the invite
/// carries its code, and answering joins it — so the missing piece was a
/// listener [InviteWatcher] that polls the friends state endpoint on the
/// same coarse cadence the lobby already polls for badges, and raises an
/// application-level dialog with a **Join game** button when a pending
/// invite appears. Joining answers `friends/invite/respond` (the server
/// hands back the room code) and walks the player into [OnlineLobbyScreen]
/// just like the answers inside the friends screen; Not now sits the
/// invite down for the session (it stays answerable in the friends tray).
///
/// Identity is the same shared pair the lobby and friends screen use
/// ([StorageService] loads), so a friend code granted anywhere grants the
/// same person. Polls are POST `friends/state` — deliberately not
/// throttled server-side — and the server still owns every invite's
/// resolution, so a knock, the tray tile and a web client all read one
/// truth.
library;

import 'dart:async';
import 'dart:collection';

import 'package:flutter/material.dart';

import '../services/friend_client.dart';
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
  final FriendClient Function()? clientFactory;

  /// Test seam: the default reads the persisted online identity.
  final Future<({String seatId, String name})>? identityOverride;

  Timer? _poller;
  bool _started = false;

  /// The invite ids already knocked (and not left re-knockable): one knock per
  /// id per session — the friends tray remains the re-answerable home.
  final Set<int> _knocked = HashSet<int>();

  FriendClient? _client;

  /// Starts the poller once. Calling again (a rebuild, a hot restart of a
  /// parent) is a no-op; a second poller would double every knock.
  void start() {
    if (_started) return;
    _started = true;
    _poller = Timer.periodic(interval, (_) => _tick());
  }

  void stop() {
    _poller?.cancel();
    _poller = null;
    _client?.close();
    _client = null;
    _started = false;
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
    final override = identityOverride;
    final identity = override != null
        ? await override
        : await _loadIdentity();
    if (identity.seatId.isEmpty) return; // No online session yet.

    final makeClient = clientFactory;
    _client ??= makeClient != null
        ? makeClient()
        : FriendClient(serverUrl: defaultServerUrl());
    final state = await _client!.state(
      seatId: identity.seatId,
      name: identity.name,
    );
    for (final invite in state.invites) {
      if (!invite.pending || _knocked.contains(invite.id)) continue;
      _knocked.add(invite.id);
      final answer = await _showKnock(invite);
      if (answer != true) continue;
      final code = await _client!.respondInvite(
        seatId: identity.seatId,
        id: invite.id,
        accept: true,
      );
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
    final storage = StorageService();
    final id = await storage.loadOnlinePlayerId();
    final name = await storage.loadOnlineName();
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
