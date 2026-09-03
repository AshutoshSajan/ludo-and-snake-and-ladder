// Generates simple synthesized WAV sound effects into assets/sounds/.
// Run once:  dart run tools/gen_sounds.dart
//
// All effects are procedurally synthesized (sine sweeps, noise bursts) so
// the project ships without binary assets.
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

const int sampleRate = 22050;

void main() {
  final dir = Directory('assets/sounds');
  dir.createSync(recursive: true);

  write('tap', _tone(880, 0.05, decay: 18));
  write('move', _tone(520, 0.07, decay: 22));
  write('dice', _diceRattle());
  write('capture', _sweep(600, 140, 0.25, decay: 8));
  write('ladder', _arpeggio([523, 659, 784], 0.1));
  write('snake', _snakeHiss());
  write('home', _arpeggio([659, 988], 0.14));
  write('safe', _arpeggio([784, 1175], 0.09));
  write('win', _arpeggio([523, 659, 784, 1047], 0.16, gap: 0.02));
  write('champion', _fanfare());
  stdout.writeln('Sound effects generated in assets/sounds/');
}

void write(String name, List<double> samples) {
  final bytes = _wavBytes(samples);
  File('assets/sounds/$name.wav').writeAsBytesSync(bytes);
}

List<double> _tone(double freq, double seconds,
    {double decay = 6, double gain = 0.7}) {
  final n = (seconds * sampleRate).round();
  return List.generate(n, (i) {
    final t = i / sampleRate;
    final env = exp(-decay * t);
    return sin(2 * pi * freq * t) * env * gain;
  });
}

List<double> _sweep(double from, double to, double seconds,
    {double decay = 5, double gain = 0.7}) {
  final n = (seconds * sampleRate).round();
  return List.generate(n, (i) {
    final t = i / sampleRate;
    final f = from + (to - from) * (i / n);
    final env = exp(-decay * t);
    return sin(2 * pi * f * t) * env * gain;
  });
}

List<double> _arpeggio(List<double> notes, double noteLen,
    {double gap = 0.0, double gain = 0.65}) {
  final out = <double>[];
  for (final f in notes) {
    out.addAll(_tone(f, noteLen, decay: 9, gain: gain));
    out.addAll(List.filled((gap * sampleRate).round(), 0.0));
  }
  return out;
}

List<double> _fanfare() {
  final out = _arpeggio([523.25, 659.25, 783.99, 1046.5], 0.12, gap: 0.01);
  final n = (0.7 * sampleRate).round();
  for (var i = 0; i < n; i++) {
    final t = i / sampleRate;
    final env = exp(-3 * t) * 0.5;
    // Sustained major chord: root + third + fifth an octave up.
    out.add((sin(2 * pi * 1046.5 * t) +
            0.6 * sin(2 * pi * 1318.5 * t) +
            0.4 * sin(2 * pi * 1568 * t)) *
        env);
  }
  return out;
}

List<double> _diceRattle() {
  final rng = Random(7);
  final out = <double>[];
  for (var b = 0; b < 4; b++) {
    final len = (0.045 * sampleRate).round();
    for (var i = 0; i < len; i++) {
      final t = i / sampleRate;
      final env = exp(-45 * t);
      out.add((rng.nextDouble() * 2 - 1) * env * 0.5);
    }
    out.addAll(List.filled((0.03 * sampleRate).round(), 0.0));
  }
  return out;
}

List<double> _snakeHiss() {
  final rng = Random(3);
  final n = (0.45 * sampleRate).round();
  return List.generate(n, (i) {
    final t = i / sampleRate;
    final env = sin(pi * i / n) * 0.5; // fade in and out
    final wobble = sin(2 * pi * (90 - 40 * t) * t) * 0.3;
    return (rng.nextDouble() * 2 - 1) * env * 0.4 +
        sin(2 * pi * 130 * t) * env * wobble;
  });
}

List<int> _wavBytes(List<double> samples) {
  final data = BytesBuilder();
  for (final s in samples) {
    final v = (s.clamp(-1.0, 1.0) * 32767).round();
    data.add([v & 0xFF, (v >> 8) & 0xFF]);
  }
  final pcm = data.takeBytes();

  final h = BytesBuilder();
  void str(String s) => h.add(utf8.encode(s));
  void u32(int v) => h.add([v & 0xFF, (v >> 8) & 0xFF, (v >> 16) & 0xFF, (v >> 24) & 0xFF]);
  void u16(int v) => h.add([v & 0xFF, (v >> 8) & 0xFF]);

  str('RIFF');
  u32(36 + pcm.length);
  str('WAVE');
  str('fmt ');
  u32(16); // PCM chunk size
  u16(1); // PCM format
  u16(1); // mono
  u32(sampleRate);
  u32(sampleRate * 2); // byte rate
  u16(2); // block align
  u16(16); // bits per sample
  str('data');
  u32(pcm.length);
  h.add(pcm);
  return h.takeBytes();
}
