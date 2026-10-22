import 'package:flutter/foundation.dart';

/// App-wide friend activity counts.
///
/// The friends surfaces poll independently (the lobby has its own badge
/// poll, the friends screen refreshes on open), but the home screen's
/// Friends button and the app-level invite watcher need one shared answer.
/// This is deliberately tiny: two counts and a revision, fed by whichever
/// poll just succeeded, so a second source can never paint a stale dot.
class FriendSignals {
  FriendSignals();

  /// Requests addressed to this player and not yet answered.
  final ValueNotifier<int> incomingRequests = ValueNotifier<int>(0);

  /// Pending play invites for this player.
  final ValueNotifier<int> pendingInvites = ValueNotifier<int>(0);

  /// Bumped after every successful state read. Tests and diagnostics can
  /// wait for a poll without guessing at the timer cadence.
  final ValueNotifier<int> revision = ValueNotifier<int>(0);

  void update({required int requests, required int invites}) {
    incomingRequests.value = requests < 0 ? 0 : requests;
    pendingInvites.value = invites < 0 ? 0 : invites;
    revision.value += 1;
  }

  void reset() {
    incomingRequests.value = 0;
    pendingInvites.value = 0;
    revision.value += 1;
  }
}

/// The process-wide counts. The app-level [InviteWatcher] and the lobby
/// both write here; every Friends badge reads the same values.
final FriendSignals friendSignals = FriendSignals();
