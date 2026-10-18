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
///
/// `reinvite` is a client-side convergence request, never WebRTC content:
/// when a seat enables voice it invites its elected offerer to (re)start
/// the session, because that offerer's first offer — sent before this
/// seat ever enabled — was dropped by the not-enabled filter and nothing
/// else would ever re-arm the pair.
const voiceKinds = {'offer', 'answer', 'ice', 'hangup', 'reinvite'};

/// One incoming relayed signal, as [OnlineClient.onVoice] delivers it.
typedef VoiceSignal = ({String k, String from, String s});

/// The WebRTC boundary. The real implementation ([FlutterVoiceBackend])
/// wraps the plugin; tests inject fakes so the mesh logic runs without a
/// browser.
abstract class VoiceBackend {
  /// Opens the local microphone. Null when capture is impossible —
  /// permission refused, no device, no getUserMedia — and the whole
  /// session then simply never leaves `enabled: false`. [onSpeaking]
  /// receives the loudness verdict the backend probes off the capture
  /// (a muted track feeds silence, so a muted mic reports nothing).
  Future<VoiceMic?> openMic({void Function(bool up)? onSpeaking});

  /// Builds one peer session with the local track already attached where
  /// the platform wants it attached. [onSignal] receives everything the
  /// peer produces (offer/answer/ice), addressed to the seat this peer
  /// connects to. [peerId] is that seat, and doubles as the playback key:
  /// the platform renderer keeps one audio player per seat so teardown
  /// can find and free exactly the one that is leaving. [onSpeaking]
  /// receives the loudness verdict of this peer's remote audio so the
  /// indicator can name who is talking.
  VoicePeer createPeer({
    required VoiceMic mic,
    required void Function(String k, String s) onSignal,
    required String peerId,
    required void Function(bool up) onSpeaking,
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

  /// True once this session's handshake has reached the connected state
  /// (offer applied + answer applied, or the reverse). The [reinvite]
  /// handler uses it to leave live calls untouched; probes for the
  /// speaking indicator mount only ever touch dead sessions.
  bool get established;

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
  final Set<String> _speaking = {};

  /// True from a successful mic grant until [disable].
  bool get enabled => _enabled;

  /// True while joined and the mic is muted locally (no signalling — the
  /// track is simply disabled, standard WebRTC mute).
  bool get muted => _muted;

  /// Seat ids this room currently holds audio peers for.
  List<String> get peers => List.unmodifiable(_peers.keys);

  /// Seats believed to be speaking right now — the local mic's own probe
  /// reports this seat, each peer session reports its remote. Feeds the
  /// voice indicator on every surface; empty when the table is quiet, and
  /// never contains an echo once the session is torn down.
  Set<String> get speaking => Set.unmodifiable(_speaking);

  void _markSpeaking(String? seat, bool up) {
    if (seat == null) return;
    final had = _speaking.contains(seat);
    if (up == had) return;
    if (up) {
      _speaking.add(seat);
    } else {
      _speaking.remove(seat);
    }
    onChanged?.call();
  }

  /// Who I am on the table; set on every [updateSeats].
  String? get mySeatId => _mySeatId;

  Future<bool> enable() async {
    if (_enabled) return true;
    final mic = await backend.openMic(
      onSpeaking: (up) => _markSpeaking(_mySeatId, up),
    );
    // Persist the grant (or the very first enable failed): a denied mic
    // must not flip into a silent half-state.
    if (mic == null) {
      onChanged?.call();
      return false;
    }
    _mic = mic;
    _enabled = true;
    mic.setMuted(_muted);
    // Peers mounted while voice was OFF carry only the _NoMic stand-in:
    // they can never attach a track, so an answer from one is mute in
    // both directions. Rebuild every such peer fresh with the real mic.
    for (final seat in List.of(_peers.keys)) {
      _peers.remove(seat)?.close();
      voiceAudio.detachRemoteAudio(seat);
      _peers[seat] = backend.createPeer(
        mic: mic,
        onSignal: (kind, payload) => sendSignal(kind, seat, payload),
        peerId: seat,
        onSpeaking: (up) => _markSpeaking(seat, up),
      );
    }
    // Then invite every seatmate. The elected offerer offers now (its
    // earlier offer — if any is even out — previously died in this seat's
    // not-enabled filter on the far end); the loser asks its offerer to
    // start a session, because waiting for a first offer that was already
    // sent and dropped would stall the pair forever.
    final mySeat = _mySeatId;
    for (final seat in _peers.keys) {
      if (mySeat == null) continue;
      if (mySeat.compareTo(seat) < 0) {
        unawaited(_peers[seat]!.offer());
      } else {
        sendSignal('reinvite', seat, '{}');
      }
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
    _speaking.clear();
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
        onSpeaking: (up) => _markSpeaking(seat, up),
      );
      // Election: the lexically-first seat offers. Deterministic from
      // data both sides already agree on. The loser invites its offerer:
      // if that first offer already crossed (and was dropped while this
      // seat was still passive), only an explicit reinvite re-arms it.
      if (_enabled && mySeatId.compareTo(seat) < 0) {
        unawaited(_peers[seat]!.offer());
      } else if (_enabled) {
        sendSignal('reinvite', seat, '{}');
      }
      onChanged?.call();
    }
  }

  void _closePeer(String seat) {
    _peers.remove(seat)?.close();
    // The platform piece frees its audio element for this seat.
    voiceAudio.detachRemoteAudio(seat);
    _speaking.remove(seat);
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
      onSpeaking: (up) => _markSpeaking(from, up),
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
      case 'reinvite':
        // The sender just enabled voice. Its first role in this pair may
        // have been lost: the elected offerer (me, lexically first) had
        // offered while the sender was still off, and the sender's
        // not-enabled filter buried that offer. If this session is not
        // already up, restart it fresh on my side — new pc, new offer —
        // and the sender's own pc (fresh too, it was only just built) can
        // accept it cleanly. A live session is left untouched.
        if (peer.established) break;
        final mySeat = _mySeatId;
        if (mySeat == null || mySeat.compareTo(from) >= 0) break;
        _peers.remove(from)?.close();
        voiceAudio.detachRemoteAudio(from);
        _speaking.remove(from);
        _peers[from] = backend.createPeer(
          mic: _mic ?? _NoMic(),
          onSignal: (kind, payload) => sendSignal(kind, from, payload),
          peerId: from,
          onSpeaking: (up) => _markSpeaking(from, up),
        );
        unawaited(_peers[from]!.offer());
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
    _speaking.clear();
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
