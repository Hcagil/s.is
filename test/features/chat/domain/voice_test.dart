import 'package:flutter_test/flutter_test.dart';
import 'package:sis/features/chat/domain/voice.dart';

void main() {
  group('Constants', () {
    test('maxVoiceMs', () => expect(maxVoiceMs, 600000));
    test('voiceMime', () => expect(voiceMime, 'audio/mp4'));
    test('voicePreview', () => expect(voicePreview, '\u{1F3A4} Voice message'));
    test('voiceBars', () => expect(voiceBars, 40));
    test('maxTranscriptChars', () => expect(maxTranscriptChars, 10000));
    test('voiceSpeeds', () => expect(voiceSpeeds, [1.0, 1.5, 2.0]));
  });

  group('nextVoiceSpeed', () {
    test('wraps from 2.0 to 1.0', () => expect(nextVoiceSpeed(2.0), 1.0));
    test('1.0 -> 1.5', () => expect(nextVoiceSpeed(1.0), 1.5));
    test('1.5 -> 2.0', () => expect(nextVoiceSpeed(1.5), 2.0));
    test('unknown speed returns 1.0', () => expect(nextVoiceSpeed(3.0), 1.0));
    test('unknown speed returns 1.0', () => expect(nextVoiceSpeed(0.75), 1.0));
  });

  group('voiceSpeedLabel', () {
    test('1.0 -> 1x', () => expect(voiceSpeedLabel(1.0), '1x'));
    test('1.5 -> 1.5x', () => expect(voiceSpeedLabel(1.5), '1.5x'));
    test('2.0 -> 2x', () => expect(voiceSpeedLabel(2.0), '2x'));
  });

  group('voiceClock', () {
    test('0 ms -> 0:00', () => expect(voiceClock(0), '0:00'));
    test('999 ms -> 0:00', () => expect(voiceClock(999), '0:00'));
    test('1000 ms -> 0:01', () => expect(voiceClock(1000), '0:01'));
    test('59999 ms -> 0:59', () => expect(voiceClock(59999), '0:59'));
    test('60000 ms -> 1:00', () => expect(voiceClock(60000), '1:00'));
    test('600000 ms -> 10:00', () => expect(voiceClock(600000), '10:00'));
    test('65432 ms -> 1:05', () => expect(voiceClock(65432), '1:05'));
  });

  group('voiceTimer', () {
    test('0 ms -> 0:00,00', () => expect(voiceTimer(0), '0:00,00'));
    test('1234 ms -> 0:01,23', () => expect(voiceTimer(1234), '0:01,23'));
    test('9 ms -> 0:00,00', () => expect(voiceTimer(9), '0:00,00'));
    test('10 ms -> 0:00,01', () => expect(voiceTimer(10), '0:00,01'));
    test('61999 ms -> 1:01,99', () => expect(voiceTimer(61999), '1:01,99'));
    test('600000 ms -> 10:00,00', () => expect(voiceTimer(600000), '10:00,00'));
  });

  group('voiceFileName', () {
    test('one second apart gives different names', () {
      final now = DateTime.now();
      final later = now.add(const Duration(seconds: 1));
      expect(voiceFileName(now), isNot(equals(voiceFileName(later))));
    });

    test('ends with .m4a', () {
      final name = voiceFileName(DateTime.now());
      expect(name.endsWith('.m4a'), isTrue);
    });
  });

  group('encodeWaveform', () {
    test('empty list -> 40 "1"s', () {
      final result = encodeWaveform([]);
      expect(result, equals('1' * voiceBars));
      expect(result.length, equals(voiceBars));
    });

    test('100 samples all 1.0 -> 40 "f"s', () {
      final samples = List<double>.filled(100, 1.0);
      final result = encodeWaveform(samples);
      expect(result, equals('f' * voiceBars));
    });

    test('100 samples all 0.0 -> 40 "0"s', () {
      final samples = List<double>.filled(100, 0.0);
      final result = encodeWaveform(samples);
      expect(result, equals('0' * voiceBars));
    });

    test('400 samples with only index 395 = 1.0', () {
      final samples = List<double>.filled(400, 0.0);
      samples[395] = 1.0;
      final result = encodeWaveform(samples);
      expect(result.length, equals(voiceBars));
      expect(result.substring(0, 39), equals('0' * 39));
      expect(result[39], equals('f'));
    });

    test('2 samples [0.0, 1.0] -> first "0", last "f"', () {
      final result = encodeWaveform([0.0, 1.0]);
      expect(result.length, equals(voiceBars));
      expect(result[0], equals('0'));
      expect(result[39], equals('f'));
    });

    test('length 40 for 1, 39, 40, 41, 1000 samples', () {
      for (final n in [1, 39, 40, 41, 1000]) {
        final samples = List<double>.filled(n, 0.5);
        final result = encodeWaveform(samples);
        expect(result.length, equals(voiceBars));
      }
    });

    test('result matches hex regex', () {
      final samples = List<double>.filled(100, 0.3);
      final result = encodeWaveform(samples);
      expect(RegExp(r'^[0-9a-f]{40}$').hasMatch(result), isTrue);
    });
  });

  group('decodeWaveform', () {
    test('null -> empty list', () => expect(decodeWaveform(null), isEmpty));
    test(
      'empty string -> empty list',
      () => expect(decodeWaveform(''), isEmpty),
    );
    test(
      'uppercase "ABC" -> empty list',
      () => expect(decodeWaveform('ABC'), isEmpty),
    );
    test(
      'lowercase "xyz" -> empty list',
      () => expect(decodeWaveform('xyz'), isEmpty),
    );
    test('decode of "0f" -> [0.0, 1.0]', () {
      final decoded = decodeWaveform('0f');
      expect(decoded, equals([0.0, 1.0]));
    });
    test('decode(encode(samples)).length == 40', () {
      final samples = List<double>.generate(123, (i) => i / 123);
      final encoded = encodeWaveform(samples);
      final decoded = decodeWaveform(encoded);
      expect(decoded.length, equals(voiceBars));
    });
    test('all decoded values in 0..1', () {
      final encoded = encodeWaveform(List<double>.filled(50, 0.7));
      final decoded = decodeWaveform(encoded);
      for (final v in decoded) {
        expect(v, inInclusiveRange(0.0, 1.0));
      }
    });
  });

  group('cleanTranscript', () {
    test('null -> null', () => expect(cleanTranscript(null), isNull));
    test('empty string -> null', () => expect(cleanTranscript(''), isNull));
    test(
      'whitespace only -> null',
      () => expect(cleanTranscript('   \n '), isNull),
    );
    test(
      'trimmed content',
      () => expect(cleanTranscript('  hi  '), equals('hi')),
    );
    test('long transcript trimmed to 10000', () {
      final long = 'a' * (maxTranscriptChars + 1);
      final cleaned = cleanTranscript(long);
      expect(cleaned, isNotNull);
      expect(cleaned!.length, equals(maxTranscriptChars));
    });
    test('trimmed long transcript', () {
      final long = '  ${'a' * maxTranscriptChars}  ';
      final cleaned = cleanTranscript(long);
      expect(cleaned, isNotNull);
      expect(cleaned!.length, equals(maxTranscriptChars));
    });
  });
}
