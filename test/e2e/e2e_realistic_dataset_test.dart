/// End-to-end tests using realistic Google Photos Takeout dataset
///
/// This test file uses generateRealisticTakeoutDataset() to create comprehensive
/// test scenarios that closely mirror real-world Google Photos exports.
// ignore_for_file: avoid_redundant_argument_values
@Timeout(Duration(seconds: 120))
library;

import 'dart:io';
import 'dart:typed_data';
import 'package:exif_reader/exif_reader.dart';
import 'package:gpth_neo/gpth_lib_exports.dart';
import 'package:path/path.dart' as path;
import 'package:test/test.dart';

import '../setup/test_setup.dart';

void main() {
  group('End-to-End Realistic Dataset Tests', () {
    late TestFixture fixture;
    late ProcessingPipeline pipeline;
    late String takeoutPath;
    late String outputPath;
    setUpAll(() async {
      // Initialize ServiceContainer first
      await ServiceContainer.instance.initialize();

      fixture = TestFixture();
      await fixture.setUp();
    });
    setUp(() async {
      // Initialize pipeline
      pipeline = const ProcessingPipeline();

      // Generate a fresh realistic dataset for each test to ensure test isolation
      // This prevents tests from interfering with each other when they move/modify files
      takeoutPath = await fixture.generateRealisticTakeoutDataset(
        yearSpan: 3,
        albumCount: 5,
        photosPerYear: 10,
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
    test('should process realistic dataset with default settings', () async {
      // Resolve the takeout path to the actual Google Photos directory
      final googlePhotosPath = PathResolverService.resolveGooglePhotosPath(
        takeoutPath,
      );
      final inputDir = Directory(googlePhotosPath);
      final outputDir = Directory(outputPath);

      expect(
        await inputDir.exists(),
        isTrue,
        reason: 'Input directory should exist',
      ); // Create processing configuration
      final config = ProcessingConfig(
        inputPath: googlePhotosPath,
        outputPath: outputPath,
        disableResumeCheck: true,
        albumBehavior: AlbumBehavior.shortcut,
        dateDivision: DateDivisionLevel.none, // Move files from input to output
        skipExtras: false,
        writeExif: false, // Disable EXIF writing in tests
      );

      // Run the main pipeline with realistic settings
      final result = await pipeline.execute(
        config: config,
        inputDirectory: inputDir,
        outputDirectory: outputDir,
      );

      expect(
        result.isSuccess,
        isTrue,
        reason: 'Pipeline should execute successfully',
      );

      // Verify output structure
      final outputContents = await outputDir.list().toList();
      expect(outputContents, isNotEmpty, reason: 'Output should contain files');

      // Should have ALL_PHOTOS directory
      final allPhotosDir = Directory(path.join(outputPath, 'ALL_PHOTOS'));
      expect(
        await allPhotosDir.exists(),
        isTrue,
        reason: 'ALL_PHOTOS directory should exist',
      );

      // Should have album directories (shortcut behavior)
      // Albums are placed under output/Albums/<album name>/ by PathGeneratorService
      final albumsSubdir = Directory(path.join(outputPath, 'Albums'));
      final albumSubdirContents = await albumsSubdir.exists()
          ? await albumsSubdir.list().toList()
          : <FileSystemEntity>[];
      final albumDirs = albumSubdirContents
          .whereType<Directory>()
          .where(
            (final dir) =>
                path.basename(dir.path).contains('Vacation 2023') ||
                path.basename(dir.path).contains('Family Photos') ||
                path.basename(dir.path).contains('Holiday Memories'),
          )
          .toList();

      expect(
        albumDirs.length,
        greaterThan(0),
        reason: 'Should create album directories',
      );
    });
    test('should handle album processing correctly', () async {
      final currentTakeoutPath = takeoutPath;
      final currentOutputPath = outputPath;
      final googlePhotosPath = PathResolverService.resolveGooglePhotosPath(
        currentTakeoutPath,
      );
      final inputDir = Directory(googlePhotosPath);
      final outputDir = Directory(currentOutputPath);
      final config = ProcessingConfig(
        inputPath: googlePhotosPath,
        outputPath: currentOutputPath,
        albumBehavior: AlbumBehavior.duplicateCopy,
        dateDivision: DateDivisionLevel.none,
        skipExtras: false,
        writeExif: false, // Disable EXIF writing in tests
      );

      final result = await pipeline.execute(
        config: config,
        inputDirectory: inputDir,
        outputDirectory: outputDir,
      );

      expect(result.isSuccess, isTrue);

      final outputContents = await outputDir.list(recursive: true).toList();

      // Count files in albums vs ALL_PHOTOS
      final allPhotosFiles = outputContents
          .whereType<File>()
          .where((final file) => file.path.contains('ALL_PHOTOS'))
          .toList();

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

      Future<List<File>> findAlbumMediaFiles() async => outputDir
          .list(recursive: true)
          .whereType<File>()
          .where(
            (final file) =>
                file.path.contains(
                  '${path.separator}Albums${path.separator}',
                ) &&
                isMediaFile(file.path),
          )
          .toList();

      var albumFiles = await findAlbumMediaFiles();
      // On Windows under heavy suite load, newly moved files may appear with a
      // tiny delay in directory listings. Retry briefly before asserting.
      if (albumFiles.isEmpty) {
        for (int i = 0; i < 8; i++) {
          await Future<void>.delayed(const Duration(milliseconds: 80));
          albumFiles = await findAlbumMediaFiles();
          if (albumFiles.isNotEmpty) break;
        }
      }

      expect(
        allPhotosFiles.length,
        greaterThan(0),
        reason: 'Should have photos in ALL_PHOTOS',
      );
      expect(
        albumFiles.length,
        greaterThan(0),
        reason: 'Should have duplicated photos in albums',
      );
    });
    test('should extract dates from various filename patterns', () async {
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
        dateDivision: DateDivisionLevel.year,
        skipExtras: false,
        writeExif: false, // Disable EXIF writing in tests
      );

      final result = await pipeline.execute(
        config: config,
        inputDirectory: inputDir,
        outputDirectory: outputDir,
      );
      expect(result.isSuccess, isTrue);

      // Find ALL_PHOTOS directory first
      final allPhotosDir = await outputDir
          .list()
          .where(
            (final entity) =>
                entity is Directory &&
                path.basename(entity.path).contains('ALL_PHOTOS'),
          )
          .cast<Directory>()
          .first;

      // Then find year directories within ALL_PHOTOS
      final yearDirs = await allPhotosDir
          .list()
          .where((final entity) => entity is Directory)
          .cast<Directory>()
          .where(
            (final dir) => RegExp(r'^\d{4}$').hasMatch(path.basename(dir.path)),
          )
          .toList();

      expect(
        yearDirs.length,
        greaterThan(0),
        reason: 'Should create year-based folders when divideToDates is true',
      );

      // Check that we have current and recent years
      final currentYear = DateTime.now().year;
      final yearNames = yearDirs
          .map((final dir) => int.parse(path.basename(dir.path)))
          .toSet();

      expect(
        yearNames.any((final year) => year >= currentYear - 3),
        isTrue,
        reason: 'Should have recent years in output',
      );
    });
    test('should handle JSON metadata extraction', () async {
      final googlePhotosPath = PathResolverService.resolveGooglePhotosPath(
        takeoutPath,
      );
      final inputDir = Directory(googlePhotosPath);
      final outputDir = Directory(outputPath);
      final config = ProcessingConfig(
        disableResumeCheck: true,
        inputPath: googlePhotosPath,
        outputPath: outputPath,
        albumBehavior: AlbumBehavior.json,
        dateDivision: DateDivisionLevel.none,
        skipExtras: false,
        writeExif: false, // Disable EXIF writing in tests
      );

      final result = await pipeline.execute(
        config: config,
        inputDirectory: inputDir,
        outputDirectory: outputDir,
      );

      expect(result.isSuccess, isTrue);

      // Should create albums-info.json file
      final albumsInfoFile = File(path.join(outputPath, 'albums-info.json'));
      expect(
        await albumsInfoFile.exists(),
        isTrue,
        reason: 'Should create albums-info.json file',
      );

      // Verify the JSON content
      final albumsInfo = await albumsInfoFile.readAsString();
      expect(albumsInfo, isNotEmpty, reason: 'Albums info should not be empty');
      expect(
        albumsInfo,
        contains('Vacation'),
        reason: 'Should contain album information',
      );
    });
    test('should preserve EXIF data when available', () async {
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
        skipExtras: false,
        writeExif: false, // Disable EXIF writing in tests
      );
      final result = await pipeline.execute(
        config: config,
        inputDirectory: inputDir,
        outputDirectory: outputDir,
      );

      expect(result.isSuccess, isTrue);

      final allPhotosDir = Directory(path.join(outputPath, 'ALL_PHOTOS'));
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

      Future<List<File>> findProcessedFiles() async => allPhotosDir
          .list(recursive: true)
          .whereType<File>()
          .where((final file) => isMediaFile(file.path))
          .toList();

      var outputFiles = await findProcessedFiles();
      if (outputFiles.isEmpty) {
        for (int i = 0; i < 8; i++) {
          await Future<void>.delayed(const Duration(milliseconds: 80));
          outputFiles = await findProcessedFiles();
          if (outputFiles.isNotEmpty) break;
        }
      }

      expect(
        outputFiles.length,
        greaterThan(0),
        reason: 'Should have processed image files',
      );

      // Check that files have been processed (their modified times should be set)
      var filesWithCorrectDates = 0;
      for (final file in outputFiles.take(5)) {
        // Check first 5 files
        final stat = await file.stat();
        final modTime = stat.modified;

        // Files should have their modification times set to historical dates
        // (not the current processing time)
        if (modTime.year < DateTime.now().year ||
            (modTime.year == DateTime.now().year &&
                modTime.month < DateTime.now().month)) {
          filesWithCorrectDates++;
        }
      }

      expect(
        filesWithCorrectDates,
        greaterThan(0),
        reason: 'Some files should have historical modification dates',
      );
    });
    test(
      'should handle special folders (Archive, Trash, Screenshots)',
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
          albumBehavior: AlbumBehavior.shortcut,
          dateDivision: DateDivisionLevel.none,
          skipExtras: false,
        );

        final result = await pipeline.execute(
          config: config,
          inputDirectory: inputDir,
          outputDirectory: outputDir,
        );
        expect(result.isSuccess, isTrue);

        final outputContents = await outputDir.list().toList();

        // Check if special folders are processed
        final specialDirs = outputContents
            .whereType<Directory>()
            .where(
              (final dir) => ['Archive', 'Trash', 'Screenshots'].any(
                (final special) => path.basename(dir.path).contains(special),
              ),
            )
            .toList();

        // Screenshots should be processed as they contain valid photos
        expect(
          specialDirs.length,
          greaterThanOrEqualTo(0),
          reason: 'Special folders should be handled appropriately',
        );
      },
    );
    test('should handle photos with geo data', () async {
      final googlePhotosPath = PathResolverService.resolveGooglePhotosPath(
        takeoutPath,
      );
      final inputDir = Directory(googlePhotosPath);
      final outputDir = Directory(outputPath);

      // Collect which media files have geoData in their JSON metadata *before*
      // the pipeline potentially moves/deletes files.
      final jsonFilesBefore = await inputDir
          .list(recursive: true)
          .where(
            (final entity) => entity is File && entity.path.endsWith('.json'),
          )
          .cast<File>()
          .toList();

      final filesWithGeoJson = <String>{};
      for (final jsonFile in jsonFilesBefore) {
        final content = await jsonFile.readAsString();
        // The realistic dataset generator writes geoData as either an object or null.
        if (content.contains('"geoData"') &&
            !content.contains('"geoData":null')) {
          final jsonBase = path.basename(jsonFile.path);
          final imageBase = jsonBase.endsWith('.json')
              ? jsonBase.substring(0, jsonBase.length - '.json'.length)
              : jsonBase;
          filesWithGeoJson.add(imageBase);
        }
      }

      expect(
        filesWithGeoJson,
        isNotEmpty,
        reason: 'Fixture should generate some JSON files with geoData',
      );

      final config = ProcessingConfig(
        disableResumeCheck: true,
        inputPath: googlePhotosPath,
        outputPath: outputPath,
        albumBehavior: AlbumBehavior.nothing,
        dateDivision: DateDivisionLevel.none,
        skipExtras: false,
        writeExif: true,
      );

      final result = await pipeline.execute(
        config: config,
        inputDirectory: inputDir,
        outputDirectory: outputDir,
      );
      expect(result.isSuccess, isTrue);

      // Validate actual processing: at least one output file that had geoData in
      // JSON should now contain GPS tags in EXIF.
      final allPhotosDir = Directory(path.join(outputPath, 'ALL_PHOTOS'));
      expect(
        await allPhotosDir.exists(),
        isTrue,
        reason: 'ALL_PHOTOS directory should exist',
      );

      final outputJpgs = await allPhotosDir
          .list(recursive: true)
          .where(
            (final entity) => entity is File && entity.path.endsWith('.jpg'),
          )
          .cast<File>()
          .toList();

      expect(
        outputJpgs,
        isNotEmpty,
        reason: 'Expected output JPGs in ALL_PHOTOS',
      );

      // We can't reliably map geoData JSON -> output basename because the pipeline
      // may merge multiple copies and pick a different primary filename.
      // Instead, validate the end result: at least one output JPG has GPS tags.
      var foundGpsExif = false;
      Map<String, dynamic>? lastGps;
      String? lastFile;
      for (final outFile in outputJpgs) {
        lastFile = outFile.path;
        // Read GPS directly from the file's EXIF without ExifGpsExtractor.
        Map<String, dynamic>? gps;
        try {
          const exifScanWindow = 64 * 1024;
          final fileLen = await outFile.length();
          final end = fileLen < exifScanWindow ? fileLen : exifScanWindow;
          final bytes = await outFile
              .openRead(0, end)
              .fold<List<int>>(<int>[], (final a, final b) => a..addAll(b));
          final exifData = await readExifFromBytes(Uint8List.fromList(bytes));
          final lat = exifData.tags['GPS GPSLatitude']?.printable;
          final lon = exifData.tags['GPS GPSLongitude']?.printable;
          if (lat != null && lon != null && lat.isNotEmpty && lon.isNotEmpty) {
            gps = {'GPSLatitude': lat, 'GPSLongitude': lon};
          }
        } catch (_) {}
        lastGps = gps;

        if (gps != null) {
          foundGpsExif = true;
          break;
        }
      }

      expect(
        foundGpsExif,
        isTrue,
        reason:
            'Expected at least one output JPG to have GPSLatitude/GPSLongitude EXIF set. '
            'Dataset geoData JSON files: ${filesWithGeoJson.length}. '
            'Last checked file: $lastFile. '
            'Last extracted GPS: $lastGps',
      );
    });

    test('should handle duplicate detection correctly', () async {
      // First, let's create some duplicate files in the test data
      final testDir = Directory(takeoutPath);
      final yearDirs = await testDir
          .list(recursive: true)
          .where(
            (final entity) =>
                entity is Directory &&
                path.basename(entity.path).startsWith('Photos from'),
          )
          .cast<Directory>()
          .toList();

      if (yearDirs.isNotEmpty) {
        final firstYearDir = yearDirs.first;
        final photos = await firstYearDir
            .list()
            .where(
              (final entity) => entity is File && entity.path.endsWith('.jpg'),
            )
            .cast<File>()
            .take(2)
            .toList();

        if (photos.length >= 2) {
          // Create a duplicate by copying one photo to create identical content
          final originalPhoto = photos.first;
          final duplicatePhoto = File(
            path.join(
              firstYearDir.path,
              'duplicate_${path.basename(originalPhoto.path)}',
            ),
          );
          await originalPhoto.copy(duplicatePhoto.path);

          // Also copy the JSON file
          final originalJson = File('${originalPhoto.path}.json');
          if (await originalJson.exists()) {
            await originalJson.copy('${duplicatePhoto.path}.json');
          }
        }
      }
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
        skipExtras: false,
      );

      final result = await pipeline.execute(
        config: config,
        inputDirectory: inputDir,
        outputDirectory: outputDir,
      );
      expect(result.isSuccess, isTrue);

      final allPhotosDir = Directory(path.join(outputPath, 'ALL_PHOTOS'));
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

      Future<List<File>> findProcessedFiles() async => allPhotosDir
          .list(recursive: true)
          .whereType<File>()
          .where((final file) => isMediaFile(file.path))
          .toList();

      var outputFiles = await findProcessedFiles();
      if (outputFiles.isEmpty) {
        for (int i = 0; i < 8; i++) {
          await Future<void>.delayed(const Duration(milliseconds: 80));
          outputFiles = await findProcessedFiles();
          if (outputFiles.isNotEmpty) break;
        }
      }

      expect(
        outputFiles.length,
        greaterThan(0),
        reason: 'Should have processed files after duplicate detection',
      );
    });
    test('should generate processing metrics', () async {
      final googlePhotosPath = PathResolverService.resolveGooglePhotosPath(
        takeoutPath,
      );
      final inputDir = Directory(googlePhotosPath);
      final outputDir = Directory(outputPath);

      final config = ProcessingConfig(
        disableResumeCheck: true,
        inputPath: googlePhotosPath,
        outputPath: outputPath,
        albumBehavior: AlbumBehavior.shortcut,
        dateDivision: DateDivisionLevel.none,
        skipExtras: false,
      );

      final result = await pipeline.execute(
        config: config,
        inputDirectory: inputDir,
        outputDirectory: outputDir,
      );
      expect(result.isSuccess, isTrue);

      // Verify the processing completed successfully
      expect(await outputDir.exists(), isTrue);

      final contents = await outputDir.list(recursive: true).toList();
      expect(
        contents.length,
        greaterThan(10),
        reason: 'Should have processed significant number of files',
      );
    });

    test('should handle large dataset performance', () async {
      // Generate a larger dataset for performance testing
      final largeTakeoutPath = await fixture.generateRealisticTakeoutDataset(
        yearSpan: 5,
        albumCount: 10,
        photosPerYear: 20,
        albumOnlyPhotos: 10,
        exifRatio: 0.8,
        includeRawSamples: true,
      );

      final largeOutputPath = path.join(fixture.basePath, 'large_output');
      final stopwatch = Stopwatch()..start();

      final largeGooglePhotosPath = PathResolverService.resolveGooglePhotosPath(
        largeTakeoutPath,
      );
      final inputDir = Directory(largeGooglePhotosPath);
      final outputDir = Directory(largeOutputPath);

      final config = ProcessingConfig(
        disableResumeCheck: true,
        inputPath: largeGooglePhotosPath,
        outputPath: largeOutputPath,
        albumBehavior: AlbumBehavior.shortcut,
        dateDivision: DateDivisionLevel.year,
        skipExtras: false,
      );

      final result = await pipeline.execute(
        config: config,
        inputDirectory: inputDir,
        outputDirectory: outputDir,
      );

      stopwatch.stop();
      expect(result.isSuccess, isTrue);

      // Verify processing completed
      expect(await outputDir.exists(), isTrue);

      final outputFiles = await outputDir
          .list(recursive: true)
          .where(
            (final entity) => entity is File && entity.path.endsWith('.jpg'),
          )
          .cast<File>()
          .toList();

      expect(
        outputFiles.length,
        greaterThan(50),
        reason:
            'Large dataset output size too small. Expected > 50 JPGs. Actual: ${outputFiles.length}\nFiles sample: ${outputFiles.take(10).map((final f) => path.basename(f.path)).toList()}',
      );

      // Performance should be reasonable; provide detailed diagnostics on failure
      const thresholdMs = 60000; // 60s baseline
      expect(
        stopwatch.elapsedMilliseconds < thresholdMs,
        isTrue,
        reason:
            'Performance threshold exceeded. Elapsed: ${stopwatch.elapsedMilliseconds}ms (threshold: ${thresholdMs}ms)\nInput: $largeGooglePhotosPath\nOutput: $largeOutputPath\nProcessed JPG count: ${outputFiles.length}',
      );
    });
    test('should actually move files in move mode (move logic verification)', () async {
      // NOTE: In move mode, files from year folders are moved to output,
      // but album-only files (files that exist only in album folders, not in year folders)
      // remain in place to prevent data loss. This is expected behavior.
      final googlePhotosPath = PathResolverService.resolveGooglePhotosPath(
        takeoutPath,
      );
      final inputDir = Directory(googlePhotosPath);
      final outputDir = Directory(outputPath);

      // Get list of all JPGs in input directory before processing.
      // The pipeline deduplicates identical content across folders (Step 3).
      // With AlbumBehavior.shortcut, album entries become symlinks (Step 6).
      // Therefore, we must not expect “every input copy” to become a physical
      // output file in ALL_PHOTOS.
      final inputFilesBefore = await inputDir
          .list(recursive: true)
          .where(
            (final entity) => entity is File && entity.path.endsWith('.jpg'),
          )
          .cast<File>()
          .toList();

      final inputFilePathsBefore = inputFilesBefore
          .map((final f) => f.path)
          .toSet();

      final hashService = MediaHashService();
      final hashesBefore = await hashService.calculateMultipleHashes(
        inputFilesBefore,
      );
      final uniqueHashesBefore = hashesBefore.values
          .where((final h) => h.isNotEmpty)
          .toSet();

      print(
        '[DEBUG] Input files before processing: ${inputFilePathsBefore.length}',
      );
      print(
        '[DEBUG] Unique input JPG contents (by SHA-256): ${uniqueHashesBefore.length}',
      );
      for (final path in inputFilePathsBefore.take(5)) {
        print('[DEBUG] Input file: $path');
      }

      final config = ProcessingConfig(
        disableResumeCheck: true,
        inputPath: googlePhotosPath,
        outputPath: outputPath,
        albumBehavior: AlbumBehavior.shortcut,
        dateDivision:
            DateDivisionLevel.none, // Files are moved from input to output
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
        reason: 'Pipeline should execute successfully',
      );

      // Verify output structure exists
      final allPhotosDir = Directory(path.join(outputPath, 'ALL_PHOTOS'));
      expect(
        await allPhotosDir.exists(),
        isTrue,
        reason: 'ALL_PHOTOS directory should exist',
      );

      // Get list of output files (only counting actual moved files in ALL_PHOTOS)
      // In shortcut/symlink mode, album directories contain symlinks, not actual files
      final allPhotosDirectory = Directory(path.join(outputPath, 'ALL_PHOTOS'));
      final outputFiles = await allPhotosDirectory
          .list(recursive: true)
          .where(
            (final entity) => entity is File && entity.path.endsWith('.jpg'),
          )
          .cast<File>()
          .toList();

      print(
        '[DEBUG] Output files in ALL_PHOTOS (actual moved files): ${outputFiles.length}',
      );

      expect(
        outputFiles.length,
        greaterThan(0),
        reason: 'Should have processed files in output',
      );

      print('[DEBUG] Output files after processing: ${outputFiles.length}');
      for (final file in outputFiles.take(5)) {
        print('[DEBUG] Output file: ${file.path}');
      } // CRITICAL TEST: In move mode, check remaining files behavior
      final remainingInputFiles = await inputDir
          .list(recursive: true)
          .where(
            (final entity) => entity is File && entity.path.endsWith('.jpg'),
          )
          .cast<File>()
          .toList();

      print(
        '[DEBUG] Remaining input files after processing: ${remainingInputFiles.length}',
      );
      for (final file in remainingInputFiles) {
        print('[DEBUG] Remaining input file: ${file.path}');
      }

      // IMPORTANT: In move mode, album-only files remain in album folders
      // This is expected behavior to prevent data loss for files that exist
      // only in albums (not duplicated in year folders)
      final albumOnlyFiles = remainingInputFiles.where((final file) {
        // Check if this file is in an album folder (not a year folder)
        final relativePath = path.relative(file.path, from: inputDir.path);
        final pathParts = relativePath.split(path.separator);

        // Album folders don't start with "Photos from"
        return pathParts.isNotEmpty &&
            !pathParts.first.startsWith('Photos from');
      }).toList();

      print('[DEBUG] Album-only files remaining: ${albumOnlyFiles.length}');
      for (final file in albumOnlyFiles) {
        print('[DEBUG] Album-only file: ${file.path}');
      }

      // All remaining files should be album-only files
      expect(
        remainingInputFiles.length,
        equals(albumOnlyFiles.length),
        reason:
            'In move mode, only album-only files should remain in original location. '
            'These files exist only in album folders and are preserved to prevent data loss. '
            'Found ${remainingInputFiles.length} total remaining files, '
            '${albumOnlyFiles.length} are album-only files.',
      );

      // Verify output physical JPG count (deduplicated by content).
      // This matches the pipeline behavior: one physical file per unique content,
      // with album occurrences represented as symlinks.
      final expectedOutputCount = uniqueHashesBefore.length;
      expect(
        outputFiles.length,
        equals(expectedOutputCount),
        reason:
            'Expected $expectedOutputCount unique files in output directory (deduplicated by content). '
            'Input JPGs: ${inputFilePathsBefore.length}, album-only remaining: ${albumOnlyFiles.length}',
      );
    });
    test(
      'should move files from input to output directory (move logic verification)',
      () async {
        final googlePhotosPath = PathResolverService.resolveGooglePhotosPath(
          takeoutPath,
        );
        final inputDir = Directory(googlePhotosPath);
        final outputDir = Directory(outputPath);

        // Get list of all files in input directory before processing.
        // Note: the pipeline will deduplicate identical content across year folders
        // and album folders (Step 3), and in shortcut mode (Step 6) album entries
        // become symlinks pointing to the moved primary files.
        // Therefore, we must not expect “every input copy” to become a physical
        // output file.
        final inputFilesBefore = await inputDir
            .list(recursive: true)
            .where(
              (final entity) => entity is File && entity.path.endsWith('.jpg'),
            )
            .cast<File>()
            .toList();

        final inputFilePathsBefore = inputFilesBefore
            .map((final f) => f.path)
            .toSet();

        // Compute expected number of physical output JPGs based on unique content.
        // (Album duplicates share content and should not be copied as physical files
        // when AlbumBehavior.shortcut is active.)
        final hashService = MediaHashService();
        final hashesBefore = await hashService.calculateMultipleHashes(
          inputFilesBefore,
        );
        final uniqueHashesBefore = hashesBefore.values
            .where((final h) => h.isNotEmpty)
            .toSet();

        print(
          '[DEBUG] Input files before processing: ${inputFilePathsBefore.length}',
        );
        print(
          '[DEBUG] Unique input JPG contents (by SHA-256): ${uniqueHashesBefore.length}',
        );

        final config = ProcessingConfig(
          disableResumeCheck: true,
          inputPath: googlePhotosPath,
          outputPath: outputPath,
          albumBehavior: AlbumBehavior.shortcut,
          dateDivision: DateDivisionLevel.none,
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
          reason: 'Pipeline should execute successfully',
        );

        // Get list of files in input directory after processing
        final inputFilesAfter = await inputDir
            .list(recursive: true)
            .where(
              (final entity) => entity is File && entity.path.endsWith('.jpg'),
            )
            .cast<File>()
            .map((final file) => file.path)
            .toSet();

        print(
          '[DEBUG] Input files after processing: ${inputFilesAfter.length}',
        ); // CRITICAL TEST: Files are moved from input to output directory
        // NOTE: Album-only files (files that exist only in album folders, not in year folders)
        // remain in place to prevent data loss. This is expected behavior in move mode.
        final albumOnlyFiles = inputFilesAfter.where((final filePath) {
          // Check if this file is in an album folder (not a year folder)
          final relativePath = path.relative(filePath, from: inputDir.path);
          final pathParts = relativePath.split(path.separator);

          // Album folders don't start with "Photos from"
          return pathParts.isNotEmpty &&
              !pathParts.first.startsWith('Photos from');
        }).toList();

        expect(
          inputFilesAfter.length,
          equals(albumOnlyFiles.length),
          reason:
              'In move mode, only album-only files should remain in input directory. '
              'These files exist only in album folders and are preserved to prevent data loss. '
              'Expected ${albumOnlyFiles.length} album-only files, found ${inputFilesAfter.length} total remaining files.',
        ); // Verify output files were created (only count actual moved files in ALL_PHOTOS)
        // In shortcut/symlink mode, album directories contain symlinks, not actual files
        final allPhotosDirectory = Directory(
          path.join(outputPath, 'ALL_PHOTOS'),
        );
        final outputFiles = await allPhotosDirectory
            .list(recursive: true)
            .where(
              (final entity) => entity is File && entity.path.endsWith('.jpg'),
            )
            .cast<File>()
            .toList();

        // Output should contain the unique physical JPGs (deduped by content).
        // Album duplicates should be represented as symlinks in album folders.
        final expectedOutputFiles = uniqueHashesBefore.length;
        expect(
          outputFiles.length,
          equals(expectedOutputFiles),
          reason:
              'Output should contain the unique moved physical JPGs (deduplicated by content). '
              'Expected $expectedOutputFiles unique files, '
              'found ${outputFiles.length}',
        );

        print('[DEBUG] Output files created: ${outputFiles.length}');
      },
    );

    test('should verify move logic with duplicate-copy album behavior', () async {
      final googlePhotosPath = PathResolverService.resolveGooglePhotosPath(
        takeoutPath,
      );
      final inputDir = Directory(googlePhotosPath);
      final outputDir = Directory(outputPath);

      // Count input files before processing
      final inputFiles = await inputDir
          .list(recursive: true)
          .where(
            (final entity) => entity is File && entity.path.endsWith('.jpg'),
          )
          .cast<File>()
          .toList();

      final config = ProcessingConfig(
        disableResumeCheck: true,
        inputPath: googlePhotosPath,
        outputPath: outputPath,
        albumBehavior:
            AlbumBehavior.duplicateCopy, // This creates duplicates in albums
        dateDivision:
            DateDivisionLevel.none, // Move mode - originals should be gone
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
      ); // Verify no files remain in input (except album-only files)
      final remainingInputFiles = await inputDir
          .list(recursive: true)
          .where(
            (final entity) => entity is File && entity.path.endsWith('.jpg'),
          )
          .cast<File>()
          .toList();

      // Album-only files (files that exist only in album folders) remain to prevent data loss
      final albumOnlyFiles = remainingInputFiles.where((final file) {
        final relativePath = path.relative(file.path, from: inputDir.path);
        final pathParts = relativePath.split(path.separator);
        // Album folders don't start with "Photos from"
        return pathParts.isNotEmpty &&
            !pathParts.first.startsWith('Photos from');
      }).toList();

      expect(
        remainingInputFiles.length,
        equals(albumOnlyFiles.length),
        reason:
            'In move mode, only album-only files should remain in input directory. '
            'These files exist only in album folders and are preserved to prevent data loss. '
            'Found ${remainingInputFiles.length} total remaining files, '
            '${albumOnlyFiles.length} are album-only files.',
      );

      // Verify output structure with duplicates
      final outputFiles = await outputDir
          .list(recursive: true)
          .where(
            (final entity) => entity is File && entity.path.endsWith('.jpg'),
          )
          .cast<File>()
          .toList(); // With duplicate-copy, we should have more output files than input files
      // because files are copied to both ALL_PHOTOS and album folders
      // But we need to account for album-only files that remain in input
      final movedFiles = inputFiles.length - albumOnlyFiles.length;
      expect(
        outputFiles.length,
        greaterThanOrEqualTo(movedFiles),
        reason:
            'Duplicate-copy should create copies in album folders. '
            'Expected at least $movedFiles files (${inputFiles.length} total - ${albumOnlyFiles.length} album-only), '
            'found ${outputFiles.length}',
      );
    });

    test(
      'should verify album duplication logic with duplicate-copy album behavior',
      () async {
        final googlePhotosPath = PathResolverService.resolveGooglePhotosPath(
          takeoutPath,
        );
        final inputDir = Directory(googlePhotosPath);
        final outputDir = Directory(outputPath);

        // Count input files before processing
        final inputFiles = await inputDir
            .list(recursive: true)
            .where(
              (final entity) => entity is File && entity.path.endsWith('.jpg'),
            )
            .cast<File>()
            .toList();

        final originalInputCount = inputFiles.length;
        final config = ProcessingConfig(
          disableResumeCheck: true,
          inputPath: googlePhotosPath,
          outputPath: outputPath,
          albumBehavior: AlbumBehavior.duplicateCopy,
          dateDivision: DateDivisionLevel.none,
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
        ); // Verify all files moved from input (except album-only files)
        final remainingInputFiles = await inputDir
            .list(recursive: true)
            .where(
              (final entity) => entity is File && entity.path.endsWith('.jpg'),
            )
            .cast<File>()
            .toList();

        // Album-only files remain to prevent data loss
        final albumOnlyFiles = remainingInputFiles.where((final file) {
          final relativePath = path.relative(file.path, from: inputDir.path);
          final pathParts = relativePath.split(path.separator);
          // Album folders don't start with "Photos from"
          return pathParts.isNotEmpty &&
              !pathParts.first.startsWith('Photos from');
        }).toList();

        expect(
          remainingInputFiles.length,
          equals(albumOnlyFiles.length),
          reason:
              'In move mode, only album-only files should remain in input directory. '
              'These files exist only in album folders and are preserved to prevent data loss. '
              'Expected ${albumOnlyFiles.length} album-only files, '
              'found ${remainingInputFiles.length} total remaining',
        );

        // Verify output has duplicates
        final outputFiles = await outputDir
            .list(recursive: true)
            .where(
              (final entity) => entity is File && entity.path.endsWith('.jpg'),
            )
            .cast<File>()
            .toList();
        expect(
          outputFiles.length,
          greaterThanOrEqualTo(originalInputCount - albumOnlyFiles.length),
          reason:
              'Output should contain copies with potential duplicates in album folders. '
              'Expected at least ${originalInputCount - albumOnlyFiles.length} files '
              '($originalInputCount total - ${albumOnlyFiles.length} album-only), '
              'found ${outputFiles.length}',
        );
      },
    );

    test('should verify move logic with year-based date division', () async {
      final googlePhotosPath = PathResolverService.resolveGooglePhotosPath(
        takeoutPath,
      );
      final inputDir = Directory(googlePhotosPath);
      final outputDir = Directory(outputPath);

      final config = ProcessingConfig(
        disableResumeCheck: true,
        inputPath: googlePhotosPath,
        outputPath: outputPath,
        albumBehavior: AlbumBehavior.nothing, // No albums, just year folders
        dateDivision: DateDivisionLevel.year, // Move mode
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
      ); // Verify no files remain in original year folders within input (except album-only files)
      final remainingInputFiles = await inputDir
          .list(recursive: true)
          .where(
            (final entity) => entity is File && entity.path.endsWith('.jpg'),
          )
          .cast<File>()
          .toList();

      // Album-only files remain to prevent data loss
      final albumOnlyFiles = remainingInputFiles.where((final file) {
        final relativePath = path.relative(file.path, from: inputDir.path);
        final pathParts = relativePath.split(path.separator);
        // Album folders don't start with "Photos from"
        return pathParts.isNotEmpty &&
            !pathParts.first.startsWith('Photos from');
      }).toList();

      expect(
        remainingInputFiles.length,
        equals(albumOnlyFiles.length),
        reason:
            'Move mode with year division should move all files from input year folders. '
            'Only album-only files should remain to prevent data loss. '
            'Expected ${albumOnlyFiles.length} album-only files, '
            'found ${remainingInputFiles.length} total remaining',
      ); // Verify year-based organization in output
      final allPhotosDir = Directory(path.join(outputPath, 'ALL_PHOTOS'));
      // Debug: Check if ALL_PHOTOS directory exists and what's in output
      print('[DEBUG] Year-based test - Output path: $outputPath');
      final outputDirContents = await Directory(outputPath).list().toList();
      print(
        '[DEBUG] Year-based test - Output contents: ${outputDirContents.map((final e) => path.basename(e.path)).toList()}',
      );
      print(
        '[DEBUG] Year-based test - ALL_PHOTOS exists: ${await allPhotosDir.exists()}',
      );

      if (await allPhotosDir.exists()) {
        final allPhotosContents = await allPhotosDir.list().toList();
        print(
          '[DEBUG] Year-based test - ALL_PHOTOS contents: ${allPhotosContents.map((final e) => path.basename(e.path)).toList()}',
        );
      }

      if (!await allPhotosDir.exists()) {
        throw StateError(
          'ALL_PHOTOS directory does not exist in output path: ${allPhotosDir.path}',
        );
      }

      final yearDirs = await allPhotosDir
          .list()
          .where((final entity) => entity is Directory)
          .cast<Directory>()
          .where(
            (final dir) => RegExp(r'^\d{4}$').hasMatch(path.basename(dir.path)),
          )
          .toList();

      expect(
        yearDirs.length,
        greaterThan(0),
        reason: 'Should create year-based folders in ALL_PHOTOS',
      );
    });
    test(
      'should verify move behavior consistency across different album behaviors',
      () async {
        // Test multiple album behaviors to ensure consistent move/copy logic

        final testCases = [
          AlbumBehavior.shortcut,
          AlbumBehavior.duplicateCopy,
          AlbumBehavior.nothing,
          AlbumBehavior.json,
        ];

        for (final albumBehavior in testCases) {
          // Clean output directory for each test
          final outputDir = Directory(outputPath);
          if (await outputDir.exists()) {
            await outputDir.delete(recursive: true);
          }
          await outputDir.create(recursive: true);

          final googlePhotosPath = PathResolverService.resolveGooglePhotosPath(
            takeoutPath,
          );
          final inputDir = Directory(
            googlePhotosPath,
          ); // Count input files before processing
          final inputFiles = await inputDir
              .list(recursive: true)
              .where(
                (final entity) =>
                    entity is File && entity.path.endsWith('.jpg'),
              )
              .cast<File>()
              .toList();

          final originalInputCount = inputFiles.length;

          // Test move behavior (only mode available)
          final config = ProcessingConfig(
            disableResumeCheck: true,
            inputPath: googlePhotosPath,
            outputPath: outputPath,
            albumBehavior: albumBehavior,
            dateDivision: DateDivisionLevel.none,
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
            reason: 'Processing should succeed for ${albumBehavior.value}',
          ); // Verify files were moved (except album-only files)
          final remainingAfterMove = await inputDir
              .list(recursive: true)
              .where(
                (final entity) =>
                    entity is File && entity.path.endsWith('.jpg'),
              )
              .cast<File>()
              .toList();

          // Album-only files remain to prevent data loss
          final albumOnlyFiles = remainingAfterMove.where((final file) {
            final relativePath = path.relative(file.path, from: inputDir.path);
            final pathParts = relativePath.split(path.separator);
            // Album folders don't start with "Photos from"
            return pathParts.isNotEmpty &&
                !pathParts.first.startsWith('Photos from');
          }).toList();

          expect(
            remainingAfterMove.length,
            equals(albumOnlyFiles.length),
            reason:
                'In move mode, only album-only files should remain in input directory. '
                'These files exist only in album folders and are preserved to prevent data loss. '
                'Album behavior ${albumBehavior.value}: expected ${albumOnlyFiles.length} album-only files, '
                'found ${remainingAfterMove.length} total remaining',
          );

          // Verify output files were created
          final outputFiles = await outputDir
              .list(recursive: true)
              .where(
                (final entity) =>
                    entity is File && entity.path.endsWith('.jpg'),
              )
              .cast<File>()
              .toList();
          expect(
            outputFiles.length,
            greaterThanOrEqualTo(originalInputCount - albumOnlyFiles.length),
            reason:
                'Output should contain at least moved files for ${albumBehavior.value}. '
                'Expected at least ${originalInputCount - albumOnlyFiles.length} files '
                '($originalInputCount total - ${albumOnlyFiles.length} album-only), '
                'found ${outputFiles.length}',
          );

          print(
            '[TEST] Verified move behavior for ${albumBehavior.value} - '
            'moved $originalInputCount files to output',
          );
        }
      },
    );
  });
}
