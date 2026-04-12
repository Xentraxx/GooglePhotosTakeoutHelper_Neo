@Timeout(Duration(seconds: 120))
library;

import 'dart:io';

import 'package:gpth_neo/gpth_lib_exports.dart';
import 'package:path/path.dart' as path;
import 'package:test/test.dart';

import '../setup/test_setup.dart';

void main() {
  group('E2E Realistic Edge Case Dataset', () {
    late TestFixture fixture;
    late ProcessingPipeline pipeline;
    late String takeoutPath;
    late String outputPath;
    late RealisticEdgeCaseManifest manifest;

    setUpAll(() async {
      await ServiceContainer.instance.initialize();
      fixture = TestFixture();
      await fixture.setUp();
    });

    setUp(() async {
      pipeline = const ProcessingPipeline();
      final build = await fixture.generateRealisticTakeoutDatasetWithManifest(
        yearSpan: 2,
        albumCount: 3,
        photosPerYear: 6,
        albumOnlyPhotos: 2,
        edgeCaseOptions: const RealisticEdgeCaseOptions(
          includeEmojiFilenames: true,
          includeAppendedCopies: true,
          includeDataSaverVariants: true,
          includeTiffAndRawMismatches: true,
          includeTruncatedSupplementalMetadata: true,
          includeOverlongFilenames: true,
        ),
      );

      takeoutPath = build.takeoutPath;
      manifest = build.manifest;

      outputPath = path.join(fixture.basePath, 'edge_output_${uniqueTestId()}');
      await Directory(outputPath).create(recursive: true);
    });

    tearDownAll(() async {
      await ServiceContainer.instance.dispose();
      await ServiceContainer.reset();
      await fixture.tearDown();
      await cleanupAllFixtures();
    });

    test('processes all injected edge cases with expected outcomes', () async {
      final googlePhotosPath = PathResolverService.resolveGooglePhotosPath(
        takeoutPath,
      );
      final inputDir = Directory(googlePhotosPath);
      final outputDir = Directory(outputPath);

      final config = ProcessingConfig(
        inputPath: googlePhotosPath,
        outputPath: outputPath,
        disableResumeCheck: true,
        albumBehavior: AlbumBehavior.nothing,
        writeExif: false,
      );

      final result = await pipeline.execute(
        config: config,
        inputDirectory: inputDir,
        outputDirectory: outputDir,
      );

      expect(result.isSuccess, isTrue, reason: 'Pipeline should succeed');
      expect(
        manifest.expectations.length,
        equals(8),
        reason: 'All requested realistic edge-case fixtures must be injected',
      );

      final mediaFiles = await outputDir
          .list(recursive: true)
          .whereType<File>()
          .where((f) {
            final name = f.path.toLowerCase();
            return name.endsWith('.jpg') ||
                name.endsWith('.jpeg') ||
                name.endsWith('.png') ||
                name.endsWith('.heic') ||
                name.endsWith('.tif') ||
                name.endsWith('.tiff');
          })
          .map((f) => path.basename(f.path))
          .toList();

      for (final expectation in manifest.expectations) {
        expect(
          mediaFiles.contains(expectation.expectedOutputBasename),
          isTrue,
          reason:
              'Edge case ${expectation.id} should produce ${expectation.expectedOutputBasename}',
        );
      }

      expect(
        mediaFiles.contains('IMG_datasaver_01.HEIC'),
        isFalse,
        reason: 'Data-saver HEIC-named JPEG should be normalized to .jpg',
      );
      expect(
        mediaFiles.contains('IMG_datasaver_02.png'),
        isFalse,
        reason: 'Data-saver PNG-named JPEG should be normalized to .jpg',
      );

      expect(
        mediaFiles.where((name) => name == 'IMG_20241231_235959(1).jpg').length,
        equals(1),
        reason: 'Appended copy (1) should be preserved as distinct media file',
      );
      expect(
        mediaFiles.where((name) => name == 'IMG_20241231_235959(2).jpg').length,
        equals(1),
        reason: 'Appended copy (2) should be preserved as distinct media file',
      );
    });
  });
}
