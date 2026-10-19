/// Loudness probes: the native half — nothing, deliberately.
///
/// flutter_webrtc's native engines expose no affordable per-stream RMS
/// seam here, and a speaking indicator built on guesses would lie to
/// players. Until a native probe exists the indicator simply stays
/// quiet on native — the never-speaking probe ([NoneVoiceSpeaking])
/// lives with the contract in `voice_speaking.dart`.
library;

import 'voice_speaking.dart';

/// The implementation selected by `voice_speaking.dart`'s conditional
/// export. Native: no-op probes.
VoiceSpeaking newVoiceSpeaking(
  Object? stream, {
  required void Function(bool up) onChange,
}) => const NoneVoiceSpeaking();
