/// End-to-end tests for Issue #139: GPS coordinates (and DateTime) from an
/// *unrelated* photo must NOT be written to a media file's EXIF.
///
/// These tests drive the full `ProcessingPipeline` (Step 2 discovery →
/// Step 4 date/GPS extraction → Step 7 EXIF writing) with `--write-exif`
/// enabled, then read back the output files' EXIF to verify:
///   - a photo whose *own* sidecar exists gets its own GPS + DateTime, and
///   - a photo whose own sidecar is MISSING does NOT inherit a different
///     photo's GPS or DateTime (the exact symptom from issue #139, where
///     ~34.5% of outputs had the wrong location and a cluster of videos were
///     mis-dated).
///
/// Scenario notes:
/// - The `-edited` cross-photo path is covered by unit + integration tests
///   (test/unit/issue_139_cross_photo_gps_test.dart and
///   test/integration/issue_139_cross_photo_contamination_test.dart) because
///   Step 3 filters `-edited` files out of the pipeline before they could
///   reach EXIF writing, so it cannot be exercised end-to-end.
/// - The e2e scenarios here use cross-extension matching (MP4 ↔ JPG), which
///   is the realistic at-scale culprit: motion-photo / Live-Photo companions
///   are NOT filtered out, so a missing own sidecar would otherwise let them
///   inherit the still photo's GPS/DateTime.
///
/// They complement:
/// - test/unit/issue_139_cross_photo_gps_test.dart        (single-file gate)
/// - test/unit/metadata_matcher_confidence_test.dart      (confidence flag)
/// - test/integration/issue_139_cross_photo_contamination_test.dart (multi-file)
// ignore_for_file: avoid_redundant_argument_values
@Timeout(Duration(seconds: 120))
library;

import 'dart:convert';
import 'dart:io';

import 'package:gpth_neo/gpth_lib_exports.dart';
import 'package:path/path.dart' as path;
import 'package:test/test.dart';

import '../setup/test_setup.dart';

/// Writes a no-EXIF JPEG (so Step 7 writes the JSON-derived date instead of
/// skipping it because a pre-existing EXIF DateTimeOriginal wins) into [dirPath].
File _createImageWithoutExifInDir(final String dirPath, final String name) {
  final dir = Directory(dirPath);
  if (!dir.existsSync()) {
    dir.createSync(recursive: true);
  }
  final file = File(path.join(dirPath, name));
  file.writeAsBytesSync(
    base64.decode(greenImgNoMetaDataBase64.replaceAll('\n', '')),
    flush: true,
  );
  return file;
}

/// Builds a sidecar JSON with the given GPS (lat, lon) and photoTakenTime.
String _sidecarJson({
  required final double lat,
  required final double lon,
  required final String photoTakenTimestamp,
  required final String title,
}) => jsonEncode({
  'title': title,
  'photoTakenTime': {'timestamp': photoTakenTimestamp, 'formatted': 'test'},
  'geoData': {
    'latitude': lat,
    'longitude': lon,
    'altitude': 0.0,
    'latitudeSpan': 0.0,
    'longitudeSpan': 0.0,
  },
  'geoDataExif': {
    'latitude': lat,
    'longitude': lon,
    'altitude': 0.0,
    'latitudeSpan': 0.0,
    'longitudeSpan': 0.0,
  },
});

/// Reads GPS latitude/longitude (as signed decimals) from a file's EXIF via
/// ExifTool. Returns null when the file has no GPS tags.
Future<({double lat, double lon})?> readGpsFromExif(
  final ServiceContainer sc,
  final File file,
) async {
  final exif = await sc.exifTool!.readExifData(file);
  if (!exif.containsKey('GPSLatitude') || !exif.containsKey('GPSLongitude')) {
    return null;
  }
  final lat = (exif['GPSLatitude'] as num).toDouble();
  final lon = (exif['GPSLongitude'] as num).toDouble();
  final latRef = (exif['GPSLatitudeRef'] ?? '').toString().toUpperCase();
  final lonRef = (exif['GPSLongitudeRef'] ?? '').toString().toUpperCase();
  return (
    lat: latRef == 'S' ? -lat.abs() : lat.abs(),
    lon: lonRef == 'W' ? -lon.abs() : lon.abs(),
  );
}

/// Reads DateTimeOriginal from a file's EXIF. Returns null when absent.
Future<String?> readDateTimeFromExif(
  final ServiceContainer sc,
  final File file,
) async {
  final exif = await sc.exifTool!.readExifData(file);
  final v = exif['DateTimeOriginal'] ?? exif['DateTime'];
  return v?.toString();
}

