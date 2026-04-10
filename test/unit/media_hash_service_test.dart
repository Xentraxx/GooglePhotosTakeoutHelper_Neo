/// Test suite for MediaHashService
///
/// Tests the media file hashing and size calculation functionality.
library;

import 'dart:io';
import 'package:gpth_neo/gpth_lib_exports.dart';
import 'package:test/test.dart';

import '../setup/test_setup.dart';

void main() {
  group('MediaHashService', () {
    late MediaHashService service;
    late TestFixture fixture;
    setUp(() async {
      service = MediaHashService();
      fixture = TestFixture();
      await fixture.setUp();
    });

    tearDown(() async {
      await fixture.tearDown();
    });

    group('calculateFileHash', () {
      test('calculates hash for existing file', () async {
        final file = fixture.createImageWithExif('test.jpg');

        final hash = await service.calculateFileHash(file);

        expect(hash, isNotEmpty);
        expect(hash, hasLength(16)); // XXH3 hash length
        expect(hash, matches(RegExp(r'^[a-f0-9]+$'))); // Hex string
      });

      test('throws FileSystemException for non-existent file', () async {
        final file = File('${fixture.basePath}/non_existent.jpg');

        expect(
          () => service.calculateFileHash(file),
          throwsA(isA<FileSystemException>()),
        );
      });

      test('produces consistent hash for same file content', () async {
        final file1 = fixture.createImageWithExif('test1.jpg');
        final file2 = fixture.createImageWithExif('test2.jpg');

        final hash1 = await service.calculateFileHash(file1);
        final hash2 = await service.calculateFileHash(file2);

        expect(hash1, equals(hash2));
      });

      test('produces different hash for different file content', () async {
        final file1 = fixture.createImageWithExif('test1.jpg');
        final file2 = fixture.createImageWithoutExif('test2.jpg');

        final hash1 = await service.calculateFileHash(file1);
        final hash2 = await service.calculateFileHash(file2);

        expect(hash1, isNot(equals(hash2)));
      });
    });

    group('calculateFileSize', () {
      test('calculates size for existing file', () async {
        final file = fixture.createImageWithExif('test.jpg');

        final size = await service.calculateFileSize(file);

        expect(size, greaterThan(0));
        expect(size, equals(await file.length()));
      });

      test('throws FileSystemException for non-existent file', () async {
        final file = File('${fixture.basePath}/non_existent.jpg');

        expect(
          () => service.calculateFileSize(file),
          throwsA(isA<FileSystemException>()),
        );
      });
    });

    group('calculateHashAndSize', () {
      test('calculates both hash and size', () async {
        final file = fixture.createImageWithExif('test.jpg');

        final result = await service.calculateHashAndSize(file);

        expect(result.hash, isNotEmpty);
        expect(result.hash, hasLength(16));
        expect(result.size, greaterThan(0));
        expect(result.size, equals(await file.length()));
      });

      test('throws FileSystemException for non-existent file', () async {
        final file = File('${fixture.basePath}/non_existent.jpg');

        expect(
          () => service.calculateHashAndSize(file),
          throwsA(isA<FileSystemException>()),
        );
      });

      test('results match individual calculations', () async {
        final file = fixture.createImageWithExif('test.jpg');

        final combined = await service.calculateHashAndSize(file);
        final individualHash = await service.calculateFileHash(file);
        final individualSize = await service.calculateFileSize(file);

        expect(combined.hash, equals(individualHash));
        expect(combined.size, equals(individualSize));
      });
    });

    group('calculateMultipleHashes', () {
      test('calculates hashes for multiple files', () async {
        final file1 = fixture.createImageWithExif('test1.jpg');
        final file2 = fixture.createImageWithoutExif('test2.jpg');
        final file3 = fixture.createImageWithExif('test3.jpg');

        final results = await service.calculateMultipleHashes([
          file1,
          file2,
          file3,
        ]);

        expect(results, hasLength(3));
        expect(results[file1.path], isNotEmpty);
        expect(results[file2.path], isNotEmpty);
        expect(results[file3.path], isNotEmpty);
        expect(
          results[file1.path],
          equals(results[file3.path]),
        ); // Same content
        expect(
          results[file1.path],
          isNot(equals(results[file2.path])),
        ); // Different content
      });

      test('handles empty file list', () async {
        final results = await service.calculateMultipleHashes([]);

        expect(results, isEmpty);
      });

      test('respects max concurrency limit', () async {
        final files = List.generate(
          5,
          (final i) => fixture.createImageWithExif('test$i.jpg'),
        );

        final results = await service.calculateMultipleHashes(files);

        expect(results, hasLength(5));
        for (final file in files) {
          expect(results[file.path], isNotEmpty);
        }
      });

      test('handles files that cannot be read gracefully', () async {
        final goodFile = fixture.createImageWithExif('good.jpg');
        final badFile = File('${fixture.basePath}/non_existent.jpg');

        final results = await service.calculateMultipleHashes([
          goodFile,
          badFile,
        ]);

        expect(results, hasLength(1));
        expect(results[goodFile.path], isNotEmpty);
        expect(results.containsKey(badFile.path), isFalse);
      });
    });

    group('areFilesIdentical', () {
      test('returns true for identical files', () async {
        final file1 = fixture.createImageWithExif('test1.jpg');
        final file2 = fixture.createImageWithExif('test2.jpg');

        final identical = await service.areFilesIdentical(file1, file2);

        expect(identical, isTrue);
      });

      test('returns false for different files', () async {
        final file1 = fixture.createImageWithExif('test1.jpg');
        final file2 = fixture.createImageWithoutExif('test2.jpg');

        final identical = await service.areFilesIdentical(file1, file2);

        expect(identical, isFalse);
      });

      test('returns false for files with different sizes', () async {
        final file1 = fixture.createImageWithExif('test1.jpg');
        final file2 = fixture.createFile('test2.txt', [1, 2, 3]);

        final identical = await service.areFilesIdentical(file1, file2);

        expect(identical, isFalse);
      });

      test('throws for non-existent files', () async {
        final file1 = fixture.createImageWithExif('test.jpg');
        final file2 = File('${fixture.basePath}/non_existent.jpg');

        expect(
          () => service.areFilesIdentical(file1, file2),
          throwsA(isA<FileSystemException>()),
        );
      });
    });
  });
}
