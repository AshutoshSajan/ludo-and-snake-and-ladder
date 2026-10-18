/// Table voice chat: the state machine, deliberately free of WebRTC.
///
/// The mesh is peer-to-peer; this server's WebSocket only carries
/// signalling (see `GameAuthority.handleIntent`'s 'voice' case). Why a
/// state machine instead of calling the plugin straight from the button:
///
/// - offerer election must be deterministic. Two players simultaneously
///   deciding "I'll offer" produce botched SDP pairs; both sides compute
///   the same answer lexically from stable seat ids, so there is never a
///   coin toss.
/// - everything except the plugin boundary is testable. [VoiceBackend]
///   stand-ins drive offers, answers, ICE, mutes, seat changes, and
///   hangups through the exact code that will run live.
///
/// Seat identity — not connection identity — addresses every peer: the
/// seat survives a reconnect, so the audio mesh survives one too.
library;

import 'dart:async';
import 'dart:convert';

/// Valid signalling directions a peer can emit or accept.
const voiceKinds = {'offer', 'answer', 'ice', 'hangup'};

/// One incoming relayed signal, as [OnlineClient.onVoice] delivers it.
typedef VoiceSignal = ({String k, String from, String s});

/// The WebRTC boundary. The real implementation ([FlutterVoiceBackend])
/// wraps the plugin; tests inject fakes so the mesh logic runs without a
/// browser.
abstract class VoiceBackend {
  /// Opens the local microphone. Null when capture is impossible —
  /// permission refused, no device, no getUserMedia — and the whole
  /// session then simply never leaves `enabled: false`.
  Future<VoiceMic?> openMic();

  /// Builds one peer session with the local track already attached where
  /// the platform wants it attached. [onSignal] receives everything the
  /// peer produces (offer/answer/ice), addressed to the seat this peer
  /// connects to. [peerId] is that seat, and doubles as the playback key:
  /// the platform renderer keeps one audio player per seat so teardown
  /// can find and free exactly the one that is leaving.
  VoicePeer createPeer({
    required VoiceMic mic,
    required void Function(String k, String s) onSignal,
    required String peerId,
  });
}

/// A captured microphone. Separate from the peer list because mute is a
/// property of the mic, not of any peer.
abstract class VoiceMic {
  void setMuted(bool muted);
  void stop();
}

/// One end of a peer-to-peer audio connection to one remote seat.
abstract class VoicePeer {
  /// Only the elected offerer calls this.
  Future<void> offer();

  Future<void> acceptOffer(String s);
  Future<void> acceptAnswer(String s);
  Future<void> addIce(String s);
  void close();
}

class VoiceRoom {
  VoiceRoom({
    required this.backend,

    /// Sends one signalling message toward [to]. In production this is the
    /// WebSocket client's sender; in tests it records frames.
    required this.sendSignal,

    /// Called after every state change so a ChangeNotifier can repaint.
    this.onChanged,
  });

  final VoiceBackend backend;

  /// Sends one signalling message toward [to].
  final void Function(String k, String to, String s) sendSignal;

  /// Called after every state change so a ChangeNotifier can repaint.
  final void Function()? onChanged;

  bool _enabled = false;
  bool _muted = false;
  VoiceMic? _mic;
  final Map<String, VoicePeer> _peers = {};
  String? _mySeatId;

  /// True from a successful mic grant until [disable].
  bool get enabled => _enabled;

  /// True while joined and the mic is muted locally (no signalling — the
  /// track is simply disabled, standard WebRTC mute).
  bool get muted => _muted;

  /// Seat ids this room currently holds audio peers for.
  List<String> get peers => List.unmodifiable(_peers.keys);

  /// Who I am on the table; set on every [updateSeats].
  String? get mySeatId => _mySeatId;

  Future<bool> enable() async {
    if (_enabled) return true;
    final mic = await backend.openMic();
    // Persist the grant (or the very first enable failed): a denied mic
    // must not flip into a silent half-state.
    if (mic == null) {
      onChanged?.call();
      return false;
    }
    _mic = mic;
    _enabled = true;
    mic.setMuted(_muted);
    // Seats already known (the lobby feed arrives before the first join).
    for (final seat in _peers.keys) {
      _reconnectPeer(seat);
    }
    onChanged?.call();
    return true;
  }

  /// Turns voice off: every peer is closed, the mic is released, and each
  /// connected seat is told so it can tear its side down at once instead
  /// of waiting for ICE to notice.
  Future<void> disable() async {
    for (final seat in List.of(_peers.keys)) {
      if (_enabled) sendSignal('hangup', seat, '{}');
      _closePeer(seat);
    }
    _mic?.stop();
    _mic = null;
    final wasOn = _enabled;
    _enabled = false;
    if (wasOn) onChanged?.call();
  }

