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

import '../app_router.dart';
import '../app_routes.dart';
import '../services/friend_client.dart';
import '../services/friend_signals.dart';
import '../services/online_client.dart';
import '../services/server_url.dart';
import '../services/sound_service.dart';
import '../services/storage_service.dart';
import '../ui/shared/table_alert.dart';
import 'online_lobby_screen.dart';

class InviteWatcher {
  InviteWatcher({
    this.interval = const Duration(seconds: 5),
    this.clientFactory,
    this.identityOverride,
    this.chime,
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
  /// The credential rides with the id: the state poll presents it as
  /// `Authorization: Bearer` (tests that override identity prove their
  /// token, too — a bearer-less poll cannot reach the server).
  final Future<({String seatId, String name, String credential})>?
  identityOverride;

  /// Test seam for the notification sound. Production leaves it null and
  /// reads the saved sound toggle before chiming; a test that counts
  /// notifications must not touch platform audio channels.
  final Future<void> Function()? chime;

  Timer? _poller;
  bool _started = false;

  /// Invite ids already knocked (and not left re-knockable): one knock per
  /// id per session — the friends tray remains the re-answerable home.
  final Set<int> _knocked = HashSet<int>();

  /// Request ids already present on the previous poll. The first poll
  /// primes this set without speaking: a player opening the app to three
  /// unanswered requests should see three dots, not hear three chimes.
  final Set<int> _seenRequests = HashSet<int>();
  bool _requestsPrimed = false;

  SoundService? _sound;

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
    _sound?.dispose();
    _sound = null;
    _knocked.clear();
    _seenRequests.clear();
    _requestsPrimed = false;
    friendSignals.reset();
    _started = false;
  }

  /// Runs one poll round right now. App focus (a tab the user looks at),
  /// the nav pulse and tests all drive this; a round already in flight
  /// swallows extra pokes.
  void poke() {
    // The production lobby can receive a server pulse before `main` starts
    // the watcher; that is not a reason to poll from an unstarted listener.
    if (!_started || _knocking) return;
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
    if (identity.seatId.isEmpty) {
      // No online session yet: the home Friends button must not keep a dot
      // from a previous identity.
      friendSignals.reset();
      return;
    }

    final factory = clientFactory;
    final answers = _client ??= factory != null
        ? factory()
        : FriendClient(
            serverUrl: defaultServerUrl(),
            credential: identity.credential,
          );
    final state = await answers.state(
      seatId: identity.seatId,
      name: identity.name,
    );
    friendSignals.update(
      requests: state.incoming.length,
      invites: state.invites.where((i) => i.pending).length,
    );
    seeRequests(state.incoming);
    await seeInvites(
      identity: identity,
      invites: state.invites,
      answers: answers,
    );
  }

  /// Raises the one-time friend-request notification.
  ///
  /// The first successful poll only primes the set: the red dot is the
  /// durable "someone is waiting" signal, and a person who opens the app
  /// to an existing request should not be greeted by a burst of chimes.
  /// Every request that appears after that speaks once, then stays silent
  /// on later polls until it is answered or withdrawn.
  void seeRequests(Iterable<FriendRequestView> incoming) {
    final requests = [
      for (final request in incoming)
        if (request.id > 0) request,
    ];
    final ids = {for (final request in requests) request.id};
    if (!_requestsPrimed) {
      _requestsPrimed = true;
      _seenRequests.addAll(ids);
      return;
    }
    final fresh = [
      for (final request in requests)
        if (!_seenRequests.contains(request.id)) request,
    ];
    _seenRequests
      ..clear()
      ..addAll(ids);
    if (fresh.isEmpty) return;
    unawaited(_chime());
    _speak(
      fresh.length == 1
          ? '${fresh.first.name} sent you a friend request'
          : '${fresh.length} new friend requests',
      icon: Icons.person_add_alt_1,
    );
  }

  /// Knocks every pending invite this session has not already surfaced.
  /// The app poller feeds it what its own poll fetched; tests feed rows
  /// directly. One dedupe set guards every caller, so an invite can never
  /// knock twice on screen.
  Future<void> seeInvites({
    required ({String seatId, String name, String credential}) identity,
    required Iterable<FriendInviteView> invites,
    required FriendClient answers,
  }) async {
    for (final invite in invites) {
      if (!invite.pending || _knocked.contains(invite.id)) continue;
      _knocked.add(invite.id);
      // A knock is a doorbell, not a silent badge: the playtest asked for
      // an audible notification wherever the invitee is.
      unawaited(_chime());
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
        _speak(
          'Could not reach their table — the invite stays open in '
          'your friends tray',
          icon: Icons.error_outline,
        );
        continue;
      }
      final next = navigatorKey.currentContext;
      if (next == null || !next.mounted) return;
      if (code == null || code.isEmpty) {
        _speak(
          'Their table is not ready — they may have left before you answered',
          icon: Icons.timer_off_outlined,
        );
        continue;
      }
      await pushAppScreen<void>(
        next,
        name: AppRoutes.join(code),
        builder: (_) =>
            OnlineLobbyScreen(startup: OnlineStartup(joinCode: code)),
      ).popped;
    }
  }

