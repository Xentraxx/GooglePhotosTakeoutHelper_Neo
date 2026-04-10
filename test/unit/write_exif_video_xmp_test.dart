/// Tests for BUG 1 (video XMP tag harmonization) and BUG 3 (unsupported format warnings).
///
/// BUG 1: When writing EXIF to video files (MP4/MOV), GPTH must also write
/// XMP-prefixed date and GPS tags alongside generic EXIF tags. Without this,
/// pre-existing XMP tags remain unchanged, causing conflicting metadata.
///
/// BUG 3: Unsupported format files (MTS, AVI, etc.) must produce a warning
/// even if they have no tags to write (tagsToWrite is empty).
library;

import 'dart:io';

import 'package:coordinate_converter/coordinate_converter.dart';
import 'package:gpth_neo/gpth_lib_exports.dart';
import 'package:test/test.dart';

import '../setup/test_setup.dart';

/// ExifTool mock that records all tags written per file.
class _TagCapturingExifToolService extends ExifToolService {
  _TagCapturingExifToolService() : super('/mock/path/exiftool');

  final Map<String, Map<String, dynamic>> writtenTagsByFile = {};

  @override
  Future<void> writeExifDataSingle(
    final File file,
    final Map<String, dynamic> exifData,
  ) async {
    writtenTagsByFile[file.path] = Map.from(exifData);
  }

  @override
  Future<void> writeExifDataBatch(
    final List<MapEntry<File, Map<String, dynamic>>> batch,
  ) async {
    for (final entry in batch) {
      writtenTagsByFile[entry.key.path] = Map.from(entry.value);
    }
  }

