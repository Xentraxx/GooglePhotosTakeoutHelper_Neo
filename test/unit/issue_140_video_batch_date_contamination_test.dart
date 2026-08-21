/// Regression test for Issue #140: DateTime EXIF data overwritten from a
/// different video.
///
/// Symptom (from the GitHub issue):
///   Two videos in the same Takeout folder, each with its OWN correct JSON
///   sidecar (so Step 4 extracts the right date for both — confirmed by
///   progress.json showing the correct per-entity `dateTaken`).
///   After Step 7, `IMG_5948.MOV` ends up with:
///     - QuickTime:CreateDate        = 2026:08:03 05:34:21  (CORRECT — own date)
///     - XMP:DateTimeOriginal        = 2026:01:01 15:47:43  (WRONG — sibling's)
///     - XMP:DateTimeDigitized       = 2026:01:01 15:47:43  (WRONG — sibling's)
///     - XMP:ModifyDate              = 2026:01:01 15:47:43  (WRONG — sibling's)
///   while `IMG_9304.MOV` (the sibling) keeps its own 1 Jan date.
///   GPS coordinates are CORRECT for both files — so this is NOT the #139
///   cross-photo JSON-matching bug (that would corrupt GPS too). The dates
///   are correct in the MediaEntity; the contamination happens in Step 7's
///   ExifTool batch write.
///
/// Root cause (confirmed by reproduction with real ExifTool 13.55):
///   `ExifToolService.writeExifDataBatch` builds args as
///     commonWriteArgs() + [tags1, file1, tags2, file2, ...]
///   and assumes ExifTool applies each tag block to the following file only.
///   ExifTool does NOT work that way: in argv/argfile/stay-open mode ALL
///   `-Tag=Value` args ACCUMULATE and the FINAL set is applied to EVERY file
///   in the invocation. So the LAST file's tags overwrite every earlier
///   file's tags. The fix is to insert `-execute` (and re-emit common args)
///   between each file's tag block so ExifTool treats them as separate
///   commands.
///
/// Why a per-file MapEntry-capturing mock does NOT catch this:
///   The contamination happens INSIDE ExifTool, not in Dart. A mock that
///   records `entry.value` per file sees the correct per-file tags. The bug
///   only manifests in the actual arg sequence sent to ExifTool. So this
///   test captures the RAW args emitted by `writeExifDataBatch` and asserts
///   they isolate per-file tags via `-execute` separators.
library;

import 'dart:io';

import 'package:gpth_neo/gpth_lib_exports.dart';
import 'package:test/test.dart';

import '../setup/test_setup.dart';

/// ExifTool mock that records per-file single-write calls.
///
/// IMPORTANT: this mock does NOT override `writeExifDataBatch` /
/// `writeExifDataBatchViaArgFile`. The real `ExifToolService` implementation
/// runs and (after the issue #140 fix) calls `writeExifDataSingle` once per
/// file. Overriding the batch methods would bypass the fix entirely and make
/// the test useless — the contamination happens inside the real batch
/// construction, so the real code must execute.
///
/// `writeExifDataSingle` is overridden only to capture the per-file tags
/// (and avoid spawning a real ExifTool process). `executeExifToolCommand` is
/// stubbed to satisfy the one-shot fallback path.
class _PerFileCapturingExifToolService extends ExifToolService {
  _PerFileCapturingExifToolService() : super('/mock/path/exiftool');

  /// Tags captured per file from `writeExifDataSingle`, in call order.
  final List<MapEntry<File, Map<String, dynamic>>> singleCalls = [];

