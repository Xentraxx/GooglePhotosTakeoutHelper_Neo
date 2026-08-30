/// Test suite for DuplicateDetectionService
///
/// Tests the duplicate media file detection functionality including
/// grouping identical files, removing duplicates, and statistics calculation.
library;

import 'dart:io';
import 'package:gpth_neo/gpth_lib_exports.dart';
import 'package:test/test.dart';

import '../setup/test_setup.dart';

void main() {
  group('DuplicateDetectionService', () {
    late MergeMediaEntitiesService service;
    late TestFixture fixture;
    late MockMediaHashService mockHashService;

    setUp(() async {
      mockHashService = MockMediaHashService();
      service = MergeMediaEntitiesService(hashService: mockHashService);
      fixture = TestFixture();
      await fixture.setUp();
    });

    tearDown(() async {
      await fixture.tearDown();
    });

    group('groupIdentical', () {
      test('groups files with same size and hash', () async {
        // Create test files with same content
        final file1 = fixture.createImageWithExif('image1.jpg');
        final file2 = fixture.createImageWithExif('image2.jpg');
        final file3 = fixture.createImageWithoutExif('image3.jpg');

        final media1 = createTestMediaEntity(file1);
        final media2 = createTestMediaEntity(file2);
        final media3 = createTestMediaEntity(file3);

        // Mock same size and hash for first two files
        mockHashService.mockFileSize(file1, 1000);
        mockHashService.mockFileSize(file2, 1000);
        mockHashService.mockFileSize(file3, 2000);
        mockHashService.mockFileHash(file1, 'hash1');
        mockHashService.mockFileHash(file2, 'hash1');
        mockHashService.mockFileHash(file3, 'hash2');

        final result = await service.groupIdenticalLegacy([
          media1,
          media2,
          media3,
        ]);

        expect(result.length, equals(2));
        expect(result['hash1']?.length, equals(2));
        expect(result['2000bytes']?.length, equals(1));
        expect(result['hash1'], containsAll([media1, media2]));
        expect(result['2000bytes'], contains(media3));
      });

      test('handles empty list', () async {
        final result = await service.groupIdenticalLegacy([]);
        expect(result, isEmpty);
      });

      test('handles single file', () async {
        final file = fixture.createImageWithExif('single.jpg');
        final media = createTestMediaEntity(file);

        mockHashService.mockFileSize(file, 1000);

        final result = await service.groupIdenticalLegacy([media]);

        expect(result.length, equals(1));
        expect(result['1000bytes'], contains(media));
      });

      test('groups by size only when no duplicates found', () async {
        final file1 = fixture.createImageWithExif('image1.jpg');
        final file2 = fixture.createImageWithoutExif('image2.jpg');

        final media1 = createTestMediaEntity(file1);
        final media2 = createTestMediaEntity(file2);

        // Mock different sizes
        mockHashService.mockFileSize(file1, 1000);
        mockHashService.mockFileSize(file2, 2000);

        final result = await service.groupIdenticalLegacy([media1, media2]);

        expect(result.length, equals(2));
        expect(result['1000bytes'], contains(media1));
        expect(result['2000bytes'], contains(media2));
      });
    });

    group('removeDuplicates', () {
      test('removes duplicates keeping best quality', () async {
        final file1 = fixture.createImageWithExif('image1.jpg');
        final file2 = fixture.createImageWithExif('image2.jpg');

        final media1 = createTestMediaEntityWithDate(
          file1,
          dateTaken: DateTime(2022, 12, 16),
          dateAccuracy: DateAccuracy.good,
        );
        final media2 = createTestMediaEntityWithDate(
          file2,
          dateTaken: DateTime(2022, 12, 16),
          dateAccuracy: DateAccuracy.fair,
        );

        // Mock same size and hash
        mockHashService.mockFileSize(file1, 1000);
        mockHashService.mockFileSize(file2, 1000);
        mockHashService.mockFileHash(file1, 'hash1');
        mockHashService.mockFileHash(file2, 'hash1');

        final result = await service.removeDuplicates([media1, media2]);

        expect(result.length, equals(1));
        final MediaEntity resultMedia = result.first;

        // Winner keeps better date accuracy (media1)
        expect(resultMedia.dateTaken, equals(media1.dateTaken));
        expect(resultMedia.dateAccuracy, equals(media1.dateAccuracy));

        // Primary file equality by path (FileEntity does not override ==)
        expect(
          resultMedia.primaryFile.sourcePath,
          equals(media1.primaryFile.sourcePath),
        );

        // Album associations preserved from the best entity
        expect(resultMedia.albumNames, equals(media1.albumNames));

        // Duplicates are recorded: exactly one duplicate coming from media2
        expect(resultMedia.duplicatesCount, equals(1));
        expect(
          resultMedia.duplicatesFiles.any(
            (final f) => f.sourcePath == media2.primaryFile.sourcePath,
          ),
          isTrue,
        );

        // No secondaries in this scenario
        expect(resultMedia.secondaryCount, equals(0));
      });

      test('handles empty list', () async {
        final result = await service.removeDuplicates([]);
        expect(result, isEmpty);
      });

      test('handles single item', () async {
        final file = fixture.createImageWithExif('single.jpg');
        final media = createTestMediaEntity(file);

        final result = await service.removeDuplicates([media]);

        expect(result.length, equals(1));
        expect(result.first, equals(media));
      });

      test('calls progress callback', () async {
        final file1 = fixture.createImageWithExif('image1.jpg');
        final file2 = fixture.createImageWithoutExif('image2.jpg');

        final media1 = createTestMediaEntity(file1);
        final media2 = createTestMediaEntity(file2);

        mockHashService.mockFileSize(file1, 1000);
        mockHashService.mockFileSize(file2, 2000);

        var callCount = 0;
        var lastProcessed = 0;
        var lastTotal = 0;

        await service.removeDuplicates(
          [media1, media2],
          progressCallback: (final processed, final total) {
            callCount++;
            lastProcessed = processed;
            lastTotal = total;
          },
        );

        expect(callCount, greaterThan(0));
        expect(lastTotal, equals(2));
        expect(lastProcessed, equals(lastTotal));
      });
    });

    group('findDuplicateGroups', () {
      test('returns only groups with multiple items', () async {
        final file1 = fixture.createImageWithExif('image1.jpg');
        final file2 = fixture.createImageWithExif('image2.jpg');
        final file3 = fixture.createImageWithoutExif('image3.jpg');

        final media1 = createTestMediaEntity(file1);
        final media2 = createTestMediaEntity(file2);
        final media3 = createTestMediaEntity(file3);

        // Mock file1 and file2 as duplicates
        mockHashService.mockFileSize(file1, 1000);
        mockHashService.mockFileSize(file2, 1000);
        mockHashService.mockFileSize(file3, 2000);
        mockHashService.mockFileHash(file1, 'hash1');
        mockHashService.mockFileHash(file2, 'hash1');

        final result = await service.findDuplicateGroups([
          media1,
          media2,
          media3,
        ]);

        expect(result.length, equals(1));
        expect(result.first.length, equals(2));
        expect(result.first, containsAll([media1, media2]));
      });

      test('returns empty list when no duplicates', () async {
        final file1 = fixture.createImageWithExif('image1.jpg');
        final file2 = fixture.createImageWithoutExif('image2.jpg');

        final media1 = createTestMediaEntity(file1);
        final media2 = createTestMediaEntity(file2);

        mockHashService.mockFileSize(file1, 1000);
        mockHashService.mockFileSize(file2, 2000);

        final result = await service.findDuplicateGroups([media1, media2]);

        expect(result, isEmpty);
      });
    });

    group('areDuplicates', () {
      test('returns true for files with same size and hash', () async {
        final file1 = fixture.createImageWithExif('image1.jpg');
        final file2 = fixture.createImageWithExif('image2.jpg');

        final media1 = createTestMediaEntity(file1);
        final media2 = createTestMediaEntity(file2);

        mockHashService.mockFileSize(file1, 1000);
        mockHashService.mockFileSize(file2, 1000);
        mockHashService.mockFileHash(file1, 'hash1');
        mockHashService.mockFileHash(file2, 'hash1');

        final result = await service.areDuplicates(media1, media2);

        expect(result, isTrue);
      });

      test('returns false for files with different sizes', () async {
        final file1 = fixture.createImageWithExif('image1.jpg');
        final file2 = fixture.createImageWithoutExif('image2.jpg');

        final media1 = createTestMediaEntity(file1);
        final media2 = createTestMediaEntity(file2);

        mockHashService.mockFileSize(file1, 1000);
        mockHashService.mockFileSize(file2, 2000);

        final result = await service.areDuplicates(media1, media2);

        expect(result, isFalse);
      });

      test(
        'returns false for files with same size but different hash',
        () async {
          final file1 = fixture.createImageWithExif('image1.jpg');
          final file2 = fixture.createImageWithExif('image2.jpg');

          final media1 = createTestMediaEntity(file1);
          final media2 = createTestMediaEntity(file2);

          mockHashService.mockFileSize(file1, 1000);
          mockHashService.mockFileSize(file2, 1000);
          mockHashService.mockFileHash(file1, 'hash1');
          mockHashService.mockFileHash(file2, 'hash2');

          final result = await service.areDuplicates(media1, media2);

          expect(result, isFalse);
        },
      );
    });

    group('calculateStats', () {
      test('calculates correct statistics', () async {
        final file1 = fixture.createImageWithExif('image1.jpg');
        final file2 = fixture.createImageWithExif('image2.jpg');
        final file3 = fixture.createImageWithoutExif('image3.jpg');

        final media1 = createTestMediaEntity(file1);
        final media2 = createTestMediaEntity(file2);
        final media3 = createTestMediaEntity(file3);

        final grouped = {
          'hash1': [media1, media2], // Duplicate group
          '2000bytes': [media3], // Unique file
        };

        final stats = service.calculateStats(grouped);

        expect(stats.totalFiles, equals(3));
        expect(stats.uniqueFiles, equals(1));
        expect(stats.duplicateGroups, equals(1));
        expect(stats.duplicateFiles, equals(2));
        expect(stats.duplicatePercentage, closeTo(66.67, 0.01));
      });

      test('handles empty groups', () async {
        final stats = service.calculateStats({});

        expect(stats.totalFiles, equals(0));
        expect(stats.uniqueFiles, equals(0));
        expect(stats.duplicateGroups, equals(0));
        expect(stats.duplicateFiles, equals(0));
        expect(stats.duplicatePercentage, equals(0));
      });
    });

    group('DuplicateStats', () {
      test('calculates duplicate percentage correctly', () {
        const stats = DuplicateStats(
          totalFiles: 10,
          uniqueFiles: 7,
          duplicateGroups: 1,
          duplicateFiles: 3,
          spaceWastedBytes: 1024,
        );

        expect(stats.duplicatePercentage, equals(30.0));
      });

      test('handles zero total files', () {
        const stats = DuplicateStats(
          totalFiles: 0,
          uniqueFiles: 0,
          duplicateGroups: 0,
          duplicateFiles: 0,
          spaceWastedBytes: 0,
        );

        expect(stats.duplicatePercentage, equals(0));
      });

      test('generates summary string', () {
        const stats = DuplicateStats(
          totalFiles: 10,
          uniqueFiles: 7,
          duplicateGroups: 2,
          duplicateFiles: 3,
          spaceWastedBytes: 1048576, // 1 MB
        );

        final summary = stats.summary;
        expect(summary, contains('2 duplicate groups'));
        expect(summary, contains('3 files'));
        expect(summary, contains('1.0 MB'));
      });
    });
  });
}

