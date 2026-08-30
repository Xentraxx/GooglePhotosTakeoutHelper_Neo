/// End-to-end test for Issue #145: wrong time after Google Photos re-upload.
///
/// Reproduces the exact scenario from the GitHub issue: a user in GMT+8
/// re-uploads processed photos to Google Photos, which ignores the EXIF
/// `OffsetTime` tag and treats the UTC `photoTakenTime` timestamp as local
/// time, so photos appear 8 hours early.
///
/// This test drives the full `ProcessingPipeline` (Step 2 → Step 7) with
/// `--local-timezone +08:00` configured, using a JPEG with a JSON sidecar
/// whose `photoTakenTime.timestamp` is a known UTC instant:
///   P20260105-205639.jpg → 2026-01-05 12:56:39 UTC (timestamp 1767581800 approx)
///
/// With the fix, the output EXIF `DateTimeOriginal` should be the LOCAL
/// clock (UTC + 8h = 2026-01-05 20:56:39) and `OffsetTime` should be +08:00,
/// so Google Photos shows the correct time. Without `--local-timezone`, the
/// UTC clock (12:56:39) is written and Google Photos would show it 8h early.
// ignore_for_file: avoid_redundant_argument_values, prefer_const_constructors
@Timeout(Duration(seconds: 120))
library;

import 'dart:convert';
import 'dart:io';

import 'package:gpth_neo/gpth_lib_exports.dart';
import 'package:path/path.dart' as path;
import 'package:test/test.dart';

import '../setup/test_setup.dart';

/// Builds a Google Photos sidecar JSON with the given photoTakenTime.
String _sidecarJson({
  required final String photoTakenTimestamp,
  required final String title,
}) => jsonEncode({
  'title': title,
  'description': '',
  'imageViews': '0',
  'creationTime': {'timestamp': photoTakenTimestamp, 'formatted': 'test'},
  'photoTakenTime': {'timestamp': photoTakenTimestamp, 'formatted': 'test'},
  'geoData': {
    'latitude': 0.0,
    'longitude': 0.0,
    'altitude': 0.0,
    'latitudeSpan': 0.0,
    'longitudeSpan': 0.0,
  },
  'geoDataExif': {
    'latitude': 0.0,
    'longitude': 0.0,
    'altitude': 0.0,
    'latitudeSpan': 0.0,
    'longitudeSpan': 0.0,
  },
});