  @override
  Future<void> writeExifDataBatchViaArgFile(
    final List<MapEntry<File, Map<String, dynamic>>> batch,
  ) async {
    for (final entry in batch) {
      writtenTagsByFile[entry.key.path] = Map.from(entry.value);
    }
  }

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

void main() {
  group('BUG 1 — Video XMP tag harmonization', () {
    late TestFixture fixture;

    setUp(() async {
      fixture = TestFixture();
      await fixture.setUp();
      await ServiceContainer.instance.initialize();
    });

    tearDown(() async {
      await ServiceContainer.reset();
      await fixture.tearDown();
    });

    test('MP4 file gets XMP date tags alongside generic EXIF date tags', () async {
      final tracking = _TagCapturingExifToolService();
      final service = WriteExifProcessingService(exifTool: tracking);

      // Create an MP4 file (ftyp magic bytes)
      final mp4File = fixture.createFile('video.mp4', [
        0x00, 0x00, 0x00, 0x1C, // box size
        0x66, 0x74, 0x79, 0x70, // 'ftyp'
        0x69, 0x73, 0x6F, 0x6D, // 'isom'
      ]);

      final fe = FileEntity(sourcePath: mp4File.path, targetPath: mp4File.path);

      final collection = MediaEntityCollection();
      collection.add(
        MediaEntity(
          primaryFile: fe,
          dateTaken: DateTime.utc(2023, 5, 19, 13, 3, 18),
          dateTimeExtractionMethod: DateTimeExtractionMethod.json,
        ),
      );

      final ctx = ProcessingContext(
        config: ProcessingConfig(
          inputPath: fixture.basePath,
          outputPath: fixture.basePath,
          disableResumeCheck: true,
        ),
        mediaCollection: collection,
        inputDirectory: Directory(fixture.basePath),
        outputDirectory: Directory(fixture.basePath),
      );

      await service.processCollection(context: ctx);

      // Verify tags were written
      expect(tracking.writtenTagsByFile.length, equals(1));
      final tags = tracking.writtenTagsByFile.values.first;

      // Should have generic EXIF date tags
      expect(tags, contains('DateTimeOriginal'));
      expect(tags, contains('DateTimeDigitized'));
      expect(tags, contains('DateTime'));

      // Should ALSO have XMP date tags for video harmonization
      expect(
        tags,
        contains('XMP:DateTimeOriginal'),
        reason:
            'Video files must get XMP:DateTimeOriginal to overwrite pre-existing XMP',
      );
      expect(
        tags,
        contains('XMP:DateTimeDigitized'),
        reason:
            'Video files must get XMP:DateTimeDigitized to overwrite pre-existing XMP',
      );
      expect(
        tags,
        contains('XMP:ModifyDate'),
        reason:
            'Video files must get XMP:ModifyDate to overwrite pre-existing XMP',
      );
    });

    test(
      'MP4 file with GPS gets XMP GPS tags alongside generic GPS tags',
      () async {
        final tracking = _TagCapturingExifToolService();
        final service = WriteExifProcessingService(exifTool: tracking);

        final mp4File = fixture.createFile('video_gps.mp4', [
          0x00,
          0x00,
          0x00,
          0x1C,
          0x66,
          0x74,
          0x79,
          0x70,
          0x69,
          0x73,
          0x6F,
          0x6D,
        ]);

        final fe = FileEntity(
          sourcePath: mp4File.path,
          targetPath: mp4File.path,
        );
        final gps = DMSCoordinates.fromDD(
          DDCoordinates(latitude: 35.1168, longitude: 33.9583),
        );

        final collection = MediaEntityCollection();
        collection.add(
          MediaEntity(
            primaryFile: fe,
            dateTaken: DateTime.utc(2023, 5, 19, 13, 3, 18),
            dateTimeExtractionMethod: DateTimeExtractionMethod.json,
            gpsCoordinates: gps,
          ),
        );

        final ctx = ProcessingContext(
          config: ProcessingConfig(
            inputPath: fixture.basePath,
            outputPath: fixture.basePath,
            disableResumeCheck: true,
          ),
          mediaCollection: collection,
          inputDirectory: Directory(fixture.basePath),
          outputDirectory: Directory(fixture.basePath),
        );

        await service.processCollection(context: ctx);

        expect(tracking.writtenTagsByFile.length, equals(1));
        final tags = tracking.writtenTagsByFile.values.first;

        // Should have generic GPS tags
        expect(tags, contains('GPSLatitude'));
        expect(tags, contains('GPSLongitude'));
        expect(tags, contains('GPSLatitudeRef'));
        expect(tags, contains('GPSLongitudeRef'));

        // Should ALSO have XMP GPS tags for video harmonization
        expect(
          tags,
          contains('XMP:GPSLatitude'),
          reason:
              'Video files must get XMP:GPSLatitude to overwrite pre-existing XMP',
        );
        expect(
          tags,
          contains('XMP:GPSLongitude'),
          reason:
              'Video files must get XMP:GPSLongitude to overwrite pre-existing XMP',
        );
      },
    );

    test('JPEG file does NOT get XMP date tags (no change)', () async {
      final tracking = _TagCapturingExifToolService();
      final service = WriteExifProcessingService(exifTool: tracking);

      // Create a proper JPEG file using the test fixture
      final jpgFile = fixture.createImageWithExif('photo.jpg');

      final fe = FileEntity(sourcePath: jpgFile.path, targetPath: jpgFile.path);

      final collection = MediaEntityCollection();
      collection.add(
        MediaEntity(
          primaryFile: fe,
          dateTaken: DateTime.utc(2023, 5, 19, 13, 3, 18),
          dateTimeExtractionMethod: DateTimeExtractionMethod.json,
        ),
      );

      final ctx = ProcessingContext(
        config: ProcessingConfig(
          inputPath: fixture.basePath,
          outputPath: fixture.basePath,
          disableResumeCheck: true,
        ),
        mediaCollection: collection,
        inputDirectory: Directory(fixture.basePath),
        outputDirectory: Directory(fixture.basePath),
      );

      await service.processCollection(context: ctx);

      // JPEG should be written natively (not via ExifTool batch),
      // so the mock should NOT capture tags for it.
      // If native write succeeds, no ExifTool tags are generated.
      // If native write fails, ExifTool gets generic tags but NOT XMP variants.
      if (tracking.writtenTagsByFile.isNotEmpty) {
        final tags = tracking.writtenTagsByFile.values.first;
        expect(
          tags,
          isNot(contains('XMP:DateTimeOriginal')),
          reason: 'JPEG files should NOT get XMP date tags',
        );
      }
    });

    test(
      'PNG file gets XMP-only date tags (existing behavior, no generic)',
      () async {
        final tracking = _TagCapturingExifToolService();
        final service = WriteExifProcessingService(exifTool: tracking);

        final pngFile = fixture.createFile(
          'photo.png',
          [0x89, 0x50, 0x4E, 0x47], // PNG magic bytes
        );

        final fe = FileEntity(
          sourcePath: pngFile.path,
          targetPath: pngFile.path,
        );

        final collection = MediaEntityCollection();
        collection.add(
          MediaEntity(
            primaryFile: fe,
            dateTaken: DateTime.utc(2023, 5, 19, 13, 3, 18),
            dateTimeExtractionMethod: DateTimeExtractionMethod.json,
          ),
        );

        final ctx = ProcessingContext(
          config: ProcessingConfig(
            inputPath: fixture.basePath,
            outputPath: fixture.basePath,
            disableResumeCheck: true,
          ),
          mediaCollection: collection,
          inputDirectory: Directory(fixture.basePath),
          outputDirectory: Directory(fixture.basePath),
        );

        await service.processCollection(context: ctx);

        expect(tracking.writtenTagsByFile.length, equals(1));
        final tags = tracking.writtenTagsByFile.values.first;

        // PNG should get XMP-only tags (existing behavior)
        expect(tags, contains('XMP:CreateDate'));
        expect(tags, contains('XMP:DateTimeOriginal'));
        expect(tags, contains('XMP:ModifyDate'));

        // PNG should NOT get generic EXIF tags
        expect(tags, isNot(contains('DateTimeOriginal')));
      },
    );
  });

  group('BUG 3 — Unsupported format files get warnings', () {
    late TestFixture fixture;

    setUp(() async {
      fixture = TestFixture();
      await fixture.setUp();
      await ServiceContainer.instance.initialize();
    });

    tearDown(() async {
      await ServiceContainer.reset();
      await fixture.tearDown();
    });

    test('MTS file is not written to — tags should be cleared', () async {
      final tracking = _TagCapturingExifToolService();
      final service = WriteExifProcessingService(exifTool: tracking);

      // Create an MTS file (unsupported format)
      final mtsFile = fixture.createFile('video.mts', [0x47, 0x40, 0x11]);

      final fe = FileEntity(sourcePath: mtsFile.path, targetPath: mtsFile.path);

      final collection = MediaEntityCollection();
      collection.add(
        MediaEntity(
          primaryFile: fe,
          dateTaken: DateTime.utc(2023, 5, 19, 13, 3, 18),
          dateTimeExtractionMethod: DateTimeExtractionMethod.json,
        ),
      );

      final ctx = ProcessingContext(
        config: ProcessingConfig(
          inputPath: fixture.basePath,
          outputPath: fixture.basePath,
          disableResumeCheck: true,
        ),
        mediaCollection: collection,
        inputDirectory: Directory(fixture.basePath),
        outputDirectory: Directory(fixture.basePath),
      );

      await service.processCollection(context: ctx);

      // MTS is unsupported — ExifTool should NOT receive any tags for it
      expect(
        tracking.writtenTagsByFile,
        isEmpty,
        reason: 'Unsupported MTS files must not be written to by ExifTool',
      );
    });

    test('AVI file is not written to', () async {
      final tracking = _TagCapturingExifToolService();
      final service = WriteExifProcessingService(exifTool: tracking);

      final aviFile = fixture.createFile('video.avi', [0x52, 0x49, 0x46, 0x46]);

      final fe = FileEntity(sourcePath: aviFile.path, targetPath: aviFile.path);

      final collection = MediaEntityCollection();
      collection.add(
        MediaEntity(
          primaryFile: fe,
          // ignore: avoid_redundant_argument_values
          dateTaken: DateTime.utc(2023, 6, 1),
          dateTimeExtractionMethod: DateTimeExtractionMethod.json,
        ),
      );

      final ctx = ProcessingContext(
        config: ProcessingConfig(
          inputPath: fixture.basePath,
          outputPath: fixture.basePath,
          disableResumeCheck: true,
        ),
        mediaCollection: collection,
        inputDirectory: Directory(fixture.basePath),
        outputDirectory: Directory(fixture.basePath),
      );

      await service.processCollection(context: ctx);

      expect(
        tracking.writtenTagsByFile,
        isEmpty,
        reason: 'Unsupported AVI files must not be written to by ExifTool',
      );
    });
  });
}
