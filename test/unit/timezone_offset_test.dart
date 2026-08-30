// ignore_for_file: lines_longer_than_80_chars

import 'package:gpth_neo/gpth_lib_exports.dart';
import 'package:test/test.dart';

/// Unit tests for the [TimezoneOffset] value object (issue #145).
///
/// Covers parsing of all accepted formats, EXIF string formatting, range
/// validation, equality, and the UTC alias handling.
void main() {
  group('TimezoneOffset.parse', () {
    test('parses signed HH:MM form', () {
      expect(TimezoneOffset.parse('+08:00').exifString, '+08:00');
      expect(TimezoneOffset.parse('-05:30').exifString, '-05:30');
      expect(TimezoneOffset.parse('+00:00').exifString, '+00:00');
    });

    test('parses hours-only form (with and without sign)', () {
      expect(TimezoneOffset.parse('+8').exifString, '+08:00');
      expect(TimezoneOffset.parse('-5').exifString, '-05:00');
      expect(TimezoneOffset.parse('8').exifString, '+08:00');
      expect(TimezoneOffset.parse('12').exifString, '+12:00');
    });

    test('parses HHMM form (no colon)', () {
      expect(TimezoneOffset.parse('+0530').exifString, '+05:30');
      expect(TimezoneOffset.parse('-0300').exifString, '-03:00');
    });

    test('parses UTC aliases as zero offset', () {
      expect(TimezoneOffset.parse('Z').isUtc, isTrue);
      expect(TimezoneOffset.parse('UTC').isUtc, isTrue);
      expect(TimezoneOffset.parse('0').isUtc, isTrue);
      expect(TimezoneOffset.parse('+00:00').isUtc, isTrue);
    });

    test('trims surrounding whitespace', () {
      expect(TimezoneOffset.parse('  +08:00  ').exifString, '+08:00');
    });

    test('is case-insensitive for UTC aliases', () {
      expect(TimezoneOffset.parse('utc').isUtc, isTrue);
      expect(TimezoneOffset.parse('z').isUtc, isTrue);
    });
  });

  group('TimezoneOffset.parse rejects invalid input', () {
    final invalid = <String>[
      '',
      'abc',
      '+abc',
      '+08:',
      '+:30',
      '+25:00',
      '-13:00',
      '+14:01',
      '-12:01',
      '+08:60',
      '+08:-30',
      '++08:00',
      '--05:00',
      '+8:30:00',
    ];

    for (final input in invalid) {
      test('rejects "$input"', () {
        expect(
          () => TimezoneOffset.parse(input),
          throwsA(isA<FormatException>()),
        );
      });
    }
  });

  group('TimezoneOffset range boundaries', () {
    test('accepts +14:00 (max)', () {
      expect(TimezoneOffset.parse('+14:00').exifString, '+14:00');
    });

    test('accepts -12:00 (min)', () {
      expect(TimezoneOffset.parse('-12:00').exifString, '-12:00');
    });

    test('accepts +12:45 (Chatham Islands)', () {
      expect(TimezoneOffset.parse('+12:45').exifString, '+12:45');
    });

    test('rejects +14:01 (just over max)', () {
      expect(
        () => TimezoneOffset.parse('+14:01'),
        throwsA(isA<FormatException>()),
      );
    });

    test('rejects -12:01 (just under min)', () {
      expect(
        () => TimezoneOffset.parse('-12:01'),
        throwsA(isA<FormatException>()),
      );
    });
  });

  group('TimezoneOffset.duration', () {
    test('+08:00 is 8 hours', () {
      expect(TimezoneOffset.parse('+08:00').duration, const Duration(hours: 8));
    });

    test('-05:30 is -5 hours 30 minutes', () {
      expect(
        TimezoneOffset.parse('-05:30').duration,
        const Duration(hours: -5, minutes: -30),
      );
    });

    test('UTC is zero duration', () {
      expect(TimezoneOffset.utc.duration, Duration.zero);
    });
  });

  group('TimezoneOffset.exifString', () {
    test('always zero-pads to ±HH:MM', () {
      expect(TimezoneOffset.parse('+5').exifString, '+05:00');
      expect(TimezoneOffset.parse('-3').exifString, '-03:00');
      expect(TimezoneOffset.parse('+0530').exifString, '+05:30');
    });

    test('always includes sign', () {
      expect(TimezoneOffset.parse('8').exifString.startsWith('+'), isTrue);
      expect(TimezoneOffset.parse('-5').exifString.startsWith('-'), isTrue);
    });
  });

  group('TimezoneOffset.tryParse', () {
    test('returns null on invalid input', () {
      expect(TimezoneOffset.tryParse('abc'), isNull);
      expect(TimezoneOffset.tryParse('+25:00'), isNull);
      expect(TimezoneOffset.tryParse(''), isNull);
    });

    test('returns offset on valid input', () {
      final result = TimezoneOffset.tryParse('+08:00');
      expect(result, isNotNull);
      expect(result!.exifString, '+08:00');
    });
  });

  group('TimezoneOffset equality', () {
    test('equal offsets are equal', () {
      expect(TimezoneOffset.parse('+08:00'), TimezoneOffset.parse('+8'));
      expect(
        TimezoneOffset.parse('+05:30'),
        TimezoneOffset(const Duration(hours: 5, minutes: 30)),
      );
    });

    test('different offsets are not equal', () {
      expect(
        TimezoneOffset.parse('+08:00'),
        isNot(TimezoneOffset.parse('+09:00')),
      );
    });

    test('hashCode matches equality', () {
      final a = TimezoneOffset.parse('+08:00');
      final b = TimezoneOffset.parse('+8');
      expect(a.hashCode, b.hashCode);
    });
  });

  group('TimezoneOffset.toString', () {
    test('returns the exifString', () {
      expect(TimezoneOffset.parse('+08:00').toString(), '+08:00');
      expect(TimezoneOffset.parse('-05:30').toString(), '-05:30');
    });
  });

  group('TimezoneOffset.isUtc', () {
    test('true for zero offset', () {
      expect(TimezoneOffset.utc.isUtc, isTrue);
      expect(TimezoneOffset.parse('+00:00').isUtc, isTrue);
    });

    test('false for non-zero offset', () {
      expect(TimezoneOffset.parse('+08:00').isUtc, isFalse);
      expect(TimezoneOffset.parse('-05:30').isUtc, isFalse);
    });
  });
}
