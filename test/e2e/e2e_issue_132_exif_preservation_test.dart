/// End-to-end test for Issue #132: running JPEGs that carry an embedded EXIF
/// thumbnail through the full pipeline (with --write-exif) must not drop the
/// thumbnail or the JFIF header, and must not shrink the file.
///
/// This complements test/unit/issue_132_exif_thumbnail_preservation_test.dart
/// (which exercises WriteExifAuxiliaryService directly) by validating the
/// same guarantee end-to-end: Step 2 discovery -> Step 7 EXIF writing ->
/// Step 8 moving, driven through ProcessingPipeline exactly as a real run
/// would, using the actual JSON sidecar (photoTakenTime/geoData) as the
/// source of the new metadata rather than calling the writer directly.
// ignore_for_file: avoid_redundant_argument_values
@Timeout(Duration(seconds: 120))
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:gpth_neo/gpth_lib_exports.dart';
import 'package:image/image.dart';
import 'package:path/path.dart' as path;
import 'package:test/test.dart';

import '../setup/test_setup.dart';

Uint8List _decodeFixture(final String base64Data) =>
    base64Decode(base64Data.replaceAll('\n', ''));

/// Same fixture shape as the unit test: a JFIF header followed by an EXIF
/// block carrying an embedded preview thumbnail.
Uint8List _jpegWithJfifAndThumbnail() {
  final Uint8List base = _decodeFixture(greenImgNoMetaDataBase64);
  final Uint8List thumbBytes = _decodeFixture(greenImgBase64);

  final ExifData exif = ExifData()
    ..thumbnail = thumbBytes
    ..imageIfd['DateTime'] = '2020:01:01 00:00:00';
  final Uint8List? out = injectJpgExif(base, exif);
  if (out == null) {
    throw StateError('Failed to build fixture JPEG with thumbnail');
  }
  return out;
}

bool _startsWithJfifHeader(final Uint8List jpeg) =>
    jpeg.length > 10 &&
    jpeg[0] == 0xFF &&
    jpeg[1] == 0xD8 &&
    jpeg[2] == 0xFF &&
    jpeg[3] == 0xE0 &&
    jpeg[6] == 0x4A &&
    jpeg[7] == 0x46 &&
    jpeg[8] == 0x49 &&
    jpeg[9] == 0x46;

void main() {
  group('E2E Issue #132: EXIF thumbnail/JFIF survive the full pipeline', () {
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

    test(
      'a JPEG with an embedded thumbnail keeps it after --write-exif',
      () async {
        final takeoutDir = fixture.createDirectory('Takeout_${uniqueTestId()}');
        final googlePhotosDir = fixture.createDirectory(
          path.join(takeoutDir.path, 'Google Photos'),
        );
        final yearDir = fixture.createDirectory(
          path.join(googlePhotosDir.path, 'Photos from 2023'),
        );

        final fixtureBytes = _jpegWithJfifAndThumbnail();
        final originalThumbnail = decodeJpgExif(fixtureBytes)!.thumbnail!;
        final photoFile = fixture.createFile(
          path.join(yearDir.path, 'IMG_0001.jpg'),
          fixtureBytes,
        );
        final originalSize = await photoFile.length();

        // photoTakenTime -> 2023-06-18; geoData -> written as GPS.
        fixture.createFile(
          path.join(yearDir.path, 'IMG_0001.jpg.json'),
          utf8.encode(
            jsonEncode({
              'title': 'IMG_0001.jpg',
              'photoTakenTime': {'timestamp': '1687110000'},
              'geoData': {
                'latitude': 48.8566,
                'longitude': 2.3522,
                'altitude': 0.0,
              },
            }),
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

        final allPhotosDir = Directory(path.join(outputPath, 'ALL_PHOTOS'));
        expect(await allPhotosDir.exists(), isTrue);
        final outputFiles = await allPhotosDir
            .list()
            .where((final e) => e is File && e.path.endsWith('.jpg'))
            .cast<File>()
            .toList();
        expect(
          outputFiles,
          hasLength(1),
          reason: 'Expected exactly one processed JPG in ALL_PHOTOS',
        );

        final outBytes = await outputFiles.first.readAsBytes();

        expect(
          _startsWithJfifHeader(outBytes),
          isTrue,
          reason:
              'JFIF APP0 header must survive the full pipeline (issue #132)',
        );

        final outExif = decodeJpgExif(outBytes);
        expect(outExif, isNotNull);
        expect(
          outExif!.thumbnail,
          isNotNull,
          reason: 'EXIF thumbnail must survive the full pipeline (issue #132)',
        );
        expect(
          outExif.thumbnail,
          equals(originalThumbnail),
          reason: 'thumbnail bytes must round-trip byte-for-byte end-to-end',
        );

        // Direct regression guard for the reported symptom: file shrinking.
        expect(
          outBytes.length,
          greaterThanOrEqualTo(originalSize - 32),
          reason:
              'processed file must not be materially smaller than the original '
              '(original: $originalSize, output: ${outBytes.length})',
        );

        // Confirm the date from the JSON sidecar was actually embedded, so
        // this is validating a real write and not a native-write failure
        // that happened to leave the original bytes untouched.
        expect(
          outExif.exifIfd['DateTimeOriginal']?.toString(),
          equals('2023:06:18 17:40:00'),
        );
      },
    );
  });
}
