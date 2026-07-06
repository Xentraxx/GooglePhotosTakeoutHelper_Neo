/// Tests for the resume-state handling added for issue #131:
/// - StepProgressLoader.isResumeStateStale(): detects a progress.json whose
///   recorded output files no longer exist (e.g. output folder emptied).
/// - StepProgressSaver.clearResumeState(): removes step-resume keys while
///   preserving the zip_extraction sentinel and emoji crash-recovery data.
library;

import 'dart:convert';
import 'dart:io';

import 'package:gpth_neo/gpth_lib_exports.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import '../setup/test_setup.dart';

ProcessingContext _makeContext({
  required final Directory inputDir,
  required final Directory outputDir,
  final MediaEntityCollection? mediaCollection,
}) => ProcessingContext(
  config: ProcessingConfig(
    inputPath: inputDir.path,
    outputPath: outputDir.path,
  ),
  mediaCollection: mediaCollection ?? MediaEntityCollection([]),
  inputDirectory: inputDir,
  outputDirectory: outputDir,
);

/// Saves progress for [stepId] using a collection containing one entity whose
/// primary file has [targetPath] set (may point to a missing file).
Future<void> _saveStepWithTarget(
  final Directory inputDir,
  final Directory outputDir,
  final int stepId, {
  required final String sourcePath,
  required final String? targetPath,
}) async {
  final entity = MediaEntity.single(
    file: FileEntity(sourcePath: sourcePath, targetPath: targetPath),
    dateTaken: DateTime(2023),
  );
  final ctx = _makeContext(
    inputDir: inputDir,
    outputDir: outputDir,
    mediaCollection: MediaEntityCollection([entity]),
  );
  await StepProgressSaver.saveProgress(
    context: ctx,
    stepId: stepId,
    duration: Duration.zero,
    stepResult: StepResult.success(
      stepName: 'Step $stepId',
      duration: Duration.zero,
    ),
  );
}

void main() {
  group('StepProgressLoader.isResumeStateStale', () {
    late TestFixture fixture;
    late Directory inputDir;
    late Directory outputDir;
    late File sourceImage;

    setUp(() async {
      fixture = TestFixture();
      await fixture.setUp();
      inputDir = fixture.createDirectory('input');
      outputDir = fixture.createDirectory('output');
      sourceImage = fixture.createImageWithExif('input/photo.jpg');
    });

    tearDown(() async {
      await fixture.tearDown();
    });

    Future<Map<String, dynamic>> readProgress(
      final ProcessingContext ctx,
    ) async => (await StepProgressLoader.readProgressJson(ctx))!;

    test('not stale when move step (6) is not completed', () async {
      final missingTarget = p.join(outputDir.path, 'ALL_PHOTOS', 'photo.jpg');
      await _saveStepWithTarget(
        inputDir,
        outputDir,
        4, // only step 4 completed — targets not expected on disk yet
        sourcePath: sourceImage.path,
        targetPath: missingTarget,
      );
      final ctx = _makeContext(inputDir: inputDir, outputDir: outputDir);

      final progress = await readProgress(ctx);
      expect(StepProgressLoader.isResumeStateStale(progress, ctx), isFalse);
    });

    test(
      'not stale when step 6 completed and recorded target still exists',
      () async {
        final existingTarget = fixture.createImageWithExif(
          'output/ALL_PHOTOS/photo.jpg',
        );
        await _saveStepWithTarget(
          inputDir,
          outputDir,
          6,
          sourcePath: sourceImage.path,
          targetPath: existingTarget.path,
        );
        final ctx = _makeContext(inputDir: inputDir, outputDir: outputDir);

        final progress = await readProgress(ctx);
        expect(StepProgressLoader.isResumeStateStale(progress, ctx), isFalse);
      },
    );

    test(
      'stale when step 6 completed but no recorded target exists anymore',
      () async {
        final missingTarget = p.join(outputDir.path, 'ALL_PHOTOS', 'photo.jpg');
        await _saveStepWithTarget(
          inputDir,
          outputDir,
          6,
          sourcePath: sourceImage.path,
          targetPath: missingTarget,
        );
        final ctx = _makeContext(inputDir: inputDir, outputDir: outputDir);

        final progress = await readProgress(ctx);
        expect(StepProgressLoader.isResumeStateStale(progress, ctx), isTrue);
      },
    );

    test('not stale when snapshot records no target paths', () async {
      await _saveStepWithTarget(
        inputDir,
        outputDir,
        6,
        sourcePath: sourceImage.path,
        targetPath: null, // never moved → nothing to verify
      );
      final ctx = _makeContext(inputDir: inputDir, outputDir: outputDir);

      final progress = await readProgress(ctx);
      expect(StepProgressLoader.isResumeStateStale(progress, ctx), isFalse);
    });
  });

  group('StepProgressSaver.clearResumeState', () {
    late TestFixture fixture;
    late Directory inputDir;
    late Directory outputDir;

    setUp(() async {
      fixture = TestFixture();
      await fixture.setUp();
      inputDir = fixture.createDirectory('input');
      outputDir = fixture.createDirectory('output');
    });

    tearDown(() async {
      await fixture.tearDown();
    });

    File progressFile() => File(p.join(outputDir.path, 'progress.json'));

    test('is a no-op when progress.json does not exist', () async {
      await StepProgressSaver.clearResumeState(outputDir);
      expect(progressFile().existsSync(), isFalse);
    });

    test('deletes the file when only resume state is present', () async {
      final ctx = _makeContext(inputDir: inputDir, outputDir: outputDir);
      await StepProgressSaver.saveProgress(
        context: ctx,
        stepId: 3,
        duration: Duration.zero,
        stepResult: StepResult.success(
          stepName: 'Step 3',
          duration: Duration.zero,
        ),
      );
      expect(progressFile().existsSync(), isTrue);

      await StepProgressSaver.clearResumeState(outputDir);
      expect(progressFile().existsSync(), isFalse);
    });

    test(
      'removes resume keys but preserves the zip_extraction sentinel',
      () async {
        final ctx = _makeContext(inputDir: inputDir, outputDir: outputDir);
        await StepProgressSaver.saveProgress(
          context: ctx,
          stepId: 6,
          duration: Duration.zero,
          stepResult: StepResult.success(
            stepName: 'Step 6',
            duration: Duration.zero,
          ),
        );
        // Merge a zip_extraction sentinel like bin/gpth.dart does.
        final doc =
            jsonDecode(progressFile().readAsStringSync())
                as Map<String, dynamic>;
        doc['zip_extraction'] = {
          'extracted_at': '2026-01-01T00:00:00Z',
          'source_zips': [
            {'name': 'takeout-001.zip', 'size_bytes': 123},
          ],
        };
        progressFile().writeAsStringSync(jsonEncode(doc));

        await StepProgressSaver.clearResumeState(outputDir);

        expect(progressFile().existsSync(), isTrue);
        final cleaned =
            jsonDecode(progressFile().readAsStringSync())
                as Map<String, dynamic>;
        expect(cleaned.containsKey('zip_extraction'), isTrue);
        expect(cleaned.containsKey('steps'), isFalse);
        expect(cleaned.containsKey('Completed steps'), isFalse);
        expect(cleaned.containsKey('media_entity_collection_object'), isFalse);
      },
    );

    test('deletes a corrupt progress.json outright', () async {
      progressFile()
        ..createSync(recursive: true)
        ..writeAsStringSync('{corrupt!!!');

      await StepProgressSaver.clearResumeState(outputDir);
      expect(progressFile().existsSync(), isFalse);
    });
  });
}
