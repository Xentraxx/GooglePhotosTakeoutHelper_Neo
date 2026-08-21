/// End-to-end test for Issue #140: DateTime EXIF data overwritten from a
/// different video.
///
/// This test drives the full `ProcessingPipeline` (Step 2 → Step 7) with
/// `--write-exif` enabled, using the EXACT scenario from the GitHub issue:
/// two .MOV videos in the same "Google Photos" album folder, each with its
/// OWN correct JSON sidecar carrying a distinct date:
///   IMG_5948.MOV → 3 Aug 2026 05:34:21 UTC  (photoTakenTime.timestamp 1785735261)
///   IMG_9304.MOV → 1 Jan 2026 15:47:43 UTC  (photoTakenTime.timestamp 1767282463)
///
/// Step 4 extracts the correct per-entity date for both (confirmed in the
/// issue's progress.json). The bug is in Step 7: the two videos are flushed
/// in a single ExifTool batch, and ExifTool's argv/argfile/stay-open modes
/// ACCUMULATE all -Tag=Value args and apply the FINAL set to EVERY file in
/// the invocation. So IMG_5948.MOV ends up with IMG_9304.MOV's date in its
/// XMP tags (DateTimeOriginal, DateTimeDigitized, ModifyDate), while
/// QuickTime:CreateDate survives (written via a different path).
///
/// This test reads back the XMP date tags from BOTH output files via real
/// ExifTool and asserts each video keeps its OWN date. It is the definitive
/// reproduction: it fails against the buggy batch construction and passes
/// once per-file tags are isolated (via `-execute` separators or separate
/// ExifTool calls).
// ignore_for_file: avoid_redundant_argument_values
@Timeout(Duration(seconds: 120))
library;

import 'dart:convert';
import 'dart:io';

import 'package:gpth_neo/gpth_lib_exports.dart';
import 'package:path/path.dart' as path;
import 'package:test/test.dart';

import '../setup/test_setup.dart';

/// Minimal MOV (QuickTime ftyp box) bytes so Step 1/7 recognize the file as
/// a video and route it through the ExifTool video write path. The trailing
/// payload bytes differ per file so Step 3 (merge duplicates) does NOT treat
/// the two videos as content-identical duplicates (which would drop one).
const List<int> _movBytes1 = [
  0x00, 0x00, 0x00, 0x18, // box size (24)
  0x66, 0x74, 0x79, 0x70, // 'ftyp'
  0x71, 0x74, 0x20, 0x20, // 'qt  ' (QuickTime major brand)
  0x00, 0x00, 0x00, 0x00, // minor version
  0x71, 0x74, 0x20, 0x20, // 'qt  ' (compatible brand)
  0xAA, 0xBB, 0xCC, 0xDD, // unique payload (file 1)
];

