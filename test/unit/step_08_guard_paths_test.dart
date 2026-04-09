/// Tests for the two early-exit guard paths in UpdateCreationTimeService.
///
/// Guard 1: config.updateCreationTime == false
///   → returns immediately with skipped=true, never touches any file.
///
/// Guard 2: no files have dateTaken set (or collection is empty)
///   → filesToTouch is empty → returns updatedCount=0, skipped=false.
///
/// Both guards are exercised without invoking win32 FFI, so the tests
/// are safe to run on the current platform.
library;

import 'dart:io';

import 'package:gpth_neo/gpth_lib_exports.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import '../setup/test_setup.dart';

// ─────────────────────────────────────────────────────────────────────────────
// Helpers
// ─────────────────────────────────────────────────────────────────────────────

ProcessingContext _makeCtx({
  required final Directory inputDir,
  required final Directory outputDir,
  required final bool updateCreationTime,
  final List<MediaEntity> entities = const [],
}) => ProcessingContext(
  config: ProcessingConfig(
    inputPath: inputDir.path,
    outputPath: outputDir.path,
    updateCreationTime: updateCreationTime,
  ),
  mediaCollection: MediaEntityCollection(entities),
  inputDirectory: inputDir,
  outputDirectory: outputDir,
);

// ─────────────────────────────────────────────────────────────────────────────
// Tests
// ─────────────────────────────────────────────────────────────────────────────

void main() {
  group('UpdateCreationTimeService – guard paths', () {
    late TestFixture fixture;
    late UpdateCreationTimeService service;

    setUp(() async {
      fixture = TestFixture();
      await fixture.setUp();
      service = UpdateCreationTimeService();
    });

    tearDown(() async => fixture.tearDown());

    // ── Guard 1: updateCreationTime disabled ─────────────────────────────────

    group('guard 1: updateCreationTime=false', () {
      test('returns skipped=true when disabled in config', () async {
        final ctx = _makeCtx(
          inputDir: Directory(p.join(fixture.basePath, 'input'))..createSync(),
          outputDir: Directory(p.join(fixture.basePath, 'output'))
            ..createSync(),
          updateCreationTime: false,
        );

        final summary = await service.updateCreationTimes(ctx);

        expect(summary.skipped, isTrue);
      });

      test('updatedCount=0 when disabled', () async {
        final ctx = _makeCtx(
          inputDir: Directory(p.join(fixture.basePath, 'in2'))..createSync(),
          outputDir: Directory(p.join(fixture.basePath, 'out2'))..createSync(),
          updateCreationTime: false,
        );

        final summary = await service.updateCreationTimes(ctx);

        expect(summary.updatedCount, equals(0));
        expect(summary.failedCount, equals(0));
      });

      test(
        'disabling is independent of how many entities are in collection',
        () async {
          // Even an entity with a real dateTaken must be skipped if disabled
          final entity = MediaEntity(
            primaryFile: FileEntity(
              sourcePath: p.join(fixture.basePath, 'photo.jpg'),
            ),
            secondaryFiles: const [],
            dateTaken: DateTime(2023, 6, 15),
          );

          final ctx = _makeCtx(
            inputDir: Directory(p.join(fixture.basePath, 'in3'))..createSync(),
            outputDir: Directory(p.join(fixture.basePath, 'out3'))
              ..createSync(),
            updateCreationTime: false,
            entities: [entity],
          );

          final summary = await service.updateCreationTimes(ctx);

          expect(summary.skipped, isTrue);
          expect(summary.updatedCount, equals(0));
        },
      );
    });

    // ── Guard 2: no files to touch ───────────────────────────────────────────

    group('guard 2: filesToTouch is empty', () {
      test('empty collection → updatedCount=0, skipped=false', () async {
        final ctx = _makeCtx(
          inputDir: Directory(p.join(fixture.basePath, 'in4'))..createSync(),
          outputDir: Directory(p.join(fixture.basePath, 'out4'))..createSync(),
          updateCreationTime: true,
          entities: [],
        );

        final summary = await service.updateCreationTimes(ctx);

        expect(summary.skipped, isFalse);
        expect(summary.updatedCount, equals(0));
      });

      test('entity with dateTaken=null is skipped → guard 2 fires', () async {
        // dateTaken not supplied → defaults to null
        final entity = MediaEntity(
          primaryFile: FileEntity(
            sourcePath: p.join(fixture.basePath, 'nodates.jpg'),
            targetPath: p.join(fixture.basePath, 'output', 'nodates.jpg'),
          ),
          secondaryFiles: const [],
          // dateTaken omitted → null
        );

        final ctx = _makeCtx(
          inputDir: Directory(p.join(fixture.basePath, 'in5'))..createSync(),
          outputDir: Directory(p.join(fixture.basePath, 'out5'))..createSync(),
          updateCreationTime: true,
          entities: [entity],
        );

        final summary = await service.updateCreationTimes(ctx);

        expect(summary.skipped, isFalse);
        expect(summary.updatedCount, equals(0));
      });

      test(
        'entity with dateTaken set but targetPath=null → guard 2 fires',
        () async {
          // targetPath is null (file not yet moved through step_06)
          final entity = MediaEntity(
            primaryFile: FileEntity(
              sourcePath: p.join(fixture.basePath, 'notmoved.jpg'),
              // targetPath not supplied → null
            ),
            secondaryFiles: const [],
            dateTaken: DateTime(2023),
          );

          final ctx = _makeCtx(
            inputDir: Directory(p.join(fixture.basePath, 'in6'))..createSync(),
            outputDir: Directory(p.join(fixture.basePath, 'out6'))
              ..createSync(),
            updateCreationTime: true,
            entities: [entity],
          );

          final summary = await service.updateCreationTimes(ctx);

          expect(summary.skipped, isFalse);
          expect(summary.updatedCount, equals(0));
        },
      );

      test(
        'all entities have dateTaken=null → guard 2, skipped=false',
        () async {
          final entities = List.generate(
            5,
            (final n) => MediaEntity(
              primaryFile: FileEntity(
                sourcePath: p.join(fixture.basePath, 'file$n.jpg'),
                targetPath: p.join(fixture.basePath, 'out', 'file$n.jpg'),
              ),
              secondaryFiles: const [],
              // dateTaken null → skipped in loop
            ),
          );

          final ctx = _makeCtx(
            inputDir: Directory(p.join(fixture.basePath, 'in7'))..createSync(),
            outputDir: Directory(p.join(fixture.basePath, 'out7'))
              ..createSync(),
            updateCreationTime: true,
            entities: entities,
          );

          final summary = await service.updateCreationTimes(ctx);

          expect(summary.skipped, isFalse);
          expect(summary.updatedCount, equals(0));
          expect(summary.failedCount, equals(0));
        },
      );
    });
  });
}
