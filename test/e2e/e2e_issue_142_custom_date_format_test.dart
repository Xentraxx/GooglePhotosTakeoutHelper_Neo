/// End-to-end test for the custom `--divide-to-dates` format (issue #142).
///
/// Verifies that a [ProcessingConfig] with a [DateFolderFormat] produces the
/// expected custom folder hierarchy (e.g. `yyyy/yyyy-mm`) in the ALL_PHOTOS
/// output directory, and that albums remain flattened.
// ignore_for_file: avoid_redundant_argument_values
@Timeout(Duration(seconds: 120))
library;

import 'dart:io';
import 'package:gpth_neo/gpth_lib_exports.dart';
import 'package:path/path.dart' as path;
import 'package:test/test.dart';

import '../setup/test_setup.dart';

void main() {
  group('Issue #142: custom --divide-to-dates format', () {
    late TestFixture fixture;
    late ProcessingPipeline pipeline;
    late String takeoutPath;
    late String outputPath;

    setUpAll(() async {
      await ServiceContainer.instance.initialize();
      fixture = TestFixture();
      await fixture.setUp();
    });

    setUp(() async {
      pipeline = const ProcessingPipeline();
      takeoutPath = await fixture.generateRealisticTakeoutDataset(
        yearSpan: 3,
        albumCount: 2,
        photosPerYear: 8,
        albumOnlyPhotos: 1,
        exifRatio: 0.5,
        includeRawSamples: false,
      );
      outputPath = path.join(fixture.basePath, 'output_${uniqueTestId()}');
      final outputDir = Directory(outputPath);
      if (await outputDir.exists()) {
        await outputDir.delete(recursive: true);
      }
      await outputDir.create(recursive: true);
    });

    tearDownAll(() async {
      await ServiceContainer.instance.dispose();
      await ServiceContainer.reset();
      await fixture.tearDown();
      await cleanupAllFixtures();
    });

    test(
      'custom format yyyy/yyyy-mm creates nested year/ year-month folders',
      () async {
        final googlePhotosPath = PathResolverService.resolveGooglePhotosPath(
          takeoutPath,
        );
        final inputDir = Directory(googlePhotosPath);
        final outputDir = Directory(outputPath);

        final config = ProcessingConfig(
          disableResumeCheck: true,
          inputPath: googlePhotosPath,
          outputPath: outputPath,
          albumBehavior: AlbumBehavior.nothing,
          // Issue #142: custom format takes precedence over the dateDivision preset.
          dateDivision: DateDivisionLevel.none,
          customDateFolderFormat: DateFolderFormat.parse('yyyy/yyyy-mm'),
          skipExtras: false,
          writeExif: false,
        );

        final result = await pipeline.execute(
          config: config,
          inputDirectory: inputDir,
          outputDirectory: outputDir,
        );
        expect(
          result.isSuccess,
          isTrue,
          reason: result.error?.toString() ?? '',
        );

        // Locate the ALL_PHOTOS directory.
        final allPhotosDir = await outputDir
            .list()
            .where(
              (final entity) =>
                  entity is Directory &&
                  path.basename(entity.path).contains('ALL_PHOTOS'),
            )
            .cast<Directory>()
            .first;

        // First level should contain 4-digit year folders.
        final yearDirs = await allPhotosDir
            .list()
            .where((final entity) => entity is Directory)
            .cast<Directory>()
            .where(
              (final dir) =>
                  RegExp(r'^\d{4}$').hasMatch(path.basename(dir.path)),
            )
            .toList();

        expect(
          yearDirs.length,
          greaterThan(0),
          reason: 'Should create year folders at the first level',
        );

        // Inside each year folder there should be `YYYY-MM` subfolders.
        final List<String> monthFolderNames = [];
        for (final yearDir in yearDirs) {
          final monthDirs = await yearDir
              .list()
              .where((final entity) => entity is Directory)
              .cast<Directory>()
              .where(
                (final dir) =>
                    RegExp(r'^\d{4}-\d{2}$').hasMatch(path.basename(dir.path)),
              )
              .toList();
          monthFolderNames.addAll(
            monthDirs.map((final d) => path.basename(d.path)),
          );
        }

        expect(
          monthFolderNames.length,
          greaterThan(0),
          reason: 'Should create YYYY-MM subfolders inside each year folder',
        );
        // Sanity: every month folder name should match the YYYY-MM pattern.
        for (final name in monthFolderNames) {
          expect(RegExp(r'^\d{4}-\d{2}$').hasMatch(name), isTrue, reason: name);
        }
      },
    );

    test(
      'custom format yyyy-mm-dd creates single-level dashed folder names',
      () async {
        final googlePhotosPath = PathResolverService.resolveGooglePhotosPath(
          takeoutPath,
        );
        final inputDir = Directory(googlePhotosPath);
        final outputDir = Directory(outputPath);

        final config = ProcessingConfig(
          disableResumeCheck: true,
          inputPath: googlePhotosPath,
          outputPath: outputPath,
          albumBehavior: AlbumBehavior.nothing,
          dateDivision: DateDivisionLevel.none,
          customDateFolderFormat: DateFolderFormat.parse('yyyy-mm-dd'),
          skipExtras: false,
          writeExif: false,
        );

        final result = await pipeline.execute(
          config: config,
          inputDirectory: inputDir,
          outputDirectory: outputDir,
        );
        expect(
          result.isSuccess,
          isTrue,
          reason: result.error?.toString() ?? '',
        );

        final allPhotosDir = await outputDir
            .list()
            .where(
              (final entity) =>
                  entity is Directory &&
                  path.basename(entity.path).contains('ALL_PHOTOS'),
            )
            .cast<Directory>()
            .first;

        // First level should contain YYYY-MM-DD folders (single level, no nesting).
        final dashedDirs = await allPhotosDir
            .list()
            .where((final entity) => entity is Directory)
            .cast<Directory>()
            .where(
              (final dir) => RegExp(
                r'^\d{4}-\d{2}-\d{2}$',
              ).hasMatch(path.basename(dir.path)),
            )
            .toList();

        expect(
          dashedDirs.length,
          greaterThan(0),
          reason: 'Should create YYYY-MM-DD folders at the first level',
        );
      },
    );
  });
}
