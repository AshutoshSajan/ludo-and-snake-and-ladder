/// Remote-audio attachment: the native half — nothing.
///
/// flutter_webrtc's native engines (Android/iOS/macOS/Windows) start
/// playing a remote audio track as soon as the SDP places it on a
/// receiver; there is no explicit render step to perform.
library;

import '../voice_room.dart';

class NoneVoiceAudio implements VoiceAudio {
  const NoneVoiceAudio();
  @override
  Future<void> attachRemoteAudio(String peerId, Object? stream) async {}

  @override
  void detachRemoteAudio(String peerId) {}
}

/// The implementation selected by `voice_audio.dart`'s conditional export.
/// Native: a no-op (engines render remote audio themselves).
const VoiceAudio deviceVoiceAudio = NoneVoiceAudio();

