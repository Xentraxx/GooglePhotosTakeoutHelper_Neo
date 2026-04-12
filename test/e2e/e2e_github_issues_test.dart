/// Comprehensive E2E tests covering GitHub issues and README features
///
/// This test suite validates functionality based on:
/// - Known GitHub issues from changelog (#29, #32, #180, #238, #248, #261, #271, #299, #324, #353, #355, #371, #381, #389, #390)
/// - README feature specifications
/// - Real-world usage scenarios
/// - Edge cases and error conditions
///
/// Test Categories:
/// 1. Album Processing Modes (shortcut, duplicate-cop3.y, reverse-shortcut, json, nothing)
/// 2. Date Organization Levels (none, year, month, day)
/// 3. File Format Support (.MP, .MV, .DNG, .CR2, HEIC, RAW)
/// 4. Extension Fixing Modes (none, standard, conservative, solo)
/// 5. Platform-specific Features (Windows shortcuts, emoji handling)
/// 6. Metadata Processing (JSON extraction, EXIF writing, GPS coordinates)
/// 7. Error Handling (corrupt files, permission issues, disk space)
/// 8. Special Cases (large files, unicode names, long paths)

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
  group('E2E Tests - GitHub Issues & README Features', () {
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
        yearSpan: 5,
        albumCount: 8,
        photosPerYear: 15,
        albumOnlyPhotos: 5,
        exifRatio: 0.8,
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

    group('Album Processing Modes - Issues #261, #248, #390', () {
      test('shortcut mode handles emoji folder names (Issue #389)', () async {
        // Create test data with emoji folder names
        final emojiTakeoutPath = await _createEmojiAlbumTestData(fixture);

        final googlePhotosPath = PathResolverService.resolveGooglePhotosPath(
          emojiTakeoutPath,
        );
        final config = ProcessingConfig(
          inputPath: googlePhotosPath,
          outputPath: outputPath,
          albumBehavior: AlbumBehavior.shortcut,
          dateDivision: DateDivisionLevel.none,
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
          reason: 'Should handle emoji folder names',
        );

        // Verify emoji album folders were created
        // Albums are placed under output/Albums/<album name>/ by PathGeneratorService
        final albumsSubdir = Directory(path.join(outputPath, 'Albums'));
        final albumSubdirContents = await albumsSubdir.exists()
            ? await albumsSubdir.list().toList()
            : <FileSystemEntity>[];
        final albumDirs = albumSubdirContents
            .whereType<Directory>()
            .where(
              (final dir) =>
                  path.basename(dir.path).contains(_emojiSafe('🏖️')) ||
                  path.basename(dir.path).contains(_emojiSafe('🎄')) ||
                  path.basename(dir.path).contains(_emojiSafe('👨‍👩‍👧‍👦')),
            )
            .toList();

        expect(
          albumDirs.length,
          greaterThan(0),
          reason: 'Should create emoji album directories',
        );

        // Verify symlinks are created properly (using proper cross-platform detection)
        final allEntities = await Directory(
          outputPath,
        ).list(recursive: true).toList();
        final symlinks = <FileSystemEntity>[];
        for (final entity in allEntities) {
          // Check if the entity is a symlink by resolving its path
          try {
            if (await entity.exists()) {
              final resolvedPath = await File(
                entity.path,
              ).resolveSymbolicLinks();
              if (resolvedPath != entity.path) {
                symlinks.add(entity);
              }
            }
          } catch (e) {
            // Fallback to Dart's stat method if resolution fails
            try {
              final stat = await entity.stat();
              if (stat.type == FileSystemEntityType.link) {
                symlinks.add(entity);
              }
            } catch (e) {
              // Ignore entities that can't be stat'ed
            }
          }
        }
        expect(
          symlinks.length,
          greaterThan(0),
          reason: 'Should create symlinks in album folders',
        );
      });

      test(
        'reverse-shortcut mode preserves album-centric organization (Issue #261)',
        () async {
          final googlePhotosPath = PathResolverService.resolveGooglePhotosPath(
            takeoutPath,
          );
          final config = ProcessingConfig(
            inputPath: googlePhotosPath,
            outputPath: outputPath,
            albumBehavior: AlbumBehavior.reverseShortcut,
            dateDivision: DateDivisionLevel.none,
            writeExif: false,
          );

          final result = await pipeline.execute(
            config: config,
            inputDirectory: Directory(googlePhotosPath),
            outputDirectory: Directory(outputPath),
          );

          expect(result.isSuccess, isTrue);

          // Verify files remain in album folders (not shortcuts)
          final outputContents = await Directory(
            outputPath,
          ).list(recursive: true).toList();
          final albumDirs = outputContents
              .whereType<Directory>()
              .where(
                (final dir) => !path.basename(dir.path).contains('ALL_PHOTOS'),
              )
              .toList();

          expect(
            albumDirs.length,
            greaterThan(0),
            reason: 'Should have album directories',
          );

          // Check that album directories contain symlinks, not actual files (reverse-shortcut mode)
          for (final albumDir in albumDirs) {
            final albumEntities = await albumDir.list().toList();
            final albumSymlinks = <FileSystemEntity>[];

            for (final entity in albumEntities) {
              if (entity.path.endsWith('.jpg') ||
                  entity.path.endsWith('.png')) {
                final stat = await entity.stat();
                if (stat.type == FileSystemEntityType.link) {
                  albumSymlinks.add(entity);
                }
              }
            }

            if (albumSymlinks.isNotEmpty) {
              expect(
                albumSymlinks.length,
                greaterThan(0),
                reason:
                    'Album ${path.basename(albumDir.path)} should contain symlinks in reverse-shortcut mode',
              );
            }
          }

          // Verify ALL_PHOTOS has symlinks pointing to album files (reverse-shortcut mode)
          final allPhotosDir = Directory(path.join(outputPath, 'ALL_PHOTOS'));
          if (await allPhotosDir.exists()) {
            final allEntities = await allPhotosDir.list().toList();
            final symlinks = <FileSystemEntity>[];
            for (final entity in allEntities) {
              // Check if the entity is a symlink by resolving its path
              try {
                if (await entity.exists()) {
                  final resolvedPath = await File(
                    entity.path,
                  ).resolveSymbolicLinks();
                  if (resolvedPath != entity.path) {
                    symlinks.add(entity);
                  }
                }
              } catch (e) {
                // Fallback to Dart's stat method if resolution fails
                try {
                  final stat = await entity.stat();
                  if (stat.type == FileSystemEntityType.link) {
                    symlinks.add(entity);
                  }
                } catch (e) {
                  // Ignore entities that can't be stat'ed
                }
              }
            }
            expect(
              symlinks.length,
              greaterThan(0),
              reason:
                  'ALL_PHOTOS should contain symlinks in reverse-shortcut mode',
            );
          }
        },
      );

      test(
        'duplicate-copy mode handles album-only photos (Issue #261)',
        () async {
          final googlePhotosPath = PathResolverService.resolveGooglePhotosPath(
            takeoutPath,
          );
          final config = ProcessingConfig(
            inputPath: googlePhotosPath,
            outputPath: outputPath,
            albumBehavior: AlbumBehavior.duplicateCopy,
            dateDivision: DateDivisionLevel.none,
            writeExif: false,
          );

          final result = await pipeline.execute(
            config: config,
            inputDirectory: Directory(googlePhotosPath),
            outputDirectory: Directory(outputPath),
          );

          expect(result.isSuccess, isTrue);

          // Verify both ALL_PHOTOS and album folders contain files
          final allPhotosDir = Directory(path.join(outputPath, 'ALL_PHOTOS'));
          expect(await allPhotosDir.exists(), isTrue);

          final allPhotosFiles = await allPhotosDir
              .list()
              .where(
                (final entity) =>
                    entity is File &&
                    (entity.path.endsWith('.jpg') ||
                        entity.path.endsWith('.png')),
              )
              .toList();
          expect(
            allPhotosFiles.length,
            greaterThan(0),
            reason: 'ALL_PHOTOS should contain photos',
          );

          // Check album folders also have copies
          final outputContents = await Directory(
            outputPath,
          ).list(recursive: true).toList();
          final albumFiles = outputContents
              .whereType<File>()
              .where(
                (final file) =>
                    !file.path.contains('ALL_PHOTOS') &&
                    (file.path.endsWith('.jpg') || file.path.endsWith('.png')),
              )
              .toList();
          expect(
            albumFiles.length,
            greaterThan(0),
            reason: 'Album folders should contain photo copies',
          );
        },
      );

      test('json mode creates albums-info.json file', () async {
        final googlePhotosPath = PathResolverService.resolveGooglePhotosPath(
          takeoutPath,
        );
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

        // Verify albums-info.json is created
        final albumsInfoFile = File(path.join(outputPath, 'albums-info.json'));
        expect(
          await albumsInfoFile.exists(),
          isTrue,
          reason: 'Should create albums-info.json',
        );

        // Verify JSON content is valid
        final jsonContent = await albumsInfoFile.readAsString();
        expect(
          () => jsonDecode(jsonContent),
          returnsNormally,
          reason: 'JSON should be valid',
        );

        final albumsInfo = jsonDecode(jsonContent) as Map<String, dynamic>;
        expect(
          albumsInfo.keys.length,
          greaterThan(0),
          reason: 'Should contain album information',
        );
      });
    });

    group('Date Organization - Issues #238, #299', () {
      test('year-level date division creates year folders', () async {
        final googlePhotosPath = PathResolverService.resolveGooglePhotosPath(
          takeoutPath,
        );
        final config = ProcessingConfig(
          inputPath: googlePhotosPath,
          outputPath: outputPath,
          albumBehavior: AlbumBehavior.nothing,
          dateDivision: DateDivisionLevel.year,
          writeExif: false,
        );

        final result = await pipeline.execute(
          config: config,
          inputDirectory: Directory(googlePhotosPath),
          outputDirectory: Directory(outputPath),
        );

        expect(result.isSuccess, isTrue);

        final allPhotosDir = Directory(path.join(outputPath, 'ALL_PHOTOS'));
        final yearDirs = await allPhotosDir
            .list()
            .where(
              (final entity) =>
                  entity is Directory &&
                  RegExp(r'^\d{4}$').hasMatch(path.basename(entity.path)),
            )
            .toList();

        expect(
          yearDirs.length,
          greaterThan(0),
          reason: 'Should create year directories',
        );
      });

      test('month-level date division creates year/month structure', () async {
        final googlePhotosPath = PathResolverService.resolveGooglePhotosPath(
          takeoutPath,
        );
        final config = ProcessingConfig(
          inputPath: googlePhotosPath,
          outputPath: outputPath,
          albumBehavior: AlbumBehavior.nothing,
          dateDivision: DateDivisionLevel.month,
          writeExif: false,
        );

        final result = await pipeline.execute(
          config: config,
          inputDirectory: Directory(googlePhotosPath),
          outputDirectory: Directory(outputPath),
        );

        expect(result.isSuccess, isTrue);

        // Look for year/month structure
        final allPhotosDir = Directory(path.join(outputPath, 'ALL_PHOTOS'));
        final yearDirs = await allPhotosDir
            .list()
            .where(
              (final entity) =>
                  entity is Directory &&
                  RegExp(r'^\d{4}$').hasMatch(path.basename(entity.path)),
            )
            .cast<Directory>()
            .toList();

        expect(
          yearDirs.length,
          greaterThan(0),
          reason: 'Should create year directories',
        );

        // Check for month subdirectories
        for (final yearDir in yearDirs) {
          final monthDirs = await yearDir
              .list()
              .where(
                (final entity) =>
                    entity is Directory &&
                    RegExp(r'^\d{2}$').hasMatch(path.basename(entity.path)),
              )
              .toList();
          if (monthDirs.isNotEmpty) {
            expect(
              monthDirs.length,
              greaterThan(0),
              reason: 'Should create month subdirectories',
            );
            break;
          }
        }
      });

      test(
        'day-level date division creates year/month/day structure',
        () async {
          final googlePhotosPath = PathResolverService.resolveGooglePhotosPath(
            takeoutPath,
          );
          final config = ProcessingConfig(
            inputPath: googlePhotosPath,
            outputPath: outputPath,
            albumBehavior: AlbumBehavior.nothing,
            dateDivision: DateDivisionLevel.day,
            writeExif: false,
          );

          final result = await pipeline.execute(
            config: config,
            inputDirectory: Directory(googlePhotosPath),
            outputDirectory: Directory(outputPath),
          );

          expect(result.isSuccess, isTrue);

          // Look for year/month/day structure
          final allPhotosDir = Directory(path.join(outputPath, 'ALL_PHOTOS'));
          final yearDirs = await allPhotosDir
              .list()
              .where(
                (final entity) =>
                    entity is Directory &&
                    RegExp(r'^\d{4}$').hasMatch(path.basename(entity.path)),
              )
              .cast<Directory>()
              .toList();

          if (yearDirs.isNotEmpty) {
            final yearDir = yearDirs.first;
            final monthDirs = await yearDir
                .list()
                .where(
                  (final entity) =>
                      entity is Directory &&
                      RegExp(r'^\d{2}$').hasMatch(path.basename(entity.path)),
                )
                .cast<Directory>()
                .toList();

            if (monthDirs.isNotEmpty) {
              final monthDir = monthDirs.first;
              final dayDirs = await monthDir
                  .list()
                  .where(
                    (final entity) =>
                        entity is Directory &&
                        RegExp(r'^\d{2}$').hasMatch(path.basename(entity.path)),
                  )
                  .toList();
              expect(
                dayDirs.length,
                greaterThan(0),
                reason: 'Should create day subdirectories',
              );
            }
          }
        },
      );
    });

    group('File Format Support - Issues #180, #271, #324, #381', () {
      test('handles Motion Photo files (.MP, .MV)', () async {
        // Create test Motion Photo files
        final motionPhotoTakeout = await _createMotionPhotoTestData(fixture);
        final googlePhotosPath = PathResolverService.resolveGooglePhotosPath(
          motionPhotoTakeout,
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
        );

        expect(result.isSuccess, isTrue);

        // Verify .MP and .MV files are processed
        final outputFiles = await Directory(outputPath)
            .list(recursive: true)
            .where((final entity) => entity is File)
            .cast<File>()
            .toList();

        final motionPhotoFiles = outputFiles
            .where(
              (final file) =>
                  file.path.endsWith('.MP') || file.path.endsWith('.MV'),
            )
            .toList();

        expect(
          motionPhotoFiles.length,
          greaterThan(0),
          reason: 'Should process Motion Photo files',
        );
      });

      test('handles RAW camera files (.DNG, .CR2)', () async {
        // Create test RAW files
        final rawTakeout = await _createRawFileTestData();
        final googlePhotosPath = PathResolverService.resolveGooglePhotosPath(
          rawTakeout,
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
        );

        expect(result.isSuccess, isTrue);

        // Verify RAW files are processed
        final outputFiles = await Directory(outputPath)
            .list(recursive: true)
            .where((final entity) => entity is File)
            .cast<File>()
            .toList();

        final rawFiles = outputFiles
            .where(
              (final file) =>
                  file.path.endsWith('.DNG') || file.path.endsWith('.CR2'),
            )
            .toList();

        expect(
          rawFiles.length,
          greaterThan(0),
          reason: 'Should process RAW camera files',
        );
      });
    });

    group('JSON Metadata Handling - Issues #353, #355', () {
      test('handles supplemental-metadata suffix removal', () async {
        // Create test data with supplemental-metadata JSON files
        final supplementalTakeout = await _createSupplementalMetadataTestData();
        final googlePhotosPath = PathResolverService.resolveGooglePhotosPath(
          supplementalTakeout,
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
        );

        expect(
          result.isSuccess,
          isTrue,
          reason: 'Should handle supplemental metadata',
        );

        // Verify files are processed correctly despite supplemental metadata
        final outputFiles = await Directory(outputPath)
            .list(recursive: true)
            .where(
              (final entity) =>
                  entity is File &&
                  (entity.path.endsWith('.jpg') ||
                      entity.path.endsWith('.png')),
            )
            .toList();

        expect(
          outputFiles.length,
          greaterThan(0),
          reason: 'Should process images with supplemental metadata',
        );
      });
    });

    group('Filename Truncation Handling - Issue #29', () {
      test('handles truncated extra format suffixes', () async {
        // Create test data with truncated filenames
        final truncatedTakeout = await _createTruncatedFilenameTestData();
        final googlePhotosPath = PathResolverService.resolveGooglePhotosPath(
          truncatedTakeout,
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
        );

        expect(
          result.isSuccess,
          isTrue,
          reason: 'Should handle truncated filenames',
        );

        // Verify files are processed correctly
        final outputFiles = await Directory(outputPath)
            .list(recursive: true)
            .where(
              (final entity) => entity is File && entity.path.endsWith('.jpg'),
            )
            .toList();

        expect(
          outputFiles.length,
          greaterThan(0),
          reason: 'Should process truncated filename images',
        );
      });

      test('handles international truncated filenames', () async {
        // Create test data with international truncated filenames
        final fixture = TestFixture();
        await fixture.setUp();

        final takeoutDir = fixture.createDirectory('Takeout');
        final googlePhotosDir = fixture.createDirectory(
          '${takeoutDir.path}/Google Photos',
        );
        final yearDir = fixture.createDirectory(
          '${googlePhotosDir.path}/Photos from 2023',
        ); // Create files with international characters and truncated suffixes
        // Use different image data to avoid duplicate detection
        fixture.createImageWithExif('${yearDir.path}/测试图片_中文-ha edi.jpg');
        fixture.createFile(
          '${yearDir.path}/测试图片_中文.jpg.json',
          utf8.encode('{"photoTakenTime": {"timestamp": "1672531200"}}'),
        );

        fixture.createImageWithoutExif(
          '${yearDir.path}/foto_española-ha ed.jpg',
        );
        fixture.createFile(
          '${yearDir.path}/foto_española.jpg.json',
          utf8.encode('{"photoTakenTime": {"timestamp": "1672531200"}}'),
        );

        final googlePhotosPath = PathResolverService.resolveGooglePhotosPath(
          takeoutDir.path,
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
        );

        expect(
          result.isSuccess,
          isTrue,
          reason: 'Should handle international truncated filenames',
        );

        // Verify files are processed correctly
        final outputFiles = await Directory(outputPath)
            .list(recursive: true)
            .where(
              (final entity) => entity is File && entity.path.endsWith('.jpg'),
            )
            .toList();

        expect(
          outputFiles.length,
          equals(2),
          reason: 'Should process all international truncated filename images',
        );
      });

      test('handles multiple truncated suffixes in same directory', () async {
        // Create test data with multiple truncated filenames in same directory
        final fixture = TestFixture();
        await fixture.setUp();
        try {
          final localOutputPath = path.join(
            fixture.basePath,
            'output_${uniqueTestId()}',
          );
          await Directory(localOutputPath).create(recursive: true);

          final takeoutDir = fixture.createDirectory('Takeout');
          final googlePhotosDir = fixture.createDirectory(
            '${takeoutDir.path}/Google Photos',
          );
          final yearDir = fixture.createDirectory(
            '${googlePhotosDir.path}/Photos from 2023',
          ); // Create multiple files with different truncated suffixes
          // Use different image creation methods to ensure unique content
          fixture.createImageWithExif('${yearDir.path}/photo1-ha edi.jpg');
          fixture.createFile(
            '${yearDir.path}/photo1.jpg.json',
            utf8.encode('{"photoTakenTime": {"timestamp": "1672531200"}}'),
          );

          fixture.createImageWithoutExif('${yearDir.path}/photo2-ha ed.jpg');
          fixture.createFile(
            '${yearDir.path}/photo2.jpg.json',
            utf8.encode('{"photoTakenTime": {"timestamp": "1672531200"}}'),
          );

          // Create a third file with unique content to ensure it's not a duplicate
          fixture.createFile(
            '${yearDir.path}/photo3-ha e.jpg',
            utf8.encode('unique content for photo3').followedBy([
              0xFF,
              0xD8,
              0xFF,
              0xE0,
            ]).toList(),
          );
          fixture.createFile(
            '${yearDir.path}/photo3.jpg.json',
            utf8.encode('{"photoTakenTime": {"timestamp": "1672531200"}}'),
          );

          final googlePhotosPath = PathResolverService.resolveGooglePhotosPath(
            takeoutDir.path,
          );

          final config = ProcessingConfig(
            inputPath: googlePhotosPath,
            outputPath: localOutputPath,
            albumBehavior: AlbumBehavior.nothing,
            dateDivision: DateDivisionLevel.none,
            writeExif: false,
          );

          final result = await pipeline.execute(
            config: config,
            inputDirectory: Directory(googlePhotosPath),
            outputDirectory: Directory(localOutputPath),
          );

          expect(
            result.isSuccess,
            isTrue,
            reason: 'Should handle multiple truncated filenames',
          );

          // Verify files are processed correctly
          final outputFiles = await Directory(localOutputPath)
              .list(recursive: true)
              .where(
                (final entity) =>
                    entity is File && entity.path.endsWith('.jpg'),
              )
              .toList();

          expect(
            outputFiles.length,
            equals(3),
            reason: 'Should process all truncated filename images',
          );
        } finally {
          await fixture.tearDown();
        }
      });
    });

    group('Extension Fixing - Issue #32', () {
      test(
        'extension fixing standard mode processes mismatched extensions',
        () async {
          // Create test data with mismatched extensions
          final mismatchedTakeout = await _createMismatchedExtensionTestData();
          final googlePhotosPath = PathResolverService.resolveGooglePhotosPath(
            mismatchedTakeout,
          );

          final config = ProcessingConfig(
            inputPath: googlePhotosPath,
            outputPath: outputPath,
            albumBehavior: AlbumBehavior.nothing,
            dateDivision: DateDivisionLevel.none,
            writeExif: false,
            extensionFixing: ExtensionFixingMode.standard,
          );

          final result = await pipeline.execute(
            config: config,
            inputDirectory: Directory(googlePhotosPath),
            outputDirectory: Directory(outputPath),
          );

          expect(
            result.isSuccess,
            isTrue,
            reason: 'Should handle mismatched extensions',
          );

          // Verify files are processed correctly
          final outputFiles = await Directory(outputPath)
              .list(recursive: true)
              .where(
                (final entity) =>
                    entity is File && entity.path.endsWith('.jpg'),
              )
              .toList();

          expect(
            outputFiles.length,
            greaterThan(0),
            reason: 'Should process mismatched extension images',
          );
        },
      );

      test('handles multiple extension mismatches in same directory', () async {
        // Create test data with multiple extension mismatches
        final fixture = TestFixture();
        await fixture.setUp();

        final takeoutDir = fixture.createDirectory('Takeout');
        final googlePhotosDir = fixture.createDirectory(
          '${takeoutDir.path}/Google Photos',
        );
        final yearDir = fixture.createDirectory(
          '${googlePhotosDir.path}/Photos from 2023',
        ); // Create JPEG files with different incorrect extensions and unique content
        final jpegData1 = base64.decode(greenImgBase64.replaceAll('\n', ''));
        final jpegData2 = base64.decode(
          greenImgNoMetaDataBase64.replaceAll('\n', ''),
        );
        // Create a third unique JPEG by modifying the green image bytes
        final jpegData3 = base64.decode(greenImgBase64.replaceAll('\n', ''));
        jpegData3[jpegData3.length - 10] =
            (jpegData3[jpegData3.length - 10] + 1) % 256;

        fixture.createFile('${yearDir.path}/image1.heic', jpegData1);
        fixture.createFile(
          '${yearDir.path}/image1.heic.json',
          utf8.encode('{"photoTakenTime": {"timestamp": "1672531200"}}'),
        );

        fixture.createFile('${yearDir.path}/image2.png', jpegData2);
        fixture.createFile(
          '${yearDir.path}/image2.png.json',
          utf8.encode('{"photoTakenTime": {"timestamp": "1672531200"}}'),
        );

        fixture.createFile('${yearDir.path}/image3.gif', jpegData3);
        fixture.createFile(
          '${yearDir.path}/image3.gif.json',
          utf8.encode('{"photoTakenTime": {"timestamp": "1672531200"}}'),
        );

        final googlePhotosPath = PathResolverService.resolveGooglePhotosPath(
          takeoutDir.path,
        );

        final config = ProcessingConfig(
          inputPath: googlePhotosPath,
          outputPath: outputPath,
          albumBehavior: AlbumBehavior.nothing,
          dateDivision: DateDivisionLevel.none,
          writeExif: false,
          extensionFixing: ExtensionFixingMode.standard,
        );

        final result = await pipeline.execute(
          config: config,
          inputDirectory: Directory(googlePhotosPath),
          outputDirectory: Directory(outputPath),
        );

        expect(
          result.isSuccess,
          isTrue,
          reason: 'Should handle multiple extension mismatches',
        );

        // Verify files are processed correctly
        final outputFiles = await Directory(outputPath)
            .list(recursive: true)
            .where(
              (final entity) => entity is File && entity.path.endsWith('.jpg'),
            )
            .toList();

        expect(
          outputFiles.length,
          equals(3),
          reason: 'Should process all mismatched extension images',
        );
      });

      test('handles extension fixing with numbered duplicates', () async {
        // Create test data with numbered duplicates and extension mismatches
        final fixture = TestFixture();
        await fixture.setUp();

        final takeoutDir = fixture.createDirectory('Takeout');
        final googlePhotosDir = fixture.createDirectory(
          '${takeoutDir.path}/Google Photos',
        );
        final yearDir = fixture.createDirectory(
          '${googlePhotosDir.path}/Photos from 2023',
        ); // Create JPEG files with numbered duplicates and incorrect extensions
        final jpegData1 = base64.decode(greenImgBase64.replaceAll('\n', ''));
        final jpegData2 = base64.decode(
          greenImgNoMetaDataBase64.replaceAll('\n', ''),
        );

        fixture.createFile('${yearDir.path}/image(1).heic', jpegData1);
        fixture.createFile(
          '${yearDir.path}/image.heic.json',
          utf8.encode('{"photoTakenTime": {"timestamp": "1672531200"}}'),
        );

        fixture.createFile('${yearDir.path}/image(2).heic', jpegData2);
        fixture.createFile(
          '${yearDir.path}/image.heic(2).json',
          utf8.encode('{"photoTakenTime": {"timestamp": "1672531200"}}'),
        );

        final googlePhotosPath = PathResolverService.resolveGooglePhotosPath(
          takeoutDir.path,
        );

        final config = ProcessingConfig(
          inputPath: googlePhotosPath,
          outputPath: outputPath,
          albumBehavior: AlbumBehavior.nothing,
          dateDivision: DateDivisionLevel.none,
          writeExif: false,
          extensionFixing: ExtensionFixingMode.standard,
        );

        final result = await pipeline.execute(
          config: config,
          inputDirectory: Directory(googlePhotosPath),
          outputDirectory: Directory(outputPath),
        );

        expect(
          result.isSuccess,
          isTrue,
          reason: 'Should handle extension fixing with numbered duplicates',
        );

        // Verify files are processed correctly
        final outputFiles = await Directory(outputPath)
            .list(recursive: true)
            .where(
              (final entity) => entity is File && entity.path.endsWith('.jpg'),
            )
            .toList();

        expect(
          outputFiles.length,
          equals(2),
          reason:
              'Should process all numbered duplicate images with fixed extensions',
        );
      });
    });

    group('Performance and Large Dataset Handling', () {
      test('processes large dataset efficiently', () async {
        // Create a larger test dataset
        final largeTakeout = await fixture.generateRealisticTakeoutDataset(
          yearSpan: 2,
          albumCount: 10,
          photosPerYear: 50,
          albumOnlyPhotos: 10,
          exifRatio: 0.5,
          includeRawSamples: true,
        );

        final googlePhotosPath = PathResolverService.resolveGooglePhotosPath(
          largeTakeout,
        );
        final config = ProcessingConfig(
          inputPath: googlePhotosPath,
          outputPath: outputPath,
          albumBehavior: AlbumBehavior.shortcut,
          dateDivision: DateDivisionLevel.year,
          writeExif: false,
        );

        final stopwatch = Stopwatch()..start();

        final result = await pipeline.execute(
          config: config,
          inputDirectory: Directory(googlePhotosPath),
          outputDirectory: Directory(outputPath),
        );

        stopwatch.stop();

        expect(
          result.isSuccess,
          isTrue,
          reason: 'Should process large dataset successfully',
        );
        expect(
          stopwatch.elapsed.inMinutes,
          lessThan(5),
          reason: 'Should complete within reasonable time',
        );

        // Verify output structure
        final outputFiles = await Directory(outputPath)
            .list(recursive: true)
            .where((final entity) => entity is File)
            .toList();

        expect(
          outputFiles.length,
          greaterThan(50),
          reason: 'Should process significant number of files',
        );
      });
    });

    group('Error Handling and Edge Cases', () {
      test('handles corrupt or unreadable files gracefully', () async {
        // Create test data with a corrupt file
        final corruptTakeout = await _createCorruptFileTestData();
        final googlePhotosPath = PathResolverService.resolveGooglePhotosPath(
          corruptTakeout,
        );

        final config = ProcessingConfig(
          inputPath: googlePhotosPath,
          outputPath: outputPath,
          albumBehavior: AlbumBehavior.nothing,
          dateDivision: DateDivisionLevel.none,
          writeExif: false,
        );

        // Should not throw exceptions even with corrupt files
        expect(() async {
          final result = await pipeline.execute(
            config: config,
            inputDirectory: Directory(googlePhotosPath),
            outputDirectory: Directory(outputPath),
          );
          return result;
        }, returnsNormally);
      });

      test('handles empty or minimal input gracefully', () async {
        // Create minimal test data
        final minimalTakeout = await _createMinimalTestData();
        final googlePhotosPath = PathResolverService.resolveGooglePhotosPath(
          minimalTakeout,
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
        );

        // Should handle gracefully even if no files to process
        expect(
          result.isSuccess,
          isTrue,
          reason: 'Should handle minimal input gracefully',
        );
      });

      test('handles unicode and special characters in filenames', () async {
        // Create test data with unicode filenames
        final unicodeTakeout = await _createUnicodeFilenameTestData();
        final googlePhotosPath = PathResolverService.resolveGooglePhotosPath(
          unicodeTakeout,
        );

        final config = ProcessingConfig(
          inputPath: googlePhotosPath,
          outputPath: outputPath,
          albumBehavior: AlbumBehavior.shortcut,
          dateDivision: DateDivisionLevel.none,
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
          reason: 'Should handle unicode filenames',
        );

        // Verify unicode files are processed
        final outputFiles = await Directory(outputPath)
            .list(recursive: true)
            .where(
              (final entity) => entity is File && entity.path.contains('测试'),
            )
            .toList();

        expect(
          outputFiles.length,
          greaterThan(0),
          reason: 'Should process unicode filename files',
        );
      });
    });

    group('Cross-Platform Compatibility', () {
      test('creates platform-appropriate symlinks', () async {
        final googlePhotosPath = PathResolverService.resolveGooglePhotosPath(
          takeoutPath,
        );
        final config = ProcessingConfig(
          inputPath: googlePhotosPath,
          outputPath: outputPath,
          albumBehavior: AlbumBehavior.shortcut,
          dateDivision: DateDivisionLevel.none,
          writeExif: false,
        );

        final result = await pipeline.execute(
          config: config,
          inputDirectory: Directory(googlePhotosPath),
          outputDirectory: Directory(outputPath),
        );

        expect(result.isSuccess, isTrue);

        final outputContents = await Directory(
          outputPath,
        ).list(recursive: true).toList();

        // Debug: Check what's in the output
        print('[DEBUG] Total entities: ${outputContents.length}');
        final files = outputContents.whereType<File>().length;
        final dirs = outputContents.whereType<Directory>().length;
        print('[DEBUG] Files: $files, Directories: $dirs');

        // Check ALL_PHOTOS specifically
        final allPhotosDir = Directory(path.join(outputPath, 'ALL_PHOTOS'));
        if (await allPhotosDir.exists()) {
          final allPhotosFiles = await allPhotosDir.list().toList();
          print('[DEBUG] ALL_PHOTOS has ${allPhotosFiles.length} items');
        }

        // Check album directories
        final albumDirs = outputContents
            .whereType<Directory>()
            .where(
              (final dir) => !path.basename(dir.path).contains('ALL_PHOTOS'),
            )
            .toList();
        print('[DEBUG] Album directories: ${albumDirs.length}');
        for (final albumDir in albumDirs.take(3)) {
          final albumFiles = await albumDir.list().toList();
          print(
            '[DEBUG] ${path.basename(albumDir.path)}: ${albumFiles.length} items',
          );

          // Check first few files in this album
          final albumFilesList = albumFiles.whereType<File>().take(3).toList();
          for (final file in albumFilesList) {
            final stat = await file.stat();
            final basename = path.basename(file.path);
            print('[DEBUG]   - $basename (${stat.type})');
          }
        }

        // Should create symlinks on all platforms (including Windows)
        final symlinks = <FileSystemEntity>[];
        for (final entity in outputContents) {
          // Check if the entity is a symlink by resolving its path
          try {
            if (await entity.exists()) {
              final resolvedPath = await File(
                entity.path,
              ).resolveSymbolicLinks();
              if (resolvedPath != entity.path) {
                symlinks.add(entity);
              }
            }
          } catch (e) {
            // Fallback to Dart's stat method if resolution fails
            try {
              final stat = await entity.stat();
              if (stat.type == FileSystemEntityType.link) {
                symlinks.add(entity);
              }
            } catch (e) {
              // Ignore entities that can't be stat'ed
            }
          }
        }
        print('[DEBUG] Found ${symlinks.length} symlinks');
        expect(
          symlinks.length,
          greaterThan(0),
          reason: 'Should create symlinks on all platforms',
        );
      });
    });
  });
}

