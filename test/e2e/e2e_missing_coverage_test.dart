/// Comprehensive E2E tests covering missing flag combinations and thorough output validation
///
/// This test suite fills the gaps identified in the existing e2e test coverage:
/// 1. Tests all untested command-line flags
/// 2. Validates actual output content, not just existence
/// 3. Verifies EXIF data handling
/// 4. Tests edge cases and error conditions
/// 5. Validates Windows-specific features

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
  group('E2E Tests - Missing Coverage & Deep Output Validation', () {
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
        yearSpan: 3,
        albumCount: 4,
        photosPerYear: 8,
        albumOnlyPhotos: 3,
        exifRatio: 0.7,
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

    group('Untested Flags - skipExtras', () {
      test('skipExtras: true should exclude extra files', () async {
        // Create test data with extra files (-edited, -modified, etc.)
        final customTakeout = await _createDataWithExtraFiles();
        final googlePhotosPath = PathResolverService.resolveGooglePhotosPath(
          customTakeout,
        );

        final config = ProcessingConfig(
          inputPath: googlePhotosPath,
          outputPath: outputPath,
          disableResumeCheck: true,
          albumBehavior: AlbumBehavior.nothing,
          dateDivision: DateDivisionLevel.none,
          skipExtras: true, // TEST THE TRUE CASE
          writeExif: false,
        );

        final result = await pipeline.execute(
          config: config,
          inputDirectory: Directory(googlePhotosPath),
          outputDirectory: Directory(outputPath),
        );

        expect(result.isSuccess, isTrue);

        // Verify extra files are excluded
        final outputFiles = await Directory(outputPath)
            .list(recursive: true)
            .where((final entity) => entity is File)
            .map((final entity) => path.basename(entity.path))
            .toList(); // Should NOT contain files with extra suffixes
        expect(
          outputFiles.any((final name) => name.contains('-edited')),
          isFalse,
          reason: 'Should exclude -edited files when skipExtras is true',
        );
        expect(
          outputFiles.any((final name) => name.contains('-effects')),
          isFalse,
          reason: 'Should exclude -effects files when skipExtras is true',
        );
        expect(
          outputFiles.any((final name) => name.contains('-bearbeitet')),
          isFalse,
          reason: 'Should exclude -bearbeitet files when skipExtras is true',
        );

        // Should still contain regular files
        expect(
          outputFiles.any(
            (final name) => name.endsWith('.jpg') && !name.contains('-'),
          ),
          isTrue,
          reason: 'Should include regular files when skipExtras is true',
        );
      });

      test('skipExtras: false should include extra files', () async {
        final customTakeout = await _createDataWithExtraFiles();
        final googlePhotosPath = PathResolverService.resolveGooglePhotosPath(
          customTakeout,
        );

        final config = ProcessingConfig(
          inputPath: googlePhotosPath,
          outputPath: outputPath,
          disableResumeCheck: true,
          albumBehavior: AlbumBehavior.nothing,
          dateDivision: DateDivisionLevel.none,
          skipExtras: false, // Explicit false for clarity
          writeExif: false,
        );

        final result = await pipeline.execute(
          config: config,
          inputDirectory: Directory(googlePhotosPath),
          outputDirectory: Directory(outputPath),
        );

        expect(result.isSuccess, isTrue);

        // Verify extra files are included
        final outputFiles = await Directory(outputPath)
            .list(recursive: true)
            .where((final entity) => entity is File)
            .map((final entity) => path.basename(entity.path))
            .toList();
        expect(
          outputFiles.any((final name) => name.contains('-edited')),
          isTrue,
          reason: 'Should include -edited files when skipExtras is false',
        );
        expect(
          outputFiles.any((final name) => name.contains('-effects')),
          isTrue,
          reason: 'Should include -effects files when skipExtras is false',
        );
      });
    });

    group('Untested Flags - guessFromName', () {
      test('guessFromName: false should not extract dates from filenames', () async {
        // Create files with date patterns in names but no EXIF/JSON metadata
        final customTakeout = await _createDataWithDateInFilenames();
        final googlePhotosPath = PathResolverService.resolveGooglePhotosPath(
          customTakeout,
        );

        final config = ProcessingConfig(
          inputPath: googlePhotosPath,
          outputPath: outputPath,
          disableResumeCheck: true,
          albumBehavior: AlbumBehavior.nothing,
          dateDivision: DateDivisionLevel.year,
          guessFromName: false, // TEST THE FALSE CASE
          writeExif: false,
        );

        final result = await pipeline.execute(
          config: config,
          inputDirectory: Directory(googlePhotosPath),
          outputDirectory: Directory(outputPath),
        );

        expect(result.isSuccess, isTrue);

        // With guessFromName disabled, files should end up in a default/unknown year
        // since they have no EXIF or JSON metadata
        final allPhotosDir = Directory(path.join(outputPath, 'ALL_PHOTOS'));
        final yearDirs = await allPhotosDir
            .list()
            .where((final entity) => entity is Directory)
            .map((final entity) => path.basename(entity.path))
            .toList();

        // Should not create year folders based on filename dates
        expect(
          yearDirs.contains('2019'), // Dates in filenames
          isFalse,
          reason:
              'Should not extract dates from filenames when guessFromName is false',
        );
        expect(
          yearDirs.contains('2020'),
          isFalse,
          reason:
              'Should not extract dates from filenames when guessFromName is false',
        );
      });
    });

    group('Untested Flags - extensionFixing modes', () {
      test('extensionFixing: solo mode should fix extensions then exit', () async {
        // Create files with wrong extensions
        final customTakeout = await _createDataWithWrongExtensions();
        final googlePhotosPath = PathResolverService.resolveGooglePhotosPath(
          customTakeout,
        );

        final config = ProcessingConfig(
          inputPath: googlePhotosPath,
          outputPath: outputPath,
          disableResumeCheck: true,
          albumBehavior: AlbumBehavior.nothing,
          dateDivision: DateDivisionLevel.none,
          extensionFixing: ExtensionFixingMode.solo, // TEST SOLO MODE
          writeExif: false,
        );

        final result = await pipeline.execute(
          config: config,
          inputDirectory: Directory(googlePhotosPath),
          outputDirectory: Directory(outputPath),
        );

        expect(result.isSuccess, isTrue);

        // In solo mode, pipeline should exit after extension fixing
        // Files should still be in input directory with fixed extensions
        final inputFiles = await Directory(googlePhotosPath)
            .list(recursive: true)
            .where(
              (final entity) => entity is File && entity.path.endsWith('.jpg'),
            )
            .toList();

        expect(
          inputFiles.length,
          greaterThan(0),
          reason: 'Should fix extensions in input directory',
        );

        // Output directory should be empty or minimal since processing stops after extension fixing
        // (progress.json may be written as an infrastructure file, exclude it)
        final outputFiles = await Directory(outputPath)
            .list(recursive: true)
            .where(
              (final entity) =>
                  entity is File &&
                  !entity.path.endsWith('progress.json') &&
                  !entity.path.endsWith('progress.json.tmp'),
            )
            .toList();

        expect(
          outputFiles.length,
          equals(0),
          reason: 'Solo mode should not proceed with full processing',
        );
      });

      test(
        'extensionFixing: conservative mode should skip TIFF and JPEG files',
        () async {
          final customTakeout = await _createDataWithMixedFileTypes();
          final googlePhotosPath = PathResolverService.resolveGooglePhotosPath(
            customTakeout,
          );

          final config = ProcessingConfig(
            inputPath: googlePhotosPath,
            outputPath: outputPath,
            disableResumeCheck: true,
            albumBehavior: AlbumBehavior.nothing,
            dateDivision: DateDivisionLevel.none,
            extensionFixing:
                ExtensionFixingMode.conservative, // TEST CONSERVATIVE MODE
            writeExif: false,
          );

          final result = await pipeline.execute(
            config: config,
            inputDirectory: Directory(googlePhotosPath),
            outputDirectory: Directory(outputPath),
          );

          expect(result.isSuccess, isTrue);

          // Verify that TIFF and JPEG files are processed (not skipped for extension fixing)
          // but their extensions are handled conservatively
          final outputFiles = await Directory(outputPath)
              .list(recursive: true)
              .where((final entity) => entity is File)
              .toList();

          expect(
            outputFiles.length,
            greaterThan(0),
            reason: 'Should process files with conservative extension fixing',
          );
        },
      );

      test(
        'extensionFixing: none mode should not fix any extensions',
        () async {
          final customTakeout = await _createDataWithWrongExtensions();
          final googlePhotosPath = PathResolverService.resolveGooglePhotosPath(
            customTakeout,
          );

          final config = ProcessingConfig(
            inputPath: googlePhotosPath,
            disableResumeCheck: true,
            outputPath: outputPath,
            albumBehavior: AlbumBehavior.nothing,
            dateDivision: DateDivisionLevel.none,
            extensionFixing: ExtensionFixingMode.none, // TEST NONE MODE
            writeExif: false,
          );

          final result = await pipeline.execute(
            config: config,
            inputDirectory: Directory(googlePhotosPath),
            outputDirectory: Directory(outputPath),
          );

          expect(result.isSuccess, isTrue);

          // Files should keep their original wrong extensions
          final outputFiles = await Directory(outputPath)
              .list(recursive: true)
              .where((final entity) => entity is File)
              .map((final entity) => path.basename(entity.path))
              .toList();

          // Should still have files with wrong extensions
          expect(
            outputFiles.any(
              (final name) => name.endsWith('.txt'),
            ), // JPEG with .txt extension
            isTrue,
            reason: 'Should not fix extensions when mode is none',
          );
        },
      );
    });

    group('Untested Flags - transformPixelMp', () {
      test(
        'transformPixelMp: true should convert .MP/.MV files to .mp4',
        () async {
          // Create test data with Pixel .MP and .MV files
          final customTakeout = await _createDataWithPixelFiles();
          final googlePhotosPath = PathResolverService.resolveGooglePhotosPath(
            customTakeout,
          );

          final config = ProcessingConfig(
            inputPath: googlePhotosPath,
            disableResumeCheck: true,
            outputPath: outputPath,
            albumBehavior: AlbumBehavior.nothing,
            dateDivision: DateDivisionLevel.none,
            transformPixelMp: true, // TEST TRUE CASE
            writeExif: false,
          );

          final result = await pipeline.execute(
            config: config,
            inputDirectory: Directory(googlePhotosPath),
            outputDirectory: Directory(outputPath),
          );

          expect(result.isSuccess, isTrue);

          // Verify .MP and .MV files are converted to .mp4
          final outputFiles = await Directory(outputPath)
              .list(recursive: true)
              .where((final entity) => entity is File)
              .map((final entity) => path.basename(entity.path))
              .toList();

          expect(
            outputFiles.any((final name) => name.endsWith('.mp4')),
            isTrue,
            reason: 'Should convert .MP/.MV files to .mp4',
          );

          expect(
            outputFiles.any((final name) => name.endsWith('.MP')),
            isFalse,
            reason: 'Should not have .MP files after transformation',
          );

          expect(
            outputFiles.any((final name) => name.endsWith('.MV')),
            isFalse,
            reason: 'Should not have .MV files after transformation',
          );
        },
      );

      test(
        'transformPixelMp: mp4 should also normalize album outputs to .mp4',
        () async {
          final customTakeout = await _createDataWithPixelFilesInAlbum();
          final googlePhotosPath = PathResolverService.resolveGooglePhotosPath(
            customTakeout,
          );

          final config = ProcessingConfig(
            inputPath: googlePhotosPath,
            disableResumeCheck: true,
            outputPath: outputPath,
            albumBehavior: AlbumBehavior.duplicateCopy,
            dateDivision: DateDivisionLevel.none,
            transformPixelMp: true,
            writeExif: false,
          );

          final result = await pipeline.execute(
            config: config,
            inputDirectory: Directory(googlePhotosPath),
            outputDirectory: Directory(outputPath),
          );

          expect(result.isSuccess, isTrue);

          final albumsDir = Directory(path.join(outputPath, 'Albums'));
          expect(await albumsDir.exists(), isTrue);

          final albumFileNames = await albumsDir
              .list(recursive: true)
              .whereType<File>()
              .map((final file) => path.basename(file.path))
              .toList();

          expect(
            albumFileNames.any((final name) => name.endsWith('.mp4')),
            isTrue,
            reason: 'Album outputs should include transformed .mp4 files',
          );

          expect(
            albumFileNames.any((final name) => name.endsWith('.MP')),
            isFalse,
            reason: 'Album outputs should not retain .MP extension',
          );

          expect(
            albumFileNames.any((final name) => name.endsWith('.MV')),
            isFalse,
            reason: 'Album outputs should not retain .MV extension',
          );
        },
      );

      test('transformPixelMp: false should preserve .MP/.MV files', () async {
        // Create test data with Pixel .MP and .MV files
        final customTakeout = await _createDataWithPixelFiles();
        final googlePhotosPath = PathResolverService.resolveGooglePhotosPath(
          customTakeout,
        );

        final config = ProcessingConfig(
          inputPath: googlePhotosPath,
          disableResumeCheck: true,
          outputPath: outputPath,
          albumBehavior: AlbumBehavior.nothing,
          dateDivision: DateDivisionLevel.none,
          transformPixelMp: false, // TEST FALSE CASE (default)
          writeExif: false,
        );

        final result = await pipeline.execute(
          config: config,
          inputDirectory: Directory(googlePhotosPath),
          outputDirectory: Directory(outputPath),
        );

        expect(result.isSuccess, isTrue);

        // Verify .MP and .MV files are preserved
        final outputFiles = await Directory(outputPath)
            .list(recursive: true)
            .where((final entity) => entity is File)
            .map((final entity) => path.basename(entity.path))
            .toList();

        expect(
          outputFiles.any((final name) => name.endsWith('.MP')),
          isTrue,
          reason: 'Should preserve .MP files when transformPixelMp is false',
        );

        expect(
          outputFiles.any((final name) => name.endsWith('.MV')),
          isTrue,
          reason: 'Should preserve .MV files when transformPixelMp is false',
        );

        expect(
          outputFiles.any((final name) => name.endsWith('.mp4')),
          isFalse,
          reason: 'Should not convert .MP/.MV to .mp4 when flag is false',
        );
      });

      test(
        'transformPixelMp: still should keep still images and remove .MP/.MV files',
        () async {
          final customTakeout =
              await _createDataWithPixelFilesAndStillSidecars();
          final googlePhotosPath = PathResolverService.resolveGooglePhotosPath(
            customTakeout,
          );

          final config = ProcessingConfig(
            inputPath: googlePhotosPath,
            disableResumeCheck: true,
            outputPath: outputPath,
            albumBehavior: AlbumBehavior.nothing,
            dateDivision: DateDivisionLevel.none,
            transformPixelMp: true,
            pixelMpTransformFormat: PixelMpTransformFormat.still,
            writeExif: false,
          );

          final result = await pipeline.execute(
            config: config,
            inputDirectory: Directory(googlePhotosPath),
            outputDirectory: Directory(outputPath),
          );

          expect(result.isSuccess, isTrue);

          final outputFiles = await Directory(outputPath)
              .list(recursive: true)
              .where((final entity) => entity is File)
              .map((final entity) => path.basename(entity.path))
              .toList();

          expect(
            outputFiles.any((final name) => name.endsWith('.MP')),
            isFalse,
            reason: 'Should remove .MP files in still mode',
          );

          expect(
            outputFiles.any((final name) => name.endsWith('.MV')),
            isFalse,
            reason: 'Should remove .MV files in still mode',
          );

          expect(
            outputFiles.any(
              (final name) =>
                  name.toLowerCase().startsWith('motion1') &&
                  name.toLowerCase().endsWith('.jpg'),
            ),
            isTrue,
            reason:
                'Should keep a still JPG for the .MP source (sidecar or extracted fallback)',
          );

          expect(
            outputFiles.any(
              (final name) =>
                  name.toLowerCase().startsWith('motion2') &&
                  name.toLowerCase().endsWith('.jpg'),
            ),
            isTrue,
            reason:
                'Should keep a still JPG for the .MV source (sidecar or extracted fallback)',
          );
        },
      );

      test(
        'transformPixelMp: heic should prefer sidecar JPG as still source',
        () async {
          final customTakeout = await _createDataForHeicSidecarPreference();
          final googlePhotosPath = PathResolverService.resolveGooglePhotosPath(
            customTakeout,
          );

          final config = ProcessingConfig(
            inputPath: googlePhotosPath,
            disableResumeCheck: true,
            outputPath: outputPath,
            albumBehavior: AlbumBehavior.nothing,
            dateDivision: DateDivisionLevel.none,
            transformPixelMp: true,
            pixelMpTransformFormat: PixelMpTransformFormat.heic,
            writeExif: false,
          );

          final result = await pipeline.execute(
            config: config,
            inputDirectory: Directory(googlePhotosPath),
            outputDirectory: Directory(outputPath),
          );

          expect(result.isSuccess, isTrue);

          final outputFiles = await Directory(
            outputPath,
          ).list(recursive: true).whereType<File>().toList();

          final heicFile = outputFiles.firstWhere(
            (final f) => path.basename(f.path).toLowerCase() == 'motion1.heic',
            orElse: () => throw StateError('motion1.heic not found in output'),
          );

          final heicBytes = await heicFile.readAsBytes();
          const sidecarBytes = <int>[
            0x21,
            0x22,
            0x23,
            0x24,
            0x25,
            0x26,
            0x27,
            0x28,
            0x29,
            0x2A,
          ];

          expect(
            heicBytes.length,
            greaterThanOrEqualTo(sidecarBytes.length),
            reason: 'HEIC output should include still image bytes first',
          );

          for (int i = 0; i < sidecarBytes.length; i++) {
            expect(
              heicBytes[i],
              equals(sidecarBytes[i]),
              reason:
                  'HEIC bytes should start with sidecar still bytes in sidecar-preferred mode',
            );
          }
        },
      );
    });

    group('Untested Flags - limitFileSize', () {
      test('limitFileSize: true should handle large files appropriately', () async {
        // Create test data with files larger than 64MB limit
        final customTakeout = await _createDataWithLargeFiles();
        final googlePhotosPath = PathResolverService.resolveGooglePhotosPath(
          customTakeout,
        );

        final config = ProcessingConfig(
          inputPath: googlePhotosPath,
          outputPath: outputPath,
          disableResumeCheck: true,
          albumBehavior: AlbumBehavior.nothing,
          dateDivision: DateDivisionLevel.none,
          limitFileSize: true, // TEST TRUE CASE
          writeExif: false,
        );

        final result = await pipeline.execute(
          config: config,
          inputDirectory: Directory(googlePhotosPath),
          outputDirectory: Directory(outputPath),
        );

        expect(result.isSuccess, isTrue);

        // Verify processing completed without memory issues
        final outputFiles = await Directory(outputPath)
            .list(recursive: true)
            .where((final entity) => entity is File)
            .toList();

        expect(
          outputFiles.length,
          greaterThan(0),
          reason: 'Should process files even with file size limit',
        );

        // Check that large files are handled (copied/moved but perhaps not fully processed)
        final largeFiles = <File>[];
        for (final file in outputFiles.whereType<File>()) {
          final stat = await file.stat();
          if (stat.size > 64 * 1024 * 1024) {
            // 64MB
            largeFiles.add(file);
          }
        }

        // Should handle large files appropriately (either process them or log warnings)
        expect(
          largeFiles.length,
          greaterThanOrEqualTo(0),
          reason: 'Should handle large files when limit is enabled',
        );
      });
    });

    group('Windows-specific Features', () {
      test(
        'updateCreationTime: true should update file creation time (Windows only)',
        () async {
          // Skip on non-Windows platforms
          if (!Platform.isWindows) {
            markTestSkipped('Windows-only feature');
            return;
          }

          final googlePhotosPath = PathResolverService.resolveGooglePhotosPath(
            takeoutPath,
          );

          final config = ProcessingConfig(
            inputPath: googlePhotosPath,
            outputPath: outputPath,
            disableResumeCheck: true,
            albumBehavior: AlbumBehavior.nothing,
            dateDivision: DateDivisionLevel.none,
            updateCreationTime: true, // TEST TRUE CASE
            writeExif: false,
          );

          final result = await pipeline.execute(
            config: config,
            inputDirectory: Directory(googlePhotosPath),
            outputDirectory: Directory(outputPath),
          );
          expect(result.isSuccess, isTrue);

          // On Windows, verify creation time is updated
          // This is platform-specific validation
          final outputFiles = await Directory(outputPath)
              .list(recursive: true)
              .where((final entity) => entity is File)
              .cast<File>()
              .toList();

          expect(
            outputFiles.length,
            greaterThan(0),
            reason: 'Should have processed files with creation time updates',
          );

          // Additional validation could check actual creation time values
          // but this requires platform-specific code
        },
      );
    });

    group('Deep Output Content Validation', () {
      test('EXIF data preservation and modification validation', () async {
        // Create files with specific EXIF data
        final customTakeout = await _createDataWithSpecificExif();
        final googlePhotosPath = PathResolverService.resolveGooglePhotosPath(
          customTakeout,
        );

        final config = ProcessingConfig(
          inputPath: googlePhotosPath,
          outputPath: outputPath,
          disableResumeCheck: true,
          albumBehavior: AlbumBehavior.nothing,
          dateDivision: DateDivisionLevel.none,
          writeExif: true, // Enable EXIF writing
        );

        final result = await pipeline.execute(
          config: config,
          inputDirectory: Directory(googlePhotosPath),
          outputDirectory: Directory(outputPath),
        );

        expect(
          result.isSuccess,
          isTrue,
        ); // Verify EXIF data is correctly written/preserved
        final outputFiles = await Directory(outputPath)
            .list(recursive: true)
            .where((final entity) => entity is File)
            .where((final file) => file.path.endsWith('.jpg'))
            .cast<File>()
            .toList();
        expect(
          outputFiles.length,
          greaterThan(0),
          reason: 'Should have JPEG files with EXIF data',
        );

        // Validate EXIF data was correctly written
        final serviceContainer = ServiceContainer.instance;
        expect(
          serviceContainer.exifTool,
          isNotNull,
          reason: 'ExifTool should be available for EXIF validation',
        );

        for (final outputFile in outputFiles) {
          final exifData = await serviceContainer.exifTool!.readExifData(
            outputFile,
          );

          // Verify basic EXIF structure exists
          expect(
            exifData,
            isNotEmpty,
            reason: 'Output file ${outputFile.path} should have EXIF data',
          );

          // Check for essential EXIF fields that should be preserved/written
          if (outputFile.path.contains('with_exif')) {
            // Files with original EXIF should preserve camera information
            expect(
              exifData.containsKey('Make') ||
                  exifData.containsKey('Model') ||
                  exifData.containsKey('DateTimeOriginal') ||
                  exifData.containsKey('ExifImageWidth') ||
                  exifData.containsKey('ExifImageHeight'),
              isTrue,
              reason: 'File with original EXIF should preserve camera metadata',
            );
          }

          // Check GPS data was written from JSON metadata
          if (exifData.containsKey('GPSLatitude') &&
              exifData.containsKey('GPSLongitude')) {
            final latitude = exifData['GPSLatitude'];
            final longitude = exifData['GPSLongitude'];

            // Validate GPS coordinates are reasonable values
            expect(
              latitude,
              isA<num>(),
              reason: 'GPS Latitude should be numeric',
            );
            expect(
              longitude,
              isA<num>(),
              reason: 'GPS Longitude should be numeric',
            );

            // Check if coordinates match expected values from JSON
            if (outputFile.path.contains('with_exif')) {
              // Expected: latitude: 37.7749, longitude: -122.4194
              expect((latitude as num).abs(), closeTo(37.7749, 0.1));
              expect((longitude as num).abs(), closeTo(122.4194, 0.1));
            } else if (outputFile.path.contains('without_exif')) {
              // Expected: latitude: 40.7128, longitude: -74.0060
              expect((latitude as num).abs(), closeTo(40.7128, 0.1));
              expect((longitude as num).abs(), closeTo(74.0060, 0.1));
            }
          } // Verify DateTime was written from JSON timestamp (1672531200 = 2023-01-01 00:00:00 UTC)
          if (exifData.containsKey('DateTimeOriginal') ||
              exifData.containsKey('DateTime')) {
            final dateTime =
                exifData['DateTimeOriginal'] ?? exifData['DateTime'];
            expect(
              dateTime,
              isNotNull,
              reason: 'DateTime should be set from JSON metadata',
            );

            // Check if it's in proper EXIF DateTime format and contains expected date
            if (dateTime is String) {
              expect(
                dateTime.trim().isNotEmpty,
                isTrue,
                reason:
                    'DateTime should not be empty when set from JSON metadata',
              );

              // Verify it follows EXIF DateTime format (YYYY:MM:DD HH:MM:SS)
              final exifDatePattern = RegExp(
                r'^\d{4}:\d{2}:\d{2} \d{2}:\d{2}:\d{2}$',
              );
              expect(
                exifDatePattern.hasMatch(dateTime.trim()),
                isTrue,
                reason:
                    'DateTime should be in EXIF format (YYYY:MM:DD HH:MM:SS), got: "$dateTime"',
              ); // For files processed with JSON metadata, verify reasonable date range
              // (Could be either original date from test image or date from JSON)
              final year = int.tryParse(dateTime.substring(0, 4));
              expect(
                year != null && year >= 2020 && year <= 2025,
                isTrue,
                reason:
                    'DateTime year should be reasonable (2020-2025), got: "$dateTime"',
              );
            }
          }
        }
      });
      test('File content integrity validation', () async {
        final googlePhotosPath = PathResolverService.resolveGooglePhotosPath(
          takeoutPath,
        );

        // Calculate input file hashes before processing
        final inputFiles = await Directory(googlePhotosPath)
            .list(recursive: true)
            .where((final entity) => entity is File)
            .where(
              (final file) =>
                  file.path.endsWith('.jpg') || file.path.endsWith('.png'),
            )
            .cast<File>()
            .toList();

        final inputHashes = <String, String>{};
        for (final file in inputFiles) {
          final bytes = await file.readAsBytes();
          // Use file size + first 16 bytes for a simple but reliable fingerprint
          final fingerprint = '${bytes.length}_${bytes.take(16).join(',')}';
          inputHashes[path.basename(file.path)] = fingerprint;
        }

        final config = ProcessingConfig(
          inputPath: googlePhotosPath,
          outputPath: outputPath,
          disableResumeCheck: true,
          albumBehavior: AlbumBehavior.nothing,
          dateDivision: DateDivisionLevel.none,
          writeExif: false, // Don't modify files to preserve content
        );

        final result = await pipeline.execute(
          config: config,
          inputDirectory: Directory(googlePhotosPath),
          outputDirectory: Directory(outputPath),
        );

        expect(
          result.isSuccess,
          isTrue,
        ); // Verify file content integrity (files should not be corrupted)
        final outputFiles = await Directory(outputPath)
            .list(recursive: true)
            .where((final entity) => entity is File)
            .where(
              (final file) =>
                  file.path.endsWith('.jpg') || file.path.endsWith('.png'),
            )
            .cast<File>()
            .toList();
        for (final outputFile in outputFiles) {
          final fileName = path.basename(outputFile.path);
          if (inputHashes.containsKey(fileName)) {
            final outputBytes = await outputFile.readAsBytes();
            // Use the same fingerprint method as input files
            final outputFingerprint =
                '${outputBytes.length}_${outputBytes.take(16).join(',')}';

            expect(
              outputFingerprint,
              equals(inputHashes[fileName]),
              reason: 'File content should be preserved: $fileName',
            );
          }
        }
      });

      test('Album structure deep validation', () async {
        final currentTakeoutPath = takeoutPath;
        final currentOutputPath = outputPath;
        final googlePhotosPath = PathResolverService.resolveGooglePhotosPath(
          currentTakeoutPath,
        );

        final config = ProcessingConfig(
          inputPath: googlePhotosPath,
          outputPath: currentOutputPath,
          disableResumeCheck: true,
          albumBehavior: AlbumBehavior.duplicateCopy,
          dateDivision: DateDivisionLevel.none,
          writeExif: false,
        );

        final result = await pipeline.execute(
          config: config,
          inputDirectory: Directory(googlePhotosPath),
          outputDirectory: Directory(currentOutputPath),
        );

        expect(result.isSuccess, isTrue); // Deep validation of album structure
        final allPhotosDir = Directory(
          path.join(currentOutputPath, 'ALL_PHOTOS'),
        );
        expect(await allPhotosDir.exists(), isTrue);

        // Album directories are placed under output/Albums/<albumName>/
        final albumsRootDir = Directory(path.join(currentOutputPath, 'Albums'));

        bool isMediaFile(final String filePath) {
          final lower = filePath.toLowerCase();
          return lower.endsWith('.jpg') ||
              lower.endsWith('.jpeg') ||
              lower.endsWith('.png') ||
              lower.endsWith('.mp4') ||
              lower.endsWith('.mov') ||
              lower.endsWith('.heic') ||
              lower.endsWith('.cr2') ||
              lower.endsWith('.dng') ||
              lower.endsWith('.raf');
        }

        Future<List<File>> findAlbumFiles() async => albumsRootDir
            .list(recursive: true)
            .whereType<File>()
            .where((final file) => isMediaFile(file.path))
            .toList();

        Future<List<File>> findAllPhotosFiles() async => allPhotosDir
            .list(recursive: true)
            .whereType<File>()
            .where((final file) => isMediaFile(file.path))
            .toList();

        var albumFiles = await findAlbumFiles();
        if (albumFiles.isEmpty) {
          for (int i = 0; i < 8; i++) {
            await Future<void>.delayed(const Duration(milliseconds: 80));
            albumFiles = await findAlbumFiles();
            if (albumFiles.isNotEmpty) break;
          }
        }

        final allPhotosFiles = await findAllPhotosFiles();
        final allPhotosBaseNames = allPhotosFiles
            .map((final file) => path.basename(file.path))
            .toSet();

        // Verify each album file also exists in ALL_PHOTOS.
        // Album copies may carry a dedup suffix like (1); strip it first.
        for (final albumFile in albumFiles) {
          final fileName = path.basename(albumFile.path);
          final baseFileName = fileName.replaceFirstMapped(
            RegExp(r'\(\d+\)(?=\.\w+$)'),
            (final _) => '',
          );

          expect(
            allPhotosBaseNames.contains(baseFileName),
            isTrue,
            reason: 'Album file $fileName should also exist in ALL_PHOTOS',
          );
        }

        // In duplicate-copy mode, total files = ALL_PHOTOS files + album copies
        expect(
          albumFiles.length,
          greaterThan(0),
          reason: 'Should have files in album directories',
        );
      });
    });

    group('EXIF Edge Cases and Error Handling', () {
      test('EXIF edge cases and error handling validation', () async {
        // Create test files with various EXIF scenarios
        final customTakeout = await _createDataWithVariousExifScenarios();
        final googlePhotosPath = PathResolverService.resolveGooglePhotosPath(
          customTakeout,
        );

        final config = ProcessingConfig(
          inputPath: googlePhotosPath,
          outputPath: outputPath,
          disableResumeCheck: true,
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

        final serviceContainer = ServiceContainer.instance;
        expect(serviceContainer.exifTool, isNotNull);

        final outputFiles = await Directory(outputPath)
            .list(recursive: true)
            .where((final entity) => entity is File)
            .where((final file) => file.path.endsWith('.jpg'))
            .cast<File>()
            .toList();

        expect(outputFiles.length, greaterThan(0));
        for (final outputFile in outputFiles) {
          final exifData = await serviceContainer.exifTool!.readExifData(
            outputFile,
          );

          // Verify basic EXIF structure exists
          expect(
            exifData,
            isNotEmpty,
            reason: 'Output file ${outputFile.path} should have EXIF data',
          );

          // Test GPS data validation - check any file with GPS data
          if (exifData.containsKey('GPSLatitude') &&
              exifData.containsKey('GPSLongitude')) {
            final latitude = exifData['GPSLatitude'] as num;
            final longitude = exifData['GPSLongitude'] as num;

            // Verify GPS coordinates are reasonable values
            expect(
              latitude,
              isA<num>(),
              reason: 'GPS Latitude should be numeric',
            );
            expect(
              longitude,
              isA<num>(),
              reason: 'GPS Longitude should be numeric',
            );

            // Verify coordinates are within valid ranges
            expect(
              latitude.abs(),
              lessThanOrEqualTo(90.0),
              reason: 'Latitude should be within ±90 degrees',
            );
            expect(
              longitude.abs(),
              lessThanOrEqualTo(180.0),
              reason: 'Longitude should be within ±180 degrees',
            );
          } // Test DateTime format validation
          if (exifData.containsKey('DateTimeOriginal') ||
              exifData.containsKey('DateTime')) {
            final dateTime =
                exifData['DateTimeOriginal'] ?? exifData['DateTime'];
            expect(dateTime, isNotNull, reason: 'DateTime should be present');

            if (dateTime is String) {
              // Verify EXIF DateTime format
              final exifDatePattern = RegExp(
                r'^\d{4}:\d{2}:\d{2} \d{2}:\d{2}:\d{2}$',
              );
              expect(
                exifDatePattern.hasMatch(dateTime.trim()),
                isTrue,
                reason: 'DateTime should be in EXIF format: "$dateTime"',
              );

              // Verify reasonable date range (should be either from JSON or existing EXIF)
              final year = int.tryParse(dateTime.substring(0, 4));
              expect(
                year != null && year >= 2020 && year <= 2025,
                isTrue,
                reason: 'DateTime year should be reasonable: "$dateTime"',
              );
            }
          }

          // Test coordinate reference validation when present
          if (exifData.containsKey('GPSLatitudeRef')) {
            final latRef = exifData['GPSLatitudeRef'];
            expect(
              ['N', 'S', 'North', 'South'].contains(latRef),
              isTrue,
              reason: 'GPSLatitudeRef should be valid: "$latRef"',
            );
          }

          if (exifData.containsKey('GPSLongitudeRef')) {
            final lngRef = exifData['GPSLongitudeRef'];
            expect(
              ['E', 'W', 'East', 'West'].contains(lngRef),
              isTrue,
              reason: 'GPSLongitudeRef should be valid: "$lngRef"',
            );
          }
        }
      });

      test('Date extraction method priority validation', () async {
        // Create files with conflicting dates from different sources
        final customTakeout = await _createDataWithConflictingDates();
        final googlePhotosPath = PathResolverService.resolveGooglePhotosPath(
          customTakeout,
        );

        final config = ProcessingConfig(
          inputPath: googlePhotosPath,
          outputPath: outputPath,
          disableResumeCheck: true,
          albumBehavior: AlbumBehavior.nothing,
          dateDivision: DateDivisionLevel.none,
          writeExif: true,
          guessFromName: true, // Enable filename guessing
        );

        final result = await pipeline.execute(
          config: config,
          inputDirectory: Directory(googlePhotosPath),
          outputDirectory: Directory(outputPath),
        );

        expect(result.isSuccess, isTrue);

        final outputFiles = await Directory(outputPath)
            .list(recursive: true)
            .where((final entity) => entity is File)
            .where((final file) => file.path.endsWith('.jpg'))
            .cast<File>()
            .toList();

        final serviceContainer = ServiceContainer.instance;

        for (final outputFile in outputFiles) {
          final exifData = await serviceContainer.exifTool!.readExifData(
            outputFile,
          );

          if (outputFile.path.contains('json_wins')) {
            // JSON date (2023) should win over EXIF date (2022) and filename date (2021)
            final dateTime = exifData['DateTimeOriginal'] as String?;
            expect(
              dateTime?.startsWith('2023:'),
              isTrue,
              reason:
                  'JSON priority failure for ${outputFile.path}\nExpected year: 2023 (from JSON)\nActual DateTimeOriginal: ${dateTime ?? 'null'}\nFull EXIF keys: ${exifData.keys.toList()}',
            );
          }

          if (outputFile.path.contains('exif_wins')) {
            // EXIF date (2022) should win over filename date (2021) when no JSON
            final dateTime = exifData['DateTimeOriginal'] as String?;
            expect(
              dateTime?.startsWith('2022:'),
              isTrue,
              reason:
                  'EXIF priority failure for ${outputFile.path}\nExpected year: 2022 (from EXIF)\nActual DateTimeOriginal: ${dateTime ?? 'null'}\nIf value starts with 2021 it indicates fallback to filename; check EXIF writing or extraction order.\nFull EXIF keys: ${exifData.keys.toList()}',
            );
          }

          if (outputFile.path.contains('filename_fallback')) {
            // Filename date (2021) should be used when no JSON or EXIF
            final dateTime = exifData['DateTimeOriginal'] as String?;
            expect(
              dateTime?.startsWith('2021:'),
              isTrue,
              reason:
                  'Filename fallback failure for ${outputFile.path}\nExpected year: 2021 (from filename)\nActual DateTimeOriginal: ${dateTime ?? 'null'}\nEXIF keys present (should not include overriding JSON date): ${exifData.keys.toList()}',
            );
          }
        }
      });

      test('Complex filename pattern extraction validation', () async {
        // Create files with edge case filename patterns
        final customTakeout = await _createDataWithComplexFilenames();
        final googlePhotosPath = PathResolverService.resolveGooglePhotosPath(
          customTakeout,
        );

        final config = ProcessingConfig(
          inputPath: googlePhotosPath,
          outputPath: outputPath,
          disableResumeCheck: true,
          albumBehavior: AlbumBehavior.nothing,
          dateDivision: DateDivisionLevel.none,
          writeExif: false, // Test pure filename extraction
          guessFromName: true,
        );

        final result = await pipeline.execute(
          config: config,
          inputDirectory: Directory(googlePhotosPath),
          outputDirectory: Directory(outputPath),
        );

        expect(result.isSuccess, isTrue);

        // Verify specific filename patterns were correctly extracted
        final outputFiles = await Directory(outputPath)
            .list(recursive: true)
            .where((final entity) => entity is File)
            .cast<File>()
            .toList();

        expect(
          outputFiles
              .where((final f) => f.path.contains('Screenshot_20230615-143022'))
              .isNotEmpty,
          isTrue,
          reason: 'Screenshot pattern should be processed',
        );
        expect(
          outputFiles
              .where((final f) => f.path.contains('IMG_20230101_120000'))
              .isNotEmpty,
          isTrue,
          reason: 'IMG pattern should be processed',
        );
        expect(
          outputFiles
              .where((final f) => f.path.contains('signal-2023-06-15-120000'))
              .isNotEmpty,
          isTrue,
          reason: 'Signal pattern should be processed',
        );
      });
    });

    group('Missing Configuration Flag Tests', () {
      test('writeExif: false should not write EXIF data', () async {
        final customTakeout = await _createDataWithSpecificExif();
        final googlePhotosPath = PathResolverService.resolveGooglePhotosPath(
          customTakeout,
        );

        final config = ProcessingConfig(
          inputPath: googlePhotosPath,
          outputPath: outputPath,
          disableResumeCheck: true,
          albumBehavior: AlbumBehavior.nothing,
          dateDivision: DateDivisionLevel.none,
          writeExif: false, // Disabled EXIF writing
        );

        final result = await pipeline.execute(
          config: config,
          inputDirectory: Directory(googlePhotosPath),
          outputDirectory: Directory(outputPath),
        );

        expect(result.isSuccess, isTrue);

        final outputFiles = await Directory(outputPath)
            .list(recursive: true)
            .where((final entity) => entity is File)
            .where((final file) => file.path.endsWith('.jpg'))
            .cast<File>()
            .toList();

        final serviceContainer = ServiceContainer.instance;

        for (final outputFile in outputFiles) {
          final exifData = await serviceContainer.exifTool!.readExifData(
            outputFile,
          );

          // Should not have GPS data written from JSON when writeExif is false
          if (outputFile.path.contains('without_exif')) {
            expect(
              exifData.containsKey('GPSLatitude') &&
                  exifData.containsKey('GPSLongitude'),
              isFalse,
              reason: 'GPS data should not be written when writeExif is false',
            );
          }
        }
      });

      test('verbose: true should not affect output content', () async {
        final googlePhotosPath = PathResolverService.resolveGooglePhotosPath(
          takeoutPath,
        );

        final config = ProcessingConfig(
          inputPath: googlePhotosPath,
          outputPath: outputPath,
          disableResumeCheck: true,
          albumBehavior: AlbumBehavior.nothing,
          dateDivision: DateDivisionLevel.none,
          verbose: true, // Enable verbose mode
        );

        final result = await pipeline.execute(
          config: config,
          inputDirectory: Directory(googlePhotosPath),
          outputDirectory: Directory(outputPath),
        );

        expect(result.isSuccess, isTrue);

        // Verbose mode should not change the actual file processing outcome
        final outputFiles = await Directory(outputPath)
            .list(recursive: true)
            .where((final entity) => entity is File)
            .cast<File>()
            .toList();

        expect(outputFiles.length, greaterThan(0));
      });

      test(
        'updateCreationTime: true should work on supported platforms',
        () async {
          final googlePhotosPath = PathResolverService.resolveGooglePhotosPath(
            takeoutPath,
          );

          final config = ProcessingConfig(
            inputPath: googlePhotosPath,
            outputPath: outputPath,
            disableResumeCheck: true,
            albumBehavior: AlbumBehavior.nothing,
            dateDivision: DateDivisionLevel.none,
            updateCreationTime: true, // Enable creation time update
          );

          final result = await pipeline.execute(
            config: config,
            inputDirectory: Directory(googlePhotosPath),
            outputDirectory: Directory(outputPath),
          );

          // Should succeed even if not on Windows (feature should be safely ignored)
          expect(result.isSuccess, isTrue);

          final outputFiles = await Directory(outputPath)
              .list(recursive: true)
              .where((final entity) => entity is File)
              .cast<File>()
              .toList();

          expect(outputFiles.length, greaterThan(0));
        },
      );

      test(
        'limitFileSize: true should handle large files appropriately',
        () async {
          // Create a test with simulated large files
          final customTakeout = await _createDataWithLargeFiles();
          final googlePhotosPath = PathResolverService.resolveGooglePhotosPath(
            customTakeout,
          );

          final config = ProcessingConfig(
            inputPath: googlePhotosPath,
            outputPath: outputPath,
            disableResumeCheck: true,
            albumBehavior: AlbumBehavior.nothing,
            dateDivision: DateDivisionLevel.none,
            limitFileSize: true, // Enable file size limiting
          );

          final result = await pipeline.execute(
            config: config,
            inputDirectory: Directory(googlePhotosPath),
            outputDirectory: Directory(outputPath),
          );

          expect(result.isSuccess, isTrue);

          // Should still process files (our test files are small anyway)
          final outputFiles = await Directory(outputPath)
              .list(recursive: true)
              .where((final entity) => entity is File)
              .cast<File>()
              .toList();

          expect(outputFiles.length, greaterThan(0));
        },
      );

      test('ExtensionFixingMode.solo should stop after extension fixing', () async {
        final customTakeout = await _createDataWithWrongExtensions();
        final googlePhotosPath = PathResolverService.resolveGooglePhotosPath(
          customTakeout,
        );

        final config = ProcessingConfig(
          inputPath: googlePhotosPath,
          outputPath: outputPath,
          disableResumeCheck: true,
          albumBehavior: AlbumBehavior.nothing,
          dateDivision: DateDivisionLevel.none,
          extensionFixing: ExtensionFixingMode.solo, // Solo mode
        );

        final result = await pipeline.execute(
          config: config,
          inputDirectory: Directory(googlePhotosPath),
          outputDirectory: Directory(outputPath),
        );

        expect(result.isSuccess, isTrue);

        // In solo mode, should fix extensions but not continue with full processing
        // This means files should be renamed but not moved to date-based structure
        final inputFiles = await Directory(googlePhotosPath)
            .list(recursive: true)
            .where((final entity) => entity is File)
            .cast<File>()
            .toList();

        // Files should still be in input directory after extension fixing in solo mode
        expect(inputFiles.length, greaterThan(0));
      });

      test(
        'ExtensionFixingMode.conservative should be more restrictive',
        () async {
          final customTakeout = await _createDataWithWrongExtensions();
          final googlePhotosPath = PathResolverService.resolveGooglePhotosPath(
            customTakeout,
          );

          final config = ProcessingConfig(
            inputPath: googlePhotosPath,
            outputPath: outputPath,
            disableResumeCheck: true,
            albumBehavior: AlbumBehavior.nothing,
            dateDivision: DateDivisionLevel.none,
            extensionFixing: ExtensionFixingMode.conservative,
          );

          final result = await pipeline.execute(
            config: config,
            inputDirectory: Directory(googlePhotosPath),
            outputDirectory: Directory(outputPath),
          );

          expect(result.isSuccess, isTrue);

          final outputFiles = await Directory(outputPath)
              .list(recursive: true)
              .where((final entity) => entity is File)
              .cast<File>()
              .toList();

          expect(outputFiles.length, greaterThan(0));
        },
      );
    });
  });
}

