import 'package:flutter_test/flutter_test.dart';
import 'package:game_club/services/note_recorder.dart';
import 'package:record/record.dart' show AudioEncoder;

void main() {
  group('encoderCandidates — the codec order a recorder is probed with', () {
    test('web asks Opus first, then AAC, then WAV', () {
      expect(NoteRecorder.encoderCandidates(web: true), const [
        AudioEncoder.opus,
        AudioEncoder.aacLc,
        AudioEncoder.wav,
      ]);
    });

    test('native platforms ask AAC first, WAV as the Linux fallback', () {
      expect(NoteRecorder.encoderCandidates(web: false), const [
        AudioEncoder.aacLc,
        AudioEncoder.wav,
      ]);
    });
  });

  group('mimeFor — the content-type stored and served back', () {
    test('each codec reports the mime its engine produces', () {
      expect(NoteRecorder.mimeFor(AudioEncoder.opus), 'audio/webm');
      expect(NoteRecorder.mimeFor(AudioEncoder.wav), 'audio/wav');
      expect(NoteRecorder.mimeFor(AudioEncoder.aacLc), 'audio/mp4');
      expect(NoteRecorder.mimeFor(AudioEncoder.aacHe), 'audio/mp4');
    });
  });

  group('the probe decision — no plugin calls, only the candidate table', () {
    test('web: "Opus accepted" wins over the later candidates (Chromium)', () {
      final found = _firstSupported(const {
        AudioEncoder.opus,
      }, NoteRecorder.encoderCandidates(web: true));
      expect(found, AudioEncoder.opus);
    });

    test('web: a Safari that answers AAC only picks AAC', () {
      final found = _firstSupported(const {
        AudioEncoder.aacLc,
      }, NoteRecorder.encoderCandidates(web: true));
      expect(found, AudioEncoder.aacLc);
    });

    test('a recorder that accepts nothing yields null — start() then reads '
        'as "No microphone" instead of a platform crash', () {
      final found = _firstSupported(
        const <AudioEncoder>{},
        NoteRecorder.encoderCandidates(web: false),
      );
      expect(found, isNull);
    });
  });

  group(
    'recordConfig — the capture pipeline, pinned without a plugin call',
    () {
      // The web delegate copies these booleans straight into getUserMedia,
      // and the plugin's own default is FALSE for all three: unset means
      // "record the raw room" (hum, clatter, game bleed), which is how the
      // noise got into voice notes while live calls stayed clean on their
      // bare 'audio: true'. These expectations are the regression pin.
      for (final encoder in [
        AudioEncoder.opus,
        AudioEncoder.aacLc,
        AudioEncoder.wav,
      ]) {
        test(
          '$encoder notes ride the speech clean-up and the compact format',
          () {
            final config = NoteRecorder.recordConfig(encoder);
            expect(config.encoder, encoder);
            expect(config.echoCancel, isTrue, reason: 'like the calls path');
            expect(config.noiseSuppress, isTrue);
            expect(config.autoGain, isTrue);
            expect(config.sampleRate, 16000, reason: '2 MiB cap for a minute');
            expect(config.numChannels, 1);
            expect(config.bitRate, 96000);
          },
        );
      }
    },
  );
}

/// Mirrors the probe loop in [NoteRecorder]: try candidates in order, take
/// the first the recorder claims to support, else null. The real loop also
/// asks the plugin (a platform seam), which is exactly the part these
/// decision tests deliberately keep out.
AudioEncoder? _firstSupported(
  Set<AudioEncoder> supports,
  List<AudioEncoder> candidates,
) {
  for (final encoder in candidates) {
    if (supports.contains(encoder)) return encoder;
  }
  return null;
}
