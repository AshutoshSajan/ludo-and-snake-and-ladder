/// The WebRTC implementation behind [VoiceBackend]: flutter_webrtc for mic
/// and peer plumbing, `voice_audio` for the platform split on playback,
/// and `voice_speaking` for the per-stream loudness probes behind the
/// "who is talking" indicator.
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
import 'voice_speaking/voice_speaking.dart';

class FlutterVoiceBackend implements VoiceBackend {
  FlutterVoiceBackend() {
    // Wire the platform playback implementation into the state machine's
    // hook — idempotent, and a no-op in tests when a raised hook (fake)
    // is already installed.
    voiceAudio = deviceVoiceAudio;
  }

  @override
  Future<VoiceMic?> openMic({void Function(bool up)? onSpeaking}) async {
    try {
      final stream = await wr.navigator.mediaDevices.getUserMedia(
        <String, dynamic>{'audio': true, 'video': false},
      );
      return RtcVoiceMic(stream, onSpeaking: onSpeaking);
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
    required void Function(bool up) onSpeaking,
  }) => RtcVoicePeer(
    onSignal: onSignal,
    mic: mic,
    peerId: peerId,
    onSpeaking: onSpeaking,
  );
}

class RtcVoiceMic implements VoiceMic {
  RtcVoiceMic(this.stream, {void Function(bool up)? onSpeaking}) {
    // Mute rides inside the probe's data for free: the analyser taps the
    // MediaStreamTrack, and a track disabled by setMuted feeds silence —
    // so a muted mic never reports the seat as speaking, in either
    // direction of the tape.
    if (onSpeaking != null) {
      _probe = newVoiceSpeaking(
        stream,
        onChange: (up) => onSpeaking(!muted && up),
      )..start();
    }
  }

  final wr.MediaStream stream;
  VoiceSpeaking? _probe;
  bool muted = false;

  @override
  void setMuted(bool value) {
    muted = value;
    for (final track in stream.getAudioTracks()) {
      track.enabled = !value;
    }
  }

  @override
  void stop() {
    _probe?.stop();
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
    this.onSpeaking,
  }) {
    _open(mic);
  }
  final void Function(String k, String s) onSignal;

  /// The seat this session addresses. Also the key the remote audio
  /// player is stored under, so this seat's player is the one freed at
  /// teardown — one shared key would let two seats overwrite the same
  /// player and leak the leaver's audio element.
  final String peerId;

  /// The room's speaking-indicator hook for this peer's remote audio.
  final void Function(bool up)? onSpeaking;
  final Completer<wr.RTCPeerConnection?> _peering = Completer();
  final List<VoiceSpeaking> _remoteProbes = [];
  wr.MediaStreamTrack? _localTrack;
  wr.MediaStream? _localStream;
  wr.RTCPeerConnection? _pc;

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
      _pc = pc;
      if (!_peering.isCompleted) _peering.complete(pc);
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
          // ...and the speaking indicator rides the same stream.
          final probe = newVoiceSpeaking(
            event.streams.first,
            onChange: (up) => onSpeaking?.call(up),
          )..start();
          _remoteProbes.add(probe);
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
  bool get established =>
      _pc != null &&
      _pc!.connectionState ==
          wr.RTCPeerConnectionState.RTCPeerConnectionStateConnected;

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
    try {
      await pc.addCandidate(
        wr.RTCIceCandidate(
          candidate,
          j['sdpMid'] as String?,
          j['sdpMLineIndex'] as int? ?? 0,
        ),
      );
    } catch (_) {
      // A stale candidate from a replaced session reaches the fresh pc
      // before any SDP it belongs to; browsers buffer candidates against
      // the pending remote description, and anything that cannot ever
      // match burns silently rather than crashing the signalling drain.
    }
  }

  @override
  void close() {
    for (final probe in _remoteProbes) {
      probe.stop();
    }
    _remoteProbes.clear();
    _peering.future
        .then((pc) {
          if (pc != null) pc.close();
        })
        .catchError((Object _) {});
  }
}
