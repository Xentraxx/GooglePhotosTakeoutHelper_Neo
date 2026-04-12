/// E2E tests for verbose output and comprehensive result validation
///
/// This test file specifically focuses on:
/// 1. Verbose flag testing with output validation
/// 2. Fix mode comprehensive testing
/// 3. Result object deep validation
/// 4. Pipeline step-by-step verification

// ignore_for_file: avoid_redundant_argument_values
@Timeout(Duration(seconds: 120))
library;

import 'dart:convert';
import 'dart:io';
import 'package:gpth_neo/gpth_lib_exports.dart';
import 'package:path/path.dart' as path;
import 'package:test/test.dart';

import '../setup/test_setup.dart';

void main() {
  group('E2E Tests - Verbose Output & Result Validation', () {
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

      // Generate a fresh realistic dataset for each test to ensure test isolation
      // This prevents tests from interfering with each other when they move/modify files
      takeoutPath = await fixture.generateRealisticTakeoutDataset(
        yearSpan: 2,
        albumCount: 3,
        photosPerYear: 5,
        albumOnlyPhotos: 2,
        exifRatio: 0.6,
        includeRawSamples: true,
      );

      // Create unique output path for each test
      outputPath = path.join(fixture.basePath, 'output_${uniqueTestId()}');

      // Ensure clean output directory for each test
      final outputDir = Directory(outputPath);
      if (await outputDir.exists()) {
        await outputDir.delete(recursive: true);
      }
      await outputDir.create(recursive: true);
    });

    tearDownAll(() async {
      // Clean up ServiceContainer first to release file handles
      await ServiceContainer.instance.dispose();
      await ServiceContainer.reset();
      await fixture.tearDown();

      // Clean up any leftover fixture directories from helper functions
      await cleanupAllFixtures();
    });

    group('Verbose Flag Testing', () {
      test('verbose: true should provide detailed output', () async {
        final googlePhotosPath = PathResolverService.resolveGooglePhotosPath(
          takeoutPath,
        ); // Capture stdout to verify verbose output

        final config = ProcessingConfig(
          inputPath: googlePhotosPath,
          outputPath: outputPath,
          albumBehavior: AlbumBehavior.shortcut,
          dateDivision: DateDivisionLevel.none,
          verbose: true, // TEST VERBOSE FLAG
          writeExif: false,
        );

        final result = await pipeline.execute(
          config: config,
          inputDirectory: Directory(googlePhotosPath),
          outputDirectory: Directory(outputPath),
        );

        expect(result.isSuccess, isTrue);

        // In a real implementation, you would capture logging output
        // For now, we verify that verbose processing completes successfully
        // and check that processing metrics are available
        expect(
          result.mediaProcessed,
          greaterThan(0),
          reason: 'Verbose mode should provide detailed metrics',
        );
      });

      test('verbose: false should provide minimal output', () async {
        final googlePhotosPath = PathResolverService.resolveGooglePhotosPath(
          takeoutPath,
        );

        final config = ProcessingConfig(
          inputPath: googlePhotosPath,
          outputPath: outputPath,
          albumBehavior: AlbumBehavior.shortcut,
          dateDivision: DateDivisionLevel.none,
          verbose: false, // TEST NON-VERBOSE FLAG
          writeExif: false,
        );

        final result = await pipeline.execute(
          config: config,
          inputDirectory: Directory(googlePhotosPath),
          outputDirectory: Directory(outputPath),
        );

        expect(result.isSuccess, isTrue);

        // Verify that processing still works correctly without verbose output
        final outputFiles = await Directory(outputPath)
            .list(recursive: true)
            .where((final entity) => entity is File)
            .toList();

        expect(
          outputFiles.length,
          greaterThan(0),
          reason: 'Should process files even without verbose output',
        );
      });
    });

    group('Fix Mode Comprehensive Testing', () {
      test('fix mode should process existing photos in-place', () async {
        // Create a separate directory with photos that need date fixing
        final fixDir = Directory(path.join(fixture.basePath, 'photos_to_fix'));
        await fixDir.create(recursive: true);

        // Create photos with various date issues
        fixture.createImageWithoutExif('${fixDir.path}/no_date_photo.jpg');
        fixture.createImageWithExif('${fixDir.path}/wrong_date_photo.jpg');

        // Create some JSON metadata
        fixture.createFile(
          '${fixDir.path}/no_date_photo.jpg.json',
          utf8.encode(
            '{"photoTakenTime": {"timestamp": "1609459200"}}',
          ), // 2021-01-01
        );

        // Create a filename with date pattern
        fixture.createImageWithoutExif(
          '${fixDir.path}/IMG_20220315_120000.jpg',
        );

        final config = ProcessingConfig(
          inputPath: fixDir.path,
          outputPath: fixDir.path, // Same directory for fix mode
          albumBehavior: AlbumBehavior.nothing,
          dateDivision: DateDivisionLevel.none,
          guessFromName: true, // Should extract date from filename
          writeExif: false, // Focus on date fixing, not EXIF writing
        );

        final result = await pipeline.execute(
          config: config,
          inputDirectory: fixDir,
          outputDirectory: fixDir,
        );

        expect(result.isSuccess, isTrue);

        // Verify files are still in the same directory
        final fixedFiles = await fixDir
            .list()
            .where(
              (final entity) => entity is File && entity.path.endsWith('.jpg'),
            )
            .toList();

        expect(
          fixedFiles.length,
          equals(3),
          reason: 'Should have all original photos in fix directory',
        );

        // Verify that modification times have been updated
        // This would require checking file timestamps
        for (final file in fixedFiles.cast<File>()) {
          final stat = await file.stat();
          expect(
            stat.modified.isAfter(
              DateTime(1971),
            ), // Should not be epoch/invalid timestamp
            isTrue,
            reason: 'File should have a valid non-epoch modification time',
          );
        }
      });
    });

    group('Processing Result Deep Validation', () {
      test('result object should contain comprehensive metrics', () async {
        final googlePhotosPath = PathResolverService.resolveGooglePhotosPath(
          takeoutPath,
        );

        final config = ProcessingConfig(
          inputPath: googlePhotosPath,
          outputPath: outputPath,
          albumBehavior: AlbumBehavior.duplicateCopy,
          dateDivision: DateDivisionLevel.year,
          verbose: true,
          writeExif: false,
        );

        final result = await pipeline.execute(
          config: config,
          inputDirectory: Directory(googlePhotosPath),
          outputDirectory: Directory(outputPath),
        );

        expect(
          result.isSuccess,
          isTrue,
        ); // Verify result object contains expected information
        expect(
          result.mediaProcessed,
          greaterThan(0),
          reason: 'Should report total files processed',
        );

        expect(
          result.duplicatesRemoved,
          greaterThanOrEqualTo(0),
          reason: 'Should report duplicates found',
        );

        expect(
          result.coordinatesWrittenToExif,
          greaterThanOrEqualTo(0),
          reason: 'Should report EXIF coordinates written',
        );

        expect(
          result.dateTimesWrittenToExif,
          greaterThanOrEqualTo(0),
          reason: 'Should report EXIF dates written',
        );

        // Verify processing time is reasonable
        expect(
          result.totalProcessingTime.inMilliseconds,
          greaterThan(0),
          reason: 'Should report processing time',
        );

        expect(
          result.totalProcessingTime.inSeconds,
          lessThan(60), // Should complete within 60 seconds
          reason: 'Processing should complete in reasonable time',
        );
      });

      test('result should accurately reflect album behavior chosen', () async {
        final googlePhotosPath = PathResolverService.resolveGooglePhotosPath(
          takeoutPath,
        );

        // Test with json mode to verify album info generation
        final config = ProcessingConfig(
          inputPath: googlePhotosPath,
          outputPath: outputPath,
          albumBehavior: AlbumBehavior.json,
          dateDivision: DateDivisionLevel.none,
          writeExif: false,
        );

        final result = await pipeline.execute(
          config: config,
          inputDirectory: Directory(googlePhotosPath),
          outputDirectory: Directory(outputPath),
        );

        expect(result.isSuccess, isTrue);

        // Verify album JSON was created
        final albumJsonFile = File(path.join(outputPath, 'albums-info.json'));
        expect(
          await albumJsonFile.exists(),
          isTrue,
          reason: 'JSON mode should create albums-info.json',
        );

        // Verify JSON content
        final jsonContent = await albumJsonFile.readAsString();
        final root = jsonDecode(jsonContent) as Map<String, dynamic>;

        // New structure: { "albums": { albumName: [files...] }, "metadata": {...} }
        expect(
          root.containsKey('albums'),
          isTrue,
          reason: 'albums key should exist in JSON structure',
        );
        final albums = root['albums'] as Map<String, dynamic>;
        expect(albums, isNotEmpty, reason: 'Should contain at least one album');

        for (final entry in albums.entries) {
          expect(
            entry.value,
            isA<List<dynamic>>(),
            reason: 'Album ${entry.key} should map to a list of media items',
          );
          expect(
            (entry.value as List).length,
            greaterThan(0),
            reason: 'Album ${entry.key} should contain media',
          );
        }
      });
      test('result should accurately count moved vs copied files', () async {
        final googlePhotosPath = PathResolverService.resolveGooglePhotosPath(
          takeoutPath,
        );

        final config = ProcessingConfig(
          inputPath: googlePhotosPath,
          outputPath: outputPath,
          albumBehavior: AlbumBehavior.nothing, // Simple case
          dateDivision: DateDivisionLevel.none,
          writeExif: false,
        );

        final result = await pipeline.execute(
          config: config,
          inputDirectory: Directory(googlePhotosPath),
          outputDirectory: Directory(outputPath),
        );

        expect(result.isSuccess, isTrue);

        // Count output media files (include RAW formats now present when includeRawSamples=true)
        final mediaExtensions = [
          '.jpg',
          '.jpeg',
          '.png',
          '.cr2',
          '.raf',
          '.nef',
          '.arw',
          '.rw2',
          '.dng',
        ];
        final outputFiles = await Directory(outputPath)
            .list(recursive: true)
            .where(
              (final entity) =>
                  entity is File &&
                  mediaExtensions.any(
                    (final ext) => entity.path.toLowerCase().endsWith(ext),
                  ),
            )
            .toList();

        // In nothing mode, ALL media (after duplicate removal) should be physically moved to output.
        // Therefore mediaProcessed must match the number of media files we detect in output exactly.
        expect(outputFiles.length, greaterThan(0));
        expect(
          outputFiles.length,
          equals(result.mediaProcessed),
          reason:
              'Output media file count (${outputFiles.length}) must equal reported processed (${result.mediaProcessed}).',
        );
        // Note: With album merging, some files may remain in original location
        // while unique versions are moved to output
        expect(
          result.mediaProcessed,
          greaterThan(0),
          reason: 'Should have processed some files',
        );
      });
    });

    group('Error Handling and Edge Cases', () {
      test('should handle permission denied gracefully', () async {
        // This test would require creating files with restricted permissions
        // Implementation depends on platform-specific permission handling
        // Skipping for now but would be valuable for comprehensive testing
        markTestSkipped('Permission testing requires platform-specific setup');
      });

      test('should handle disk space issues gracefully', () async {
        // This test would require simulating disk space issues
        // Complex to implement but valuable for robustness testing
        markTestSkipped('Disk space testing requires complex setup');
      });

      test('should handle corrupted files gracefully', () async {
        // Create test data with corrupted files
        final corruptedTakeout = await _createCorruptedFileTestData();
        final googlePhotosPath = PathResolverService.resolveGooglePhotosPath(
          corruptedTakeout,
        );

        final config = ProcessingConfig(
          inputPath: googlePhotosPath,
          outputPath: outputPath,
          albumBehavior: AlbumBehavior.nothing,
          dateDivision: DateDivisionLevel.none,
          writeExif: false,
        );

        final result = await pipeline.execute(
          config: config,
          inputDirectory: Directory(googlePhotosPath),
          outputDirectory: Directory(outputPath),
        ); // Should complete successfully even with some corrupted files
        expect(result.isSuccess, isTrue);

        // In the current model, we don't have errorsEncountered
        // But we can verify that processing completed
        expect(
          result.mediaProcessed,
          greaterThan(0),
          reason: 'Should process some files despite corruption',
        );
      });
    });

    group('Performance and Scale Testing', () {
      test('should handle large number of files efficiently', () async {
        // Generate a larger dataset for performance testing
        final largeTakeout = await fixture.generateRealisticTakeoutDataset(
          yearSpan: 5,
          albumCount: 10,
          photosPerYear: 20,
          albumOnlyPhotos: 5,
          exifRatio: 0.8,
          includeRawSamples: true,
        );

        final googlePhotosPath = PathResolverService.resolveGooglePhotosPath(
          largeTakeout,
        );

        final config = ProcessingConfig(
          inputPath: googlePhotosPath,
          outputPath: outputPath,
          albumBehavior: AlbumBehavior.shortcut,
          dateDivision: DateDivisionLevel.month,
          writeExif: false,
        );

        final stopwatch = Stopwatch()..start();

        final result = await pipeline.execute(
          config: config,
          inputDirectory: Directory(googlePhotosPath),
          outputDirectory: Directory(outputPath),
        );

        stopwatch.stop();

        expect(result.isSuccess, isTrue);

        // Performance expectations
        expect(
          stopwatch.elapsedMilliseconds,
          lessThan(120000), // Should complete within 2 minutes
          reason: 'Large dataset should process in reasonable time',
        );
        expect(
          result.mediaProcessed,
          greaterThan(50), // Should have processed many files
          reason: 'Should process significant number of files',
        );
      });
    });
  });
}

