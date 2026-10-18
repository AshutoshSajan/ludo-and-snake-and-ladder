/// Shared WebRTC stand-ins for voice tests.
///
/// [FakeBackend] replaces `FlutterVoiceBackend` at the [VoiceBackend]
/// seam, so the voice state machine and every surface wired to it run
/// without a browser or the plugin. [FakePeer] mirrors the real peer's
/// contract — the offer's SDP leaves *through* [VoicePeer.onSignal], as
/// does the answer produced inside `acceptOffer`.
library;

import 'package:game_club/services/voice_room.dart';

const serializedOfferBid = 'SDP-FROM-THIS-SIDE';

class FakeBackend implements VoiceBackend {
  FakeMic? mic;
  final peers = <FakePeer>[];
  bool denyMic = false;

  @override
  Future<VoiceMic?> openMic() async {
    if (denyMic) return null;
    return mic = FakeMic();
  }

  @override
  VoicePeer createPeer({
    required VoiceMic mic,
    required void Function(String k, String s) onSignal,
    required String peerId,
  }) {
    final peer = FakePeer(
      onSignal,
      peerId,
      onTrack: () => audioAttached.add(peerId),
    );
    peers.add(peer);
    return peer;
  }

  /// Audio keys every [FakePeer] attached under — the playback seam the
  /// real peer feeds its [peerId] through.
  final audioAttached = <String>[];
}

class FakeMic implements VoiceMic {
  bool muted = false;
  bool stopped = false;

  @override
  void setMuted(bool muted) => this.muted = muted;

  @override
  void stop() => stopped = true;
}

class FakePeer implements VoicePeer {
  FakePeer(this.onSignal, this.peerId, {this._onTrack});

  final void Function(String k, String s) onSignal;

  /// The seat this session addresses, which must also be the audio
  /// playback key — one shared key (like the historical constant 'pc')
  /// lets two seats overwrite the same player and leaks the leaver's.
  final String peerId;

  /// Simulated arrival of the negotiated remote track: the real peer
  /// mounts the far side's audio under [peerId] here; the recording
  /// callback lets tests follow the playback-key lifecycle against the
  /// backend ([VoiceBackend.createPeer]'s peerId should be the seat).
  final void Function()? _onTrack;

  /// Frames this peer produced locally (offers/answers/ice).
  final List<({String k, String s})> produced = [];

  /// Frames accepted from the wire, in order.
  final List<({String k, String s})> received = [];
  bool closed = false;

  @override
  Future<void> offer() {
    produced.add((k: 'offer', s: serializedOfferBid));
    onSignal('offer', serializedOfferBid);
    return Future.value();
  }

  @override
  Future<void> acceptOffer(String s) {
    received.add((k: 'offer', s: s));
    // Remote track arrives with the negotiation → audio mounts under the
    // seat key, exactly as [RtcVoicePeer.onTrack] does live.
    _onTrack?.call();
    onSignal('answer', serializedOfferBid);
    return Future.value();
  }

  @override
  Future<void> acceptAnswer(String s) {
    received.add((k: 'answer', s: s));
    return Future.value();
  }

  @override
  Future<void> addIce(String s) {
    received.add((k: 'ice', s: s));
    return Future.value();
  }

  @override
  void close() => closed = true;
}
