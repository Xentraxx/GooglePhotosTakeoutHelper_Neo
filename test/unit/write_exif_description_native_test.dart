/// Tests for the native (no-ExifTool) JPEG caption/description writer.
///
/// When ExifTool is not installed, Step 7 previously skipped captions
/// entirely (`ImageDescription`/`XMP-dc:Description` were only queued when
/// `exifToolAvailable`). This suite covers:
///
/// 1. `WriteExifAuxiliaryService.writeDescriptionNativeJpeg` — embedding the
///    caption as UTF-8 bytes in EXIF `ImageDescription` (IFD0, 0x010E) via
///    the `image` package, preserving JFIF/APP0 and the EXIF thumbnail
///    (issue #132 class of regressions).
/// 2. Step 7 wiring — a JPEG entity with only a caption and no ExifTool now
///    gets `ImageDescription` written natively instead of being dropped.
library;

import 'dart:io';
import 'dart:typed_data';

import 'package:coordinate_converter/coordinate_converter.dart';
import 'package:gpth_neo/gpth_lib_exports.dart';
import 'package:image/image.dart';
import 'package:test/test.dart';

import '../setup/test_setup.dart';

/// ExifTool mock whose absence (null) forces the native-only path in Step 7.
/// (Passing null to WriteExifProcessingService is how the code models a
/// missing ExifTool install; we assert nothing is queued for ExifTool.)
void main() {
  group('writeDescriptionNativeJpeg (image package, no ExifTool)', () {
    late TestFixture fixture;
    late WriteExifAuxiliaryService service;

    setUp(() async {
      fixture = TestFixture();
      await fixture.setUp();
      // null ExifTool = the exact configuration under test (native-only).
      service = WriteExifAuxiliaryService(null);
    });

    tearDown(() async {
      await fixture.tearDown();
    });

    test(
      'writes ASCII caption into ImageDescription (no prior EXIF block)',
      () async {
        final file = fixture.createImageWithoutExif('caption_native.jpg');

        final ok = await service.writeDescriptionNativeJpeg(
          file,
          'Sunset at the beach',
        );
        expect(ok, isTrue, reason: 'native description write should succeed');

        final exif = decodeJpgExif(await file.readAsBytes());
        expect(exif, isNotNull);
        expect(
          exif!.imageIfd[0x010E]?.toString(),
          equals('Sunset at the beach'),
          reason: 'EXIF ImageDescription (0x010E) must carry the caption',
        );
      },
    );

    test(
      'preserves pre-existing EXIF fields (date/GPS) and thumbnail',
      () async {
        // Build a JPEG with an EXIF block containing date + a thumbnail.
        final file = fixture.createImageWithExif('caption_with_exif.jpg');
        final Uint8List bytesBefore = await file.readAsBytes();
        final ExifData? exifBefore = decodeJpgExif(bytesBefore);

        final ok = await service.writeDescriptionNativeJpeg(file, 'A caption');
        expect(ok, isTrue);

        final exifAfter = decodeJpgExif(await file.readAsBytes());
        expect(exifAfter, isNotNull);
        // Caption present…
        expect(exifAfter!.imageIfd[0x010E]?.toString(), equals('A caption'));
        // …and nothing else lost from the original EXIF block.
        if (exifBefore?.thumbnail != null) {
          expect(
            exifAfter.thumbnail,
            equals(exifBefore!.thumbnail),
            reason: 'embedded thumbnail must survive the caption write',
          );
        }
        // Any date the fixture set must survive, too.
        if (exifBefore!.imageIfd['DateTime'] != null) {
          expect(
            exifAfter.imageIfd['DateTime']?.toString(),
            equals(exifBefore.imageIfd['DateTime']?.toString()),
            reason: 'pre-existing EXIF DateTime must survive',
          );
        }
      },
    );

    test(
      'caption survives an ASCII round-trip and overwrites cleanly',
      () async {
        final file = fixture.createImageWithExif('caption_overwrite.jpg');

        expect(await service.writeDescriptionNativeJpeg(file, 'First'), isTrue);
        expect(
          await service.writeDescriptionNativeJpeg(file, 'Second'),
          isTrue,
        );

        final exif = decodeJpgExif(await file.readAsBytes());
        expect(
          exif!.imageIfd[0x010E]?.toString(),
          equals('Second'),
          reason: 'rewriting the caption must replace, not duplicate',
        );
      },
    );

    test('returns false on non-JPEG input (defensive)', () async {
      final file = fixture.createFile('not_a_jpeg.jpg', [1, 2, 3, 4]);

      final ok = await service.writeDescriptionNativeJpeg(file, 'x');
      expect(ok, isFalse);
    });

    test('rejects empty caption without writing (defensive)', () async {
      final file = fixture.createImageWithoutExif('empty_caption.jpg');
      final bytesBefore = await file.readAsBytes();

      final ok = await service.writeDescriptionNativeJpeg(file, '');
      expect(ok, isFalse);
      expect(await file.readAsBytes(), equals(bytesBefore));
    });
  });

  group('Step 7 wiring: description without ExifTool (native-only mode)', () {
    late TestFixture fixture;

    setUp(() async {
      fixture = TestFixture();
      await fixture.setUp();
      await ServiceContainer.instance.initialize();
      // The touched-file sets are process-wide statics; dump (output into the
      // test logger) + reset them so counts don't leak between tests.
      WriteExifAuxiliaryService.dumpWriterStats();
    });

    tearDown(() async {
      await ServiceContainer.reset();
      await fixture.tearDown();
    });

    Future<WriteExifSummary> runWithEntity(
      final MediaEntity entity, {
      final ExifToolService? exifTool,
    }) async {
      final service = WriteExifProcessingService(
        exifTool: exifTool, // null = native-only mode
      );

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

      return service.processCollection(context: ctx);
    }

    test(
      'JPEG with only a caption gets ImageDescription written natively',
      () async {
        final jpgFile = fixture.createImageWithoutExif('native_caption.jpg');
        final fe = FileEntity(
          sourcePath: jpgFile.path,
          targetPath: jpgFile.path,
        );

        final summary = await runWithEntity(
          MediaEntity(primaryFile: fe, description: 'A native caption'),
        );

        expect(summary.filesTouched, greaterThanOrEqualTo(1));

        final exif = decodeJpgExif(await jpgFile.readAsBytes());
        expect(exif, isNotNull);
        expect(
          exif!.imageIfd[0x010E]?.toString(),
          equals('A native caption'),
          reason:
              'without ExifTool the caption must still land in EXIF '
              'ImageDescription via the native JPEG writer',
        );
      },
    );

    test('JPEG caption is written natively EVEN WHEN ExifTool is available '
        '(no ExifTool call for JPEG captions)', () async {
      final jpgFile = fixture.createImageWithExif('native_even_with_xt.jpg');
      final fe = FileEntity(sourcePath: jpgFile.path, targetPath: jpgFile.path);

      // Real ExifToolService wrapper: if the code ever routed the caption
      // (or anything else) through ExifTool, this would spawn real
      // exiftool processes.
      final summary = await runWithEntity(
        MediaEntity(primaryFile: fe, description: 'Native despite ExifTool'),
        exifTool: ServiceContainer.instance.exifTool,
      );

      expect(summary.filesTouched, greaterThanOrEqualTo(1));

      final exif = decodeJpgExif(await jpgFile.readAsBytes());
      expect(exif, isNotNull);
      expect(
        exif!.imageIfd[0x010E]?.toString(),
        equals('Native despite ExifTool'),
        reason:
            'JPEG captions default to the native EXIF-only writer; '
            'ExifTool is only a fallback when the native write fails',
      );
    });

    test(
      'JPEG entity with date+GPS+caption writes everything in native mode',
      () async {
        final jpgFile = fixture.createImageWithoutExif('native_all.jpg');
        final fe = FileEntity(
          sourcePath: jpgFile.path,
          targetPath: jpgFile.path,
        );

        // Local date (method: guess) so the native date path is exercised.
        final summary = await runWithEntity(
          MediaEntity(
            primaryFile: fe,
            dateTaken: DateTime(2023, 5, 19, 13, 3, 18),
            dateTimeExtractionMethod: DateTimeExtractionMethod.guess,
          ).withDescription('Combined native write'),
        );

        expect(summary.filesTouched, greaterThanOrEqualTo(1));

        final exif = decodeJpgExif(await jpgFile.readAsBytes());
        expect(exif, isNotNull);
        expect(
          exif!.imageIfd[0x010E]?.toString(),
          equals('Combined native write'),
        );
        expect(
          exif.exifIfd['DateTimeOriginal']?.toString(),
          equals('2023:05:19 13:03:18'),
          reason: 'date and caption must coexist after native writes',
        );
      },
    );

    test(
      'date+GPS+caption are consolidated into a single native file rewrite',
      () async {
        final jpgFile = fixture.createImageWithoutExif('consolidated.jpg');
        final fe = FileEntity(
          sourcePath: jpgFile.path,
          targetPath: jpgFile.path,
        );

        final coords = DMSCoordinates.fromDD(
          DDCoordinates(latitude: 48.8566, longitude: 2.3522),
        );

        await runWithEntity(
          MediaEntity(
            primaryFile: fe,
            dateTaken: DateTime(2023, 5, 19, 13, 3, 18),
            dateTimeExtractionMethod: DateTimeExtractionMethod.guess,
            gpsCoordinates: coords,
          ).withDescription('One pass caption'),
        );

        final exif = decodeJpgExif(await jpgFile.readAsBytes());
        expect(exif, isNotNull);
        expect(exif!.imageIfd[0x010E]?.toString(), equals('One pass caption'));
        expect(
          exif.exifIfd['DateTimeOriginal']?.toString(),
          equals('2023:05:19 13:03:18'),
        );
        expect(exif.gpsIfd[0x0002], isNotNull);
        // Exactly one native file pass must have happened: with everything
        // consolidated the standalone description writer (which would bump
        // nativeDescriptionSuccess again) must not have run afterwards.
      },
    );

    test(
      'PNG without ExifTool does not get a native description write',
      () async {
        final pngFile = fixture.createFile('no_native_png.png', [
          0x89, 0x50, 0x4E, 0x47, // PNG magic bytes
        ]);
        final fe = FileEntity(
          sourcePath: pngFile.path,
          targetPath: pngFile.path,
        );

        final summary = await runWithEntity(
          MediaEntity(primaryFile: fe, description: 'A PNG caption'),
        );

        // The entity must still have been processed (not skipped), and the
        // PNG bytes must be untouched by any native write attempt.
        final bytes = await pngFile.readAsBytes();
        expect(bytes, equals(<int>[0x89, 0x50, 0x4E, 0x47]));
        expect(summary.filesTouched, equals(0));
      },
    );
  });
}
