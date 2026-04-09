/// Test to verify file synchronization fixes
///
/// This test specifically checks for race conditions that could lead to
/// PathNotFoundException errors in the test suite.
library;

import 'dart:io';
import 'package:test/test.dart';
import '../setup/test_setup.dart';

void main() {
  group('File Synchronization Test', () {
    late TestFixture fixture;

    setUp(() async {
      fixture = TestFixture();
      await fixture.setUp();
    });

    tearDown(() async {
      await fixture.tearDown();
    });

    test('files are immediately accessible after creation', () async {
      // Create multiple files in quick succession
      final files = <File>[];

      for (int i = 0; i < 10; i++) {
        final file = fixture.createFile('test_$i.jpg', [i, i + 1, i + 2]);
        files.add(file);

        // Verify file is immediately accessible
        expect(
          file.existsSync(),
          isTrue,
          reason: 'File test_$i.jpg should exist immediately after creation',
        );
        expect(
          file.lengthSync(),
          greaterThan(0),
          reason: 'File test_$i.jpg should have content',
        );
      }

      // Verify all files are still accessible
      for (int i = 0; i < files.length; i++) {
        final file = files[i];
        expect(
          file.existsSync(),
          isTrue,
          reason: 'File ${file.path} should still exist',
        );
        expect(
          file.readAsBytesSync(),
          equals([i, i + 1, i + 2]),
          reason: 'File ${file.path} should have correct content',
        );
      }
    });

    test('image files with EXIF are immediately accessible', () async {
      // Create multiple image files in quick succession
      final files = <File>[];

      for (int i = 0; i < 5; i++) {
        final file = fixture.createImageWithExif('image_$i.jpg');
        files.add(file);

        // Verify file is immediately accessible and has content
        expect(
          file.existsSync(),
          isTrue,
          reason: 'Image image_$i.jpg should exist immediately',
        );
        expect(
          file.lengthSync(),
          greaterThan(100),
          reason: 'Image image_$i.jpg should have substantial content',
        );
      }

      // Verify all files are still accessible
      for (final file in files) {
        expect(
          file.existsSync(),
          isTrue,
          reason: 'Image ${file.path} should still exist',
        );
        final content = file.readAsBytesSync();
        expect(
          content.length,
          greaterThan(100),
          reason: 'Image ${file.path} should maintain its content',
        );
      }
    });

    test('JSON files are immediately accessible', () async {
      // Create multiple JSON files in quick succession
      final files = <File>[];

      for (int i = 0; i < 5; i++) {
        final timestamp = 1600000000 + i * 1000;
        final file = fixture.createJsonFile(
          'metadata_$i.json',
          photoTakenTimestamp: timestamp.toString(),
          includeExtendedFields: true,
        );
        files.add(file);

        // Verify file is immediately accessible
        expect(
          file.existsSync(),
          isTrue,
          reason: 'JSON metadata_$i.json should exist immediately',
        );
        expect(
          file.lengthSync(),
          greaterThan(10),
          reason: 'JSON metadata_$i.json should have content',
        );
      }

      // Verify all files can be read as JSON
      for (int i = 0; i < files.length; i++) {
        final file = files[i];
        expect(
          file.existsSync(),
          isTrue,
          reason: 'JSON ${file.path} should still exist',
        );

        final content = file.readAsStringSync();
        expect(
          content.contains('photoTakenTime'),
          isTrue,
          reason: 'JSON ${file.path} should contain expected structure',
        );
      }
    });

    test('files in subdirectories are immediately accessible', () async {
      // Create files in nested directory structure
      final albumDir = fixture.createDirectory('TestAlbum');
      final files = <File>[];

      for (int i = 0; i < 3; i++) {
        final file = fixture.createImageWithExifInDir(
          albumDir.path,
          'album_photo_$i.jpg',
        );
        files.add(file);

        // Verify file is immediately accessible
        expect(
          file.existsSync(),
          isTrue,
          reason: 'Album photo album_photo_$i.jpg should exist immediately',
        );
      }

      // Verify directory structure
      expect(
        albumDir.existsSync(),
        isTrue,
        reason: 'Album directory should exist',
      );

      final dirContents = albumDir.listSync();
      expect(
        dirContents.length,
        equals(3),
        reason: 'Album directory should contain all 3 files',
      );
    });
  });
}