/// Mock implementation of MediaHashService for testing
class MockMediaHashService implements MediaHashService {
  // IMPORTANT: use file paths as keys to avoid instance-identity mismatches.
  final Map<String, int> _fileSizes = {};
  final Map<String, String> _fileHashes = {};

  @override
  int get maxCacheSize => 1000;

  // LoggerMixin implementation stubs for testing
  @override
  late LoggingService logger = LoggingService();

  @override
  void logInfo(final String message, {final bool forcePrint = false}) {}

  @override
  void logWarning(final String message, {final bool forcePrint = false}) {}

  @override
  void logError(final String message, {final bool forcePrint = false}) {}

  @override
  void logDebug(final String message, {final bool forcePrint = false}) {}

  @override
  void logPrint(final String message, {final bool forcePrint = true}) {}

  void mockFileSize(final File file, final int size) {
    _fileSizes[file.path] = size;
  }

  void mockFileHash(final File file, final String hash) {
    _fileHashes[file.path] = hash;
  }

  @override
  Future<int> calculateFileSize(final File file) async {
    final String p = file.path;
    if (_fileSizes.containsKey(p)) {
      return _fileSizes[p]!;
    }
    return file.lengthSync();
  }

  @override
  Future<String> calculateFileHash(final File file) async {
    final String p = file.path;
    if (_fileHashes.containsKey(p)) {
      return _fileHashes[p]!;
    }
    throw FileSystemException('File not mocked', p);
  }

