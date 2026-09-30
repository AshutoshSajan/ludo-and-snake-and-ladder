import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

/// The chat notification must be unmistakable against the game's own sounds.
///
/// Measured, not asserted by hand, because the failure is invisible until it is
/// heard in context. The first version was a rising two-note chime at
/// 875 -> 1175 Hz: 875 is `tap`'s exact pitch and 1175 is `safe`'s exact second
/// note, so the notification sat on top of two game sounds. Generating it
/// revealed nothing; comparing pitch content did.
///
/// Dominant pitch is found with a Goertzel sweep rather than zero crossings,
/// because zero crossings measure brightness *and* noise: `snake` is a 225 Hz
/// growl whose gritty waveform crosses zero thousands of times a second, and a
/// zcr-based check reported it as brighter than the chime.
void main() {
  const rate = 22050;
  const win = 1024;
  const hop = 512;
  const binHz = 25;

  List<double> readSamples(String path) {
    final bytes = File(path).readAsBytesSync();
    final data = ByteData.sublistView(bytes);
    const start = 12 + 16 + 8; // RIFF + fmt + data headers
    final count = (bytes.length - start) ~/ 2;
    return [
      for (var i = 0; i < count; i++)
        data.getInt16(start + i * 2, Endian.little) / 32768.0,
    ];
  }

  /// The pitch of the strongest frame, or 0 if the sound is silent.
  double dominantPitch(List<double> x) {
    double bestFreq = 0, bestMag = 0;
    for (var s = 0; s + win <= x.length; s += hop) {
      var rms = 0.0;
      for (var i = s; i < s + win; i++) {
        rms += x[i] * x[i];
      }
      rms = rms / win;
      if (rms < 0.02) continue; // silence between notes
      for (var f = 150; f < 4000; f += binHz) {
        var re = 0.0, im = 0.0;
        final w = 2 * pi * f / rate;
        for (var i = s; i < s + win; i++) {
          re += x[i] * cos(w * (i - s));
          im += x[i] * sin(w * (i - s));
        }
        final mag = re * re + im * im;
        if (mag > bestMag) {
          bestMag = mag;
          bestFreq = f.toDouble();
        }
      }
    }
    return bestFreq;
  }

  /// The distinct pitched notes in a sound, quantised to the analysis bin.
  Set<int> notesOf(String path) {
    final x = readSamples(path);
    final found = <int>{};
    for (var s = 0; s + win <= x.length; s += hop) {
      var rms = 0.0;
      for (var i = s; i < s + win; i++) {
        rms += x[i] * x[i];
      }
      if (rms / win < 0.02) continue;
      final f = dominantPitch(List<double>.from(x.sublist(s, s + win)));
      if (f > 0) found.add((f / binHz).round());
    }
    return found;
  }

  test('the notification shares no pitch with any other sound', () {
    final dir = Directory('assets/sounds');
    final files = dir
        .listSync()
        .whereType<File>()
        .where((f) => f.path.endsWith('.wav'))
        .toList()
        .toList()
      ..sort((a, b) => a.path.compareTo(b.path));
    expect(files, isNotEmpty);

    final chat = notesOf('assets/sounds/message.wav');
    expect(chat, isNotEmpty, reason: 'message.wav analysed as silence');

    for (final f in files) {
      if (f.path.endsWith('message.wav')) continue;
      final other = notesOf(f.path);
      // `dice` is a percussive rattle with no stable pitch, so comparing bins
      // against it would be noise on both sides. The rest are tonal.
      if (f.path.endsWith('dice.wav')) continue;
      final shared = chat.intersection(other);
      expect(shared, isEmpty,
          reason: 'message.wav shares pitch bin(s) $shared with '
              '${f.uri.pathSegments.last} — a notification that overlaps a game '
              'sound is not a notification');
    }
  });

  test('it matches the format of the other assets', () {
    // A mismatched sample rate is audible as a chipmunk or a groan.
    final header = File('assets/sounds/message.wav').readAsBytesSync();
    final rate = ByteData.sublistView(header).getUint32(24, Endian.little);
    for (final name in ['tap', 'dice', 'win']) {
      final other = ByteData.sublistView(
        File('assets/sounds/$name.wav').readAsBytesSync(),
      ).getUint32(24, Endian.little);
      expect(rate, other, reason: 'sample rate differs from $name.wav');
    }
  });

  test('it is long enough to read as several events, not one click', () {
    final header = File('assets/sounds/message.wav').readAsBytesSync();
    final r = ByteData.sublistView(header).getUint32(24, Endian.little);
    final seconds = (header.length - 36) / 2 / r;
    expect(seconds, greaterThan(0.15),
        reason: 'too short to tell apart from a UI tap');
  });
}