void main() {
  group('E2E Issue #139: no cross-photo GPS/DateTime in output EXIF', () {
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
      await fixture.tearDown();
    });

    tearDownAll(() async {
      await ServiceContainer.instance.dispose();
      await ServiceContainer.reset();
      await cleanupAllFixtures();
    });

    /// Lists all output files in ALL_PHOTOS (recursively).
    Future<List<File>> listOutputFiles() async {
      final allPhotos = Directory(path.join(outputPath, 'ALL_PHOTOS'));
      expect(
        await allPhotos.exists(),
        isTrue,
        reason: 'ALL_PHOTOS output dir should exist',
      );
      final files = <File>[];
      await for (final e in allPhotos.list(recursive: true)) {
        if (e is File) files.add(e);
      }
      return files;
    }

    /// Finds the single output file whose basename equals [basename].
    /// Step 1 may change extensions (e.g. a JPEG-bytes .HEIC → .jpg), so
    /// callers should pass the *expected output* basename; for files whose
    /// extension may change, match by a unique stem suffix instead.
    Future<File> findOutputByName(final String basename) async {
      final files = await listOutputFiles();
      final matches = files
          .where((final f) => path.basename(f.path) == basename)
          .toList();
      expect(
        matches,
        hasLength(1),
        reason:
            'expected exactly one output file named "$basename"; '
            'got: ${files.map((f) => path.basename(f.path)).toList()}',
      );
      return matches.first;
    }

    test(
      'MP4 companion does NOT get the JPG still\'s GPS/DateTime in EXIF',
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

        // Takeout layout: a Live-Photo-style pair in a year folder — a JPG
        // still and an MP4 motion companion sharing the same stem. Only the
        // JPG has a sidecar; the MP4 has none. Without the fix, the MP4
        // would cross-extension-match the JPG's sidecar (strategy 7b) and
        // inherit the JPG's GPS + DateTime.
        final takeoutDir = fixture.createDirectory('Takeout_${uniqueTestId()}');
        final googlePhotosDir = fixture.createDirectory(
          path.join(takeoutDir.path, 'Google Photos'),
        );
        final yearDir = fixture.createDirectory(
          path.join(googlePhotosDir.path, 'Photos from 2023'),
        );

        _createImageWithoutExifInDir(yearDir.path, 'IMG_2367.JPG');
        final mp4 = File(path.join(yearDir.path, 'IMG_2367.MP4'));
        // Minimal ftyp box header so Step 1/7 recognize it as MP4-ish.
        await mp4.writeAsBytes([
          0x00,
          0x00,
          0x00,
          0x20,
          0x66,
          0x74,
          0x79,
          0x70,
        ]);

        // JPG's sidecar: Berlin (52.52, 13.405), 2023-01-01.
        fixture.createFile(
          path.join(yearDir.path, 'IMG_2367.JPG.supplemental-metadata.json'),
          utf8.encode(
            _sidecarJson(
              lat: 52.52,
              lon: 13.405,
              photoTakenTimestamp: '1672531200', // 2023-01-01 00:00:00 UTC
              title: 'IMG_2367.JPG',
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

        // JPG still: own sidecar → GPS + DateTime written.
        final jpgOut = await findOutputByName('IMG_2367.JPG');
        expect(
          path.extension(jpgOut.path).toLowerCase(),
          anyOf(equals('.jpg'), equals('.jpeg')),
          reason: 'the still photo should be a JPEG in the output',
        );
        final jpgGps = await readGpsFromExif(sc, jpgOut);
        expect(
          jpgGps,
          isNotNull,
          reason: 'JPG still (own sidecar) should have GPS written',
        );
        expect(jpgGps!.lat, closeTo(52.52, 0.01));
        expect(jpgGps.lon, closeTo(13.405, 0.01));
        final jpgDt = await readDateTimeFromExif(sc, jpgOut);
        expect(jpgDt, contains('2023:01:01'));

        // MP4 companion: no own sidecar → must NOT inherit Berlin GPS or the
        // JPG's DateTime. (The MP4 may fail to get any EXIF written because
        // it's a dummy byte stream — that's fine; the point is it must NOT
        // carry the JPG's GPS/DateTime.)
        final mp4Out = await findOutputByName('IMG_2367.MP4');
        final mp4Gps = await readGpsFromExif(sc, mp4Out);
        expect(
          mp4Gps,
          isNull,
          reason:
              'MP4 companion must NOT have the JPG still\'s (Berlin) GPS '
              'written — cross-extension match is a different photo',
        );
        final mp4Dt = await readDateTimeFromExif(sc, mp4Out);
        expect(
          mp4Dt,
          isNot(contains('2023:01:01')),
          reason:
              'MP4 companion must NOT inherit the JPG still\'s DateTime '
              '(mis-dated-video symptom from issue #139 comments)',
        );
      },
    );

    test(
      'own sidecar present: GPS + DateTime ARE written (regression guard)',
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

        final takeoutDir = fixture.createDirectory('Takeout_${uniqueTestId()}');
        final googlePhotosDir = fixture.createDirectory(
          path.join(takeoutDir.path, 'Google Photos'),
        );
        final yearDir = fixture.createDirectory(
          path.join(googlePhotosDir.path, 'Photos from 2023'),
        );

        _createImageWithoutExifInDir(yearDir.path, 'mine.jpg');
        fixture.createFile(
          path.join(yearDir.path, 'mine.jpg.supplemental-metadata.json'),
          utf8.encode(
            _sidecarJson(
              lat: 37.7749,
              lon: -122.4194,
              photoTakenTimestamp: '1672531200', // 2023-01-01 00:00:00 UTC
              title: 'mine.jpg',
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

        final out = await findOutputByName('mine.jpg');
        final gps = await readGpsFromExif(sc, out);
        expect(
          gps,
          isNotNull,
          reason: 'photo with own sidecar should have GPS written',
        );
        expect(gps!.lat, closeTo(37.7749, 0.01));
        expect(gps.lon, closeTo(-122.4194, 0.01));
        final dt = await readDateTimeFromExif(sc, out);
        expect(dt, contains('2023:01:01'));
      },
    );
  });
}
