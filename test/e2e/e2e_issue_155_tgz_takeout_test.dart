/// End-to-end test for Issue #155: support .tgz / .tar Takeout containers
/// (https://github.com/Xentraxx/GooglePhotosTakeoutHelper_Neo/issues/155).
///
/// Google Takeout lets users download their export as a gzip-compressed tar
/// (.tgz) instead of .zip. Previously GPTH only recognized .zip archives, so
/// a .tgz Takeout had to be extracted manually.
///
/// This test mirrors the CLI flow in bin/gpth.dart: an input folder holding a
/// `takeout.tgz` (fabricated with a fake `Takeout/Google Photos` tree inside)
/// is auto-detected as an archive, extracted via ArchiveExtractionService into
/// a local `.gpth-unzipped` directory, and the full pipeline (Step 2 → Step 7)
/// then processes the extracted structure. The output must match what the
/// same Takeout content yields as a .zip, verifying that the tar/tgz path is
/// transparent to the rest of the pipeline.
// ignore_for_file: avoid_redundant_argument_values
@Timeout(Duration(seconds: 180))
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:gpth_neo/gpth_lib_exports.dart';
import 'package:path/path.dart' as path;
import 'package:test/test.dart';

import '../setup/test_setup.dart';

/// Minimal JPEG (SOI + EOI) so Step 1/2 recognize the file as an image.
/// The payload length varies between the zip and tgz variants so Step 3 does
/// not confuse cross-archive duplicates.
Uint8List _jpegBytes(final int padLength) {
  final builder = BytesBuilder();
  builder.add([0xFF, 0xD8]); // SOI
  builder.add(List<int>.filled(padLength, 0x42));
  builder.add([0xFF, 0xD9]); // EOI
  return builder.toBytes();
}

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

/// Creates a .tgz archive (gzip-compressed tar) with the given entries.
Future<File> _createTgz(
  final Directory dir,
  final String fileName,
  final Map<String, List<int>> files,
) async {
  final archive = Archive();
  for (final entry in files.entries) {
    archive.addFile(ArchiveFile.bytes(entry.key, entry.value));
  }
  final tarBytes = TarEncoder().encode(archive);
  final tgzBytes = gzip.encode(tarBytes);
  final f = File(path.join(dir.path, fileName));
  await f.writeAsBytes(tgzBytes, flush: true);
  return f;
}

/// Creates a .zip archive with the given entries.
Future<File> _createZip(
  final Directory dir,
  final String fileName,
  final Map<String, List<int>> files,
) async {
  final archive = Archive();
  for (final entry in files.entries) {
    archive.addFile(ArchiveFile.bytes(entry.key, entry.value));
  }
  final zipBytes = ZipEncoder().encode(archive);
  final f = File(path.join(dir.path, fileName));
  await f.writeAsBytes(zipBytes, flush: true);
  return f;
}

