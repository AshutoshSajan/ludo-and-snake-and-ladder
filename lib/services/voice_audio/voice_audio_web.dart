/// Remote-audio attachment: the web half. Browsers only output a WebRTC
/// stream through an `<audio>` (or `<video>`) element whose srcObject is
/// the stream — anything else is silence with no error. Native engines
/// render remote audio themselves, which is what `voice_audio_none.dart`
/// implements (nothing).
library;

import 'package:dart_webrtc/dart_webrtc.dart';
import 'package:web/web.dart' as web;

import 'dart:js_interop';

import '../voice_room.dart';

final Map<String, web.HTMLAudioElement> _players = {};

class WebVoiceAudio implements VoiceAudio {
  const WebVoiceAudio();
  @override
  Future<void> attachRemoteAudio(String peerId, Object? stream) async {
    if (stream is! MediaStreamWeb) return;
    // One element per peer: replacing srcObject on a reused element is
    // fine, but separate elements let two seats' audio be torn down
    // independently.
    final player = _players[peerId] ??= web.HTMLAudioElement();
    player.srcObject = stream.jsStream;
    player.setAttribute('autoplay', '');
    try {
      await player.play().toDart;
    } catch (_) {
      // A rejected play() used to escape as an unhandled error. Chrome
      // lets WebRTC audio autoplay once the page has captured a mic (the
      // tap that joined the call), so a rejection should be rare — but if
      // it happens it means silence, not a crash worth crashing a zone
      // over.
    }
  }

  @override
  void detachRemoteAudio(String peerId) {
    final player = _players[peerId];
    if (player == null) return;
    player.pause();
    player.srcObject = null;
    _players.remove(peerId);
  }
}

/// The implementation selected by `voice_audio.dart`'s conditional export.
const VoiceAudio deviceVoiceAudio = WebVoiceAudio();