  @override
  Future<({String hash, int size})> calculateHashAndSize(
    final File file,
  ) async {
    final String hash = await calculateFileHash(file);
    final int size = await calculateFileSize(file);
    return (hash: hash, size: size);
  }

  @override
  Future<Map<String, String>> calculateMultipleHashes(
    final List<File> files,
  ) async {
    final results = <String, String>{};
    for (final file in files) {
      try {
        final String hash = await calculateFileHash(file);
        results[file.path] = hash;
      } catch (_) {
        // Skip files that can't be hashed
      }
    }
    return results;
  }

  @override
  Future<bool> areFilesIdentical(final File file1, final File file2) async {
    final int size1 = await calculateFileSize(file1);
    final int size2 = await calculateFileSize(file2);
    if (size1 != size2) return false;

    final String hash1 = await calculateFileHash(file1);
    final String hash2 = await calculateFileHash(file2);
    return hash1 == hash2;
  }

  @override
  Map<String, dynamic> getCacheStats() => {
    'hashCacheSize': _fileHashes.length,
    'sizeCacheSize': _fileSizes.length,
    'maxCacheSize': maxCacheSize,
    'cacheUtilization': '0.0%',
  };

  @override
  void clearCache() {
    _fileHashes.clear();
    _fileSizes.clear();
  }
}

/// Helper function to create test MediaEntity
MediaEntity createTestMediaEntity(final File file) =>
    MediaEntity.single(file: FileEntity(sourcePath: file.path));

/// Helper function to create test MediaEntity with date information
MediaEntity createTestMediaEntityWithDate(
  final File file, {
  final DateTime? dateTaken,
  final DateAccuracy? dateAccuracy,
}) => MediaEntity.single(
  file: FileEntity(sourcePath: file.path),
  dateTaken: dateTaken,
  dateAccuracy: dateAccuracy,
);