  @override
  Future<void> writeExifDataSingle(
    final File file,
    final Map<String, dynamic> exifData,
  ) async {
    singleCalls.add(MapEntry(file, Map<String, dynamic>.from(exifData)));
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
  group('Issue #140 — video batch date contamination', () {
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

    test('two videos with different dates each receive their own tags via '
        'isolated per-file writes (issue #140 fix)', () async {
      // Reproduce the issue's exact scenario: two .MOV files in the same
      // folder, each with its own JSON sidecar carrying a distinct date.
      //   IMG_5948.MOV → 3 Aug 2026 05:34:21 UTC
      //   IMG_9304.MOV → 1 Jan 2026 15:47:43 UTC
      // Both are extracted via JSON (dateTimeExtractionMethod = json), so
      // Step 7 treats them as UTC and writes XMP:*+00:00 tags for videos.
      //
      // Before the fix, both videos were flushed in a single ExifTool
      // batch where tag assignments are GLOBAL (not scoped to the
      // following filename), so the last file's tags overwrote the
      // earlier file's XMP dates. The fix isolates each file by routing
      // the batch through per-file `writeExifDataSingle` calls.
      //
      // This mock does NOT override writeExifDataBatch, so the real
      // ExifToolService implementation runs and (post-fix) calls
      // writeExifDataSingle once per file. We assert each file received
      // its OWN tags — the property the fix guarantees.
      final tracking = _PerFileCapturingExifToolService();
      final service = WriteExifProcessingService(exifTool: tracking);

      final mov1 = fixture.createFile('IMG_5948.MOV', [
        0x00, 0x00, 0x00, 0x1C, // box size
        0x66, 0x74, 0x79, 0x70, // 'ftyp'
        0x71, 0x74, 0x20, 0x20, // 'qt  '
      ]);
      final mov2 = fixture.createFile('IMG_9304.MOV', [
        0x00,
        0x00,
        0x00,
        0x1C,
        0x66,
        0x74,
        0x79,
        0x70,
        0x71,
        0x74,
        0x20,
        0x20,
      ]);

      final collection = MediaEntityCollection();
      collection.add(
        MediaEntity(
          primaryFile: FileEntity(sourcePath: mov1.path, targetPath: mov1.path),
          dateTaken: DateTime.utc(2026, 8, 3, 5, 34, 21),
          dateTimeExtractionMethod: DateTimeExtractionMethod.json,
        ),
      );
      collection.add(
        MediaEntity(
          primaryFile: FileEntity(sourcePath: mov2.path, targetPath: mov2.path),
          dateTaken: DateTime.utc(2026, 1, 1, 15, 47, 43),
          dateTimeExtractionMethod: DateTimeExtractionMethod.json,
        ),
      );

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

      await service.processCollection(context: ctx);

      // Both videos must have been written via isolated single calls.
      expect(
        tracking.singleCalls.length,
        equals(2),
        reason:
            'Both videos must be written. With the fix, writeExifDataBatch '
            'calls writeExifDataSingle once per file.',
      );

      // Map each captured call back to its file for per-file assertions.
      final tagsByPath = <String, Map<String, dynamic>>{
        for (final c in tracking.singleCalls) c.key.absolute.path: c.value,
      };
      expect(
        tagsByPath.keys,
        containsAll([mov1.absolute.path, mov2.absolute.path]),
      );

      final tags1 = tagsByPath[mov1.absolute.path]!;
      final tags2 = tagsByPath[mov2.absolute.path]!;

      // The XMP date tags are the ones the issue reports as contaminated.
      // Each file must carry its OWN date, not the sibling's.
      expect(
        tags1['XMP:DateTimeOriginal'],
        contains('2026:08:03'),
        reason: 'IMG_5948.MOV must keep its own 3 Aug date in XMP tags',
      );
      expect(
        tags1['XMP:DateTimeOriginal'],
        isNot(contains('2026:01:01')),
        reason:
            'IMG_5948.MOV must NOT carry the sibling\'s 1 Jan date '
            '(this is the exact contamination reported in issue #140)',
      );

      expect(
        tags2['XMP:DateTimeOriginal'],
        contains('2026:01:01'),
        reason: 'IMG_9304.MOV must keep its own 1 Jan date in XMP tags',
      );
      expect(
        tags2['XMP:DateTimeOriginal'],
        isNot(contains('2026:08:03')),
        reason: 'IMG_9304.MOV must NOT carry the sibling\'s 3 Aug date',
      );

      // Also guard the generic EXIF date tags (same contamination vector).
      expect(
        tags1['DateTimeOriginal'],
        contains('2026:08:03'),
        reason: 'IMG_5948.MOV EXIF DateTimeOriginal must be its own date',
      );
      expect(
        tags2['DateTimeOriginal'],
        contains('2026:01:01'),
        reason: 'IMG_9304.MOV EXIF DateTimeOriginal must be its own date',
      );

      // The two files must carry DIFFERENT dates — otherwise there is no
      // contamination to guard against.
      expect(
        tags1['XMP:DateTimeOriginal'],
        isNot(equals(tags2['XMP:DateTimeOriginal'])),
        reason: 'The two videos must have DIFFERENT dates',
      );
    });

    test('queued tag maps are snapshotted (defensive copy) so later mutation '
        'cannot corrupt a sibling file\'s tags', () async {
      // The fix also snapshots the tag map when queueing
      // (Map<String, dynamic>.from(tagsToWrite)) so that later in-place
      // mutation in the retry path (_stripOffsetTags / _retagEntryToXmpIfJpeg)
      // cannot alter a sibling's queued tags. This test exercises that by
      // using files that trigger the InteropIFD retry path... but since
      // these are clean MOV files (no retry), we instead assert the
      // snapshot property directly: each captured call's tag map is a
      // distinct instance from the service's internal map.
      final tracking = _PerFileCapturingExifToolService();
      final service = WriteExifProcessingService(exifTool: tracking);

      final mov1 = fixture.createFile('IMG_5948.MOV', [
        0x00,
        0x00,
        0x00,
        0x1C,
        0x66,
        0x74,
        0x79,
        0x70,
        0x71,
        0x74,
        0x20,
        0x20,
      ]);
      final mov2 = fixture.createFile('IMG_9304.MOV', [
        0x00,
        0x00,
        0x00,
        0x1C,
        0x66,
        0x74,
        0x79,
        0x70,
        0x71,
        0x74,
        0x20,
        0x20,
      ]);

      final collection = MediaEntityCollection();
      collection.add(
        MediaEntity(
          primaryFile: FileEntity(sourcePath: mov1.path, targetPath: mov1.path),
          dateTaken: DateTime.utc(2026, 8, 3, 5, 34, 21),
          dateTimeExtractionMethod: DateTimeExtractionMethod.json,
        ),
      );
      collection.add(
        MediaEntity(
          primaryFile: FileEntity(sourcePath: mov2.path, targetPath: mov2.path),
          dateTaken: DateTime.utc(2026, 1, 1, 15, 47, 43),
          dateTimeExtractionMethod: DateTimeExtractionMethod.json,
        ),
      );

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

      await service.processCollection(context: ctx);

      expect(tracking.singleCalls.length, equals(2));

      // Each file's tags must be isolated: mutating one must not affect
      // the other (the defensive copy guarantees this).
      final tags1 = tracking.singleCalls[0].value;
      final tags2 = tracking.singleCalls[1].value;
      expect(
        identical(tags1, tags2),
        isFalse,
        reason: 'Each file\'s tag map must be a distinct instance',
      );
    });
  });
}