  /// Mute is local: it toggles the track's enabled flag, so nothing is
  /// renegotiated and the remote hears silence immediately.
  void setMuted(bool muted) {
    _muted = muted;
    _mic?.setMuted(muted);
    onChanged?.call();
  }

  /// The lobby/seats feed. Creates peers for seats that appeared, closes
  /// those that are gone, and offers only where the election says so.
  void updateSeats(Set<String> seatIds, String mySeatId) {
    _mySeatId = mySeatId;
    for (final gone in _peers.keys.toList()) {
      if (!seatIds.contains(gone)) _closePeer(gone);
    }
    for (final seat in seatIds) {
      if (seat == mySeatId || _peers.containsKey(seat)) continue;
      _peers[seat] = backend.createPeer(
        mic: _mic ?? _NoMic(),
        onSignal: (k, s) => sendSignal(k, seat, s),
        peerId: seat,
      );
      // Election: the lexically-first seat offers. Deterministic from
      // data both sides already agree on.
      if (_enabled && mySeatId.compareTo(seat) < 0) {
        unawaited(_peers[seat]!.offer());
      }
      onChanged?.call();
    }
  }

  /// Voice was enabled while peers for existing seats already exist (the
  /// seats feed came first). Reconnect flow after a mute-free enable.
  void _reconnectPeer(String seat) {
    final mySeat = _mySeatId;
    if (mySeat == null) return;
    if (mySeat.compareTo(seat) < 0) {
      unawaited(_peers[seat]?.offer());
    }
    // Otherwise the other side offers; we wait for their signal.
  }

  void _closePeer(String seat) {
    _peers.remove(seat)?.close();
    // The platform piece frees its audio element for this seat.
    voiceAudio.detachRemoteAudio(seat);
    onChanged?.call();
  }

  /// One relayed signal from [from]. Creates the peer if the seats feed
  /// was slower than the signalling (a fast joiner can offer before the
  /// lobby message lands) — the mesh self-heals instead of dropping the
  /// first offer.
  Future<void> onSignal(VoiceSignal msg) async {
    if (!_enabled) return;
    final (k, from, s) = (msg.k, msg.from, msg.s);
    if (!voiceKinds.contains(k) || from == _mySeatId) return;
    final peer = _peers[from] ??= backend.createPeer(
      mic: _mic ?? _NoMic(),
      onSignal: (kind, payload) => sendSignal(kind, from, payload),
      peerId: from,
    );
    switch (k) {
      case 'offer':
        await peer.acceptOffer(s);
      case 'answer':
        await peer.acceptAnswer(s);
      case 'ice':
        await peer.addIce(s);
      case 'hangup':
        _closePeer(from);
    }
  }

  /// Closes everything without asking — used when the room is gone
  /// entirely (error, roomClosed, leaving). No hangups are sent because
  /// there is no room to deliver them meaningfully to.
  Future<void> abandoned() async {
    for (final seat in List.of(_peers.keys)) {
      _closePeer(seat);
    }
    _mic?.stop();
    _mic = null;
    final wasOn = _enabled;
    _enabled = false;
    if (wasOn) onChanged?.call();
  }
}

/// A bare-token mic stand-in for the rare path where peers exist before
/// the mic finished opening (fast signalling vs. slow permission prompt).
/// Mute calls on it are no-ops; nothing else ever touches it.
class _NoMic implements VoiceMic {
  @override
  void setMuted(bool muted) {}

  @override
  void stop() {}
}

/// Remote audio playback. Platform-split because a browser needs the
/// stream attached to an `<audio>` element, while the native engines
/// render remote audio themselves the moment the track arrives. The real
/// backend and the peer's onTrack hook wire streams through these two
/// functions; [FlutterVoiceBackend] registers the real implementation.
abstract class VoiceAudio {
  Future<void> attachRemoteAudio(String peerId, Object? stream);
  void detachRemoteAudio(String peerId);
}

VoiceAudio voiceAudio = _SilentAudio();

/// Tests (or alternative engines) can assign their own before the peers
/// start attaching streams.
class _SilentAudio implements VoiceAudio {
  @override
  Future<void> attachRemoteAudio(String peerId, Object? stream) async {}

  @override
  void detachRemoteAudio(String peerId) {}
}

/// Builds the JSON an ICE candidate rides in, shared by the real peer
/// implementation (which produces it) and nothing else.
String encodeIce({
  required String? candidate,
  required String? sdpMid,
  required int? sdpMLineIndex,
}) => jsonEncode({
  'candidate': candidate,
  'sdpMid': sdpMid,
  'sdpMLineIndex': sdpMLineIndex,
});