void main() {
  group('E2E Issue #145: local timezone conversion for Google Photos re-upload', () {
    late TestFixture fixture;
    late ProcessingPipeline pipeline;
    late String outputPath;

    setUpAll(() async {
      await ServiceContainer.instance.initialize();
    });

    setUp(() async {
      fixture = TestFixture();
      await fixture.setUp();
      pipeline = const ProcessingPipeline();
      outputPath = path.join(fixture.basePath, 'output_${uniqueTestId()}');
      await Directory(outputPath).create(recursive: true);
    });

    tearDown(() async {
      ServiceContainer.instance.globalConfig.localTimezoneOffset = null;
      await fixture.tearDown();
    });

    tearDownAll(() async {
      await ServiceContainer.instance.dispose();
      await ServiceContainer.reset();
      await cleanupAllFixtures();
    });

    test(
      'with --local-timezone +08:00, EXIF clock is local and OffsetTime is +08:00',
      () async {
        final sc = ServiceContainer.instance;
        final exifTool = await ExifToolService.find();
        expect(
          exifTool,
          isNotNull,
          reason: 'ExifTool must be available for EXIF readback',
        );
        sc.exifTool = exifTool;
        sc.globalConfig.exifToolInstalled = true;
        // Configure the local timezone offset (issue #145).
        sc.globalConfig.localTimezoneOffset = TimezoneOffset(
          Duration(hours: 8),
        );

        // Takeout layout: one JPEG in a "Google Photos" album folder with a
        // sidecar whose photoTakenTime is a UTC instant.
        final takeoutDir = fixture.createDirectory('Takeout_${uniqueTestId()}');
        final googlePhotosDir = fixture.createDirectory(
          path.join(takeoutDir.path, 'Google Photos'),
        );

        // P20260105-205639.jpg → 2026-01-05 12:56:39 UTC
        // (photoTakenTime.timestamp = 1767617799)
        // Local (GMT+8) = 2026-01-05 20:56:39
        const utcTimestamp = '1767617799'; // 2026-01-05 12:56:39 UTC
        final jpg = File(
          path.join(googlePhotosDir.path, 'P20260105-205639.jpg'),
        );
        // Use a JPEG WITHOUT existing EXIF so Step 7 writes the JSON-derived
        // date (Step 7 skips files that already have an EXIF date tag when the
        // date comes from JSON).
        jpg.writeAsBytesSync(
          fixture
              .createImageWithoutExif('P20260105-205639.jpg')
              .readAsBytesSync(),
          flush: true,
        );
        fixture.createFile(
          path.join(
            googlePhotosDir.path,
            'P20260105-205639.jpg.supplemental-metadata.json',
          ),
          utf8.encode(
            _sidecarJson(
              photoTakenTimestamp: utcTimestamp,
              title: 'P20260105-205639.jpg',
            ),
          ),
        );

        final googlePhotosPath = PathResolverService.resolveGooglePhotosPath(
          takeoutDir.path,
        );
        final config = ProcessingConfig(
          disableResumeCheck: true,
          inputPath: googlePhotosPath,
          outputPath: outputPath,
          albumBehavior: AlbumBehavior.nothing,
          dateDivision: DateDivisionLevel.none,
          writeExif: true,
          localTimezoneOffset: TimezoneOffset(Duration(hours: 8)),
        );

        final result = await pipeline.execute(
          config: config,
          inputDirectory: Directory(googlePhotosPath),
          outputDirectory: Directory(outputPath),
        );
        expect(result.isSuccess, isTrue);

        // Locate the output JPEG in ALL_PHOTOS.
        final allPhotos = Directory(path.join(outputPath, 'ALL_PHOTOS'));
        expect(await allPhotos.exists(), isTrue);
        final files = <File>[];
        await for (final e in allPhotos.list(recursive: true)) {
          if (e is File) files.add(e);
        }
        printOnFailure(
          'Output files in ALL_PHOTOS: '
          '${files.map((f) => path.relative(f.path, from: outputPath)).toList()}',
        );
        final jpgOut = files.firstWhere(
          (f) => f.path.toLowerCase().endsWith('.jpg'),
          orElse: () => fail(
            'Output JPEG not found. Files: '
            '${files.map((f) => path.basename(f.path)).toList()}',
          ),
        );

        // Read back the EXIF date + offset tags via real ExifTool.
        final res = await exifTool!.executeExifToolCommand([
          '-DateTimeOriginal',
          '-OffsetTime',
          '-OffsetTimeOriginal',
          '-s',
          '-s',
          '-s',
          jpgOut.path,
        ]);
        // ExifTool -s -s -s prints just the values, one per line, in tag order.
        final lines = res.trim().split('\n');
        printOnFailure('ExifTool readback:\n$res');

        // DateTimeOriginal should be the LOCAL clock (UTC + 8h).
        // 2026-01-05 12:56:39 UTC → 2026-01-05 20:56:39 local.
        expect(
          lines.isNotEmpty,
          isTrue,
          reason: 'ExifTool should return date tags',
        );
        expect(
          lines[0],
          contains('2026:01:05 20:56:39'),
          reason:
              'DateTimeOriginal must be the local clock (UTC + 8h) so Google '
              'Photos shows the correct time (issue #145)',
        );
        // OffsetTime should be +08:00.
        expect(
          lines.length,
          greaterThanOrEqualTo(2),
          reason: 'ExifTool should return OffsetTime tags',
        );
        expect(
          lines[1],
          contains('+08:00'),
          reason: 'OffsetTime must reflect the configured +08:00 offset',
        );
      },
    );

    test(
      'without --local-timezone, EXIF clock is UTC and OffsetTime is +00:00',
      () async {
        final sc = ServiceContainer.instance;
        final exifTool = await ExifToolService.find();
        expect(
          exifTool,
          isNotNull,
          reason: 'ExifTool must be available for EXIF readback',
        );
        sc.exifTool = exifTool;
        sc.globalConfig.exifToolInstalled = true;
        // No local timezone offset configured → default UTC behaviour.

        final takeoutDir = fixture.createDirectory('Takeout_${uniqueTestId()}');
        final googlePhotosDir = fixture.createDirectory(
          path.join(takeoutDir.path, 'Google Photos'),
        );

        const utcTimestamp = '1767617799'; // 2026-01-05 12:56:39 UTC
        final jpg = File(path.join(googlePhotosDir.path, 'photo_utc.jpg'));
        jpg.writeAsBytesSync(
          fixture.createImageWithoutExif('photo_utc.jpg').readAsBytesSync(),
          flush: true,
        );
        fixture.createFile(
          path.join(
            googlePhotosDir.path,
            'photo_utc.jpg.supplemental-metadata.json',
          ),
          utf8.encode(
            _sidecarJson(
              photoTakenTimestamp: utcTimestamp,
              title: 'photo_utc.jpg',
            ),
          ),
        );

        final googlePhotosPath = PathResolverService.resolveGooglePhotosPath(
          takeoutDir.path,
        );
        final config = ProcessingConfig(
          disableResumeCheck: true,
          inputPath: googlePhotosPath,
          outputPath: outputPath,
          albumBehavior: AlbumBehavior.nothing,
          dateDivision: DateDivisionLevel.none,
          writeExif: true,
        );

        final result = await pipeline.execute(
          config: config,
          inputDirectory: Directory(googlePhotosPath),
          outputDirectory: Directory(outputPath),
        );
        expect(result.isSuccess, isTrue);

        final allPhotos = Directory(path.join(outputPath, 'ALL_PHOTOS'));
        expect(await allPhotos.exists(), isTrue);
        final files = <File>[];
        await for (final e in allPhotos.list(recursive: true)) {
          if (e is File) files.add(e);
        }
        final jpgOut = files.firstWhere(
          (f) => f.path.toLowerCase().endsWith('.jpg'),
          orElse: () => fail(
            'Output JPEG not found. Files: '
            '${files.map((f) => path.basename(f.path)).toList()}',
          ),
        );

        final res = await exifTool!.executeExifToolCommand([
          '-DateTimeOriginal',
          '-OffsetTime',
          '-s',
          '-s',
          '-s',
          jpgOut.path,
        ]);
        final lines = res.trim().split('\n');
        printOnFailure('ExifTool readback (no offset):\n$res');

        // Without --local-timezone: UTC clock + OffsetTime=+00:00 (current behaviour).
        expect(
          lines[0],
          contains('2026:01:05 12:56:39'),
          reason:
              'DateTimeOriginal must be the UTC clock when no offset is set',
        );
        expect(
          lines[1],
          contains('+00:00'),
          reason: 'OffsetTime must be +00:00 (UTC) when no offset is set',
        );
      },
    );
  });
}