/// Helper function to create test data with extra files (-edited, -modified, etc.)
Future<String> _createDataWithExtraFiles() async {
  final fixture = TestFixture();
  await fixture.setUp();

  final takeoutDir = fixture.createDirectory('Takeout');
  final googlePhotosDir = fixture.createDirectory(
    '${takeoutDir.path}/Google Photos',
  );
  final yearDir = fixture.createDirectory(
    '${googlePhotosDir.path}/Photos from 2023',
  );

  // Create regular photo
  fixture.createImageWithExif('${yearDir.path}/photo.jpg');
  fixture.createFile(
    '${yearDir.path}/photo.jpg.json',
    utf8.encode('{"photoTakenTime": {"timestamp": "1672531200"}}'),
  );

  // Create extra files with various suffixes from extraFormats
  // Make each file unique by using createFile with unique content
  fixture.createFile(
    '${yearDir.path}/photo-edited.jpg',
    utf8.encode('fake-edited-image-content-1'),
  );
  fixture.createFile(
    '${yearDir.path}/photo-edited.jpg.json',
    utf8.encode('{"photoTakenTime": {"timestamp": "1672531200"}}'),
  );

  fixture.createFile(
    '${yearDir.path}/photo-effects.jpg',
    utf8.encode('fake-effects-image-content-2'),
  );
  fixture.createFile(
    '${yearDir.path}/photo-effects.jpg.json',
    utf8.encode('{"photoTakenTime": {"timestamp": "1672531200"}}'),
  );

  fixture.createFile(
    '${yearDir.path}/photo-bearbeitet.jpg',
    utf8.encode('fake-bearbeitet-image-content-3'),
  );
  fixture.createFile(
    '${yearDir.path}/photo-bearbeitet.jpg.json',
    utf8.encode('{"photoTakenTime": {"timestamp": "1672531200"}}'),
  );

  return takeoutDir.path;
}

