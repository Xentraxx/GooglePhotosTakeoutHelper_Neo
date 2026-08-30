/// Unit tests for the [DateFolderFormat] value object (issue #142).
///
/// Covers token substitution, case-insensitivity, literal separators,
/// 2-digit year, path-component sanitization, unknown-token rejection,
/// empty-input rejection, and the [DateDivisionSelection] helper.
library;

import 'package:gpth_neo/gpth_lib_exports.dart';
import 'package:path/path.dart' as path;
import 'package:test/test.dart';

void main() {
  // A fixed date used across assertions: 2026-08-30.
  final DateTime date = DateTime(2026, 8, 30);

  group('DateFolderFormat.parse', () {
    test('parses a simple yyyy/mm format', () {
      final f = DateFolderFormat.parse('yyyy/mm');
      expect(f.template, 'yyyy/mm');
    });

    test('trims surrounding whitespace', () {
      final f = DateFolderFormat.parse('  yyyy/mm  ');
      expect(f.template, 'yyyy/mm');
    });

    test('is case-insensitive (uppercase tokens)', () {
      final f = DateFolderFormat.parse('YYYY/MM');
      expect(f.generateFolderPath(date), path.join('2026', '08'));
    });

    test('is case-insensitive (mixed-case tokens)', () {
      final f = DateFolderFormat.parse('YyYy/Mm');
      expect(f.generateFolderPath(date), path.join('2026', '08'));
    });

    test('rejects empty string', () {
      expect(() => DateFolderFormat.parse(''), throwsA(isA<FormatException>()));
    });

    test('rejects whitespace-only string', () {
      expect(
        () => DateFolderFormat.parse('   '),
        throwsA(isA<FormatException>()),
      );
    });

    test('rejects format with no recognized token', () {
      expect(
        () => DateFolderFormat.parse('garbage'),
        throwsA(isA<FormatException>()),
      );
    });

    test('rejects format with only literal separators', () {
      expect(
        () => DateFolderFormat.parse('/-/'),
        throwsA(isA<FormatException>()),
      );
    });
  });

  group('DateFolderFormat.tryParse', () {
    test('returns a format on valid input', () {
      final f = DateFolderFormat.tryParse('yyyy/yyyy-mm');
      expect(f, isNotNull);
      expect(f!.template, 'yyyy/yyyy-mm');
    });

    test('returns null on invalid input', () {
      expect(DateFolderFormat.tryParse(''), isNull);
      expect(DateFolderFormat.tryParse('no-tokens'), isNull);
    });
  });

  group('DateFolderFormat.isPreset', () {
    test('true for 0-3', () {
      for (final v in ['0', '1', '2', '3']) {
        expect(DateFolderFormat.isPreset(v), isTrue, reason: v);
      }
    });

    test('true for 0-3 with surrounding whitespace', () {
      expect(DateFolderFormat.isPreset('  2  '), isTrue);
    });

    test('false for non-preset strings', () {
      expect(DateFolderFormat.isPreset('4'), isFalse);
      expect(DateFolderFormat.isPreset('yyyy/mm'), isFalse);
      expect(DateFolderFormat.isPreset(''), isFalse);
    });
  });

  group('DateFolderFormat.generateFolderPath', () {
    test('yyyy → single year folder', () {
      expect(DateFolderFormat.parse('yyyy').generateFolderPath(date), '2026');
    });

    test('yyyy/mm → year/month (two levels)', () {
      expect(
        DateFolderFormat.parse('yyyy/mm').generateFolderPath(date),
        path.join('2026', '08'),
      );
    });

    test('yyyy/mm/dd → year/month/day (three levels)', () {
      expect(
        DateFolderFormat.parse('yyyy/mm/dd').generateFolderPath(date),
        path.join('2026', '08', '30'),
      );
    });

    test('issue #142 example: yyyy/yyyy-mm', () {
      expect(
        DateFolderFormat.parse('yyyy/yyyy-mm').generateFolderPath(date),
        path.join('2026', '2026-08'),
      );
    });

    test('yy → 2-digit year', () {
      expect(DateFolderFormat.parse('yy').generateFolderPath(date), '26');
    });

    test('yyyy-mm-dd → single folder with dashes', () {
      expect(
        DateFolderFormat.parse('yyyy-mm-dd').generateFolderPath(date),
        '2026-08-30',
      );
    });

    test('pads single-digit month and day', () {
      final DateTime jan5 = DateTime(2026, 1, 5);
      expect(
        DateFolderFormat.parse('yyyy/mm/dd').generateFolderPath(jan5),
        path.join('2026', '01', '05'),
      );
    });

    test('handles leading/trailing slashes (drops empty components)', () {
      // Leading/trailing slashes produce empty components that are dropped.
      expect(
        DateFolderFormat.parse('/yyyy/mm/').generateFolderPath(date),
        path.join('2026', '08'),
      );
    });

    test('sanitizes illegal filename characters in literal text', () {
      // A literal ':' between tokens would be illegal on Windows; it should be
      // replaced with '_'.
      expect(
        DateFolderFormat.parse('yyyy:mm').generateFolderPath(date),
        '2026_08',
      );
    });
  });

  group('DateFolderFormat equality', () {
    test('equal when templates match', () {
      expect(DateFolderFormat.parse('yyyy/mm'), DateFolderFormat.parse('yyyy/mm'));
    });

    test('not equal when templates differ', () {
      expect(
        DateFolderFormat.parse('yyyy/mm') ==
            DateFolderFormat.parse('yyyy/dd'),
        isFalse,
      );
    });
  });

  group('DateDivisionSelection', () {
    test('preset selection', () {
      final s = DateDivisionSelection.preset(2);
      expect(s.preset, 2);
      expect(s.custom, isNull);
      expect(s.isCustom, isFalse);
    });

    test('custom selection', () {
      final fmt = DateFolderFormat.parse('yyyy/mm');
      final s = DateDivisionSelection.custom(fmt);
      expect(s.custom, fmt);
      expect(s.preset, isNull);
      expect(s.isCustom, isTrue);
    });

    test('equality for presets', () {
      expect(
        DateDivisionSelection.preset(1),
        DateDivisionSelection.preset(1),
      );
    });

    test('equality for custom', () {
      expect(
        DateDivisionSelection.custom(DateFolderFormat.parse('yyyy/mm')),
        DateDivisionSelection.custom(DateFolderFormat.parse('yyyy/mm')),
      );
    });

    test('inequality', () {
      expect(
        DateDivisionSelection.preset(1) ==
            DateDivisionSelection.preset(2),
        isFalse,
      );
      expect(
        DateDivisionSelection.preset(1) ==
            DateDivisionSelection.custom(DateFolderFormat.parse('yyyy/mm')),
        isFalse,
      );
    });
  });
}
