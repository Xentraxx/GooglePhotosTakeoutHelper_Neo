import 'dart:convert';
import 'dart:io';
import 'package:gpth_neo/gpth_lib_exports.dart';
import 'package:test/test.dart';

import '../setup/test_setup.dart';

void main() {
  group('Extension Fixing and Metadata Matcher Integration Tests - Issue #32', () {
    late TestFixture fixture;

    setUp(() async {
      fixture = TestFixture();
      await fixture.setUp();
    });

    tearDown(() async {
      await fixture.tearDown();
    });

    /// Helper method to create a JSON metadata file
    File createJsonFile(
      final String name,
      final Map<String, dynamic> metadata,
    ) => fixture.createFile(name, utf8.encode(jsonEncode(metadata)));

    /// Helper method to create sample metadata content
    Map<String, dynamic> createSampleMetadata(final String title) => {
      'title': title,
      'description': 'Sample photo metadata',
      'photoTakenTime': {
        'timestamp': '1640995200', // Jan 1, 2022
      },
      'geoData': {'latitude': 37.7749, 'longitude': -122.4194},
    };

    group('Extension Fixing Scenarios from Issue #32', () {
      test('finds JSON after extension is fixed from HEIC to jpg', () async {
        // Scenario: Original HEIC file gets extension fixed (replaced) to .jpg
        // Original: IMG_2367.HEIC with IMG_2367.HEIC.supplemental-metadata.json
        // After fixing: IMG_2367.jpg (extension replaced, supplemental JSON also renamed)

        final jsonFile = createJsonFile(
          'IMG_2367.jpg.supplemental-metadata.json',
          createSampleMetadata('Original HEIC photo'),
        );

        // Simulate the file after extension fixing (HEIC -> jpg, extension replaced)
        final fixedMediaFile = fixture.createImageWithExif('IMG_2367.jpg');

        // Should find the JSON with the updated supplemental-metadata name
        final result = await jsonForFile(fixedMediaFile, tryhard: false);
        expect(result?.path, equals(jsonFile.path));
      });

      test('finds JSON for numbered duplicate after extension fixing', () async {
        // Scenario: IMG_2367(1).HEIC -> IMG_2367(1).jpg (extension replaced)
        // JSON: IMG_2367.jpg.supplemental-metadata(1).json (supplemental also renamed)

        final jsonFile = createJsonFile(
          'IMG_2367.jpg.supplemental-metadata(1).json',
          createSampleMetadata('Duplicate HEIC photo'),
        );

        final fixedMediaFile = fixture.createImageWithExif('IMG_2367(1).jpg');

        final result = await jsonForFile(fixedMediaFile, tryhard: false);
        expect(result?.path, equals(jsonFile.path));
      });

      test('finds JSON for MP4 files with HEIC-based JSON names', () async {
        // Scenario: MP4 file shares JSON with HEIC file
        // MP4: IMG_2367.MP4
        // JSON: IMG_2367.HEIC.supplemental-metadata.json (shared)

        final jsonFile = createJsonFile(
          'IMG_2367.HEIC.supplemental-metadata.json',
          createSampleMetadata('Shared HEIC/MP4 metadata'),
        );

        final mp4File = fixture.createFile('IMG_2367.MP4', []);

        final result = await jsonForFile(mp4File, tryhard: true);
        expect(result?.path, equals(jsonFile.path));
      });

      test('handles complex numbered duplicates with extension fixing', () async {
        // Complex scenario from issue #32:
        // Original files: IMG_2367(1).HEIC, IMG_2367(1).MP4
        // After fixing: IMG_2367(1).jpg (extension replaced), IMG_2367(1).MP4 (unchanged)
        // JSON supplemental also renamed: IMG_2367.jpg.supplemental-metadata(1).json

        final heicJsonFile = createJsonFile(
          'IMG_2367.jpg.supplemental-metadata(1).json',
          createSampleMetadata('HEIC duplicate metadata'),
        );

        final mp4JsonFile = createJsonFile(
          'IMG_2367.MP4.supplemental-metadata(1).json',
          createSampleMetadata('MP4 duplicate metadata'),
        );

        // Test the fixed HEIC file (extension replaced, not appended)
        final fixedHeicFile = fixture.createImageWithExif('IMG_2367(1).jpg');
        final heicResult = await jsonForFile(fixedHeicFile, tryhard: false);
        expect(heicResult?.path, equals(heicJsonFile.path));

        // Test the MP4 file (unchanged)
        final mp4File = fixture.createFile('IMG_2367(1).MP4', []);
        final mp4Result = await jsonForFile(mp4File, tryhard: false);
        expect(mp4Result?.path, equals(mp4JsonFile.path));
      });

      test(
        'handles extension fixing with PhotoMigrator-created JSON files',
        () async {
          // Scenario mentioned in issue: PhotoMigrator creates additional JSON files
          // Original: IMG_2367.HEIC, IMG_2367.MP4
          // After extension fixing: IMG_2367.jpg (extension replaced)
          // Supplemental JSONs also renamed by Step 1

          final heicJsonFile = createJsonFile(
            'IMG_2367.jpg.supplemental-metadata.json',
            createSampleMetadata('Original HEIC metadata'),
          );

          final mp4JsonFile = createJsonFile(
            'IMG_2367.MP4.supplemental-metadata.json',
            createSampleMetadata('PhotoMigrator-created MP4 metadata'),
          );

          // Test the fixed HEIC file should find its renamed JSON
          final fixedHeicFile = fixture.createImageWithExif('IMG_2367.jpg');
          final heicResult = await jsonForFile(fixedHeicFile, tryhard: false);
          expect(heicResult?.path, equals(heicJsonFile.path));

          // Test the MP4 file should find its JSON
          final mp4File = fixture.createFile('IMG_2367.MP4', []);
          final mp4Result = await jsonForFile(mp4File, tryhard: false);
          expect(mp4Result?.path, equals(mp4JsonFile.path));
        },
      );
    });

    group('Strategy Order Validation Tests', () {
      test('verifies strategy order is from most to least likely', () async {
        // Test that basic strategies are ordered correctly
        final basicStrategies = JsonMetadataMatcherService.getAllStrategies(
          includeAggressive: false,
        );
        expect(basicStrategies.length, equals(6));
        expect(basicStrategies[0].name, equals('No modification'));
        expect(basicStrategies[1].name, equals('Filename shortening'));
        expect(basicStrategies[2].name, equals('Bracket number swapping'));
        expect(basicStrategies[3].name, equals('Remove file extension'));
        expect(
          basicStrategies[4].name,
          equals('Remove complete extra formats'),
        );
        expect(basicStrategies[5].name, equals('MP file JSON matching'));
      });
      test(
        'verifies aggressive strategies are appropriately ordered',
        () async {
          final allStrategies = JsonMetadataMatcherService.getAllStrategies(
            includeAggressive: true,
          );
          expect(allStrategies.length, equals(10)); // 6 basic + 4 aggressive
          expect(allStrategies[6].name, equals('Cross-extension matching'));
          expect(allStrategies[7].name, equals('Remove partial extra formats'));
          expect(
            allStrategies[8].name,
            equals('Extension restoration after partial removal'),
          );
          expect(allStrategies[9].name, equals('Edge case pattern removal'));
        },
      );

      test('tests strategy effectiveness order with real scenarios', () async {
        // Create a scenario where multiple strategies could match
        // but we want to ensure the most conservative one wins

        // Create files that would match multiple strategies
        final primaryJsonFile = createJsonFile(
          'photo.jpg.supplemental-metadata.json',
          createSampleMetadata('Primary match - no modification'),
        );

        final bracketJsonFile = createJsonFile(
          'photo.jpg(1).supplemental-metadata.json',
          createSampleMetadata('Bracket swap match'),
        );

        final mediaFile = fixture.createImageWithExif('photo.jpg');

        // Should find the primary match (Strategy 1: No modification)
        final result = await jsonForFile(mediaFile, tryhard: false);
        expect(result?.path, equals(primaryJsonFile.path));
        expect(result?.path, isNot(equals(bracketJsonFile.path)));
      });

      test(
        'tests that extension removal strategy works for fixed files',
        () async {
          // Test Strategy 4: Remove file extension
          // After extension fixing, supplemental JSON is also renamed,
          // so standard matching finds it directly

          final jsonFile = createJsonFile(
            'IMG_2367.jpg.supplemental-metadata.json',
            createSampleMetadata('Extension removal test'),
          );

          // Simulate extension-fixed file (extension replaced, not appended)
          final fixedFile = fixture.createImageWithExif('IMG_2367.jpg');

          // Should find JSON via standard matching
          final result = await jsonForFile(fixedFile, tryhard: false);
          expect(result?.path, equals(jsonFile.path));
        },
      );

      test(
        'validates that bracket swapping works with extension fixing',
        () async {
          // Combined test: bracket swapping + extension fixing
          // File: IMG_2367(1).jpg (after extension replacement)
          // JSON: IMG_2367.jpg(1).supplemental-metadata.json (bracket swapped pattern)

          final jsonFile = createJsonFile(
            'IMG_2367.jpg(1).supplemental-metadata.json',
            createSampleMetadata('Bracket swap with extension fixing'),
          );

          final fixedFile = fixture.createImageWithExif('IMG_2367(1).jpg');

          // Should find JSON through bracket swapping
          final result = await jsonForFile(fixedFile, tryhard: false);
          expect(result?.path, equals(jsonFile.path));
        },
      );
    });

    group('Edge Cases and Robustness Tests', () {
      test('handles case sensitivity issues', () async {
        // Test case variations that might occur during extension fixing

        final jsonFile = createJsonFile(
          'Photo.jpg.supplemental-metadata.json',
          createSampleMetadata('Case sensitivity test'),
        );

        final fixedFile = fixture.createImageWithExif('Photo.jpg');

        final result = await jsonForFile(fixedFile, tryhard: false);
        expect(result?.path, equals(jsonFile.path));
      });

      test('supplemental-metadata is found when it is the only sidecar', () async {
        // Real-world: Google Takeout only creates supplemental-metadata.json.
        // Standard .json and supplemental never coexist for the same file.

        final supplementalJsonFile = createJsonFile(
          'photo.jpg.supplemental-metadata.json',
          createSampleMetadata('Supplemental metadata'),
        );

        final mediaFile = fixture.createImageWithExif('photo.jpg');

        final result = await jsonForFile(mediaFile, tryhard: false);
        expect(result?.path, equals(supplementalJsonFile.path));
      });
      test('handles filename truncation in supplemental-metadata files', () async {
        // Test Google Photos 51-character limit handling
        // Create a filename that would result in truncation when supplemental-metadata is added
        // Base name needs to be short enough to allow meaningful truncation
        // 23 chars + .jpg (4) + . (1) + supplemental-meta (16) + .json (5) = 49 chars

        const baseName = 'filename_for_truncation'; // 23 chars
        final jsonFile = createJsonFile(
          '$baseName.jpg.supplemental-meta.json', // Truncated version
          createSampleMetadata('Truncated supplemental metadata'),
        );

        final mediaFile = fixture.createImageWithExif('$baseName.jpg');

        final result = await jsonForFile(mediaFile, tryhard: false);
        expect(result?.path, equals(jsonFile.path));
      });
    });

    group('Regression Tests for Known Issues', () {
      test(
        'ensures no false positives from overly aggressive matching',
        () async {
          // Test that we don't match unrelated JSON files

          createJsonFile(
            'different_photo.jpg.json',
            createSampleMetadata('Wrong photo metadata'),
          );

          final mediaFile = fixture.createImageWithExif('target_photo.jpg');

          final result = await jsonForFile(mediaFile, tryhard: true);
          expect(result, isNull);
        },
      );

      test(
        'handles special characters in filenames after extension fixing',
        () async {
          // Test files with special characters that might be affected by extension fixing

          final jsonFile = createJsonFile(
            'Fin de año 2023.jpg.supplemental-metadata.json',
            createSampleMetadata('Special characters test'),
          );

          final fixedFile = fixture.createImageWithExif('Fin de año 2023.jpg');

          final result = await jsonForFile(fixedFile, tryhard: false);
          expect(result?.path, equals(jsonFile.path));
        },
      );
    });

    group('Duplicate (N) suffix JSON matching — BUG 4 fix', () {
      test(
        'matches (1) duplicate when filename has multiple (N) groups',
        () async {
          // Scenario: Google Takeout creates "Käfersteige (10)(1).jpg" where
          // (10) is part of the original name and (1) is the duplicate marker.
          // The JSON is "Käfersteige (10).jpg.supplemental-metadata(1).json".
          final jsonFile = createJsonFile(
            'photo (10).jpg.supplemental-metadata(1).json',
            createSampleMetadata('Duplicate with multiple brackets'),
          );

          final mediaFile = fixture.createImageWithExif('photo (10)(1).jpg');

          final result = await jsonForFile(mediaFile, tryhard: false);
          expect(result?.path, equals(jsonFile.path));
        },
      );

      test(
        'matches (2) duplicate when filename has content (N) and dupe (N)',
        () async {
          // "DSC_0048_49_50_tonemapped(1).jpg" — (1) is the duplicate marker.
          // JSON: "DSC_0048_49_50_tonemapped.jpg.supplemental-metadata(1).json"
          final jsonFile = createJsonFile(
            'DSC_0048_49_50_tonemapped.jpg.supplemental-metadata(1).json',
            createSampleMetadata('Tonemapped duplicate'),
          );

          final mediaFile = fixture.createImageWithExif(
            'DSC_0048_49_50_tonemapped(1).jpg',
          );

          final result = await jsonForFile(mediaFile, tryhard: false);
          expect(result?.path, equals(jsonFile.path));
        },
      );

      test(
        'still matches simple (1) duplicate without multiple brackets',
        () async {
          // Simple case: "photo(1).jpg" with "photo.jpg.supplemental-metadata(1).json"
          final jsonFile = createJsonFile(
            'photo.jpg.supplemental-metadata(1).json',
            createSampleMetadata('Simple duplicate'),
          );

          final mediaFile = fixture.createImageWithExif('photo(1).jpg');

          final result = await jsonForFile(mediaFile, tryhard: false);
          expect(result?.path, equals(jsonFile.path));
        },
      );

      test('matches numbered duplicate with middle pattern', () async {
        // JSON has number in middle: "photo(1).supplemental-metadata.json"
        final jsonFile = createJsonFile(
          'photo(1).supplemental-metadata.json',
          createSampleMetadata('Middle pattern duplicate'),
        );

        final mediaFile = fixture.createImageWithExif('photo(1).jpg');

        final result = await jsonForFile(mediaFile, tryhard: false);
        expect(result?.path, equals(jsonFile.path));
      });

      test('prefers direct match over numbered duplicate match', () async {
        // If both direct and numbered JSON exist, direct should win
        final directJsonFile = createJsonFile(
          'photo(1).jpg.supplemental-metadata.json',
          createSampleMetadata('Direct match'),
        );

        // Also create the numbered variant
        createJsonFile(
          'photo.jpg.supplemental-metadata(1).json',
          createSampleMetadata('Numbered match'),
        );

        final mediaFile = fixture.createImageWithExif('photo(1).jpg');

        final result = await jsonForFile(mediaFile, tryhard: false);
        // Strategy 1 (no modification) should find the direct match first
        expect(result?.path, equals(directJsonFile.path));
      });

      test('handles triple bracket pattern like photo (3)(5)(1).jpg', () async {
        // Edge case: three bracket groups, last one is duplicate marker
        final jsonFile = createJsonFile(
          'photo (3)(5).jpg.supplemental-metadata(1).json',
          createSampleMetadata('Triple bracket'),
        );

        final mediaFile = fixture.createImageWithExif('photo (3)(5)(1).jpg');

        final result = await jsonForFile(mediaFile, tryhard: false);
        expect(result?.path, equals(jsonFile.path));
      });

      test(
        'coexisting originals and numbered duplicates each find their own JSON',
        () async {
          // Real-world scenario photographed from a Google Takeout export:
          //   _DSC1166.JPG          → _DSC1166.JPG.supplemental-metadata.json
          //   _DSC1166(1).jpg       → _DSC1166.jpg.supplemental-metadata(1).json
          //   _DSC1166.ARW          → _DSC1166.ARW.supplemental-metadata.json
          //
          // Verifies that:
          //   1. The plain file does NOT accidentally match the numbered JSON.
          //   2. The (1) duplicate does NOT steal the plain file's JSON.
          //   3. A different-extension file (ARW) finds its own JSON unaffected.

          // Create all six files in the same directory
          final jpgJson = createJsonFile(
            '_DSC1166.JPG.supplemental-metadata.json',
            createSampleMetadata('Original JPG'),
          );
          final jpgNumberedJson = createJsonFile(
            '_DSC1166.jpg.supplemental-metadata(1).json',
            createSampleMetadata('Duplicate JPG'),
          );
          final arwJson = createJsonFile(
            '_DSC1166.ARW.supplemental-metadata.json',
            createSampleMetadata('RAW file'),
          );

          final jpg = fixture.createImageWithExif('_DSC1166.JPG');
          final jpgDuplicate = fixture.createImageWithExif('_DSC1166(1).jpg');
          final arw = fixture.createFile('_DSC1166.ARW', [1, 2, 3]);

          // Each file must find exactly its own JSON
          expect(
            (await jsonForFile(jpg, tryhard: false))?.path,
            equals(jpgJson.path),
            reason: '_DSC1166.JPG should match its own plain JSON',
          );
          expect(
            (await jsonForFile(jpgDuplicate, tryhard: false))?.path,
            equals(jpgNumberedJson.path),
            reason: '_DSC1166(1).jpg should match the (1) numbered JSON',
          );
          expect(
            (await jsonForFile(arw, tryhard: false))?.path,
            equals(arwJson.path),
            reason: '_DSC1166.ARW should match its own ARW JSON',
          );
        },
      );
    });
  });
}