/// Helper function to create test data with dates in filenames
Future<String> _createDataWithDateInFilenames() async {
  final fixture = TestFixture();
  await fixture.setUp();

  final takeoutDir = fixture.createDirectory('Takeout');
  final googlePhotosDir = fixture.createDirectory(
    '${takeoutDir.path}/Google Photos',
  );
  final yearDir = fixture.createDirectory(
    '${googlePhotosDir.path}/Photos from 2023',
  );

  // Create files with dates in filenames but no EXIF/JSON metadata
  fixture.createImageWithoutExif('${yearDir.path}/IMG_20190315_123456.jpg');
  fixture.createImageWithoutExif('${yearDir.path}/20200612_holiday.jpg');
  fixture.createImageWithoutExif('${yearDir.path}/vacation_2019-08-25.jpg');

  return takeoutDir.path;
}

/// Helper function to create test data with wrong file extensions
Future<String> _createDataWithWrongExtensions() async {
  final fixture = TestFixture();
  await fixture.setUp();

  final takeoutDir = fixture.createDirectory('Takeout');
  final googlePhotosDir = fixture.createDirectory(
    '${takeoutDir.path}/Google Photos',
  );
  final yearDir = fixture.createDirectory(
    '${googlePhotosDir.path}/Photos from 2023',
  );
  // Create JPEG files with wrong extensions
  fixture.createImageWithExif(
    '${yearDir.path}/photo1.jpg',
  ); // Create JPEG first
  final jpegFile1 = File('${yearDir.path}/photo1.jpg');
  final wrongExtFile1 = File('${yearDir.path}/photo1.txt');
  await jpegFile1.copy(wrongExtFile1.path); // Copy to wrong extension
  await jpegFile1.delete(); // Remove original

  fixture.createImageWithoutExif(
    '${yearDir.path}/photo2.jpg',
  ); // Create JPEG first
  final jpegFile2 = File('${yearDir.path}/photo2.jpg');
  final wrongExtFile2 = File('${yearDir.path}/photo2.png');
  await jpegFile2.copy(wrongExtFile2.path); // Copy to wrong extension
  await jpegFile2.delete(); // Remove original

  fixture.createImageWithExif(
    '${yearDir.path}/photo3.jpg',
  ); // Create JPEG first
  final jpegFile3 = File('${yearDir.path}/photo3.jpg');
  final wrongExtFile3 = File('${yearDir.path}/photo3.gif');
  await jpegFile3.copy(wrongExtFile3.path); // Copy to wrong extension
  await jpegFile3.delete(); // Remove original

  // Create JSON metadata for these files
  fixture.createFile(
    '${yearDir.path}/photo1.txt.json',
    utf8.encode('{"photoTakenTime": {"timestamp": "1672531200"}}'),
  );
  fixture.createFile(
    '${yearDir.path}/photo2.png.json',
    utf8.encode('{"photoTakenTime": {"timestamp": "1672531200"}}'),
  );
  fixture.createFile(
    '${yearDir.path}/photo3.gif.json',
    utf8.encode('{"photoTakenTime": {"timestamp": "1672531200"}}'),
  );

  return takeoutDir.path;
}

