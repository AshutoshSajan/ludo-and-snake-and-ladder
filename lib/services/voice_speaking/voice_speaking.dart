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

abstract class VoiceSpeaking {
  void start();
  void stop();
}
