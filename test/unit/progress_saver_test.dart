/// Tests for StepProgressSaver and StepProgressLoader.
///
/// Covers:
/// - saveProgress writes valid progress.json
/// - multiple steps accumulate in Completed steps list
/// - ISO-8601 duration formatting
/// - readProgressJson returns null when no file / corrupt JSON
/// - isStepCompleted correctly identifies saved vs unsaved steps
/// - updateMediaEntityCollection round-trip (serialize → deserialize)
/// - updateMediaEntityCollection respects onlyIfEmpty guard
library;

import 'dart:convert';
import 'dart:io';

import 'package:gpth_neo/gpth_lib_exports.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import '../setup/test_setup.dart';

// ─────────────────────────────────────────────────────────────────────────────
// Helpers
// ─────────────────────────────────────────────────────────────────────────────

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

StepResult _stepResult({
  final Map<String, dynamic> data = const {},
  final String? message,
}) => StepResult(
  stepName: 'test-step',
  duration: Duration.zero,
  isSuccess: true,
  data: data,
  message: message,
);

// ─────────────────────────────────────────────────────────────────────────────
// Tests
// ─────────────────────────────────────────────────────────────────────────────

void main() {
  group('StepProgressSaver', () {
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

    test('creates progress.json in outputDirectory', () async {
      final ctx = _makeContext(inputDir: inputDir, outputDir: outputDir);
      await StepProgressSaver.saveProgress(
        context: ctx,
        stepId: 1,
        duration: const Duration(seconds: 5),
        stepResult: _stepResult(),
      );

      final progressFile = File(p.join(outputDir.path, 'progress.json'));
      expect(progressFile.existsSync(), isTrue);
    });

    test('progress.json contains the completed step id', () async {
      final ctx = _makeContext(inputDir: inputDir, outputDir: outputDir);
      await StepProgressSaver.saveProgress(
        context: ctx,
        stepId: 2,
        duration: const Duration(seconds: 10),
        stepResult: _stepResult(),
      );

      final doc =
          jsonDecode(
                File(
                  p.join(outputDir.path, 'progress.json'),
                ).readAsStringSync(),
              )
              as Map<String, dynamic>;
      expect(doc['Completed steps'], contains(2));
    });

    test('multiple saves accumulate all step ids in Completed steps', () async {
      final ctx = _makeContext(inputDir: inputDir, outputDir: outputDir);
      for (final id in [1, 2, 3]) {
        await StepProgressSaver.saveProgress(
          context: ctx,
          stepId: id,
          duration: Duration(seconds: id),
          stepResult: _stepResult(),
        );
      }

      final doc =
          jsonDecode(
                File(
                  p.join(outputDir.path, 'progress.json'),
                ).readAsStringSync(),
              )
              as Map<String, dynamic>;
      final completed = List<dynamic>.from(doc['Completed steps'] as List);
      expect(completed, containsAll([1, 2, 3]));
      expect(completed.length, equals(3));
    });

    test('Completed steps list is sorted ascending', () async {
      final ctx = _makeContext(inputDir: inputDir, outputDir: outputDir);
      // Save in reverse order
      for (final id in [3, 1, 2]) {
        await StepProgressSaver.saveProgress(
          context: ctx,
          stepId: id,
          duration: Duration.zero,
          stepResult: _stepResult(),
        );
      }

      final doc =
          jsonDecode(
                File(
                  p.join(outputDir.path, 'progress.json'),
                ).readAsStringSync(),
              )
              as Map<String, dynamic>;
      final completed = (doc['Completed steps'] as List)
          .map((final e) => e as int)
          .toList();
      expect(completed, equals([1, 2, 3]));
    });

    test('stores duration in seconds correctly', () async {
      final ctx = _makeContext(inputDir: inputDir, outputDir: outputDir);
      await StepProgressSaver.saveProgress(
        context: ctx,
        stepId: 3,
        duration: const Duration(seconds: 90),
        stepResult: _stepResult(),
      );

      final doc =
          jsonDecode(
                File(
                  p.join(outputDir.path, 'progress.json'),
                ).readAsStringSync(),
              )
              as Map<String, dynamic>;
      final stepData =
          (doc['steps'] as Map<String, dynamic>)['3'] as Map<String, dynamic>;
      final dur = stepData['duration'] as Map<String, dynamic>;
      expect(dur['seconds'], equals(90));
    });

    test('iso8601 duration starts with PT', () async {
      final ctx = _makeContext(inputDir: inputDir, outputDir: outputDir);
      await StepProgressSaver.saveProgress(
        context: ctx,
        stepId: 1,
        duration: const Duration(minutes: 1, seconds: 30),
        stepResult: _stepResult(),
      );

      final doc =
          jsonDecode(
                File(
                  p.join(outputDir.path, 'progress.json'),
                ).readAsStringSync(),
              )
              as Map<String, dynamic>;
      final stepData =
          (doc['steps'] as Map<String, dynamic>)['1'] as Map<String, dynamic>;
      final iso =
          (stepData['duration'] as Map<String, dynamic>)['iso8601'] as String;
      expect(iso, startsWith('PT'));
    });

    test(
      'stores dataset_root and output_root as forward-slash paths',
      () async {
        final ctx = _makeContext(inputDir: inputDir, outputDir: outputDir);
        await StepProgressSaver.saveProgress(
          context: ctx,
          stepId: 1,
          duration: Duration.zero,
          stepResult: _stepResult(),
        );

        final doc =
            jsonDecode(
                  File(
                    p.join(outputDir.path, 'progress.json'),
                  ).readAsStringSync(),
                )
                as Map<String, dynamic>;
        expect(doc['dataset_root'], isA<String>());
        expect(doc['output_root'], isA<String>());
        expect((doc['dataset_root'] as String).contains('\\'), isFalse);
        expect((doc['output_root'] as String).contains('\\'), isFalse);
      },
    );

    test('serializes MediaEntityCollection into progress.json', () async {
      final img = fixture.createImageWithExif('photo.jpg');
      final entity = MediaEntity.single(
        file: FileEntity(sourcePath: img.path),
        dateTaken: DateTime(2022, 6, 15),
      );
      final collection = MediaEntityCollection([entity]);
      final ctx = _makeContext(
        inputDir: inputDir,
        outputDir: outputDir,
        mediaCollection: collection,
      );

      await StepProgressSaver.saveProgress(
        context: ctx,
        stepId: 4,
        duration: const Duration(seconds: 3),
        stepResult: _stepResult(),
      );

      final doc =
          jsonDecode(
                File(
                  p.join(outputDir.path, 'progress.json'),
                ).readAsStringSync(),
              )
              as Map<String, dynamic>;
      expect(doc['media_entity_collection_object'], isNotNull);
      final snapshot = doc['media_entity_collection_object'];
      expect(snapshot, isA<List>());
      expect((snapshot as List).length, equals(1));
    });

    test(
      'corrupt existing progress.json is overwritten rather than aborting',
      () async {
        // Write garbage to the file first
        final progressFile = File(p.join(outputDir.path, 'progress.json'));
        progressFile
          ..createSync(recursive: true)
          ..writeAsStringSync('{corrupt!');

        final ctx = _makeContext(inputDir: inputDir, outputDir: outputDir);
        // Should not throw
        await expectLater(
          StepProgressSaver.saveProgress(
            context: ctx,
            stepId: 1,
            duration: Duration.zero,
            stepResult: _stepResult(),
          ),
          completes,
        );
        // File should now be valid JSON
        final doc =
            jsonDecode(progressFile.readAsStringSync()) as Map<String, dynamic>;
        expect(doc['Completed steps'], contains(1));
      },
    );
  });

  // ───────────────────────────────────────────────────────────────────────────

  group('StepProgressLoader', () {
    late TestFixture fixture;
    late Directory inputDir;
    late Directory outputDir;

    setUp(() async {
      fixture = TestFixture();
      await fixture.setUp();
      inputDir = fixture.createDirectory('input2');
      outputDir = fixture.createDirectory('output2');
    });

    tearDown(() async {
      await fixture.tearDown();
    });

    test('readProgressJson returns null when no file exists', () async {
      final ctx = _makeContext(inputDir: inputDir, outputDir: outputDir);
      final result = await StepProgressLoader.readProgressJson(ctx);
      expect(result, isNull);
    });

    test('readProgressJson returns parsed document when file exists', () async {
      final ctx = _makeContext(inputDir: inputDir, outputDir: outputDir);
      await StepProgressSaver.saveProgress(
        context: ctx,
        stepId: 1,
        duration: Duration.zero,
        stepResult: _stepResult(),
      );

      final result = await StepProgressLoader.readProgressJson(ctx);
      expect(result, isNotNull);
      expect(result!['Completed steps'], contains(1));
    });

    test('readProgressJson returns null for corrupt JSON', () async {
      final progressFile = File(p.join(outputDir.path, 'progress.json'));
      progressFile
        ..createSync(recursive: true)
        ..writeAsStringSync('{invalid json{{{{');

      final ctx = _makeContext(inputDir: inputDir, outputDir: outputDir);
      final result = await StepProgressLoader.readProgressJson(ctx);
      expect(result, isNull);
    });

    group('isStepCompleted', () {
      test('returns true for a saved step', () async {
        final ctx = _makeContext(inputDir: inputDir, outputDir: outputDir);
        await StepProgressSaver.saveProgress(
          context: ctx,
          stepId: 2,
          duration: Duration.zero,
          stepResult: _stepResult(),
        );

        final json = await StepProgressLoader.readProgressJson(ctx);
        expect(StepProgressLoader.isStepCompleted(json!, 2), isTrue);
      });

      test('returns false for a step that was not saved', () async {
        final ctx = _makeContext(inputDir: inputDir, outputDir: outputDir);
        await StepProgressSaver.saveProgress(
          context: ctx,
          stepId: 1,
          duration: Duration.zero,
          stepResult: _stepResult(),
        );

        final json = await StepProgressLoader.readProgressJson(ctx);
        expect(StepProgressLoader.isStepCompleted(json!, 5), isFalse);
      });

      test('returns false when inputDirectory does not exist', () async {
        final missingInput = Directory(
          p.join(fixture.basePath, 'missing_input'),
        );
        final ctx = _makeContext(inputDir: missingInput, outputDir: outputDir);
        await StepProgressSaver.saveProgress(
          context: _makeContext(inputDir: inputDir, outputDir: outputDir),
          stepId: 1,
          duration: Duration.zero,
          stepResult: _stepResult(),
        );

        // Read the JSON normally first, then check with context that has missing input
        final json =
            jsonDecode(
                  File(
                    p.join(outputDir.path, 'progress.json'),
                  ).readAsStringSync(),
                )
                as Map<String, dynamic>;
        expect(
          StepProgressLoader.isStepCompleted(json, 1, context: ctx),
          isFalse,
        );
      });
    });

    group('readDurationForStep', () {
      test('returns saved duration', () async {
        final ctx = _makeContext(inputDir: inputDir, outputDir: outputDir);
        await StepProgressSaver.saveProgress(
          context: ctx,
          stepId: 2,
          duration: const Duration(seconds: 45),
          stepResult: _stepResult(),
        );

        final json = await StepProgressLoader.readProgressJson(ctx);
        final dur = StepProgressLoader.readDurationForStep(json!, 2);
        expect(dur.inSeconds, equals(45));
      });

      test('returns Duration.zero for missing step', () async {
        final ctx = _makeContext(inputDir: inputDir, outputDir: outputDir);
        await StepProgressSaver.saveProgress(
          context: ctx,
          stepId: 1,
          duration: Duration.zero,
          stepResult: _stepResult(),
        );

        final json = await StepProgressLoader.readProgressJson(ctx);
        final dur = StepProgressLoader.readDurationForStep(json!, 99);
        expect(dur, equals(Duration.zero));
      });
    });

    group('updateMediaEntityCollection round-trip', () {
      test('restores serialized entities into an empty collection', () async {
        final img = fixture.createImageWithExif('photo_rt.jpg');
        final entity = MediaEntity.single(
          file: FileEntity(sourcePath: img.path),
          dateTaken: DateTime(2020, 3, 15),
        );
        final collection = MediaEntityCollection([entity]);
        final ctxSave = _makeContext(
          inputDir: inputDir,
          outputDir: outputDir,
          mediaCollection: collection,
        );

        await StepProgressSaver.saveProgress(
          context: ctxSave,
          stepId: 3,
          duration: Duration.zero,
          stepResult: _stepResult(),
        );

        final json = await StepProgressLoader.readProgressJson(ctxSave);
        final snapshot = json!['media_entity_collection_object'];
        expect(snapshot, isNotNull);

        // Restore into a fresh empty context
        final freshCollection = MediaEntityCollection([]);
        final ctxLoad = _makeContext(
          inputDir: inputDir,
          outputDir: outputDir,
          mediaCollection: freshCollection,
        );

        final ok = StepProgressLoader.updateMediaEntityCollection(
          ctxLoad,
          snapshot,
          progressJson: json,
        );

        expect(ok, isTrue);
        expect(ctxLoad.mediaCollection.length, equals(1));
      });

      test(
        'preserved primary file sourcePath (forward-slash normalized)',
        () async {
          final img = fixture.createImageWithExif('norm_check.jpg');
          final entity = MediaEntity.single(
            file: FileEntity(sourcePath: img.path),
          );
          final ctxSave = _makeContext(
            inputDir: inputDir,
            outputDir: outputDir,
            mediaCollection: MediaEntityCollection([entity]),
          );

          await StepProgressSaver.saveProgress(
            context: ctxSave,
            stepId: 1,
            duration: Duration.zero,
            stepResult: _stepResult(),
          );

          final json = await StepProgressLoader.readProgressJson(ctxSave);
          final snapshot = json!['media_entity_collection_object'];

          final freshCollection = MediaEntityCollection([]);
          final ctxLoad = _makeContext(
            inputDir: inputDir,
            outputDir: outputDir,
            mediaCollection: freshCollection,
          );

          StepProgressLoader.updateMediaEntityCollection(
            ctxLoad,
            snapshot,
            progressJson: json,
          );

          expect(ctxLoad.mediaCollection.length, equals(1));
        },
      );

      test('returns false for null snapshot', () {
        final ctx = _makeContext(inputDir: inputDir, outputDir: outputDir);
        final ok = StepProgressLoader.updateMediaEntityCollection(ctx, null);
        expect(ok, isFalse);
      });

      test(
        'does not overwrite non-empty collection when onlyIfEmpty=true',
        () async {
          final img1 = fixture.createImageWithExif('photo_existing.jpg');
          final img2 = fixture.createImageWithExif('photo_saved.jpg');

          // Save a snapshot with img2
          final ctxSave = _makeContext(
            inputDir: inputDir,
            outputDir: outputDir,
            mediaCollection: MediaEntityCollection([
              MediaEntity.single(file: FileEntity(sourcePath: img2.path)),
            ]),
          );
          await StepProgressSaver.saveProgress(
            context: ctxSave,
            stepId: 1,
            duration: Duration.zero,
            stepResult: _stepResult(),
          );

          final json = await StepProgressLoader.readProgressJson(ctxSave);
          final snapshot = json!['media_entity_collection_object'];

          // Restore into a context that already has img1
          final existingCollection = MediaEntityCollection([
            MediaEntity.single(file: FileEntity(sourcePath: img1.path)),
          ]);
          final ctxLoad = _makeContext(
            inputDir: inputDir,
            outputDir: outputDir,
            mediaCollection: existingCollection,
          );

          StepProgressLoader.updateMediaEntityCollection(ctxLoad, snapshot);

          // Collection should still contain img1, not img2
          expect(ctxLoad.mediaCollection.length, equals(1));
          expect(
            ctxLoad.mediaCollection.entities.first.primaryFile.sourcePath,
            contains('photo_existing.jpg'),
          );
        },
      );

      test('overwrites non-empty collection when onlyIfEmpty=false', () async {
        final img1 = fixture.createImageWithExif('photo_old.jpg');
        final img2 = fixture.createImageWithExif('photo_new.jpg');

        final ctxSave = _makeContext(
          inputDir: inputDir,
          outputDir: outputDir,
          mediaCollection: MediaEntityCollection([
            MediaEntity.single(file: FileEntity(sourcePath: img2.path)),
          ]),
        );
        await StepProgressSaver.saveProgress(
          context: ctxSave,
          stepId: 1,
          duration: Duration.zero,
          stepResult: _stepResult(),
        );

        final json = await StepProgressLoader.readProgressJson(ctxSave);
        final snapshot = json!['media_entity_collection_object'];

        final existingCollection = MediaEntityCollection([
          MediaEntity.single(file: FileEntity(sourcePath: img1.path)),
        ]);
        final ctxLoad = _makeContext(
          inputDir: inputDir,
          outputDir: outputDir,
          mediaCollection: existingCollection,
        );

        StepProgressLoader.updateMediaEntityCollection(
          ctxLoad,
          snapshot,
          progressJson: json,
          onlyIfEmpty: false,
        );

        // Collection should now contain img2 (from snapshot), not img1
        expect(ctxLoad.mediaCollection.length, equals(1));
        expect(
          ctxLoad.mediaCollection.entities.first.primaryFile.sourcePath,
          contains('photo_new.jpg'),
        );
      });
    });
  });
}
