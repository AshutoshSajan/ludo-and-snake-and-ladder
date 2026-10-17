/// Records chat voice notes locally.
///
/// A thin shell over the `record` plugin, on purpose: everything worth
/// testing flows through [OnlineClient.sendVoiceNote] (upload + announce)
/// and the composer's state machine, while this class only marshals the
/// microphone. One formatter-question is answered here, though: the
/// recorder produces **AAC in an MP4 container** everywhere an AAC
/// encoder ships (web via MediaRecorder, Apple, Android, Windows) and
/// **WAV** on Linux, whose GStreamer pipeline has no AAC — between them
/// that covers every platform the app builds for with a format every
/// player (browser or native) can decode. 16 kHz mono keeps a minute
/// under the server's 2 MiB cap on either codec.
library;

import 'dart:io' show File;

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';
import 'package:record/record.dart';

/// The finished recording, ready for [OnlineClient.sendVoiceNote].
class NoteRecording {
  const NoteRecording({required this.bytes, required this.mime, required this.durMs});

  final List<int> bytes;
  final String mime;
  final int durMs;
}

class NoteRecorder {
  NoteRecorder._(this._recorder) : _stopwatch = Stopwatch();

  final AudioRecorder _recorder;
  final Stopwatch _stopwatch;

  /// The recorder's own cap: a minute of speech is generous, bound the
  /// encoder's output and the server's patience at once.
  static const max = Duration(seconds: 60);

  Future<NoteRecording?> finish() async {
    final durMs = _stopwatch.elapsedMilliseconds.clamp(0, max.inMilliseconds);
    final pathOrUrl = await _recorder.stop();
    if (pathOrUrl == null) return null;
    final encoder = _encoderFor();
    try {
      final bytes = kIsWeb
          ? await _fetchBlob(pathOrUrl)
          : await File(pathOrUrl).readAsBytes();
      if (bytes.isEmpty) return null;
      return NoteRecording(
        bytes: bytes,
        mime: encoder == AudioEncoder.wav ? 'audio/wav' : 'audio/mp4',
        durMs: durMs,
      );
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
  /// (permission, no device, browser without getUserMedia).
  static Future<NoteRecorder?> start() async {
    final recorder = AudioRecorder();
    try {
      if (!await recorder.hasPermission()) return null;
      final encoder = _encoderFor();
      final ext = encoder == AudioEncoder.wav ? 'wav' : 'm4a';
      final dir = (await getTemporaryDirectory()).path;
      await recorder.start(
        RecordConfig(encoder: encoder, sampleRate: 16000, numChannels: 1, bitRate: 96000),
        path: '$dir/table-chat-note.$ext',
      );
      final session = NoteRecorder._(recorder);
      session._stopwatch.start();
      return session;
    } catch (_) {
      return null;
    }
  }

  /// On web [finish] receives a blob: URL — fetch it while it is hot
  /// (the framework revokes blob URLs aggressively once referenced).
  static Future<List<int>> _fetchBlob(String url) async {
    final res = await http.get(Uri.parse(url));
    if (res.statusCode != 200) return const [];
    return res.bodyBytes;
  }
}

AudioEncoder _encoderFor() =>
    defaultTargetPlatform == TargetPlatform.linux
    ? AudioEncoder.wav
    : AudioEncoder.aacLc;