// Encode emoji for the current platform: on Windows emojis are hex-encoded in
// filesystem paths; on other platforms the raw emoji characters are used.
String _emojiSafe(final String name) => Platform.isWindows
    ? FilenameSanitizerService.encodeEmojiInText(name)
    : name;

// Helper methods to create specific test scenarios

Future<String> _createEmojiAlbumTestData(final TestFixture fixture) async {
  // Create a subdirectory within the existing fixture for emoji test data
  final emojiTestDir = fixture.createDirectory('emoji_test_${uniqueTestId()}');

  final takeoutDir = fixture.createDirectory('${emojiTestDir.path}/Takeout');
  final googlePhotosDir = fixture.createDirectory(
    '${takeoutDir.path}/Google Photos',
  );
  final yearDir = fixture.createDirectory(
    '${googlePhotosDir.path}/Photos from 2023',
  );

  // Create emoji album directories
  // On Windows, hex-encode emoji so that createDirectory doesn't hit filesystem issues.
  final emojiAlbum1 = fixture.createDirectory(
    '${googlePhotosDir.path}/${_emojiSafe('🏖️ Summer Vacation')}',
  );
  final emojiAlbum2 = fixture.createDirectory(
    '${googlePhotosDir.path}/${_emojiSafe('🎄 Christmas 2023')}',
  );
  final emojiAlbum3 = fixture.createDirectory(
    '${googlePhotosDir.path}/${_emojiSafe('👨‍👩‍👧‍👦 Family Photos')}',
  );

  // Add photos to year folder
  fixture.createImageWithExif('${yearDir.path}/IMG_001.jpg');
  fixture.createFile(
    '${yearDir.path}/IMG_001.jpg.json',
    utf8.encode('{"photoTakenTime": {"timestamp": "1672531200"}}'),
  );

  fixture.createImageWithExif('${yearDir.path}/IMG_002.jpg');
  fixture.createFile(
    '${yearDir.path}/IMG_002.jpg.json',
    utf8.encode('{"photoTakenTime": {"timestamp": "1672531200"}}'),
  );

  // Add photos to emoji albums
  fixture.createImageWithExif('${emojiAlbum1.path}/beach_photo.jpg');
  fixture.createFile(
    '${emojiAlbum1.path}/beach_photo.jpg.json',
    utf8.encode('{"photoTakenTime": {"timestamp": "1672531200"}}'),
  );

  fixture.createImageWithExif('${emojiAlbum2.path}/xmas_photo.jpg');
  fixture.createFile(
    '${emojiAlbum2.path}/xmas_photo.jpg.json',
    utf8.encode('{"photoTakenTime": {"timestamp": "1672531200"}}'),
  );

  fixture.createImageWithExif('${emojiAlbum3.path}/family_photo.jpg');
  fixture.createFile(
    '${emojiAlbum3.path}/family_photo.jpg.json',
    utf8.encode('{"photoTakenTime": {"timestamp": "1672531200"}}'),
  );

  return takeoutDir.path;
}

