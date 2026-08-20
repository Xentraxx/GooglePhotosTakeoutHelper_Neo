/// End-to-end test for Issue #138: `.cover` (album cover) and `.mp~<digits>`
/// (edited alternate) files are MP4-container motion photos that must be
/// discovered and transformed like standard `.mp` files.
///
/// Before the fix, neither extension was recognized by `dart:mime` or
/// `MediaExtensions.additional`, so `wherePhotoVideo()` silently dropped them
/// in Step 1 & Step 2. Even if discovered, hardcoded `.mp`/`.mv` checks in
/// Step 1 (skip guard) and Step 6 (transform dispatcher) would not route them
/// through the motion-photo pipeline.
///
/// This test validates the full pipeline path: Step 1 skips them (no rename
/// to .mp4), Step 2 discovers them, and Step 6 transforms them to .mp4 (with
/// `--transform-pixel-mp mp4`) alongside a standard `.mp` control file.
// ignore_for_file: avoid_redundant_argument_values
@Timeout(Duration(seconds: 120))
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:gpth_neo/gpth_lib_exports.dart';
import 'package:path/path.dart' as path;
import 'package:test/test.dart';

import '../setup/test_setup.dart';

/// Minimal MP4 container bytes: a 32-byte box whose 4-byte type at offset 4 is
/// 'ftyp', followed by 'isom' major brand. This is enough for dart:mime's
/// `lookupMimeType` to detect `video/mp4` from header bytes, which is what
/// Step 1's magic-byte detection and Step 2's header-bytes discovery path use.
Uint8List _mp4ContainerBytes() {
  final bytes = Uint8List(32);
  // Box size (offset 0-3): 32 in big-endian
  bytes[0] = 0x00;
  bytes[1] = 0x00;
  bytes[2] = 0x00;
  bytes[3] = 0x20;
  // Box type (offset 4-7): 'ftyp'
  bytes[4] = 0x66; // f
  bytes[5] = 0x74; // t
  bytes[6] = 0x79; // y
  bytes[7] = 0x70; // p
  // 'isom' major brand (offset 8-11)
  bytes[8] = 0x69; // i
  bytes[9] = 0x73; // s
  bytes[10] = 0x6F; // o
  bytes[11] = 0x6D; // m
  return bytes;
}

/// Builds a Google Photos Takeout JSON sidecar with the given photo title and
/// timestamp.
String _photoJson(final String title, final String timestamp) => jsonEncode({
  'title': title,
  'photoTakenTime': {'timestamp': timestamp},
  'geoData': {'latitude': 0.0, 'longitude': 0.0, 'altitude': 0.0},
});

void main() {
  group('E2E Issue #138: .cover and .mp~N recognized as motion photos', () {
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
      '.cover, .mp~2, and .mp are all discovered and transformed to .mp4',
      () async {
        // Build a minimal Takeout structure:
        //   Takeout/Google Photos/Photos from 2023/
        //     IMG_0001.cover      + IMG_0001.cover.json      (issue #138)
        //     IMG_0002.mp~2       + IMG_0002.mp~2.json       (issue #138)
        //     IMG_0003.MP         + IMG_0003.MP.json          (control)
        final takeoutDir = fixture.createDirectory('Takeout_${uniqueTestId()}');
        final googlePhotosDir = fixture.createDirectory(
          path.join(takeoutDir.path, 'Google Photos'),
        );
        final yearDir = fixture.createDirectory(
          path.join(googlePhotosDir.path, 'Photos from 2023'),
        );

        final mp4Bytes = _mp4ContainerBytes();

        // Issue #138 case 1: .cover (album cover image)
        fixture.createFile(path.join(yearDir.path, 'IMG_0001.cover'), mp4Bytes);
        fixture.createFile(
          path.join(yearDir.path, 'IMG_0001.cover.json'),
          utf8.encode(_photoJson('IMG_0001.cover', '1687110000')),
        );

        // Issue #138 case 2: .mp~2 (edited alternate version)
        fixture.createFile(path.join(yearDir.path, 'IMG_0002.mp~2'), mp4Bytes);
        fixture.createFile(
          path.join(yearDir.path, 'IMG_0002.mp~2.json'),
          utf8.encode(_photoJson('IMG_0002.mp~2', '1687196400')),
        );

        // Control: standard .MP file (must still work — no regression)
        fixture.createFile(path.join(yearDir.path, 'IMG_0003.MP'), mp4Bytes);
        fixture.createFile(
          path.join(yearDir.path, 'IMG_0003.MP.json'),
          utf8.encode(_photoJson('IMG_0003.MP', '1687282800')),
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
          // Default extension fixing mode (standard) — this is the mode where
          // the bug manifested, because wherePhotoVideo() dropped the files.
          extensionFixing: ExtensionFixingMode.standard,
          // Transform Pixel motion photos to .mp4 — this routes .cover/.mp~N
          // through Step 6's transform pipeline instead of leaving them as-is.
          transformPixelMp: true,
          pixelMpTransformFormat: PixelMpTransformFormat.mp4,
        );

        final result = await pipeline.execute(
          config: config,
          inputDirectory: Directory(googlePhotosPath),
          outputDirectory: Directory(outputPath),
        );
        expect(result.isSuccess, isTrue);

        final allPhotosDir = Directory(path.join(outputPath, 'ALL_PHOTOS'));
        expect(await allPhotosDir.exists(), isTrue);

        // Collect all output files (non-JSON) in ALL_PHOTOS.
        final outputFiles = await allPhotosDir
            .list()
            .where((final e) => e is File && !e.path.endsWith('.json'))
            .cast<File>()
            .toList();

        // All three motion-photo files must have been transformed to .mp4.
        final outputNames = outputFiles
            .map((final f) => path.basename(f.path))
            .toSet();

        expect(
          outputNames,
          contains('IMG_0001.mp4'),
          reason: '.cover file must be transformed to .mp4 by Step 6',
        );
        expect(
          outputNames,
          contains('IMG_0002.mp4'),
          reason: '.mp~2 file must be transformed to .mp4 by Step 6',
        );
        expect(
          outputNames,
          contains('IMG_0003.mp4'),
          reason: '.MP control file must still be transformed to .mp4',
        );

        // The original .cover / .mp~2 / .MP files must NOT appear in output
        // (they should have been transformed, not copied as-is).
        expect(
          outputNames,
          isNot(contains('IMG_0001.cover')),
          reason: '.cover file must not be copied to output unchanged',
        );
        expect(
          outputNames,
          isNot(contains('IMG_0002.mp~2')),
          reason: '.mp~2 file must not be copied to output unchanged',
        );
        expect(
          outputNames,
          isNot(contains('IMG_0003.MP')),
          reason: '.MP file must not be copied to output unchanged',
        );

        // Exactly three media files in output (no extras, no drops).
        expect(
          outputFiles,
          hasLength(3),
          reason: 'Expected exactly 3 transformed .mp4 files in ALL_PHOTOS',
        );
      },
    );
  });
}
