/// Test suite for TruncatedFilenameFixerService
///
/// Tests the service that fixes truncated filenames by restoring
/// the original filename from the JSON metadata 'title' field.
library;

import 'dart:convert';
import 'dart:io';
import 'package:gpth_neo/gpth_lib_exports.dart';
import 'package:path/path.dart' as path;
import 'package:test/test.dart';
import '../setup/test_setup.dart';

void main() {
  group('TruncatedFilenameFixerService', () {
    late TestFixture fixture;
    late TruncatedFilenameFixerService service;
    late ProcessingContext context;

    /// Helper method to create a JSON metadata file
    File createJsonFile(
      final String name,
      final Map<String, dynamic> metadata,
    ) => fixture.createFile(name, utf8.encode(jsonEncode(metadata)));

    /// Helper method to create sample metadata content with a title
    Map<String, dynamic> createSampleMetadata(final String title) => {
      'title': title,
      'description': 'Sample photo metadata',
      'photoTakenTime': {
        'timestamp': '1640995200', // Jan 1, 2022
      },
    };

    setUp(() async {
      fixture = TestFixture();
      await fixture.setUp();
      service = const TruncatedFilenameFixerService();

      // Create a minimal processing context for tests
      final config = ProcessingConfig(
        inputPath: fixture.basePath,
        outputPath: fixture.basePath,
      );
      context = ProcessingContext(
        config: config,
        mediaCollection: MediaEntityCollection(),
        inputDirectory: Directory(fixture.basePath),
        outputDirectory: Directory(fixture.basePath),
      );
    });

    tearDown(() async {
      await fixture.tearDown();
    });

    group('Basic truncation detection and fixing', () {
      test('fixes truncated filename when title is longer', () async {
        // Create a truncated media file (simulating Google Photos truncation)
        const truncatedName = 'This_is_a_very_long_file';
        const fullName = 'This_is_a_very_long_filename_that_was_truncated';

        final mediaFile = fixture.createImageWithExif('$truncatedName.jpg');
        createJsonFile(
          '$truncatedName.jpg.json',
          createSampleMetadata(fullName),
        );

        // Add to media collection
        context.mediaCollection.add(
          MediaEntity.single(file: FileEntity(sourcePath: mediaFile.path)),
        );

        final summary = await service.fixTruncatedFilenames(context);

        expect(summary.fixedCount, equals(1));

        // Verify file was renamed
        expect(await File(mediaFile.path).exists(), isFalse);
        expect(
          await File(path.join(fixture.basePath, '$fullName.jpg')).exists(),
          isTrue,
        );
        // Verify JSON was also renamed
        expect(
          await File(
            path.join(fixture.basePath, '$fullName.jpg.json'),
          ).exists(),
          isTrue,
        );
        // Verify FileEntity was updated
        expect(
          context.mediaCollection.asList().first.primaryFile.sourcePath,
          equals(path.join(fixture.basePath, '$fullName.jpg')),
        );
      });

      test('does not rename when filename matches title', () async {
        const filename = 'normal_photo';

        final mediaFile = fixture.createImageWithExif('$filename.jpg');
        createJsonFile('$filename.jpg.json', createSampleMetadata(filename));

        context.mediaCollection.add(
          MediaEntity.single(file: FileEntity(sourcePath: mediaFile.path)),
        );

        final summary = await service.fixTruncatedFilenames(context);

        expect(summary.fixedCount, equals(0));
        expect(await mediaFile.exists(), isTrue);
      });

      test(
        'does not rename when current name is not a prefix of title',
        () async {
          // Different filename, not truncated
          const filename = 'different_photo';

          final mediaFile = fixture.createImageWithExif('$filename.jpg');
          createJsonFile(
            '$filename.jpg.json',
            createSampleMetadata('completely_different_name'),
          );

          context.mediaCollection.add(
            MediaEntity.single(file: FileEntity(sourcePath: mediaFile.path)),
          );

          final summary = await service.fixTruncatedFilenames(context);

          expect(summary.fixedCount, equals(0));
          expect(await mediaFile.exists(), isTrue);
        },
      );
    });

    group('Title with extension handling', () {
      test('handles title that includes file extension', () async {
        // Some JSON files have the extension in the title
        const truncatedName = 'Long_photo_name_that';
        const fullNameWithExt = 'Long_photo_name_that_was_truncated.jpg';

        final mediaFile = fixture.createImageWithExif('$truncatedName.jpg');
        createJsonFile(
          '$truncatedName.jpg.json',
          createSampleMetadata(fullNameWithExt),
        );

        context.mediaCollection.add(
          MediaEntity.single(file: FileEntity(sourcePath: mediaFile.path)),
        );

        final summary = await service.fixTruncatedFilenames(context);

        expect(summary.fixedCount, equals(1));

        // Should use the full name from title but keep current extension
        expect(
          await File(
            path.join(
              fixture.basePath,
              'Long_photo_name_that_was_truncated.jpg',
            ),
          ).exists(),
          isTrue,
        );
      });

      test('preserves corrected extension when fixing truncated name', () async {
        // Scenario: Extension was corrected from HEIC to jpg, name was truncated
        // Original: IMG_2367_trunca.HEIC with IMG_2367_trunca.HEIC.supplemental-metadata.json
        // After fixing: IMG_2367_trunca.jpg (extension replaced, supplemental JSON also renamed)
        const truncatedName = 'IMG_2367_trunca';
        const fullName = 'IMG_2367_truncated_full_name';

        // File has .jpg extension (extension was replaced, not appended)
        final mediaFile = fixture.createImageWithExif('$truncatedName.jpg');
        // JSON uses supplemental-metadata pattern (also renamed by Step 1)
        createJsonFile(
          '$truncatedName.jpg.supplemental-metadata.json',
          createSampleMetadata(fullName),
        );

        context.mediaCollection.add(
          MediaEntity.single(file: FileEntity(sourcePath: mediaFile.path)),
        );

        final summary = await service.fixTruncatedFilenames(context);

        expect(summary.fixedCount, equals(1));

        // Should preserve the .jpg extension
        expect(
          await File(path.join(fixture.basePath, '$fullName.jpg')).exists(),
          isTrue,
        );
      });
    });

    group('Supplemental metadata JSON handling', () {
      test('fixes filename with supplemental-metadata.json pattern', () async {
        const truncatedName = 'Vacation_photo_fro';
        const fullName = 'Vacation_photo_from_summer_2023';

        final mediaFile = fixture.createImageWithExif('$truncatedName.jpg');
        createJsonFile(
          '$truncatedName.jpg.supplemental-metadata.json',
          createSampleMetadata(fullName),
        );

        context.mediaCollection.add(
          MediaEntity.single(file: FileEntity(sourcePath: mediaFile.path)),
        );

        final summary = await service.fixTruncatedFilenames(context);

        expect(summary.fixedCount, equals(1));

        // Both files should be renamed
        expect(
          await File(path.join(fixture.basePath, '$fullName.jpg')).exists(),
          isTrue,
        );
        expect(
          await File(
            path.join(
              fixture.basePath,
              '$fullName.jpg.supplemental-metadata.json',
            ),
          ).exists(),
          isTrue,
        );
      });
    });

    group('Edge cases', () {
      test('skips files without JSON metadata', () async {
        final mediaFile = fixture.createImageWithExif('orphan_photo.jpg');

        context.mediaCollection.add(
          MediaEntity.single(file: FileEntity(sourcePath: mediaFile.path)),
        );

        final summary = await service.fixTruncatedFilenames(context);

        expect(summary.fixedCount, equals(0));
        expect(summary.skippedNoJson, equals(1));
      });

      test('skips files with empty title in JSON', () async {
        final mediaFile = fixture.createImageWithExif('photo.jpg');
        createJsonFile('photo.jpg.json', {
          'title': '',
          'photoTakenTime': {'timestamp': '1640995200'},
        });

        context.mediaCollection.add(
          MediaEntity.single(file: FileEntity(sourcePath: mediaFile.path)),
        );

        final summary = await service.fixTruncatedFilenames(context);

        expect(summary.fixedCount, equals(0));
        expect(await mediaFile.exists(), isTrue);
      });

      test('skips files with missing title in JSON', () async {
        final mediaFile = fixture.createImageWithExif('photo.jpg');
        createJsonFile('photo.jpg.json', {
          'photoTakenTime': {'timestamp': '1640995200'},
        });

        context.mediaCollection.add(
          MediaEntity.single(file: FileEntity(sourcePath: mediaFile.path)),
        );

        final summary = await service.fixTruncatedFilenames(context);

        expect(summary.fixedCount, equals(0));
        expect(await mediaFile.exists(), isTrue);
      });

      test('skips when target filename already exists', () async {
        const truncatedName = 'truncated';
        const fullName = 'truncated_full_name';

        fixture.createImageWithExif('$truncatedName.jpg');
        fixture.createImageWithExif('$fullName.jpg'); // Target already exists
        createJsonFile(
          '$truncatedName.jpg.json',
          createSampleMetadata(fullName),
        );

        context.mediaCollection.add(
          MediaEntity.single(
            file: FileEntity(
              sourcePath: path.join(fixture.basePath, '$truncatedName.jpg'),
            ),
          ),
        );

        final summary = await service.fixTruncatedFilenames(context);

        expect(summary.fixedCount, equals(0));
        expect(summary.skippedTargetExists, equals(1));
      });

      test('handles invalid JSON gracefully', () async {
        final mediaFile = fixture.createImageWithExif('photo.jpg');
        fixture.createFile('photo.jpg.json', utf8.encode('invalid json {{{'));

        context.mediaCollection.add(
          MediaEntity.single(file: FileEntity(sourcePath: mediaFile.path)),
        );

        final summary = await service.fixTruncatedFilenames(context);

        expect(summary.fixedCount, equals(0));
        expect(await mediaFile.exists(), isTrue);
      });

      test('handles Unicode filenames', () async {
        const truncatedName = '日本の写真_trun';
        const fullName = '日本の写真_truncated_name';

        final mediaFile = fixture.createImageWithExif('$truncatedName.jpg');
        createJsonFile(
          '$truncatedName.jpg.json',
          createSampleMetadata(fullName),
        );

        context.mediaCollection.add(
          MediaEntity.single(file: FileEntity(sourcePath: mediaFile.path)),
        );

        final summary = await service.fixTruncatedFilenames(context);

        expect(summary.fixedCount, equals(1));
        expect(
          await File(path.join(fixture.basePath, '$fullName.jpg')).exists(),
          isTrue,
        );
      });
    });

    group('Real-world scenarios from Google Photos', () {
      test('fixes typical 51 character truncation', () async {
        // Google Photos often truncates at 51 chars for filename.json
        const truncatedName =
            'My_awesome_vacation_photo_from_summer_202'; // 42 chars
        const fullName =
            'My_awesome_vacation_photo_from_summer_2023_beach'; // 49 chars

        fixture.createImageWithExif('$truncatedName.jpg');
        createJsonFile(
          '$truncatedName.jpg.json',
          createSampleMetadata(fullName),
        );

        context.mediaCollection.add(
          MediaEntity.single(
            file: FileEntity(
              sourcePath: path.join(fixture.basePath, '$truncatedName.jpg'),
            ),
          ),
        );

        final summary = await service.fixTruncatedFilenames(context);

        expect(summary.fixedCount, equals(1));
      });

      test(
        'does not duplicate Pixel suffixes like .PANO, .MP, .NIGHT, .vr',
        () async {
          // Issue #112: PXL_20230518_0954585.PANO.jpg with title
          // PXL_20230518_095458599.PANO.jpg should become
          // PXL_20230518_095458599.PANO.jpg, NOT .PANO.PANO.jpg
          final suffixes = {
            'PANO': 'jpg',
            'NIGHT': 'jpg',
            'MP': 'mp4',
            'vr': 'jpg',
          };
          for (final entry in suffixes.entries) {
            final suffix = entry.key;
            final ext = entry.value;
            const truncated = 'PXL_20230518_0954585';
            const full = 'PXL_20230518_095458599';

            final mediaFile = fixture.createImageWithExif(
              '$truncated.$suffix.$ext',
            );
            createJsonFile(
              '$truncated.$suffix.$ext.json',
              createSampleMetadata('$full.$suffix.$ext'),
            );

            context.mediaCollection.add(
              MediaEntity.single(file: FileEntity(sourcePath: mediaFile.path)),
            );

            final summary = await service.fixTruncatedFilenames(context);
            expect(summary.fixedCount, equals(1));

            // Must NOT have doubled suffix
            final expectedPath = path.join(
              fixture.basePath,
              '$full.$suffix.$ext',
            );
            expect(
              await File(expectedPath).exists(),
              isTrue,
              reason:
                  '.$suffix.$ext should not be duplicated to .$suffix.$suffix.$ext',
            );

            // Clean up for next iteration
            await fixture.tearDown();
            fixture = TestFixture();
            await fixture.setUp();
            context = ProcessingContext(
              config: ProcessingConfig(
                inputPath: fixture.basePath,
                outputPath: fixture.basePath,
              ),
              mediaCollection: MediaEntityCollection(),
              inputDirectory: Directory(fixture.basePath),
              outputDirectory: Directory(fixture.basePath),
            );
          }
        },
      );

      test('handles multiple truncated files in collection', () async {
        // Create multiple truncated files
        final files = [
          {
            'truncated': 'Photo_001_trunca',
            'full': 'Photo_001_truncated_name_here',
          },
          {
            'truncated': 'Photo_002_trunca',
            'full': 'Photo_002_truncated_name_here',
          },
          {
            'truncated': 'Photo_003_trunca',
            'full': 'Photo_003_truncated_name_here',
          },
        ];

        for (final f in files) {
          final mediaFile = fixture.createImageWithExif(
            '${f['truncated']}.jpg',
          );
          createJsonFile(
            '${f['truncated']}.jpg.json',
            createSampleMetadata(f['full']!),
          );
          context.mediaCollection.add(
            MediaEntity.single(file: FileEntity(sourcePath: mediaFile.path)),
          );
        }

        final summary = await service.fixTruncatedFilenames(context);

        expect(summary.fixedCount, equals(3));

        for (final f in files) {
          expect(
            await File(
              path.join(fixture.basePath, '${f['full']}.jpg'),
            ).exists(),
            isTrue,
          );
        }
      });
    });
  });
}