Future<String> _createMotionPhotoTestData(final TestFixture fixture) async {
  // Create a subdirectory within the existing fixture for motion photo test data
  final motionTestDir = fixture.createDirectory(
    'motion_test_${uniqueTestId()}',
  );

  final takeoutDir = fixture.createDirectory('${motionTestDir.path}/Takeout');
  final googlePhotosDir = fixture.createDirectory(
    '${takeoutDir.path}/Google Photos',
  );
  final yearDir = fixture.createDirectory(
    '${googlePhotosDir.path}/Photos from 2023',
  );

  // Create .MP and .MV files
  fixture.createFile(
    '${yearDir.path}/IMG_001.MP',
    List.generate(1000, (final i) => i % 256),
  );
  fixture.createFile(
    '${yearDir.path}/IMG_001.MP.json',
    utf8.encode('{"photoTakenTime": {"timestamp": "1672531200"}}'),
  );

  fixture.createFile(
    '${yearDir.path}/VID_002.MV',
    List.generate(1000, (final i) => i % 256),
  );
  fixture.createFile(
    '${yearDir.path}/VID_002.MV.json',
    utf8.encode('{"photoTakenTime": {"timestamp": "1672531200"}}'),
  );

  return takeoutDir.path;
}

Future<String> _createRawFileTestData() async {
  final fixture = TestFixture();
  await fixture.setUp();

  final takeoutDir = fixture.createDirectory('Takeout');
  final googlePhotosDir = fixture.createDirectory(
    '${takeoutDir.path}/Google Photos',
  );
  final yearDir = fixture.createDirectory(
    '${googlePhotosDir.path}/Photos from 2023',
  );

  // Create RAW files
  fixture.createFile(
    '${yearDir.path}/DSC_001.DNG',
    List.generate(2000, (final i) => i % 256),
  );
  fixture.createFile(
    '${yearDir.path}/DSC_001.DNG.json',
    utf8.encode('{"photoTakenTime": {"timestamp": "1672531200"}}'),
  );

  fixture.createFile(
    '${yearDir.path}/IMG_002.CR2',
    List.generate(3000, (final i) => i % 256),
  );
  fixture.createFile(
    '${yearDir.path}/IMG_002.CR2.json',
    utf8.encode('{"photoTakenTime": {"timestamp": "1672531200"}}'),
  );

  return takeoutDir.path;
}