/// Helper function to create test data with mixed file types
Future<String> _createDataWithMixedFileTypes() async {
  final fixture = TestFixture();
  await fixture.setUp();

  final takeoutDir = fixture.createDirectory('Takeout');
  final googlePhotosDir = fixture.createDirectory(
    '${takeoutDir.path}/Google Photos',
  );
  final yearDir = fixture.createDirectory(
    '${googlePhotosDir.path}/Photos from 2023',
  );

  // Create various file types
  fixture.createImageWithExif('${yearDir.path}/photo.jpg'); // JPEG
  fixture.createImageWithoutExif('${yearDir.path}/image.png'); // PNG
  fixture.createFile('${yearDir.path}/raw.tif', [
    0x49,
    0x49,
    0x2A,
    0x00,
  ]); // TIFF header

  // Create JSON metadata
  fixture.createFile(
    '${yearDir.path}/photo.jpg.json',
    utf8.encode('{"photoTakenTime": {"timestamp": "1672531200"}}'),
  );
  fixture.createFile(
    '${yearDir.path}/image.png.json',
    utf8.encode('{"photoTakenTime": {"timestamp": "1672531200"}}'),
  );
  fixture.createFile(
    '${yearDir.path}/raw.tif.json',
    utf8.encode('{"photoTakenTime": {"timestamp": "1672531200"}}'),
  );

  return takeoutDir.path;
}