void main() {
  group('E2E Issue #155: .tgz Takeout containers are supported', () {
    late TestFixture fixture;
    late ProcessingPipeline pipeline;

    setUpAll(() async {
      await ServiceContainer.instance.initialize();
    });

    setUp(() async {
      fixture = TestFixture();
      await fixture.setUp();
      pipeline = const ProcessingPipeline();
    });

    tearDown(() async {
      await fixture.tearDown();
    });

    tearDownAll(() async {
      await ServiceContainer.instance.dispose();
      await ServiceContainer.reset();
      await cleanupAllFixtures();
    });

    test('tgz in input folder is detected, extracted and processed', () async {
      final sc = ServiceContainer.instance;
      final exifTool = await ExifToolService.find();
      sc.exifTool = exifTool;
      sc.globalConfig.exifToolInstalled = exifTool != null;

      final inputDir = fixture.createDirectory('input_${uniqueTestId()}');

      // Fake Takeout exported as .tgz: one photo with its own sidecar
      // carrying a known taken time: 15 Jun 2024 10:00:00 UTC.
      const takenTime = '1718445600';
      await _createTgz(inputDir, 'takeout.tgz', {
        'Takeout/Google Photos/party/P155_photo.jpg': _jpegBytes(64).toList(),
        'Takeout/Google Photos/party/P155_photo.jpg.supplemental-metadata.json':
            utf8.encode(
              _sidecarJson(
                photoTakenTimestamp: takenTime,
                title: 'P155_photo.jpg',
              ),
            ),
      });

      // Mirror the CLI flow (bin/gpth.dart): scan the input dir for archive
      // files, auto-extract into `.gpth-unzipped`, and process what appears.
      final archives = inputDir
          .listSync()
          .whereType<File>()
          .where(ArchiveExtractionService.isSupportedArchive)
          .toList();
      expect(archives, hasLength(1), reason: 'takeout.tgz must be detected');
      expect(
        ArchiveExtractionService.detectArchiveType(archives.single),
        equals(ArchiveType.tgz),
      );

      final extractDir = Directory(path.join(inputDir.path, '.gpth-unzipped'));
      final outputPath = path.join(
        fixture.basePath,
        'output_${uniqueTestId()}',
      );
      await Directory(outputPath).create(recursive: true);

      await ServiceContainer.instance.interactiveService.extractAll(
        archives,
        extractDir,
      );
      final googlePhotosPath = PathResolverService.resolveGooglePhotosPath(
        extractDir.path,
      );

      final result = await pipeline.execute(
        config: ProcessingConfig(
          disableResumeCheck: true,
          inputPath: googlePhotosPath,
          outputPath: outputPath,
          albumBehavior: AlbumBehavior.nothing,
          dateDivision: DateDivisionLevel.year,
          writeExif: exifTool != null,
        ),
        inputDirectory: Directory(googlePhotosPath),
        outputDirectory: Directory(outputPath),
      );
      expect(result.isSuccess, isTrue);

      // The photo must land in ALL_PHOTOS under its sidecar-derived year.
      final allPhotos = Directory(path.join(outputPath, 'ALL_PHOTOS'));
      expect(await allPhotos.exists(), isTrue);
      final files = <File>[];
      await for (final e in allPhotos.list(recursive: true)) {
        if (e is File && path.extension(e.path).toLowerCase() == '.jpg') {
          files.add(e);
        }
      }
      expect(files, hasLength(1), reason: 'the tgz photo must be moved');
      expect(path.basename(files.single.path), equals('P155_photo.jpg'));
      expect(
        files.single.readAsBytesSync(),
        equals(_jpegBytes(64)),
        reason: 'extracted photo content must be intact',
      );

      // The sidecar-derived date (2024) must have been extracted from the
      // tgz-extracted JSON, proving the metadata survived tar+gzip round-trip.
      expect(
        path
            .relative(files.single.path, from: allPhotos.path)
            .replaceAll('\\', '/'),
        equals('2024/P155_photo.jpg'),
        reason:
            'the photo must be dated via its sidecar (year 2024) '
            'extracted from the tgz',
      );
    });

    test(
      'tgz yields the same pipeline outcome as the equivalent zip',
      () async {
        final sc = ServiceContainer.instance;
        final exifTool = await ExifToolService.find();
        sc.exifTool = exifTool;
        sc.globalConfig.exifToolInstalled = exifTool != null;

        const takenTime = '1718445600';
        final content = {
          'Takeout/Google Photos/party/P155_z.jpg': _jpegBytes(96).toList(),
          'Takeout/Google Photos/party/P155_z.jpg.supplemental-metadata.json':
              utf8.encode(
                _sidecarJson(
                  photoTakenTimestamp: takenTime,
                  title: 'P155_z.jpg',
                ),
              ),
        };

        Future<List<String>> runWhitExtension(final String ext) async {
          final inputDir = fixture.createDirectory(
            'input_$ext${uniqueTestId()}',
          );
          final archiveFile = ext == 'tgz'
              ? await _createTgz(inputDir, 'takeout.$ext', content)
              : await _createZip(inputDir, 'takeout.$ext', content);
          expect(
            ArchiveExtractionService.isSupportedArchive(archiveFile),
            isTrue,
          );

          final extractDir = Directory(
            path.join(inputDir.path, '.gpth-unzipped'),
          );
          final outputPath = path.join(
            fixture.basePath,
            'output_$ext${uniqueTestId()}',
          );
          await Directory(outputPath).create(recursive: true);

          final archives = inputDir
              .listSync()
              .whereType<File>()
              .where(ArchiveExtractionService.isSupportedArchive)
              .toList();
          await ServiceContainer.instance.interactiveService.extractAll(
            archives,
            extractDir,
          );
          final googlePhotosPath = PathResolverService.resolveGooglePhotosPath(
            extractDir.path,
          );
          final result = await pipeline.execute(
            config: ProcessingConfig(
              disableResumeCheck: true,
              inputPath: googlePhotosPath,
              outputPath: outputPath,
              albumBehavior: AlbumBehavior.nothing,
              dateDivision: DateDivisionLevel.year,
              writeExif: exifTool != null,
            ),
            inputDirectory: Directory(googlePhotosPath),
            outputDirectory: Directory(outputPath),
          );
          expect(result.isSuccess, isTrue);

          final allPhotos = Directory(path.join(outputPath, 'ALL_PHOTOS'));
          final files = <String>[];
          await for (final e in allPhotos.list(recursive: true)) {
            if (e is File && path.extension(e.path).toLowerCase() == '.jpg') {
              files.add(
                path
                    .relative(e.path, from: allPhotos.path)
                    .replaceAll('\\', '/'),
              );
            }
          }
          return files..sort();
        }

        final zipOutcome = await runWhitExtension('zip');
        final tgzOutcome = await runWhitExtension('tgz');

        expect(
          tgzOutcome,
          equals(zipOutcome),
          reason:
              'identical Takeout content must yield identical output layout, '
              'regardless of the container (.zip vs .tgz)',
        );
        expect(zipOutcome, contains('2024/P155_z.jpg'));
      },
    );
  });
}