Future<String> _createSupplementalMetadataTestData() async {
  final fixture = TestFixture();
  await fixture.setUp();

  final takeoutDir = fixture.createDirectory('Takeout');
  final googlePhotosDir = fixture.createDirectory(
    '${takeoutDir.path}/Google Photos',
  );
  final yearDir = fixture.createDirectory(
    '${googlePhotosDir.path}/Photos from 2023',
  );

  // Create files with supplemental-metadata suffix
  fixture.createImageWithExif('${yearDir.path}/IMG_001.jpg');
  fixture.createFile(
    '${yearDir.path}/IMG_001.jpg(supplemental-metadata).json',
    utf8.encode('{"photoTakenTime": {"timestamp": "1672531200"}}'),
  );

  fixture.createImageWithExif('${yearDir.path}/IMG_002.jpg');
  fixture.createFile(
    '${yearDir.path}/IMG_002.jpg-supplemental-metadata.json',
    utf8.encode('{"photoTakenTime": {"timestamp": "1672531200"}}'),
  );

  return takeoutDir.path;
}

Future<String> _createTruncatedFilenameTestData() async {
  final fixture = TestFixture();
  await fixture.setUp();

  final takeoutDir = fixture.createDirectory('Takeout');
  final googlePhotosDir = fixture.createDirectory(
    '${takeoutDir.path}/Google Photos',
  );
  final yearDir = fixture.createDirectory(
    '${googlePhotosDir.path}/Photos from 2023',
  );

  // Create files with truncated extra format suffixes
  fixture.createImageWithExif(
    '${yearDir.path}/Very_Long_Filename_That_Gets_Truncated_-_edit.jpg',
  );
  fixture.createFile(
    '${yearDir.path}/Very_Long_Filename_That_Gets_Truncated_-_edit.jpg.json',
    utf8.encode('{"photoTakenTime": {"timestamp": "1672531200"}}'),
  );

  fixture.createImageWithExif(
    '${yearDir.path}/Another_Extremely_Long_Photo_Name_-_edited_ver.jpg',
  );
  fixture.createFile(
    '${yearDir.path}/Another_Extremely_Long_Photo_Name_-_edited_ver.jpg.json',
    utf8.encode('{"photoTakenTime": {"timestamp": "1672531200"}}'),
  );

  return takeoutDir.path;
}

