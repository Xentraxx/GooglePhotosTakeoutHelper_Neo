/// Regression test for the stableTagsetKey batching bug.
///
/// Bug: stableTagsetKey included tag *values* in the bucket key. Every file
/// received a unique date string → unique key → 1-entry buckets → one ExifTool
/// process per file on the final flush (O(N) process spawns).
///
/// Fix (5.1.2): key on tag *names* only. All files needing the same tag set
/// land in one bucket → a single batch call on the final flush.
library;

import 'dart:io';

import 'package:gpth_neo/gpth_lib_exports.dart';
import 'package:test/test.dart';

import '../setup/test_setup.dart';

/// ExifTool service mock that records how it was called (single vs batch).
class _TrackingExifToolService extends ExifToolService {
  _TrackingExifToolService() : super('/mock/path/exiftool');

  int singleCallCount = 0;
  int batchCallCount = 0;
  int totalFilesInBatches = 0;

  @override
  Future<void> writeExifDataSingle(
    final File file,
    final Map<String, dynamic> exifData,
  ) async {
    singleCallCount++;
  }

  @override
  Future<void> writeExifDataBatch(
    final List<MapEntry<File, Map<String, dynamic>>> batch,
  ) async {
    batchCallCount++;
    totalFilesInBatches += batch.length;
  }

  @override
  Future<void> writeExifDataBatchViaArgFile(
    final List<MapEntry<File, Map<String, dynamic>>> batch,
  ) async {
    batchCallCount++;
    totalFilesInBatches += batch.length;
  }

  @override
  Future<Map<String, dynamic>> readExifData(final File file) async => {};

  @override
  Future<void> startPersistentProcess() async {}

  @override
  Future<String> executeExifToolCommand(
    final List<String> args, {
    final Duration? timeout,
  }) async => '';

  @override
  Future<void> dispose() async {}
}

void main() {
  group('WriteExifProcessingService — tagset batching (5.1.2 regression test)', () {
    late TestFixture fixture;

    setUp(() async {
      fixture = TestFixture();
      await fixture.setUp();
      await ServiceContainer.instance.initialize();
    });

    tearDown(() async {
      await ServiceContainer.reset();
      await fixture.tearDown();
    });

    test(
      'files with same tag names but unique date values are grouped into one batch',
      () async {
        // --- Arrange ---
        final tracking = _TrackingExifToolService();
        final service = WriteExifProcessingService(exifTool: tracking);
        const fileCount = 6;

        final collection = MediaEntityCollection();

        for (int i = 0; i < fileCount; i++) {
          // PNG files bypass the native JPEG write path and go straight into
          // the ExifTool queue with XMP date tags:
          //   XMP:CreateDate, XMP:DateTimeOriginal, XMP:ModifyDate
          // Each entity has a *different* date (unique values) but they all
          // produce the exact same set of tag *names*.
          final file = fixture.createFile(
            'photo_$i.png',
            [0x89, 0x50, 0x4E, 0x47], // PNG magic bytes
          );

          // sourcePath == targetPath so the step sees the file as already
          // moved and ready to write EXIF into.
          final fe = FileEntity(sourcePath: file.path, targetPath: file.path);

          collection.add(
            MediaEntity(
              primaryFile: fe,
              dateTaken: DateTime(2020, 1, i + 1), // unique per entity
              dateTimeExtractionMethod: DateTimeExtractionMethod.json,
            ),
          );
        }

        final ctx = ProcessingContext(
          config: ProcessingConfig(
            inputPath: fixture.basePath,
            outputPath: fixture.basePath,
            disableResumeCheck: true,
          ),
          mediaCollection: collection,
          inputDirectory: Directory(fixture.basePath),
          outputDirectory: Directory(fixture.basePath),
        );

        // --- Act ---
        await service.processCollection(context: ctx);

        // --- Assert ---
        //
        // With the fix (5.1.2):
        //   All 6 files share the same XMP tag-name key →
        //   final flush produces 1 batch call with all 6 files,
        //   0 per-file single calls.
        //
        // Without the fix (regression):
        //   Each file's unique date value produces a unique key →
        //   6 single-entry buckets → 6 single calls, 0 batch calls.
        expect(
          tracking.singleCallCount,
          equals(0),
          reason:
              'No per-file single ExifTool calls should occur on the happy path',
        );
        expect(
          tracking.batchCallCount,
          equals(1),
          reason:
              'All $fileCount files with the same tag-name set must be flushed in exactly one batch',
        );
        expect(
          tracking.totalFilesInBatches,
          equals(fileCount),
          reason: 'The batch must contain all $fileCount files',
        );
      },
    );
  });
}
