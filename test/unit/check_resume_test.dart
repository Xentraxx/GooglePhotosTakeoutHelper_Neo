/// Tests for ProcessingStep.checkResume().
///
/// Covers:
/// - disableResumeCheck=true → always returns null
/// - no progress.json → returns null
/// - step not in completed list → returns null
/// - step completed → returns StepResult.success
/// - restored data map matches what was saved
/// - restored duration matches what was saved
/// - stored message is surfaced as result.message
/// - empty stored message → fallback message contains step id
/// - updateMediaEntityCollection repopulates collection on resume
/// - corrupt progress.json → swallowed, returns null
library;

import 'dart:io';

import 'package:gpth_neo/gpth_lib_exports.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import '../setup/test_setup.dart';

// ─────────────────────────────────────────────────────────────────────────────
// Minimal concrete ProcessingStep used only in this file
// ─────────────────────────────────────────────────────────────────────────────

class _TestStep extends ProcessingStep {
  const _TestStep() : super('Test Step');

  @override
  Future<StepResult> execute(final ProcessingContext context) async =>
      StepResult.success(stepName: name, duration: Duration.zero);
}

// ─────────────────────────────────────────────────────────────────────────────
// Helpers
// ─────────────────────────────────────────────────────────────────────────────

ProcessingContext _makeContext({
  required final Directory inputDir,
  required final Directory outputDir,
  final bool disableResumeCheck = false,
  final MediaEntityCollection? mediaCollection,
}) => ProcessingContext(
  config: ProcessingConfig(
    inputPath: inputDir.path,
    outputPath: outputDir.path,
    disableResumeCheck: disableResumeCheck,
  ),
  mediaCollection: mediaCollection ?? MediaEntityCollection([]),
  inputDirectory: inputDir,
  outputDirectory: outputDir,
);

const _step = _TestStep();

/// Saves a completed step into progress.json so checkResume can find it.
Future<void> _saveStep(
  final ProcessingContext ctx,
  final int stepId, {
  final Duration duration = Duration.zero,
  final Map<String, dynamic> data = const {},
  final String? message,
}) => StepProgressSaver.saveProgress(
  context: ctx,
  stepId: stepId,
  duration: duration,
  stepResult: StepResult(
    stepName: 'Test Step',
    duration: duration,
    isSuccess: true,
    data: data,
    message: message,
  ),
);

// ─────────────────────────────────────────────────────────────────────────────
// Tests
// ─────────────────────────────────────────────────────────────────────────────

void main() {
  group('ProcessingStep.checkResume', () {
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

    test(
      'returns null when disableResumeCheck is true, even if step saved',
      () async {
        final ctx = _makeContext(
          inputDir: inputDir,
          outputDir: outputDir,
          disableResumeCheck: true,
        );
        await _saveStep(ctx, 1);

        final result = await _step.checkResume(ctx, 1);
        expect(result, isNull);
      },
    );

    test('returns null when progress.json does not exist', () async {
      final ctx = _makeContext(inputDir: inputDir, outputDir: outputDir);

      final result = await _step.checkResume(ctx, 1);
      expect(result, isNull);
    });

    test('returns null when step id is not in completed list', () async {
      final ctx = _makeContext(inputDir: inputDir, outputDir: outputDir);
      await _saveStep(ctx, 2); // save step 2, query step 1

      final result = await _step.checkResume(ctx, 1);
      expect(result, isNull);
    });

    test('returns StepResult.success when step is completed', () async {
      final ctx = _makeContext(inputDir: inputDir, outputDir: outputDir);
      await _saveStep(ctx, 3);

      final result = await _step.checkResume(ctx, 3);
      expect(result, isNotNull);
      expect(result!.isSuccess, isTrue);
    });

    test('restored data map matches saved data', () async {
      final ctx = _makeContext(inputDir: inputDir, outputDir: outputDir);
      const savedData = {'filesFixed': 42, 'skipped': false};
      await _saveStep(ctx, 4, data: savedData);

      final result = await _step.checkResume(ctx, 4);
      expect(result, isNotNull);
      expect(result!.data['filesFixed'], equals(42));
    });

    test('restored duration matches saved duration', () async {
      final ctx = _makeContext(inputDir: inputDir, outputDir: outputDir);
      const savedDuration = Duration(seconds: 37);
      await _saveStep(ctx, 5, duration: savedDuration);

      final result = await _step.checkResume(ctx, 5);
      expect(result, isNotNull);
      expect(result!.duration.inSeconds, equals(37));
    });

    test('stored message is surfaced as result.message', () async {
      final ctx = _makeContext(inputDir: inputDir, outputDir: outputDir);
      await _saveStep(ctx, 6, message: 'custom saved message');

      final result = await _step.checkResume(ctx, 6);
      expect(result, isNotNull);
      expect(result!.message, equals('custom saved message'));
    });

    test(
      'empty stored message produces fallback message with step id',
      () async {
        final ctx = _makeContext(inputDir: inputDir, outputDir: outputDir);
        // saveProgress stores an empty string when message is null
        await _saveStep(ctx, 7);

        final result = await _step.checkResume(ctx, 7);
        expect(result, isNotNull);
        expect(result!.message, contains('7'));
        expect(result.message, contains('progress.json'));
      },
    );

    test(
      'updateMediaEntityCollection repopulates collection on resume',
      () async {
        // Save a context that has one entity
        final img = fixture.createImageWithExif('photo.jpg');
        final entity = MediaEntity.single(
          file: FileEntity(sourcePath: img.path),
          dateTaken: DateTime(2023),
        );
        final populatedCollection = MediaEntityCollection([entity]);
        final saveCtx = _makeContext(
          inputDir: inputDir,
          outputDir: outputDir,
          mediaCollection: populatedCollection,
        );
        await _saveStep(saveCtx, 3);

        // Load into a fresh empty collection
        final emptyCollection = MediaEntityCollection([]);
        final loadCtx = _makeContext(
          inputDir: inputDir,
          outputDir: outputDir,
          mediaCollection: emptyCollection,
        );

        final result = await _step.checkResume(loadCtx, 3);
        expect(result, isNotNull);
        expect(loadCtx.mediaCollection.isNotEmpty, isTrue);
      },
    );

    test('corrupt progress.json is swallowed and returns null', () async {
      // Write garbage directly to progress.json
      final progressFile = File(p.join(outputDir.path, 'progress.json'));
      progressFile
        ..createSync(recursive: true)
        ..writeAsStringSync('{corrupt!!!');

      final ctx = _makeContext(inputDir: inputDir, outputDir: outputDir);

      final result = await _step.checkResume(ctx, 1);
      expect(result, isNull);
    });
  });
}