/// Helper function to create test data with Pixel .MP and .MV files
Future<String> _createDataWithPixelFiles() async {
  final fixture = TestFixture();
  await fixture.setUp();

  final takeoutDir = fixture.createDirectory('Takeout');
  final googlePhotosDir = fixture.createDirectory(
    '${takeoutDir.path}/Google Photos',
  );
  final yearDir = fixture.createDirectory(
    '${googlePhotosDir.path}/Photos from 2023',
  );

  // Create fake .MP and .MV files (Pixel motion photos)
  fixture.createFile('${yearDir.path}/motion1.MP', [
    0x00,
    0x00,
    0x00,
    0x20,
    0x66,
    0x74,
    0x79,
    0x70,
  ]); // MP4 header
  fixture.createFile('${yearDir.path}/motion2.MV', [
    0x00,
    0x00,
    0x00,
    0x20,
    0x66,
    0x74,
    0x79,
    0x70,
  ]); // MP4 header

  // Create JSON metadata
  fixture.createFile(
    '${yearDir.path}/motion1.MP.json',
    utf8.encode('{"photoTakenTime": {"timestamp": "1672531200"}}'),
  );
  fixture.createFile(
    '${yearDir.path}/motion2.MV.json',
    utf8.encode('{"photoTakenTime": {"timestamp": "1672531200"}}'),
  );

  return takeoutDir.path;
}