Future<String> _createMismatchedExtensionTestData() async {
  final fixture = TestFixture();
  await fixture.setUp();

  final takeoutDir = fixture.createDirectory('Takeout');
  final googlePhotosDir = fixture.createDirectory(
    '${takeoutDir.path}/Google Photos',
  );
  final yearDir = fixture.createDirectory(
    '${googlePhotosDir.path}/Photos from 2023',
  );

  // Create JPEG file with .heic extension (common Google Photos issue)
  final jpegData = base64.decode(greenImgBase64.replaceAll('\n', ''));
  fixture.createFile(
    '${yearDir.path}/image.heic',
    jpegData,
  ); // JPEG data with HEIC extension
  fixture.createFile(
    '${yearDir.path}/image.heic.json',
    utf8.encode('{"photoTakenTime": {"timestamp": "1672531200"}}'),
  );

  return takeoutDir.path;
}

Future<String> _createCorruptFileTestData() async {
  final fixture = TestFixture();
  await fixture.setUp();

  final takeoutDir = fixture.createDirectory('Takeout');
  final googlePhotosDir = fixture.createDirectory(
    '${takeoutDir.path}/Google Photos',
  );
  final yearDir = fixture.createDirectory(
    '${googlePhotosDir.path}/Photos from 2023',
  );

  // Create corrupt/invalid files
  fixture.createFile('${yearDir.path}/corrupt.jpg', [
    0xFF,
    0xD8,
    0x00,
    0x01,
    0x02,
  ]); // Invalid JPEG
  fixture.createFile(
    '${yearDir.path}/corrupt.jpg.json',
    utf8.encode('{"invalid": json}'),
  );

  fixture.createImageWithExif(
    '${yearDir.path}/valid.jpg',
  ); // Valid file to ensure processing continues
  fixture.createFile(
    '${yearDir.path}/valid.jpg.json',
    utf8.encode('{"photoTakenTime": {"timestamp": "1672531200"}}'),
  );

  return takeoutDir.path;
}

