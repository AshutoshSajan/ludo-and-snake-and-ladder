/// Records chat voice notes locally.
///
/// A thin shell over the `record` plugin, on purpose: everything worth
/// testing flows through [OnlineClient.sendVoiceNote] (upload + announce)
/// and the composer's state machine, while this class only marshals the
/// microphone. The one formatter-question answered here is *which codec*,
/// and it is answered by capability, not by assumption:
///
/// - Chromium browsers (Chrome, Edge, Firefox) only ever expose an
///   **Opus-in-WebM** MediaRecorder; every AAC mimeType they reject, and
///   the plugin throws "not supported" — which used to surface as a
///   misleading "No microphone" message.
/// - Safari (macOS and iOS) carries AAC but will not decode WebM at the
///   `<audio>` element, so it records `audio/mp4` instead.
/// - Native platforms keep the older rule: AAC where the OS ships an
///   encoder (Apple, Android, Windows), WAV on Linux, whose GStreamer
///   pipeline has none.
///
/// 16 kHz mono keeps a minute of speech under the server's 2 MiB cap on
/// every codec involved, and the browser's speech clean-up (echo cancel,
/// noise suppression, auto gain) stays on — see [NoteRecorder.recordConfig]
/// for why it cannot be left to the plugin's defaults.
library;

import 'dart:io' show File;

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';
import 'package:record/record.dart';

/// The finished recording, ready for [OnlineClient.sendVoiceNote].
class NoteRecording {
  const NoteRecording({
    required this.bytes,
    required this.mime,
    required this.durMs,
  });

  final List<int> bytes;
  final String mime;
  final int durMs;
}

class NoteRecorder {
  NoteRecorder._(this._recorder, this.encoder) : _stopwatch = Stopwatch();

  final AudioRecorder _recorder;
  final Stopwatch _stopwatch;

  /// The codec this session actually records in — `finish()` derives the
  /// upload's mime from it, and a changed codec must not resurrect the old
  /// container by accident.
  final AudioEncoder encoder;

  /// The recorder's own cap: a minute of speech is generous, bound the
  /// encoder's output and the server's patience at once.
  static const max = Duration(seconds: 60);

  /// The capture config for a table note: 16 kHz mono — a minute of
  /// speech stays under the server's 2 MiB cap — with the browser's
  /// speech clean-up **turned on**.
  ///
  /// The plugin's [RecordConfig] defaults `echoCancel`, `noiseSuppress`
  /// and `autoGain` to **false**, and the web delegate passes them
  /// straight into `getUserMedia` — so leaving them unset does not fall
  /// back to the browser default, it explicitly opts the mic OUT of
  /// every clean-up. Notes came out carrying the raw room: fan hum,
  /// keyboard clatter, game audio bleeding in. Speech capture wants all
  /// three on — the live-call path already gets them for free from its
  /// bare `'audio': true` (the browser default), which is exactly how
  /// calls came out cleaner than notes. Platform delegates that cannot
  /// honor a flag degrade gracefully instead.
  static RecordConfig recordConfig(AudioEncoder encoder) => RecordConfig(
    encoder: encoder,
    sampleRate: 16000,
    numChannels: 1,
    bitRate: 96000,
    echoCancel: true,
    noiseSuppress: true,
    autoGain: true,
  );

  Future<NoteRecording?> finish() async {
    final durMs = _stopwatch.elapsedMilliseconds.clamp(0, max.inMilliseconds);
    final pathOrUrl = await _recorder.stop();
    if (pathOrUrl == null) return null;
    try {
      final bytes = kIsWeb
          ? await _fetchBlob(pathOrUrl)
          : await File(pathOrUrl).readAsBytes();
      if (bytes.isEmpty) return null;
      return NoteRecording(bytes: bytes, mime: mimeFor(encoder), durMs: durMs);
    } catch (_) {
      return null;
    }
  }

  /// Throws the recording away without encoding the tail.
  Future<void> cancel() async {
    try {
      await _recorder.cancel();
    } catch (_) {
      // A recorder that refuses to cancel is a plugin hiccup, not a
      // thing worth crashing a chat over.
    }
  }

  /// Starts a session, or returns null when the microphone is refused
  /// (permission, no device, no usable encoder).
  static Future<NoteRecorder?> start() async {
    final recorder = AudioRecorder();
    try {
      if (!await recorder.hasPermission()) return null;
      final encoder = await _encoderThatWorks(recorder);
      if (encoder == null) return null;
      final ext = switch (encoder) {
        AudioEncoder.wav => 'wav',
        AudioEncoder.opus => 'webm',
        _ => 'm4a',
      };
      // Web gives the recorder no path at all: `record`'s web delegates
      // ignore [path] — stop() resolves to the browser's blob: URL, which
      // _fetchBlob picks up — and path_provider has no web implementation,
      // so getTemporaryDirectory() throws. That throw sat inside this
      // catch and read as "No microphone", failing every web start with
      // mic access allowed and the codec probed fine. Only native keeps a
      // real temp file.
      final String path;
      if (kIsWeb) {
        path = '';
      } else {
        path = '${(await getTemporaryDirectory()).path}/table-chat-note.$ext';
      }
      await recorder.start(recordConfig(encoder), path: path);
      final session = NoteRecorder._(recorder, encoder);
      session._stopwatch.start();
      return session;
    } catch (_) {
      return null;
    }
  }

  /// The first encoder this recorder can actually produce, or null when
  /// none applies. Native platforms keep the old deterministic choice;
  /// web browsers have no shared codec across engines, so the plugin's
  /// own capability probe decides.
  static Future<AudioEncoder?> _encoderThatWorks(AudioRecorder recorder) async {
    if (!kIsWeb) {
      final encoder = defaultTargetPlatform == TargetPlatform.linux
          ? AudioEncoder.wav
          : AudioEncoder.aacLc;
      return await recorder.isEncoderSupported(encoder) ? encoder : null;
    }
    for (final encoder in encoderCandidates(web: true)) {
      if (await recorder.isEncoderSupported(encoder)) return encoder;
    }
    return null;
  }

  /// Web-ordered codec preferences. Opus first: Chromium engines carry it
  /// and nothing else, so a Safari that (some day) adds WebM/Opus still
  /// gets the server- and bandwidth-friendly default. AAC follows for
  /// Safari, WAV last as the always-decodable fallback.
  static List<AudioEncoder> encoderCandidates({required bool web}) {
    if (!web) {
      return const [AudioEncoder.aacLc, AudioEncoder.wav];
    }
    return const [AudioEncoder.opus, AudioEncoder.aacLc, AudioEncoder.wav];
  }

  /// The `content-type` the server stores and serves back. Pods ride the
  /// browser's audio stack: Chromium decodes WebM/Opus, Safari decoded
  /// its own AAC/MP4 at record time.
  static String mimeFor(AudioEncoder encoder) => switch (encoder) {
    AudioEncoder.wav => 'audio/wav',
    AudioEncoder.opus => 'audio/webm',
    _ => 'audio/mp4',
  };

  /// On web [finish] receives a blob: URL — fetch it while it is hot
  /// (the framework revokes blob URLs aggressively once referenced).
  static Future<List<int>> _fetchBlob(String url) async {
    final res = await http.get(Uri.parse(url));
    if (res.statusCode != 200) return const [];
    return res.bodyBytes;
  }
}