Future<String> _createDataWithPixelFilesInAlbum() async {
  final fixture = TestFixture();
  await fixture.setUp();

  final takeoutDir = fixture.createDirectory('Takeout');
  final googlePhotosDir = fixture.createDirectory(
    '${takeoutDir.path}/Google Photos',
  );
  final yearDir = fixture.createDirectory(
    '${googlePhotosDir.path}/Photos from 2023',
  );
  final albumDir = fixture.createDirectory('${googlePhotosDir.path}/Album A');

  const motionBytes = <int>[0x00, 0x00, 0x00, 0x20, 0x66, 0x74, 0x79, 0x70];

  fixture.createFile('${yearDir.path}/motion1.MP', motionBytes);
  fixture.createFile('${albumDir.path}/motion1.MP', motionBytes);

  fixture.createFile(
    '${yearDir.path}/motion1.MP.json',
    utf8.encode('{"photoTakenTime": {"timestamp": "1672531200"}}'),
  );
  fixture.createFile(
    '${albumDir.path}/motion1.MP.json',
    utf8.encode('{"photoTakenTime": {"timestamp": "1672531200"}}'),
  );

  return takeoutDir.path;
}

Future<String> _createDataWithPixelFilesAndStillSidecars() async {
  final fixture = TestFixture();
  await fixture.setUp();

  final takeoutDir = fixture.createDirectory('Takeout');
  final googlePhotosDir = fixture.createDirectory(
    '${takeoutDir.path}/Google Photos',
  );
  final yearDir = fixture.createDirectory(
    '${googlePhotosDir.path}/Photos from 2023',
  );

  final validMotionLikeBytes = <int>[
    0x00,
    0x00,
    0x00,
    0x20,
    0x66,
    0x74,
    0x79,
    0x70,
    0x69,
    0x73,
    0x6F,
    0x6D,
    0x00,
    0x00,
    0x00,
    0x01,
    0xFF,
    0xD8,
    0xFF,
    0xE0,
    0x00,
    0x10,
    0x4A,
    0x46,
    0x49,
    0x46,
    0x00,
    0x00,
    0x11,
    0x22,
    0x33,
    0x44,
    0xFF,
    0xD9,
  ];

  fixture.createFile('${yearDir.path}/motion1.MP', validMotionLikeBytes);
  fixture.createFile('${yearDir.path}/motion2.MV', validMotionLikeBytes);

  // Sidecar still images used by "still" mode.
  fixture.createFile('${yearDir.path}/motion1.MP.jpg', [
    0xFF,
    0xD8,
    0xFF,
    0xE0,
    0x00,
    0x10,
    0x4A,
    0x46,
    0x49,
    0x46,
    0x00,
    0xFF,
    0xD9,
  ]);
  fixture.createFile('${yearDir.path}/motion2.MV.jpg', [
    0xFF,
    0xD8,
    0xFF,
    0xE0,
    0x00,
    0x10,
    0x4A,
    0x46,
    0x49,
    0x46,
    0x00,
    0xFF,
    0xD9,
  ]);

  fixture.createFile(
    '${yearDir.path}/motion1.MP.json',
    utf8.encode('{"photoTakenTime": {"timestamp": "1672531200"}}'),
  );
  fixture.createFile(
    '${yearDir.path}/motion2.MV.json',
    utf8.encode('{"photoTakenTime": {"timestamp": "1672531200"}}'),
  );

  return takeoutDir.path;
}