  /// Speaks through the app's corner from a navigator-owned context.
  ///
  /// [showTableAlert]'s normal lookup walks *up* the tree to the overlay,
  /// but this listener holds the navigator's context — the overlay is
  /// below it. Looking up from here throws, and the poller's catch would
  /// turn a failed answer into silence. The navigator's overlay is passed
  /// in instead, which is the same canvas the knock uses.
  void _speak(String text, {IconData icon = Icons.info_outline}) {
    final overlay = navigatorKey.currentState?.overlay;
    final context = navigatorKey.currentContext;
    if (overlay == null || context == null || !context.mounted) return;
    showTableAlert(context, text, icon: icon, onOverlay: overlay);
  }

  /// The notification chime. Reads the persisted sound toggle so a muted
  /// table stays muted; the haptic is independent and respects its own
  /// setting inside [Haptics].
  Future<void> _chime() async {
    final injected = chime;
    if (injected != null) {
      await injected();
      return;
    }
    try {
      final sound = _sound ??= SoundService();
      final enabled = await StorageService().loadSoundEnabled();
      sound.enabled = enabled;
      if (enabled) await sound.message();
    } catch (_) {
      // A missing platform audio plugin must never swallow the knock.
    } finally {
      Haptics.success();
    }
  }

  Future<({String seatId, String name, String credential})>
  _loadIdentity() async {
    final override = identityOverride;
    if (override != null) return override;
    final storage = StorageService();
    final id = await storage.loadOnlinePlayerId();
    final credential = await storage.loadOnlineCredential();
    var name = await storage.loadOnlineName();
    if (name.isEmpty) {
      // A first-time player never typed a name: derive the same stable
      // name the lobby would offer, so the state poll answers with a
      // profile instead of a 400, and the friend lanes point at ONE id.
      name = DefaultNames.unique(playerId: id);
      await storage.saveOnlineName(name);
    }
    return (seatId: id, name: name, credential: credential);
  }

  /// The knock: the table family's gold-rimmed card at the top right,
  /// with the two answers the invitation contract has — not a
  /// white-on-white material dialog. Not now does not answer the server —
  /// the invite stays pending in the friends tray.
  Future<bool?> _showKnock(FriendInviteView invite) {
    // The card is already above the navigator; the chime runs beside it
    // rather than delaying the visible knock on audio startup.
    // The family's overlay state, straight from the navigator key — a
    // navigator's own context has no Overlay *above* it for the family
    // to climb to (see showInviteKnock's doc).
    final overlay = navigatorKey.currentState?.overlay;
    if (overlay == null) return Future.value(null);
    return showInviteKnock(
      overlay,
      title: 'Play invite',
      body:
          '${invite.name} invites you to '
          '${invite.game == 'snakes' ? 'Snakes & Ladders' : 'Ludo'}',
    );
  }
}

/// The app-wide watcher. `main` starts it after the first frame, the online
/// lobby pokes it on a server push, and every Friends badge reads the counts
/// it publishes through [friendSignals].
final InviteWatcher inviteWatcher = InviteWatcher();
