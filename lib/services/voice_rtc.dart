/// The WebRTC implementation behind [VoiceBackend]: flutter_webrtc for mic
/// and peer plumbing, `voice_audio` for the platform split on playback.
///
/// Signalling payloads (SDP, ICE) travel as their own JSON strings — the
/// server relays them opaquely by seat and never opens them. ICE frames
/// that the browser fires before the remote answer is applied are queued
/// by the remote peer itself (the standard trickle ICE buffering).
library;

import 'dart:async';
import 'dart:convert';

import 'package:flutter_webrtc/flutter_webrtc.dart' as wr;

import 'voice_audio/voice_audio.dart';
import 'voice_room.dart';

class FlutterVoiceBackend implements VoiceBackend {
  FlutterVoiceBackend() {
    // Wire the platform playback implementation into the state machine's
    // hook — idempotent, and a no-op in tests when a raised hook (fake)
    // is already installed.
    voiceAudio = deviceVoiceAudio;
  }

  @override
  Future<VoiceMic?> openMic() async {
    try {
      final stream = await wr.navigator.mediaDevices.getUserMedia(
        <String, dynamic>{'audio': true, 'video': false},
      );
      return RtcVoiceMic(stream);
    } catch (_) {
      // Permission refused, no mic, browser without getUserMedia: voice
      // simply stays off and the button reports the miss.
      return null;
    }
  }

  @override
  VoicePeer createPeer({
    required VoiceMic mic,
    required void Function(String k, String s) onSignal,
    required String peerId,
  }) => RtcVoicePeer(onSignal: onSignal, mic: mic, peerId: peerId);
}

class RtcVoiceMic implements VoiceMic {
  RtcVoiceMic(this.stream);

  final wr.MediaStream stream;

  @override
  void setMuted(bool muted) {
    for (final track in stream.getAudioTracks()) {
      track.enabled = !muted;
    }
  }

  @override
  void stop() {
    for (final track in stream.getTracks()) {
      track.stop();
    }
  }
}

class RtcVoicePeer implements VoicePeer {
  RtcVoicePeer({
    required this.onSignal,
    required VoiceMic mic,
    required this.peerId,
  }) {
    _open(mic);
  }

  final void Function(String k, String s) onSignal;

  /// The seat this session addresses. Also the key the remote audio
  /// player is stored under, so this seat's player is the one freed at
  /// teardown — one shared key would let two seats overwrite the same
  /// player and leak the leaver's audio element.
  final String peerId;
  final Completer<wr.RTCPeerConnection?> _peering = Completer();
  wr.MediaStreamTrack? _localTrack;
  wr.MediaStream? _localStream;

  Future<void> _open(VoiceMic mic) async {
    try {
      final pc = await wr.createPeerConnection(<String, dynamic>{
        // Public STUN keeps NAT traversal free of infrastructure. Pairs
        // behind stricter NATs (some CGNAT paths) can still fail without
        // a TURN server — the known cost of a STUN-only deployment.
        'iceServers': [
          {'urls': 'stun:stun.l.google.com:19302'},
          {'urls': 'stun:stun1.l.google.com:19302'},
        ],
      });
      _peering.complete(pc);
      pc.onIceCandidate = (c) {
        if (c.candidate == null) return;
        onSignal(
          'ice',
          encodeIce(
            candidate: c.candidate,
            sdpMid: c.sdpMid,
            sdpMLineIndex: c.sdpMLineIndex,
          ),
        );
      };
      // Remote audio arrives on early track events...
      pc.onTrack = (event) {
        if (event.streams.isNotEmpty) {
          unawaited(voiceAudio.attachRemoteAudio(peerId, event.streams.first));
        }
      };
      if (mic is RtcVoiceMic) {
        final tracks = mic.stream.getAudioTracks();
        _localTrack = tracks.isNotEmpty ? tracks.first : null;
        _localStream = _localTrack != null ? mic.stream : null;
      }
    } catch (_) {
      if (!_peering.isCompleted) _peering.complete(null);
    }
  }

  @override
  Future<void> offer() async {
    final pc = await _peering.future;
    if (pc == null) return;
    if (_localTrack != null) await _addLocalMic(pc);
    final offer = await pc.createOffer(<String, dynamic>{});
    await pc.setLocalDescription(offer);
    onSignal('offer', jsonEncode({'type': 'offer', 'sdp': offer.sdp}));
  }

  @override
  Future<void> acceptOffer(String s) async {
    final pc = await _peering.future;
    if (pc == null) return;
    final desc = wr.RTCSessionDescription(
      (jsonDecode(s) as Map<String, dynamic>)['sdp'] as String?,
      'offer',
    );
    await pc.setRemoteDescription(desc);
    if (_localTrack != null) await _addLocalMic(pc);
    final answer = await pc.createAnswer(<String, dynamic>{});
    await pc.setLocalDescription(answer);
    onSignal('answer', jsonEncode({'type': 'answer', 'sdp': answer.sdp}));
  }

  /// Puts the mic on the wire.
  ///
  /// The stream MUST travel with the track: `addTrack(track)` without a
  /// MediaStream association arrives on the far side with
  /// `event.streams == []`, so [onTrack]'s guard skips it, nothing is ever
  /// attached to an `<audio>` element, and the whole mesh plays silence
  /// with no error anywhere. Associating the mic's stream means the far
  /// side always gets `streams[0]` keyed under this session's [peerId].
  Future<void> _addLocalMic(wr.RTCPeerConnection pc) async {
    await pc.addTrack(_localTrack!, _localStream!);
  }

  @override
  Future<void> acceptAnswer(String s) async {
    final pc = await _peering.future;
    if (pc == null) return;
    await pc.setRemoteDescription(
      wr.RTCSessionDescription(
        (jsonDecode(s) as Map<String, dynamic>)['sdp'] as String?,
        'answer',
      ),
    );
  }

  @override
  Future<void> addIce(String s) async {
    final pc = await _peering.future;
    if (pc == null) return;
    final j = jsonDecode(s) as Map<String, dynamic>;
    final candidate = j['candidate'] as String?;
    if (candidate == null || candidate.isEmpty) return;
    await pc.addCandidate(
      wr.RTCIceCandidate(
        candidate,
        j['sdpMid'] as String?,
        j['sdpMLineIndex'] as int? ?? 0,
      ),
    );
  }

  @override
  void close() {
    _peering.future
        .then((pc) {
          if (pc != null) pc.close();
        })
        .catchError((Object _) {});
  }
}
