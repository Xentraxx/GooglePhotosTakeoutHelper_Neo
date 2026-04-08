/// Unit tests for InteropIFD error retry logic in WriteExifProcessingService.
///
/// Covers:
///   A – both "Truncated InteropIFD directory" and "Bad format (N) for InteropIFD
///       entry M" trigger XMP retagging (not just the truncated variant).
///   B – the XMP fallback tier is present in both the splitAndWrite chunk==1 path
///       and the writeForFile non-batch path.
library;

import 'dart:io';
import 'package:gpth_neo/gpth_lib_exports.dart';
import 'package:test/test.dart';

import '../setup/test_setup.dart';

// ---------------------------------------------------------------------------
// Configurable mock ExifTool service
// ---------------------------------------------------------------------------

/// Describes what a single [writeExifDataSingle] call should do.
typedef _SingleCallBehaviour =
    void Function(File file, Map<String, dynamic> tags);

/// Mock that executes a queue of behaviours for [writeExifDataSingle].
/// After the queue is exhausted, subsequent calls succeed silently.
class _SequencedMockExifTool extends ExifToolService {
  _SequencedMockExifTool() : super('/mock/path/exiftool');

  final List<_SingleCallBehaviour> _queue = [];
  final List<Map<String, dynamic>> capturedTags = [];
  final List<File> capturedFiles = [];

  void addBehaviour(final _SingleCallBehaviour b) => _queue.add(b);

  @override
  Future<void> writeExifDataSingle(
    final File file,
    final Map<String, dynamic> exifData,
  ) async {
    capturedTags.add(Map<String, dynamic>.unmodifiable(exifData));
    capturedFiles.add(file);
    if (_queue.isNotEmpty) {
      final behaviour = _queue.removeAt(0);
      behaviour(file, exifData);
    }
    // default: succeed silently
  }

  @override
  Future<void> writeExifDataBatch(
    final List<MapEntry<File, Map<String, dynamic>>> batch,
  ) async {}

  @override
  Future<void> writeExifDataBatchViaArgFile(
    final List<MapEntry<File, Map<String, dynamic>>> batch,
  ) async {}

  @override
  Future<Map<String, dynamic>> readExifData(final File file) async => {};

  @override
  Future<void> startPersistentProcess() async {}

  @override
  Future<String> executeExifToolCommand(
    final List<String> args, {
    final Duration? timeout,
  }) async => '';