const List<int> _movBytes2 = [
  0x00, 0x00, 0x00, 0x18, // box size (24)
  0x66, 0x74, 0x79, 0x70, // 'ftyp'
  0x71, 0x74, 0x20, 0x20, // 'qt  ' (QuickTime major brand)
  0x00, 0x00, 0x00, 0x00, // minor version
  0x71, 0x74, 0x20, 0x20, // 'qt  ' (compatible brand)
  0x11, 0x22, 0x33, 0x44, // unique payload (file 2)
];

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
  group('E2E Issue #140: video batch does not contaminate XMP dates', () {
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

    test('two videos with different dates each keep their own XMP date', () async {
      final sc = ServiceContainer.instance;
      final exifTool = await ExifToolService.find();
      expect(
        exifTool,
        isNotNull,
        reason: 'ExifTool must be available for EXIF readback',
      );
      sc.exifTool = exifTool;
      sc.globalConfig.exifToolInstalled = true;

      // Takeout layout: two .MOV files in a "Google Photos" album folder,
      // each with its own sidecar. This mirrors the issue exactly.
      final takeoutDir = fixture.createDirectory('Takeout_${uniqueTestId()}');
      final googlePhotosDir = fixture.createDirectory(
        path.join(takeoutDir.path, 'Google Photos'),
      );

      // IMG_5948.MOV → 3 Aug 2026 05:34:21 UTC
      // (photoTakenTime.timestamp = 1785735261)
      final mov1 = File(path.join(googlePhotosDir.path, 'IMG_5948.MOV'));
      await mov1.writeAsBytes(_movBytes1, flush: true);
      fixture.createFile(
        path.join(
          googlePhotosDir.path,
          'IMG_5948.MOV.supplemental-metadata.json',
        ),
        utf8.encode(
          _sidecarJson(
            photoTakenTimestamp: '1785735261',
            title: 'IMG_5948.MOV',
          ),
        ),
      );

      // IMG_9304.MOV → 1 Jan 2026 15:47:43 UTC
      // (photoTakenTime.timestamp = 1767282463)
      final mov2 = File(path.join(googlePhotosDir.path, 'IMG_9304.MOV'));
      await mov2.writeAsBytes(_movBytes2, flush: true);
      fixture.createFile(
        path.join(
          googlePhotosDir.path,
          'IMG_9304.MOV.supplemental-metadata.json',
        ),
        utf8.encode(
          _sidecarJson(
            photoTakenTimestamp: '1767282463',
            title: 'IMG_9304.MOV',
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

      // Locate both output videos in ALL_PHOTOS.
      final allPhotos = Directory(path.join(outputPath, 'ALL_PHOTOS'));
      expect(await allPhotos.exists(), isTrue);
      final files = <File>[];
      await for (final e in allPhotos.list(recursive: true)) {
        if (e is File) files.add(e);
      }
      // Debug: list all output files so we can see how Step 1/6 named them.
      printOnFailure(
        'Output files in ALL_PHOTOS: '
        '${files.map((f) => path.relative(f.path, from: outputPath)).toList()}',
      );
      final mov1Out = files.firstWhere(
        (f) => path.basename(f.path) == 'IMG_5948.MOV',
        orElse: () => fail(
          'IMG_5948.MOV not found in output. Files: '
          '${files.map((f) => path.basename(f.path)).toList()}',
        ),
      );
      final mov2Out = files.firstWhere(
        (f) => path.basename(f.path) == 'IMG_9304.MOV',
        orElse: () => fail(
          'IMG_9304.MOV not found in output. Files: '
          '${files.map((f) => path.basename(f.path)).toList()}',
        ),
      );

      // Read back the XMP date tags via real ExifTool. These are the exact
      // tags the issue reports as contaminated.
      Future<Map<String, dynamic>> readAll(final File f) async {
        // Use -time:all -G1 to get group-qualified tag names so we can
        // distinguish XMP-exif:DateTimeOriginal from QuickTime:CreateDate.
        final res = await exifTool!.executeExifToolCommand([
          '-time:all',
          '-G1',
          '-a',
          '-s',
          f.path,
        ]);
        final out = <String, String>{};
        for (final line in res.split('\n')) {
          // Lines look like: "[XMP-exif]      DateTimeOriginal   : 2026:01:01 15:47:43"
          final m = RegExp(
            r'^\[([^\]]+)\]\s+(\S+)\s*:\s*(.*)$',
          ).firstMatch(line.trim());
          if (m != null) {
            out['${m.group(1)}:${m.group(2)}'] = (m.group(3) ?? '').trim();
          }
        }
        return out;
      }

      final tags1 = await readAll(mov1Out);
      final tags2 = await readAll(mov2Out);

      // IMG_5948.MOV must keep its OWN 3 Aug date in XMP tags.
      // (The bug: it gets IMG_9304.MOV's 1 Jan date instead.)
      expect(
        tags1['XMP-exif:DateTimeOriginal'],
        contains('2026:08:03'),
        reason:
            'IMG_5948.MOV XMP:DateTimeOriginal must be its own 3 Aug date, '
            'not the sibling\'s 1 Jan date (issue #140)',
      );
      expect(
        tags1['XMP-exif:DateTimeOriginal'],
        isNot(contains('2026:01:01')),
        reason:
            'IMG_5948.MOV must NOT carry the sibling\'s 1 Jan date in XMP '
            '(this is the exact contamination reported in issue #140)',
      );
      expect(
        tags1['XMP-xmp:ModifyDate'],
        contains('2026:08:03'),
        reason: 'IMG_5948.MOV XMP:ModifyDate must be its own 3 Aug date',
      );

      // IMG_9304.MOV keeps its own 1 Jan date.
      expect(
        tags2['XMP-exif:DateTimeOriginal'],
        contains('2026:01:01'),
        reason: 'IMG_9304.MOV XMP:DateTimeOriginal must be its own 1 Jan date',
      );
      expect(
        tags2['XMP-exif:DateTimeOriginal'],
        isNot(contains('2026:08:03')),
        reason: 'IMG_9304.MOV must NOT carry the sibling\'s 3 Aug date in XMP',
      );
    });
  });
}
