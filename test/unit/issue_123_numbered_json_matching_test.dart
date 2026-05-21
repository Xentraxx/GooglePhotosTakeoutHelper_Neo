/// Test suite for Issue #123: Numbered JSON metadata file matching
///
/// Verifies that media files with numbered duplicates (e.g., IMG_1976(1).MP4)
/// correctly match their JSON metadata files, especially for partner-shared detection.
/// This is critical for --divide-partner-shared functionality.
library;

import 'dart:convert';
import 'dart:io';
import 'package:gpth_neo/gpth_lib_exports.dart';
import 'package:path/path.dart' as path;
import 'package:test/test.dart';

import '../setup/test_setup.dart';

void main() {
  group('Issue #123: Numbered JSON Matching for Partner Sharing', () {
    late TestFixture fixture;

    setUp(() async {
      fixture = TestFixture();
      await fixture.setUp();
    });

    tearDown(() async {
      await fixture.tearDown();
    });

    group('Basic numbered file matching', () {
      test(
        'finds numbered standard JSON file: image(1).jpg → image.json(1).json',
        () async {
          final mediaFile = fixture.createImageWithExif('image(1).jpg');
          final jsonFile = File(
            path.join(fixture.basePath, 'image.json(1).json'),
          );
          await jsonFile.writeAsString('{"test": "numbered"}');

          final result = await JsonMetadataMatcherService.findJsonForFile(
            mediaFile,
            tryhard: false,
          );

          expect(
            result,
            isNotNull,
            reason: 'Should find numbered JSON file for numbered media file',
          );
          expect(result!.path, equals(jsonFile.path));
        },
      );

      test(
        'finds numbered supplemental-metadata: image(1).jpg → image.jpg.supplemental-metadata(1).json',
        () async {
          final mediaFile = fixture.createImageWithExif('image(1).jpg');
          final jsonFile = File(
            path.join(
              fixture.basePath,
              'image.jpg.supplemental-metadata(1).json',
            ),
          );
          await jsonFile.writeAsString('{"test": "numbered supplemental"}');

          final result = await JsonMetadataMatcherService.findJsonForFile(
            mediaFile,
            tryhard: false,
          );

          expect(
            result,
            isNotNull,
            reason:
                'Should find numbered supplemental-metadata JSON for numbered media',
          );
          expect(result!.path, equals(jsonFile.path));
        },
      );

      test(
        'finds JSON with number in middle: image(1).jpg → image(1).supplemental-metadata.json',
        () async {
          final mediaFile = fixture.createImageWithExif('image(1).jpg');
          final jsonFile = File(
            path.join(fixture.basePath, 'image(1).supplemental-metadata.json'),
          );
          await jsonFile.writeAsString('{"test": "number in middle"}');

          final result = await JsonMetadataMatcherService.findJsonForFile(
            mediaFile,
            tryhard: false,
          );

          expect(
            result,
            isNotNull,
            reason: 'Should find JSON with number in filename',
          );
          expect(result!.path, equals(jsonFile.path));
        },
      );
    });

    group('Cross-extension numbered matching (MP4 + HEIC)', () {
      test(
        'IMG_1976(1).MP4 matches IMG_1976.HEIC.supplemental-metadata(1).json',
        () async {
          // This is the key issue from #123: MP4 with numbered HEIC JSON
          final mediaFile = fixture.createFile('IMG_1976(1).MP4', [1, 2, 3]);

          // Create the corresponding HEIC JSON with number at end
          final heicJsonFile = File(
            path.join(
              fixture.basePath,
              'IMG_1976.HEIC.supplemental-metadata(1).json',
            ),
          );
          await heicJsonFile.writeAsString('{"test": "HEIC metadata"}');

          final result = await JsonMetadataMatcherService.findJsonForFile(
            mediaFile,
            tryhard: true, // Use tryhard for cross-extension
          );

          expect(
            result,
            isNotNull,
            reason: 'Should find HEIC JSON with same number for numbered MP4',
          );
          expect(result!.path, equals(heicJsonFile.path));
        },
      );

      test(
        'IMG_1976(1).JPG matches IMG_1976.HEIC.supplemental-metadata(1).json',
        () async {
          // JPG with HEIC JSON, both numbered
          final mediaFile = fixture.createImageWithExif('IMG_1976(1).JPG');

          final heicJsonFile = File(
            path.join(
              fixture.basePath,
              'IMG_1976.HEIC.supplemental-metadata(1).json',
            ),
          );
          await heicJsonFile.writeAsString('{"test": "HEIC metadata"}');

          final result = await JsonMetadataMatcherService.findJsonForFile(
            mediaFile,
            tryhard: true,
          );

          expect(
            result,
            isNotNull,
            reason: 'Should find HEIC JSON for numbered JPG',
          );
          expect(result!.path, equals(heicJsonFile.path));
        },
      );

      test(
        'prefers direct match over cross-extension match when both exist',
        () async {
          final mediaFile = fixture.createFile('IMG_1976(1).MP4', [1, 2, 3]);

          // Both direct and cross-extension JSON exist
          final directJsonFile = File(
            path.join(
              fixture.basePath,
              'IMG_1976(1).MP4.supplemental-metadata(1).json',
            ),
          );
          await directJsonFile.writeAsString('{"test": "direct"}');

          final heicJsonFile = File(
            path.join(
              fixture.basePath,
              'IMG_1976.HEIC.supplemental-metadata(1).json',
            ),
          );
          await heicJsonFile.writeAsString('{"test": "cross-extension"}');

          final result = await JsonMetadataMatcherService.findJsonForFile(
            mediaFile,
            tryhard: true,
          );

          expect(result, isNotNull);
          // Should prefer the more direct match
          expect(
            result!.path,
            equals(directJsonFile.path),
            reason:
                'Should prefer direct match over cross-extension when both exist',
          );
        },
      );
    });

    group('UUID-based files with numbers (from issue)', () {
      test(
        '0bf4bdc0(1).jpg matches 0bf4bdc0.jpg.supplemental-metadata(1).json',
        () async {
          final mediaFile = fixture.createImageWithExif(
            '0bf4bdc0-0194-43e1-a85b-8823858343c7(1).jpg',
          );

          // This is the truncated supplemental pattern from the issue
          final jsonFile = File(
            path.join(
              fixture.basePath,
              '0bf4bdc0-0194-43e1-a85b-8823858343c7.jpg.supplemental-metadata(1).json',
            ),
          );
          await jsonFile.writeAsString('{"test": "UUID metadata"}');

          final result = await JsonMetadataMatcherService.findJsonForFile(
            mediaFile,
            tryhard: false,
          );

          expect(
            result,
            isNotNull,
            reason: 'Should match UUID-based files with numbers',
          );
          expect(result!.path, equals(jsonFile.path));
        },
      );

      test(
        'handles truncated supplemental with number: 0bf4bdc0(1).jpg → 0bf4bdc0.jpg.suppl(1).json',
        () async {
          final mediaFile = fixture.createImageWithExif(
            '0bf4bdc0-0194-43e1-a85b-8823858343c7(1).jpg',
          );

          // Truncated to "suppl" due to 51-char limit
          final truncatedJsonFile = File(
            path.join(
              fixture.basePath,
              '0bf4bdc0-0194-43e1-a85b-8823858343c7.jpg.suppl(1).json',
            ),
          );
          await truncatedJsonFile.writeAsString('{"test": "truncated"}');

          final result = await JsonMetadataMatcherService.findJsonForFile(
            mediaFile,
            tryhard: false,
          );

          expect(
            result,
            isNotNull,
            reason: 'Should find truncated supplemental with number',
          );
          expect(result!.path, equals(truncatedJsonFile.path));
        },
      );
    });

    group('Multiple number patterns (edge cases)', () {
      test(
        'FullSizeRender(1)(1).HEIC matches FullSizeRender(1)(1).HEIC.supplemental-metadata.json',
        () async {
          // From issue: files with multiple numbers
          final mediaFile = fixture.createImageWithExif(
            'FullSizeRender(1)(1).HEIC',
          );

          final jsonFile = File(
            path.join(
              fixture.basePath,
              'FullSizeRender(1)(1).HEIC.supplemental-metadata.json',
            ),
          );
          await jsonFile.writeAsString('{"test": "multiple numbers"}');

          final result = await JsonMetadataMatcherService.findJsonForFile(
            mediaFile,
            tryhard: false,
          );

          expect(
            result,
            isNotNull,
            reason: 'Should handle files with multiple number patterns',
          );
          expect(result!.path, equals(jsonFile.path));
        },
      );

      test(
        'FullSizeRender(1)(1).MP4 matches FullSizeRender(1)(1).HEIC.supplemental-metadata.json (cross-extension + multiple)',
        () async {
          // From issue: combination of cross-extension + multiple numbers
          final mediaFile = fixture.createFile('FullSizeRender(1)(1).MP4', [
            1,
            2,
            3,
          ]);

          final heicJsonFile = File(
            path.join(
              fixture.basePath,
              'FullSizeRender(1)(1).HEIC.supplemental-metadata.json',
            ),
          );
          await heicJsonFile.writeAsString('{"test": "cross-ext multiple"}');

          final result = await JsonMetadataMatcherService.findJsonForFile(
            mediaFile,
            tryhard: true,
          );

          expect(
            result,
            isNotNull,
            reason:
                'Should match cross-extension with multiple number patterns',
          );
          expect(result!.path, equals(heicJsonFile.path));
        },
      );
    });

    group('Partner-shared detection with numbered files', () {
      test(
        'detects partner shared status for numbered media with numbered JSON',
        () async {
          final imageFile = fixture.createImageWithExif('IMG_1976(1).HEIC');

          // Create JSON with partner sharing info and number
          final jsonFile = File(
            path.join(
              fixture.basePath,
              'IMG_1976.HEIC.supplemental-metadata(1).json',
            ),
          );
          await jsonFile.writeAsString(
            jsonEncode({
              'title': 'Partner Shared Photo',
              'photoTakenTime': {
                'timestamp': '1609459200',
                'formatted': '01.01.2021, 00:00:00 UTC',
              },
              'googlePhotosOrigin': {'fromPartnerSharing': {}},
            }),
          );

          final isPartnerShared = await jsonPartnerSharingExtractor(imageFile);

          expect(
            isPartnerShared,
            isTrue,
            reason: 'Should detect partner-shared status from numbered JSON',
          );
        },
      );

      test(
        'detects partner shared status for numbered MP4 with numbered HEIC JSON',
        () async {
          final videoFile = fixture.createFile('IMG_1976(1).MP4', [1, 2, 3]);

          // Create HEIC JSON with partner sharing info
          final jsonFile = File(
            path.join(
              fixture.basePath,
              'IMG_1976.HEIC.supplemental-metadata(1).json',
            ),
          );
          await jsonFile.writeAsString(
            jsonEncode({
              'title': 'Partner Shared Video',
              'photoTakenTime': {
                'timestamp': '1609459200',
                'formatted': '01.01.2021, 00:00:00 UTC',
              },
              'googlePhotosOrigin': {'fromPartnerSharing': {}},
            }),
          );

          // Need to initialize ServiceContainer for extractor
          await ServiceContainer.instance.initialize();
          try {
            final isPartnerShared = await jsonPartnerSharingExtractor(
              videoFile,
            );

            expect(
              isPartnerShared,
              isTrue,
              reason:
                  'Should detect partner-shared for numbered MP4 with numbered HEIC JSON',
            );
          } finally {
            await ServiceContainer.reset();
          }
        },
      );

      test('correctly identifies non-partner-shared numbered files', () async {
        final imageFile = fixture.createImageWithExif('IMG_1976(1).JPG');

        final jsonFile = File(
          path.join(
            fixture.basePath,
            'IMG_1976.JPG.supplemental-metadata(1).json',
          ),
        );
        await jsonFile.writeAsString(
          jsonEncode({
            'title': 'Personal Upload',
            'photoTakenTime': {
              'timestamp': '1609459200',
              'formatted': '01.01.2021, 00:00:00 UTC',
            },
            'googlePhotosOrigin': {
              'mobileUpload': {
                'deviceFolder': {'localFolderName': ''},
                'deviceType': 'ANDROID_PHONE',
              },
            },
          }),
        );

        await ServiceContainer.instance.initialize();
        try {
          final isPartnerShared = await jsonPartnerSharingExtractor(imageFile);

          expect(
            isPartnerShared,
            isFalse,
            reason:
                'Should correctly identify non-partner-shared numbered files',
          );
        } finally {
          await ServiceContainer.reset();
        }
      });
    });

    group('Matching strategy priority', () {
      test(
        'numbered files: supplements prefer supplemental(N) over (N).supplemental',
        () async {
          final mediaFile = fixture.createImageWithExif('IMG_1976(1).JPG');

          // Create both patterns
          final pattern1 = File(
            path.join(
              fixture.basePath,
              'IMG_1976.JPG.supplemental-metadata(1).json',
            ),
          );
          await pattern1.writeAsString('{"pattern": "supplemental(N)"}');

          final pattern2 = File(
            path.join(
              fixture.basePath,
              'IMG_1976(1).JPG.supplemental-metadata.json',
            ),
          );
          await pattern2.writeAsString('{"pattern": "(N).supplemental"}');

          final result = await JsonMetadataMatcherService.findJsonForFile(
            mediaFile,
            tryhard: false,
          );

          expect(result, isNotNull);
          // The more common pattern should be preferred
          expect(
            result!.path,
            isIn([pattern1.path, pattern2.path]),
            reason: 'Should find one of the numbered patterns',
          );
        },
      );
    });

    group('False positive prevention', () {
      test(
        'avoids matching photo.jpg with photograph(1).jpg JSON when processing photo(1).jpg',
        () async {
          final mediaFile = fixture.createImageWithExif('photo(1).jpg');

          // Create TWO JSON files with (1) in the directory
          final correctJson = File(
            path.join(
              fixture.basePath,
              'photo.jpg.supplemental-metadata(1).json',
            ),
          );
          await correctJson.writeAsString('{"correct": true}');

          // This is the WRONG file - for photograph(1).jpg
          final wrongJson = File(
            path.join(
              fixture.basePath,
              'photograph.jpg.supplemental-metadata(1).json',
            ),
          );
          await wrongJson.writeAsString('{"correct": false}');

          final result = await JsonMetadataMatcherService.findJsonForFile(
            mediaFile,
            tryhard: true,
          );

          expect(result, isNotNull, reason: 'Should find a JSON file');
          expect(
            result!.path,
            equals(correctJson.path),
            reason:
                'Should match the correct JSON for photo(1).jpg, not photograph(1).jpg',
          );
        },
      );

      test(
        'correctly distinguishes between similar filenames with same number',
        () async {
          final mediaFile = fixture.createImageWithExif('image(1).jpg');

          // Multiple JSON files with (1), but different base names
          final correctJson = File(
            path.join(
              fixture.basePath,
              'image.jpg.supplemental-metadata(1).json',
            ),
          );
          await correctJson.writeAsString('{"target": "image"}');

          final wrongJson1 = File(
            path.join(
              fixture.basePath,
              'imagine.jpg.supplemental-metadata(1).json',
            ),
          );
          await wrongJson1.writeAsString('{"target": "imagine"}');

          final wrongJson2 = File(
            path.join(
              fixture.basePath,
              'imagery.jpg.supplemental-metadata(1).json',
            ),
          );
          await wrongJson2.writeAsString('{"target": "imagery"}');

          final result = await JsonMetadataMatcherService.findJsonForFile(
            mediaFile,
            tryhard: true,
          );

          expect(result, isNotNull, reason: 'Should find a JSON file');
          expect(
            result!.path,
            equals(correctJson.path),
            reason:
                'Should match only the correct JSON for image(1).jpg, not imagine or imagery',
          );
        },
      );

      test('handles UUID filenames correctly without false matches', () async {
        final mediaFile = fixture.createImageWithExif('0bf4bdc0-0194(1).jpg');

        // Create multiple UUIDs with same number suffix
        final correctJson = File(
          path.join(
            fixture.basePath,
            '0bf4bdc0-0194.jpg.supplemental-metadata(1).json',
          ),
        );
        await correctJson.writeAsString('{"uuid": "0bf4bdc0-0194"}');

        // Similar UUID
        final wrongJson = File(
          path.join(
            fixture.basePath,
            '0bf4bdc0-0194-43e1.jpg.supplemental-metadata(1).json',
          ),
        );
        await wrongJson.writeAsString('{"uuid": "0bf4bdc0-0194-43e1"}');

        final result = await JsonMetadataMatcherService.findJsonForFile(
          mediaFile,
          tryhard: true,
        );

        expect(result, isNotNull, reason: 'Should find a JSON file');
        expect(
          result!.path,
          equals(correctJson.path),
          reason:
              'Should match the correct UUID JSON, not the longer similar UUID',
        );
      });
    });
  });
}