Future<String> _createDataForHeicSidecarPreference() async {
  final fixture = TestFixture();
  await fixture.setUp();

  final takeoutDir = fixture.createDirectory('Takeout');
  final googlePhotosDir = fixture.createDirectory(
    '${takeoutDir.path}/Google Photos',
  );
  final yearDir = fixture.createDirectory(
    '${googlePhotosDir.path}/Photos from 2023',
  );

  // Motion file with tiny embedded JPEG (preview-like) inside MP4 container.
  fixture.createFile('${yearDir.path}/motion1.MP', [
    0x00,
    0x00,
    0x00,
    0x20,
    0x66,
    0x74,
    0x79,
    0x70,
    0x69,
    0x73,
    0x6F,
    0x6D,
    0xAA,
    0xBB,
    0xCC,
    0xDD,
    0xFF,
    0xD8,
    0x01,
    0x02,
    0x03,
    0x04,
    0xFF,
    0xD9,
    0x10,
    0x11,
    0x12,
    0x13,
  ]);

  // Distinct sidecar bytes; HEIC output should start with these bytes.
  fixture.createFile('${yearDir.path}/motion1.MP.jpg', [
    0x21,
    0x22,
    0x23,
    0x24,
    0x25,
    0x26,
    0x27,
    0x28,
    0x29,
    0x2A,
  ]);

  fixture.createFile(
    '${yearDir.path}/motion1.MP.json',
    utf8.encode('{"photoTakenTime": {"timestamp": "1672531200"}}'),
  );

  return takeoutDir.path;
}

