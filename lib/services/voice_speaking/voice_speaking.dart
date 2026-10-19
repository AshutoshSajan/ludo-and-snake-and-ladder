/// Loudness probes for the speaking indicator: the contract and the
/// platform dispatcher.
///
/// One probe per analysed stream — the local mic, and each remote peer's
/// incoming audio. `start()` begins sampling; `stop()` must be called by
/// the owner (mic teardown, peer close) and always ends by reporting
/// "quiet", so no seat stays lit after its stream dies.
///
/// A browser measures a stream through an `AudioContext` analyser; the
/// native engines have no equivalent seam here, so their probe is a
/// no-op (the indicator shows nothing for native until a native probe
/// exists — silence is honest talk state, unlike a fake one).
library;

export 'voice_speaking_none.dart'
    if (dart.library.js_util) 'voice_speaking_web.dart';

/// The probe that reports "never speaking": shared by every platform that
/// cannot afford a real measurement, native today (no affordable per-stream
/// RMS seam in flutter_webrtc) and — via the degrade path in
/// `voice_speaking_web` — any stream shape a web `AudioContext` cannot
/// analyse. Silence is an honest talk state; a fake indicator would lie.
///
/// It lives in the contract file on purpose: both branches of the
/// conditional export ever select exactly one *implementation* file, so the
/// fallback must be visible to the selected branch whichever one it
/// becomes (the web branch referenced it once assuming its sibling was in
/// scope — the web build failed, because under a conditional export the
/// other branch is never in scope).
class NoneVoiceSpeaking implements VoiceSpeaking {
  const NoneVoiceSpeaking();
  @override
  void start() {}
  @override
  void stop() {}
}

abstract class VoiceSpeaking {
  void start();
  void stop();
}
