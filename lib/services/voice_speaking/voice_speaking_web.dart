/// Loudness probes: the web half.
///
/// A WebRTC stream's level is only measurable through an `AudioContext`:
/// the stream feeds a source node → an analyser. The analyser alone is
/// not enough — an analysing graph nobody pulls never renders, so the
/// tail also connects into a zero-gain sink at the destination: the pull
/// is real, the audible output is none, and the WebRTC stream keeps its
/// separate `<audio>` player from `voice_audio`.
library;

import 'dart:async';
import 'dart:js_interop';
import 'dart:typed_data';
import 'dart:math' as math;

import 'package:dart_webrtc/dart_webrtc.dart';
import 'package:web/web.dart' as web;

import 'voice_speaking.dart';

/// RMS above which a stream counts as speaking, and below which it stops
/// again. Asymmetric hysteresis so a babbling trace doesn't flicker.
const _enterRms = 0.022;
const _exitRms = 0.014;

/// Probe cadence — snappy enough to feel live, slow enough to be cheap.
const _pollEvery = Duration(milliseconds: 120);

class WebVoiceSpeaking implements VoiceSpeaking {
  WebVoiceSpeaking(this._stream, {required this.onChange});

  /// The raw MediaStream to analyse (local capture or a remote peer's).
  final web.MediaStream _stream;
  final void Function(bool up) onChange;

  web.AudioContext? _ctx;
  Timer? _timer;
  web.AnalyserNode? _analyser;
  Float32List? _buffer;
  bool _up = false;

  @override
  void start() {
    try {
      final ctx = web.AudioContext();
      _ctx = ctx;
      final source = ctx.createMediaStreamSource(_stream);
      final sink = ctx.createGain()..gain.value = 0;
      final analyser = ctx.createAnalyser();
      analyser.fftSize = 1024;
      final buffer = Float32List(analyser.fftSize);
      source.connect(analyser);
      analyser.connect(sink);
      sink.connect(ctx.destination);
      _analyser = analyser;
      _buffer = buffer;
      _timer = Timer.periodic(_pollEvery, (_) => _read());
    } catch (_) {
      // A context that refuses (count limits, autoplay-adjacent policy):
      // the indicator just stays dark for this stream, which is the
      // honest state for an analysis that never ran.
      _stopContext();
    }
  }

  void _read() {
    final analyser = _analyser;
    final buffer = _buffer;
    if (analyser == null || buffer == null) return;
    analyser.getFloatTimeDomainData(buffer.toJS);
    var sum = 0.0;
    for (final s in buffer) {
      sum += s * s;
    }
    final rms = math.sqrt(sum / buffer.length);
    if (!_up && rms >= _enterRms) {
      _up = true;
      onChange(true);
    } else if (_up && rms < _exitRms) {
      _up = false;
      onChange(false);
    }
  }

  @override
  void stop() {
    _timer?.cancel();
    _timer = null;
    _stopContext();
    if (_up) {
      _up = false;
      // The consumer may still be listening; say the stream went quiet
      // rather than leave a seat lit forever.
      onChange(false);
    }
  }

  void _stopContext() {
    final ctx = _ctx;
    _ctx = null;
    _analyser = null;
    _buffer = null;
    if (ctx != null) {
      try {
        ctx.close();
      } catch (_) {}
    }
  }
}

/// The implementation selected by `voice_speaking.dart`'s conditional
/// export: a live web analyser. A non-web stream shape degrades to a
/// no-op probe instead of crashing the chain.
VoiceSpeaking newVoiceSpeaking(
  Object? stream, {
  required void Function(bool up) onChange,
}) {
  if (stream is! MediaStreamWeb) return NoneVoiceSpeaking();
  return WebVoiceSpeaking(stream.jsStream, onChange: onChange);
}