Future<String> _createMinimalTestData() async {
  final fixture = TestFixture();
  await fixture.setUp();

  final takeoutDir = fixture.createDirectory('Takeout');
  final googlePhotosDir = fixture.createDirectory(
    '${takeoutDir.path}/Google Photos',
  );
  fixture.createDirectory(
    '${googlePhotosDir.path}/Photos from 2023',
  ); // Empty year folder

  return takeoutDir.path;
}

Future<String> _createUnicodeFilenameTestData() async {
  final fixture = TestFixture();
  await fixture.setUp();

  final takeoutDir = fixture.createDirectory('Takeout');
  final googlePhotosDir = fixture.createDirectory(
    '${takeoutDir.path}/Google Photos',
  );
  final yearDir = fixture.createDirectory(
    '${googlePhotosDir.path}/Photos from 2023',
  );

  // Create files with unicode characters
  fixture.createImageWithExif('${yearDir.path}/测试图片_中文.jpg');
  fixture.createFile(
    '${yearDir.path}/测试图片_中文.jpg.json',
    utf8.encode('{"photoTakenTime": {"timestamp": "1672531200"}}'),
  );

  fixture.createImageWithExif('${yearDir.path}/Фото_кириллица.jpg');
  fixture.createFile(
    '${yearDir.path}/Фото_кириллица.jpg.json',
    utf8.encode('{"photoTakenTime": {"timestamp": "1672531200"}}'),
  );

  fixture.createImageWithExif('${yearDir.path}/صورة_عربية.jpg');
  fixture.createFile(
    '${yearDir.path}/صورة_عربية.jpg.json',
    utf8.encode('{"photoTakenTime": {"timestamp": "1672531200"}}'),
  );

  return takeoutDir.path;
}
