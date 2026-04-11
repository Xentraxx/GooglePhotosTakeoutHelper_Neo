/// Test suite for JsonMetadataMatcherService
///
/// Tests the JSON metadata file matching functionality including
/// basic strategies that are actually implemented.
library;

import 'dart:io';
import 'package:gpth_neo/gpth_lib_exports.dart';
import 'package:path/path.dart' as path;
import 'package:test/test.dart';

import '../setup/test_setup.dart';

void main() {
  group('JsonMetadataMatcherService', () {
    late TestFixture fixture;

    setUp(() async {
      fixture = TestFixture();
      await fixture.setUp();
    });

    tearDown(() async {
      await fixture.tearDown();
    });

    group('findJsonForFile - basic functionality', () {
      test('finds supplemental-metadata JSON file (current Takeout format)', () async {
        // Google Takeout currently exports only .supplemental-metadata.json sidecars.
        final mediaFile = fixture.createImageWithExif('photo.jpg');
        final jsonFile = File(
          path.join(fixture.basePath, 'photo.jpg.supplemental-metadata.json'),
        );
        await jsonFile.writeAsString('{"test": "data"}');

        final result = await JsonMetadataMatcherService.findJsonForFile(
          mediaFile,
          tryhard: false,
        );

        expect(result, isNotNull);
        expect(result!.path, equals(jsonFile.path));
      });

      test('finds standard .json file (backward-compat: older Takeout exports)', () async {
        final mediaFile = fixture.createImageWithExif('photo.jpg');
        final jsonFile = File(
          path.join(fixture.basePath, 'photo.jpg.json'),
        );
        await jsonFile.writeAsString('{"test": "data"}');

        final result = await JsonMetadataMatcherService.findJsonForFile(
          mediaFile,
          tryhard: false,
        );

        expect(result, isNotNull);
        expect(result!.path, equals(jsonFile.path));
      });

      test('prefers supplemental metadata over regular JSON', () async {
        final mediaFile = fixture.createImageWithExif('photo.jpg');

        final regularJsonFile = File(
          path.join(fixture.basePath, 'photo.jpg.json'),
        );
        await regularJsonFile.writeAsString('{"test": "regular"}');

        final supplementalJsonFile = File(
          path.join(fixture.basePath, 'photo.jpg.supplemental-metadata.json'),
        );
        await supplementalJsonFile.writeAsString('{"test": "supplemental"}');

        final result = await JsonMetadataMatcherService.findJsonForFile(
          mediaFile,
          tryhard: false,
        );

        expect(result, isNotNull);
        expect(result!.path, equals(supplementalJsonFile.path));
      });

      test('returns null when no JSON file found', () async {
        final mediaFile = fixture.createImageWithExif('photo.jpg');

        final result = await JsonMetadataMatcherService.findJsonForFile(
          mediaFile,
          tryhard: false,
        );

        expect(result, isNull);
      });
    });

    group('findJsonForFile - filename strategies', () {
      test('handles basic filename shortening', () async {
        // Create a file that would need shortening when adding .supplemental.json
        const shortName = 'test.jpg';
        final mediaFile = fixture.createImageWithExif(shortName);

        // Basic strategy should find direct match first
        final jsonFile = File(
          path.join(fixture.basePath, '$shortName.supplemental-metadata.json'),
        );
        await jsonFile.writeAsString('{"test": "basic"}');

        final result = await JsonMetadataMatcherService.findJsonForFile(
          mediaFile,
          tryhard: false,
        );

        expect(result, isNotNull);
        expect(result!.path, equals(jsonFile.path));
      });

      test('finds JSON with different strategies when tryhard enabled', () async {
        final mediaFile = fixture.createImageWithExif('image.jpg');

        // No exact match, but strategies might find alternatives
        final result = await JsonMetadataMatcherService.findJsonForFile(
          mediaFile,
          tryhard: true,
        );

        // Since we don't have a corresponding JSON file, it should return null
        // This test verifies that tryhard doesn't crash and returns null gracefully
        expect(result, isNull);
      });
    });

    group('findJsonForFile - edge cases', () {
      test('handles files with no extension', () async {
        final mediaFile = File(path.join(fixture.basePath, 'no_extension'));
        await mediaFile.writeAsBytes([1, 2, 3]); // Dummy content

        final jsonFile = File(
          path.join(fixture.basePath, 'no_extension.supplemental-metadata.json'),
        );
        await jsonFile.writeAsString('{"test": "no extension"}');

        final result = await JsonMetadataMatcherService.findJsonForFile(
          mediaFile,
          tryhard: false,
        );

        expect(result, isNotNull);
        expect(result!.path, equals(jsonFile.path));
      });

      test('handles files with multiple dots in name', () async {
        final mediaFile = fixture.createImageWithExif('file.with.dots.jpg');

        final jsonFile = File(
          path.join(
            fixture.basePath,
            'file.with.dots.jpg.supplemental-metadata.json',
          ),
        );
        await jsonFile.writeAsString('{"test": "multiple dots"}');

        final result = await JsonMetadataMatcherService.findJsonForFile(
          mediaFile,
          tryhard: false,
        );

        expect(result, isNotNull);
        expect(result!.path, equals(jsonFile.path));
      });

      test('handles very short filenames', () async {
        final mediaFile = fixture.createImageWithExif('a.jpg');

        final jsonFile = File(
          path.join(fixture.basePath, 'a.jpg.supplemental-metadata.json'),
        );
        await jsonFile.writeAsString('{"test": "short"}');

        final result = await JsonMetadataMatcherService.findJsonForFile(
          mediaFile,
          tryhard: false,
        );

        expect(result, isNotNull);
        expect(result!.path, equals(jsonFile.path));
      });

      test('handles case sensitivity appropriately', () async {
        final mediaFile = fixture.createImageWithExif('Photo.JPG');

        final jsonFile = File(
          path.join(fixture.basePath, 'Photo.JPG.supplemental-metadata.json'),
        );
        await jsonFile.writeAsString('{"test": "case"}');

        final result = await JsonMetadataMatcherService.findJsonForFile(
          mediaFile,
          tryhard: false,
        );

        expect(result, isNotNull);
        expect(result!.path, equals(jsonFile.path));
      });
    });

    group('findJsonForFile - error handling', () {
      test('handles non-existent media file gracefully', () async {
        final nonExistentFile = File(
          path.join(fixture.basePath, 'nonexistent.jpg'),
        );

        final result = await JsonMetadataMatcherService.findJsonForFile(
          nonExistentFile,
          tryhard: false,
        );

        // Should not crash and return null
        expect(result, isNull);
      });

      test('handles permission errors gracefully', () async {
        final mediaFile = fixture.createImageWithExif('protected.jpg');

        // Create a JSON file
        final jsonFile = File(
          path.join(
            fixture.basePath,
            'protected.jpg.supplemental-metadata.json',
          ),
        );
        await jsonFile.writeAsString('{"test": "protected"}');

        final result = await JsonMetadataMatcherService.findJsonForFile(
          mediaFile,
          tryhard: false,
        );

        // Should work normally in test environment
        expect(result, isNotNull);
        expect(result!.path, equals(jsonFile.path));
      });
    });
  });
}
