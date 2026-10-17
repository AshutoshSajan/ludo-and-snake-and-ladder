/// Remote-audio attachment: the platform dispatcher.
///
/// On a browser a WebRTC stream must be attached to an `<audio>` element
/// or it plays nothing (guard: `dart.library.js_util`); on native the
/// engine renders remote audio itself, so the no-op stands in. [FlutterVoiceBackend]
/// assigns whichever [deviceVoiceAudio] this selects into `voiceRoom`'s
/// hook at construction; tests assign their own.
library;

export 'voice_audio_none.dart'
    if (dart.library.js_util) 'voice_audio_web.dart';