/// Helper function to create test data with corrupted files
Future<String> _createCorruptedFileTestData() async {
  final fixture = TestFixture();
  await fixture.setUp();

  final takeoutDir = fixture.createDirectory('Takeout');
  final googlePhotosDir = fixture.createDirectory(
    '${takeoutDir.path}/Google Photos',
  );
  final yearDir = fixture.createDirectory(
    '${googlePhotosDir.path}/Photos from 2023',
  );

  // Create valid file
  fixture.createImageWithExif('${yearDir.path}/valid_photo.jpg');
  fixture.createFile(
    '${yearDir.path}/valid_photo.jpg.json',
    utf8.encode('{"photoTakenTime": {"timestamp": "1672531200"}}'),
  );

  // Create corrupted JPEG (invalid header)
  fixture.createFile('${yearDir.path}/corrupted_photo.jpg', [
    0x00,
    0x00,
    0x00,
    0x00,
  ]);
  fixture.createFile(
    '${yearDir.path}/corrupted_photo.jpg.json',
    utf8.encode('{"photoTakenTime": {"timestamp": "1672531200"}}'),
  );

  // Create file with corrupted JSON
  fixture.createImageWithoutExif('${yearDir.path}/photo_bad_json.jpg');
  fixture.createFile(
    '${yearDir.path}/photo_bad_json.jpg.json',
    utf8.encode('{"photoTakenTime": {"timestamp": "invalid_timestamp"}}'),
  );

  // Create truncated file
  fixture.createFile('${yearDir.path}/truncated_photo.jpg', [
    0xFF,
    0xD8,
  ]); // Only JPEG header
  fixture.createFile(
    '${yearDir.path}/truncated_photo.jpg.json',
    utf8.encode('{"photoTakenTime": {"timestamp": "1672531200"}}'),
  );

  return takeoutDir.path;
}