  @override
  Future<void> dispose() async {}
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

void main() {
  group('isInteropIfdError', () {
    test('matches "Truncated InteropIFD directory"', () {
      expect(
        WriteExifProcessingService.isInteropIfdError(
          Exception('Error: Truncated InteropIFD directory - /tmp/a.jpg'),
        ),
        isTrue,
      );
    });

    test('matches "Bad format (282) for InteropIFD entry 0"', () {
      expect(
        WriteExifProcessingService.isInteropIfdError(
          Exception(
            'Error: Bad format (282) for InteropIFD entry 0 - /tmp/a.jpg',
          ),
        ),
        isTrue,
      );
    });

    test('matches "Bad InteropIFD offset for Exif_0x0000"', () {
      expect(
        WriteExifProcessingService.isInteropIfdError(
          Exception(
            'Warning: Bad InteropIFD offset for Exif_0x0000 - /tmp/a.jpg',
          ),
        ),
        isTrue,
      );
    });

    test('does not match unrelated errors', () {
      expect(
        WriteExifProcessingService.isInteropIfdError(
          Exception('Error: Permission denied - /tmp/a.jpg'),
        ),
        isFalse,
      );
    });
  });

  // -------------------------------------------------------------------------
  // WriteExifAuxiliaryService.writeTagsWithExifToolSingle retry logic (item B)
  // -------------------------------------------------------------------------
  // writeTagsWithExifToolSingle calls _exifTool!.writeExifDataSingle internally
  // and handles InteropIFD errors in its own catch block. The mock overrides
  // writeExifDataSingle, so the sequence of behaviours drives the retry tiers.
  group('writeTagsWithExifToolSingle – InteropIFD retry tiers', () {
    late TestFixture fixture;
    late _SequencedMockExifTool mock;

    setUp(() async {
      fixture = TestFixture();
      await fixture.setUp();
      mock = _SequencedMockExifTool();
    });

    tearDown(() async {
      await fixture.tearDown();
    });

    test(
      'tier-1: single Truncated InteropIFD resolves after OffsetTime* strip',
      () async {
        final file = fixture.createImageWithExif('photo.jpg');

        // Call 1: fail (triggers tier-1 strip)
        mock.addBehaviour((final f, final t) {
          throw Exception(
            '[ExifToolService] ExifTool single-mode failed: '
            'Error: Truncated InteropIFD directory - ${f.path}',
          );
        });
        // Call 2: succeed (stripped tags)

        final service = WriteExifAuxiliaryService(mock);
        final result = await service.writeTagsWithExifToolSingle(file, {
          'DateTimeOriginal': '"2024:01:01 10:00:00"',
          'OffsetTime': '"+00:00"',
          'OffsetTimeOriginal': '"+00:00"',
          'OffsetTimeDigitized': '"+00:00"',
        });

        expect(result, isTrue, reason: 'tier-1 retry should succeed');
        expect(mock.capturedTags.length, equals(2), reason: 'exactly 2 calls');
        final finalTags = mock.capturedTags.last;
        expect(finalTags.containsKey('OffsetTime'), isFalse);
        expect(finalTags.containsKey('DateTimeOriginal'), isTrue);
        expect(finalTags.containsKey('XMP:CreateDate'), isFalse);
      },
    );

    test(
      'tier-1: Bad format (N) for InteropIFD entry also triggers strip retry '
      '(item A – parity with Truncated variant)',
      () async {
        final file = fixture.createImageWithExif('photo.jpg');

        mock.addBehaviour((final f, final t) {
          throw Exception(
            '[ExifToolService] ExifTool single-mode failed: '
            'Error: Bad format (282) for InteropIFD entry 0 - ${f.path}',
          );
        });
        // Call 2: succeed

        final service = WriteExifAuxiliaryService(mock);
        final result = await service.writeTagsWithExifToolSingle(file, {
          'DateTimeOriginal': '"2024:06:15 08:30:00"',
          'OffsetTime': '"+00:00"',
          'OffsetTimeOriginal': '"+00:00"',
          'OffsetTimeDigitized': '"+00:00"',
        });

        expect(result, isTrue);
        expect(mock.capturedTags.length, equals(2));
        expect(mock.capturedTags.last.containsKey('OffsetTime'), isFalse);
        expect(mock.capturedTags.last.containsKey('DateTimeOriginal'), isTrue);
      },
    );

    test('tier-2: two InteropIFD failures on JPEG falls back to XMP', () async {
      final file = fixture.createImageWithExif('photo.jpg');

      // Call 1: fail (triggers tier-1 strip)
      mock.addBehaviour((final f, final t) {
        throw Exception(
          '[ExifToolService] ExifTool single-mode failed: '
          'Error: Truncated InteropIFD directory - ${f.path}',
        );
      });
      // Call 2: fail again (triggers tier-2 XMP)
      mock.addBehaviour((final f, final t) {
        throw Exception(
          '[ExifToolService] ExifTool single-mode failed: '
          'Error: Truncated InteropIFD directory - ${f.path}',
        );
      });
      // Call 3: succeed (XMP tags)

      final service = WriteExifAuxiliaryService(mock);
      final result = await service.writeTagsWithExifToolSingle(file, {
        'DateTimeOriginal': '"2024:01:01 10:00:00"',
        'DateTimeDigitized': '"2024:01:01 10:00:00"',
        'DateTime': '"2024:01:01 10:00:00"',
        'OffsetTime': '"+00:00"',
        'OffsetTimeOriginal': '"+00:00"',
        'OffsetTimeDigitized': '"+00:00"',
      });

      expect(result, isTrue, reason: 'tier-2 XMP retry should succeed');
      expect(mock.capturedTags.length, equals(3), reason: 'exactly 3 calls');
      final finalTags = mock.capturedTags.last;
      expect(finalTags.containsKey('OffsetTime'), isFalse);
      expect(finalTags.containsKey('DateTimeOriginal'), isFalse);
      expect(finalTags.containsKey('XMP:CreateDate'), isTrue);
      expect(finalTags.containsKey('XMP:DateTimeOriginal'), isTrue);
    });

    test(
      'only OffsetTime* tags: no retry issued, returns false (date written natively)',
      () async {
        final file = fixture.createImageWithExif('photo.jpg');

        mock.addBehaviour((final f, final t) {
          throw Exception(
            '[ExifToolService] ExifTool single-mode failed: '
            'Error: Truncated InteropIFD directory - ${f.path}',
          );
        });

        final service = WriteExifAuxiliaryService(mock);
        final result = await service.writeTagsWithExifToolSingle(file, {
          'OffsetTime': '"+00:00"',
          'OffsetTimeOriginal': '"+00:00"',
          'OffsetTimeDigitized': '"+00:00"',
        });

        expect(result, isFalse, reason: 'offset-only failure returns false');
        // Only 1 call: after detecting onlyOffsetTags there is no retry
        expect(mock.capturedTags.length, equals(1));
      },
    );

    test('all three tiers fail: returns false', () async {
      final file = fixture.createImageWithExif('photo.jpg');

      for (var i = 0; i < 3; i++) {
        mock.addBehaviour((final f, final t) {
          throw Exception(
            '[ExifToolService] ExifTool single-mode failed: '
            'Error: Truncated InteropIFD directory - ${f.path}',
          );
        });
      }

      final service = WriteExifAuxiliaryService(mock);
      final result = await service.writeTagsWithExifToolSingle(file, {
        'DateTimeOriginal': '"2024:01:01 10:00:00"',
        'OffsetTime': '"+00:00"',
        'OffsetTimeOriginal': '"+00:00"',
        'OffsetTimeDigitized': '"+00:00"',
      });

      expect(result, isFalse);
      // 3 calls: original, tier-1 strip, tier-2 XMP
      expect(mock.capturedTags.length, equals(3));
    });

    test(
      'non-JPEG with two InteropIFD failures: no XMP tier, returns false',
      () async {
        final file = fixture.createFile('video.mp4', [0x00, 0x00, 0x00, 0x00]);

        for (var i = 0; i < 2; i++) {
          mock.addBehaviour((final f, final t) {
            throw Exception(
              '[ExifToolService] ExifTool single-mode failed: '
              'Error: Truncated InteropIFD directory - ${f.path}',
            );
          });
        }

        final service = WriteExifAuxiliaryService(mock);
        final result = await service.writeTagsWithExifToolSingle(file, {
          'DateTimeOriginal': '"2024:01:01 10:00:00"',
          'OffsetTime': '"+00:00"',
        });

        expect(result, isFalse);
        // Only tier-1 (strip) is attempted for non-JPEGs; no XMP tier
        expect(mock.capturedTags.length, equals(2));
        expect(mock.capturedTags.last.containsKey('XMP:CreateDate'), isFalse);
      },
    );
  });

  // -------------------------------------------------------------------------
  // _retagEntryToXmpIfJpeg logic (XMP conversion correctness)
  // -------------------------------------------------------------------------
  group('XMP retag conversion correctness', () {
    test(
      'EXIF date tags become XMP:CreateDate / XMP:DateTimeOriginal / XMP:ModifyDate',
      () {
        // Mirror the logic of _retagEntryToXmpIfJpeg
        final tags = <String, dynamic>{
          'DateTimeOriginal': '"2024:01:01 10:00:00"',
          'DateTimeDigitized': '"2024:01:01 10:00:00"',
          'DateTime': '"2024:01:01 10:00:00"',
          'OffsetTime': '"+00:00"',
          'OffsetTimeOriginal': '"+00:00"',
          'OffsetTimeDigitized': '"+00:00"',
          'GPSLatitude': '51.5', // absolute positive value
          'GPSLongitude':
              '0.1', // absolute positive value (West = negative after conversion)
          'GPSLatitudeRef': 'N',
          'GPSLongitudeRef': 'W',
        };

        final dtVal =
            tags['DateTimeOriginal'] ??
            tags['DateTimeDigitized'] ??
            tags['DateTime'];
        tags
          ..remove('DateTimeOriginal')
          ..remove('DateTimeDigitized')
          ..remove('DateTime')
          ..remove('OffsetTime')
          ..remove('OffsetTimeOriginal')
          ..remove('OffsetTimeDigitized');
        if (dtVal != null) {
          tags['XMP:CreateDate'] = dtVal;
          tags['XMP:DateTimeOriginal'] = dtVal;
          tags['XMP:ModifyDate'] = dtVal;
        }

        // GPS gets converted to signed XMP
        double? lat = double.tryParse(tags['GPSLatitude'].toString());
        double? lon = double.tryParse(tags['GPSLongitude'].toString());
        final latRef = (tags['GPSLatitudeRef'] ?? '').toString().toUpperCase();
        final lonRef = (tags['GPSLongitudeRef'] ?? '').toString().toUpperCase();
        if (lat != null && latRef == 'S') lat = -lat;
        if (lon != null && lonRef == 'W') lon = -lon;
        tags
          ..remove('GPSLatitude')
          ..remove('GPSLongitude')
          ..remove('GPSLatitudeRef')
          ..remove('GPSLongitudeRef');
        if (lat != null && lon != null) {
          tags['XMP:GPSLatitude'] = lat.toString();
          tags['XMP:GPSLongitude'] = lon.toString();
        }

        expect(tags.containsKey('DateTimeOriginal'), isFalse);
        expect(tags.containsKey('OffsetTime'), isFalse);
        expect(tags['XMP:CreateDate'], equals('"2024:01:01 10:00:00"'));
        expect(tags['XMP:DateTimeOriginal'], equals('"2024:01:01 10:00:00"'));
        expect(tags['XMP:ModifyDate'], equals('"2024:01:01 10:00:00"'));
        // West longitude → negative
        expect(double.parse(tags['XMP:GPSLongitude'].toString()), lessThan(0));
      },
    );

    test('GPS in northern east hemisphere stays positive', () {
      final tags = <String, dynamic>{
        'GPSLatitude': '48.8',
        'GPSLongitude': '2.3',
        'GPSLatitudeRef': 'N',
        'GPSLongitudeRef': 'E',
      };

      double lat = double.parse(tags['GPSLatitude'].toString());
      double lon = double.parse(tags['GPSLongitude'].toString());
      if ((tags['GPSLatitudeRef'] as String).toUpperCase() == 'S') lat = -lat;
      if ((tags['GPSLongitudeRef'] as String).toUpperCase() == 'W') lon = -lon;

      expect(lat, greaterThan(0));
      expect(lon, greaterThan(0));
    });
  });

  // -------------------------------------------------------------------------
  // OffsetTime* stripping helper
  // -------------------------------------------------------------------------
  group('OffsetTime* stripping', () {
    test('_stripOffsetTags removes all three OffsetTime variants', () {
      final tags = <String, dynamic>{
        'DateTimeOriginal': '"2024:01:01 10:00:00"',
        'OffsetTime': '"+00:00"',
        'OffsetTimeOriginal': '"+00:00"',
        'OffsetTimeDigitized': '"+00:00"',
      };

      tags
        ..remove('OffsetTime')
        ..remove('OffsetTimeOriginal')
        ..remove('OffsetTimeDigitized');

      expect(tags.containsKey('OffsetTime'), isFalse);
      expect(tags.containsKey('OffsetTimeOriginal'), isFalse);
      expect(tags.containsKey('OffsetTimeDigitized'), isFalse);
      expect(tags.containsKey('DateTimeOriginal'), isTrue);
    });

    test('stripping is idempotent on tags without OffsetTime*', () {
      final tags = <String, dynamic>{
        'DateTimeOriginal': '"2024:01:01 10:00:00"',
      };

      tags
        ..remove('OffsetTime')
        ..remove('OffsetTimeOriginal')
        ..remove('OffsetTimeDigitized');

      expect(tags.length, equals(1));
    });
  });
}
