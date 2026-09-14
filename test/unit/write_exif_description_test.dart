/// Tests for writing the Google Photos caption/description (Takeout JSON's
/// `description` field) into `ImageDescription` and `XMP-dc:Description`
/// alongside the existing date/GPS EXIF writing in Step 7.
library;

import 'dart:io';

import 'package:coordinate_converter/coordinate_converter.dart';
import 'package:gpth_neo/gpth_lib_exports.dart';
import 'package:test/test.dart';

import '../setup/test_setup.dart';

/// ExifTool mock that records all tags written per file, without touching a
/// real binary.
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
  group('Description/caption EXIF writing', () {
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

    Future<Map<String, Map<String, dynamic>>> runWithEntity(
      final MediaEntity entity,
    ) async {
      final tracking = _TagCapturingExifToolService();
      final service = WriteExifProcessingService(exifTool: tracking);

      final collection = MediaEntityCollection()..add(entity);

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
      return tracking.writtenTagsByFile;
    }

    test(
      'JPEG with only a description (no date/GPS) still gets written',
      () async {
        final jpgFile = fixture.createImageWithoutExif('caption_only.jpg');
        final fe = FileEntity(
          sourcePath: jpgFile.path,
          targetPath: jpgFile.path,
        );

        final written = await runWithEntity(
          MediaEntity(primaryFile: fe, description: 'A caption with no date'),
        );

        expect(
          written.length,
          equals(1),
          reason:
              'an entity with only a description must not be skipped as '
              '"no metadata to write"',
        );
        final tags = written.values.first;
        expect(tags['ImageDescription'], equals('A caption with no date'));
        expect(tags['XMP-dc:Description'], equals('A caption with no date'));
      },
    );

    test('MP4 video gets both description tags', () async {
      final mp4File = fixture.createFile('video.mp4', [
        0x00, 0x00, 0x00, 0x1C, // box size
        0x66, 0x74, 0x79, 0x70, // 'ftyp'
        0x69, 0x73, 0x6F, 0x6D, // 'isom'
      ]);
      final fe = FileEntity(sourcePath: mp4File.path, targetPath: mp4File.path);

      final written = await runWithEntity(
        MediaEntity(primaryFile: fe, description: 'A video caption'),
      );

      final tags = written.values.first;
      expect(tags['ImageDescription'], equals('A video caption'));
      expect(tags['XMP-dc:Description'], equals('A video caption'));
    });

    test('PNG gets both description tags', () async {
      final pngFile = fixture.createFile('photo.png', [
        0x89, 0x50, 0x4E, 0x47, // PNG magic bytes
      ]);
      final fe = FileEntity(sourcePath: pngFile.path, targetPath: pngFile.path);

      final written = await runWithEntity(
        MediaEntity(primaryFile: fe, description: 'A PNG caption'),
      );

      final tags = written.values.first;
      expect(tags['ImageDescription'], equals('A PNG caption'));
      expect(tags['XMP-dc:Description'], equals('A PNG caption'));
    });

    test(
      'description coexists with date and GPS tags in the same write',
      () async {
        final pngFile = fixture.createFile('photo_full.png', [
          0x89,
          0x50,
          0x4E,
          0x47,
        ]);
        final fe = FileEntity(
          sourcePath: pngFile.path,
          targetPath: pngFile.path,
        );
        final gps = DMSCoordinates.fromDD(
          DDCoordinates(latitude: 35.1168, longitude: 33.9583),
        );

        final written = await runWithEntity(
          MediaEntity(
            primaryFile: fe,
            dateTaken: DateTime.utc(2023, 5, 19, 13, 3, 18),
            dateTimeExtractionMethod: DateTimeExtractionMethod.json,
            gpsCoordinates: gps,
            description: 'Combined write',
          ),
        );

        expect(
          written.length,
          equals(1),
          reason: 'date, GPS, and description must be a single write',
        );
        final tags = written.values.first;
        expect(tags['ImageDescription'], equals('Combined write'));
        expect(tags['XMP-dc:Description'], equals('Combined write'));
        expect(tags, contains('XMP:CreateDate'));
        expect(tags, contains('XMP:GPSLatitude'));
      },
    );

    test('entity with no date, GPS, or description is skipped', () async {
      final jpgFile = fixture.createImageWithoutExif('nothing.jpg');
      final fe = FileEntity(sourcePath: jpgFile.path, targetPath: jpgFile.path);

      final written = await runWithEntity(MediaEntity(primaryFile: fe));

      expect(written, isEmpty);
    });

    test(
      'blank description (defensive Step 7 guard) writes no description tag',
      () async {
        final pngFile = fixture.createFile('blank_caption.png', [
          0x89,
          0x50,
          0x4E,
          0x47,
        ]);
        final fe = FileEntity(
          sourcePath: pngFile.path,
          targetPath: pngFile.path,
        );

        final written = await runWithEntity(
          MediaEntity(
            primaryFile: fe,
            dateTaken: DateTime.utc(2023, 5, 19),
            dateTimeExtractionMethod: DateTimeExtractionMethod.json,
            description: '',
          ),
        );

        final tags = written.values.first;
        expect(tags, isNot(contains('ImageDescription')));
        expect(tags, isNot(contains('XMP-dc:Description')));
      },
    );
  });

  group('MediaEntity description mutators', () {
    test('withDescription returns a copy with the description set', () {
      final entity = MediaEntity.single(
        file: FileEntity(sourcePath: '/tmp/x.jpg'),
      );
      expect(entity.description, isNull);

      final updated = entity.withDescription('Hello');
      expect(updated.description, equals('Hello'));
      // Original is untouched (immutability).
      expect(entity.description, isNull);
    });

    test('mergeWith prefers this entity\'s description, else other\'s', () {
      final withDesc = MediaEntity.single(
        file: FileEntity(sourcePath: '/tmp/a.jpg'),
      ).withDescription('mine');
      final withoutDesc = MediaEntity.single(
        file: FileEntity(sourcePath: '/tmp/b.jpg'),
      );

      expect(withDesc.mergeWith(withoutDesc).description, equals('mine'));
      expect(withoutDesc.mergeWith(withDesc).description, equals('mine'));
    });

    test(
      'toJson/fromJson round trip does not need to preserve description',
      () {
        // Consistent with gpsCoordinates: cheap to re-derive from the JSON
        // sidecar on resume, so it is deliberately left out of the persisted
        // progress-state shape.
        final entity = MediaEntity.single(
          file: FileEntity(sourcePath: '/tmp/c.jpg'),
        ).withDescription('caption');

        final restored = MediaEntity.fromJson(entity.toJson());
        expect(restored.description, isNull);
      },
    );
  });
}