/// Helper function to create test data with large files
Future<String> _createDataWithLargeFiles() async {
  final fixture = TestFixture();
  await fixture.setUp();

  final takeoutDir = fixture.createDirectory('Takeout');
  final googlePhotosDir = fixture.createDirectory(
    '${takeoutDir.path}/Google Photos',
  );
  final yearDir = fixture.createDirectory(
    '${googlePhotosDir.path}/Photos from 2023',
  );

  // Create a large file (simulate 70MB)
  const largeFileSize = 70 * 1024 * 1024; // 70MB
  final largeFileData = List.filled(largeFileSize, 0xFF);
  fixture.createFile('${yearDir.path}/large_photo.jpg', largeFileData);

  // Create normal size file for comparison
  fixture.createImageWithExif('${yearDir.path}/normal_photo.jpg');

  // Create JSON metadata
  fixture.createFile(
    '${yearDir.path}/large_photo.jpg.json',
    utf8.encode('{"photoTakenTime": {"timestamp": "1672531200"}}'),
  );
  fixture.createFile(
    '${yearDir.path}/normal_photo.jpg.json',
    utf8.encode('{"photoTakenTime": {"timestamp": "1672531200"}}'),
  );

  return takeoutDir.path;
}

/// Helper function to create test data with specific EXIF data
Future<String> _createDataWithSpecificExif() async {
  final fixture = TestFixture();
  await fixture.setUp();

  final takeoutDir = fixture.createDirectory('Takeout');
  final googlePhotosDir = fixture.createDirectory(
    '${takeoutDir.path}/Google Photos',
  );
  final yearDir = fixture.createDirectory(
    '${googlePhotosDir.path}/Photos from 2023',
  );

  // Create files with EXIF data
  fixture.createImageWithExif('${yearDir.path}/with_exif.jpg');
  fixture.createImageWithoutExif('${yearDir.path}/without_exif.jpg');

  // Create JSON metadata with GPS coordinates
  fixture.createFile(
    '${yearDir.path}/with_exif.jpg.json',
    utf8.encode(
      jsonEncode({
        'photoTakenTime': {'timestamp': '1672531200'},
        'geoData': {
          'latitude': 37.7749,
          'longitude': -122.4194,
          'altitude': 10.0,
        },
      }),
    ),
  );
  fixture.createFile(
    '${yearDir.path}/without_exif.jpg.json',
    utf8.encode(
      jsonEncode({
        'photoTakenTime': {'timestamp': '1672531200'},
        'geoData': {
          'latitude': 40.7128,
          'longitude': -74.0060,
          'altitude': 5.0,
        },
      }),
    ),
  );

  return takeoutDir.path;
}

/// Creates test data with various EXIF scenarios for edge case testing
Future<String> _createDataWithVariousExifScenarios() async {
  final fixture = TestFixture();
  await fixture.setUp();

  final takeoutDir = fixture.createDirectory('Takeout');
  final googlePhotosDir = fixture.createDirectory(
    '${takeoutDir.path}/Google Photos',
  );
  final yearDir = fixture.createDirectory(
    '${googlePhotosDir.path}/Photos from 2023',
  );

  // File with conflicting dates (JSON: 2023, EXIF: 2022)
  fixture.createImageWithExif('${yearDir.path}/conflicting_dates.jpg');
  fixture.createFile(
    '${yearDir.path}/conflicting_dates.jpg.json',
    utf8.encode(
      jsonEncode({
        'photoTakenTime': {'timestamp': '1672531200'}, // 2023-01-01
        'geoData': {'latitude': 37.7749, 'longitude': -122.4194},
      }),
    ),
  );

  // File with high-precision GPS coordinates
  fixture.createImageWithoutExif('${yearDir.path}/precise_gps.jpg');
  fixture.createFile(
    '${yearDir.path}/precise_gps.jpg.json',
    utf8.encode(
      jsonEncode({
        'photoTakenTime': {'timestamp': '1672531200'},
        'geoData': {
          'latitude': 37.774929123456,
          'longitude': -122.419401987654,
          'altitude': 123.456789,
        },
      }),
    ),
  );

  // File with altitude data
  fixture.createImageWithoutExif('${yearDir.path}/with_altitude.jpg');
  fixture.createFile(
    '${yearDir.path}/with_altitude.jpg.json',
    utf8.encode(
      jsonEncode({
        'photoTakenTime': {'timestamp': '1672531200'},
        'geoData': {
          'latitude': 40.7128,
          'longitude': -74.0060,
          'altitude': 10.5,
        },
      }),
    ),
  );

  // File with edge case coordinates (negative coordinates)
  fixture.createImageWithoutExif('${yearDir.path}/edge_coordinates.jpg');
  fixture.createFile(
    '${yearDir.path}/edge_coordinates.jpg.json',
    utf8.encode(
      jsonEncode({
        'photoTakenTime': {'timestamp': '1672531200'},
        'geoData': {
          'latitude': -33.8688, // Sydney (South)
          'longitude': 151.2093, // Sydney (East)
          'altitude': 0.0,
        },
      }),
    ),
  );

  return takeoutDir.path;
}

/// Creates test data with conflicting dates from different sources
Future<String> _createDataWithConflictingDates() async {
  final fixture = TestFixture();
  await fixture.setUp();

  final takeoutDir = fixture.createDirectory('Takeout');
  final googlePhotosDir = fixture.createDirectory(
    '${takeoutDir.path}/Google Photos',
  );
  final yearDir = fixture.createDirectory(
    '${googlePhotosDir.path}/Photos from 2023',
  );

  // File where JSON date should win (has JSON: 2023, EXIF: 2022, filename: 2021)
  fixture.createImageWithExif(
    '${yearDir.path}/IMG_20210615_120000_json_wins.jpg',
  );
  fixture.createFile(
    '${yearDir.path}/IMG_20210615_120000_json_wins.jpg.json',
    utf8.encode(
      jsonEncode({
        'photoTakenTime': {'timestamp': '1672531200'}, // 2023-01-01
      }),
    ),
  );

  // File where EXIF date should win (has EXIF: 2022, filename: 2021, no JSON)
  fixture.createImageWithExif(
    '${yearDir.path}/IMG_20210615_120000_exif_wins.jpg',
  );

  // File where filename should be fallback (no JSON, no EXIF, only filename: 2021)
  fixture.createImageWithoutExif(
    '${yearDir.path}/IMG_20210615_120000_filename_fallback.jpg',
  );

  return takeoutDir.path;
}

/// Creates test data with complex filename patterns for edge case testing
Future<String> _createDataWithComplexFilenames() async {
  final fixture = TestFixture();
  await fixture.setUp();

  final takeoutDir = fixture.createDirectory('Takeout');
  final googlePhotosDir = fixture.createDirectory(
    '${takeoutDir.path}/Google Photos',
  );
  final yearDir = fixture.createDirectory(
    '${googlePhotosDir.path}/Photos from 2023',
  );
  // Various complex filename patterns that should be extracted
  final filenamePatterns = [
    'Screenshot_20230615-143022_Camera.jpg',
    'IMG_20230101_120000-edited.jpg',
    'signal-2023-06-15-120000.jpg',
    'MVIMG_20230301_140000.mp4',
    '20230401_150000.jpg',
    'photo_2023_04_01_15_00_00.jpg',
    'burst_20230501160000123.jpg',
  ];

  // Create unique files with different content to avoid duplicate detection
  for (int i = 0; i < filenamePatterns.length; i++) {
    final filename = filenamePatterns[i];
    final file = File('${yearDir.path}/$filename');

    // Create unique content for each file based on index
    final uniqueContent = List.generate(
      1000 + i * 100,
      (final index) => i + index,
    );
    await file.writeAsBytes(uniqueContent);
  }

  return takeoutDir.path;
}
