import 'dart:io';
import 'package:gpth_neo/gpth_lib_exports.dart';

/// Processing Pipeline for Google Photos Takeout Helper Neo
///
/// This pipeline executes 8 processing steps in their fixed order:
/// 1. Fix Extensions        - Correct mismatched file extensions (configurable)
/// 2. Discover Media        - Find and classify all media files from input directory
/// 3. Remove Duplicates     - Remove duplicate files using content hashing
/// 4. Extract Dates         - Determine accurate timestamps from JSON, EXIF, and filenames
/// 5. Find Albums           - Normalize and consolidate album relationships
/// 6. Move Files            - Organize files to output structure using selected album behavior
/// 7. Write EXIF            - Embed metadata into files already placed in output (requires ExifTool for non-JPEG formats)
/// 8. Update Creation Time  - Sync file creation timestamps (Windows only, configurable)
///
/// Each step checks configuration flags to determine if it should run.
/// This eliminates the need for complex builder patterns while maintaining
/// full flexibility through configuration.
class ProcessingPipeline with LoggerMixin {
  /// Create a processing pipeline
  const ProcessingPipeline({this.interactiveService});

  /// Optional interactive service for displaying processing summaries and results
  final ConsolidatedInteractiveService? interactiveService;

  /// Execute the complete processing pipeline
  ///
  /// Runs all 8 steps in sequence, with each step checking configuration
  /// to determine if it should execute. Returns comprehensive results
  /// including timing, statistics, and any errors encountered.
  Future<ProcessingResult> execute({
    required final ProcessingConfig config,
    required final Directory inputDirectory,
    required final Directory outputDirectory,
  }) async {
    final overallStopwatch = Stopwatch()..start();
    final mediaCollection = MediaEntityCollection();

    // --- Crash-recovery: restore any emoji-renamed source dirs from a previous run ---
    await StepProgressSaver.restoreEmojiRenamesFromProgress(outputDirectory);

    // --- Rename emoji album directories in the input so all steps can list them ---
    final sanitizer = FilenameSanitizerService();
    final Map<String, String> hexToOriginal = {}; // hexPath → originalPath
    if (Platform.isWindows && await inputDirectory.exists()) {
      await for (final entity in inputDirectory.list()) {
        if (entity is Directory) {
          final renamed = sanitizer.encodeAndRenameAlbumIfEmoji(entity);
          if (renamed.path != entity.path) {
            hexToOriginal[renamed.path] = entity.path;
          }
        }
      }
      if (hexToOriginal.isNotEmpty) {
        // Ensure the output directory exists before writing progress (it may not
        // have been created yet at this early stage of the pipeline).
        if (!await outputDirectory.exists()) {
          await outputDirectory.create(recursive: true);
        }
        await StepProgressSaver.saveEmojiRenames(
          outputDirectory,
          hexToOriginal,
        );
      }
    }

    // Create processing context
    final context = ProcessingContext(
      config: config,
      mediaCollection: mediaCollection,
      inputDirectory: inputDirectory,
      outputDirectory: outputDirectory,
    );

    // Configure concurrency manager logging to respect processing configuration
    ConcurrencyManager.logger = LoggingService.fromConfig(context.config);

    // Define the 8 processing steps in the new fixed order
    final List<ProcessingStep> steps = [
      const FixExtensionsStep(), // Step 1
      const DiscoverMediaStep(), // Step 2
      const MergeMediaEntitiesStep(), // Step 3
      const ExtractDatesStep(), // Step 4
      const FindAlbumsStep(), // Step 5
      const MoveMediaEntitiesStep(), // Step 6
      const WriteExifStep(), // Step 7  (after moving)
      const UpdateCreationTimeStep(), // Step 8
    ];

    final stepResults = <StepResult>[];
    final stepTimings = <String, Duration>{};

    // Counters for ProcessingResult
    var duplicatesRemoved = 0;
    var extrasSkipped = 0;
    var extensionsFixed = 0;
    var coordinatesWrittenToExif = 0;
    var dateTimesWrittenToExif = 0;
    var creationTimesUpdated = 0;
    final extractionMethodStats = <DateTimeExtractionMethod, int>{};

    if (config.verbose) {
      logDebug(
        '\n=== Starting Google Photos Takeout Helper Neo Processing ===',
        forcePrint: true,
      );
      logDebug('Input: ${config.inputPath}', forcePrint: true);
      logDebug('Output: ${outputDirectory.path}', forcePrint: true);
      logDebug(
        'Configuration: ${config.albumBehavior.name} album behavior, '
        '${config.dateDivision.name} date division',
        forcePrint: true,
      );
    }

    // Execute each step in sequence
    for (int i = 0; i < steps.length; i++) {
      final step = steps[i];
      final stepNumber = i + 1;

      logPrint('');
      logPrint('▶️ --- Step $stepNumber/8: ${step.name} ---');

      // Check if step should be skipped
      if (step.shouldSkip(context)) {
        if (config.verbose) {
          logDebug(
            'Skipping ${step.name} (conditions not met)',
            forcePrint: true,
          );
        }

        stepResults.add(
          StepResult.success(
            stepName: step.name,
            duration: Duration.zero,
            data: {'skipped': true},
            message: 'Step skipped due to configuration or conditions',
          ),
        );
        continue;
      }

      // Execute the step
      try {
        final result = await step.execute(context);
        stepResults.add(result);
        stepTimings[step.name] = result.duration;

        // Extract statistics from step results
        _extractStepStatistics(
          step,
          result,
          duplicatesRemoved: (final int value) => duplicatesRemoved = value,
          extrasSkipped: (final int value) => extrasSkipped = value,
          extensionsFixed: (final int value) => extensionsFixed = value,
          coordinatesWrittenToExif: (final int value) =>
              coordinatesWrittenToExif = value,
          dateTimesWrittenToExif: (final int value) =>
              dateTimesWrittenToExif = value,
          creationTimesUpdated: (final int value) =>
              creationTimesUpdated = value,
          extractionMethodStats: extractionMethodStats,
        );

        if (result.isSuccess) {
          logPrint(
            '✅ ${step.name} completed in ${const FormattingService().formatDuration(result.duration)}',
          );
          if (result.message != null) logPrint('   ${result.message}');
        } else {
          logPrint('❌ ${step.name} failed: ${result.message}');
          if (result.error != null) logPrint('   Error: ${result.error}');
        }

        // Stop processing if a critical step fails
        if (!result.isSuccess && _isCriticalStep(step)) {
          if (config.verbose) {
            logDebug(
              '\n⚠️  Critical step failed, stopping pipeline execution',
              forcePrint: true,
            );
          }
          break;
        }

        // Stop after extension fixing in solo mode
        if (step is FixExtensionsStep &&
            !config.shouldContinueAfterExtensionFix) {
          if (config.verbose) {
            logDebug(
              '\n⚠️  Extension fixing solo mode complete, stopping pipeline execution',
              forcePrint: true,
            );
          }
          break;
        }
      } catch (e) {
        final error = Exception('Unexpected error in ${step.name}: $e');
        final failureResult = StepResult.failure(
          stepName: step.name,
          duration: Duration.zero,
          error: error,
          message: 'Step failed with unexpected error',
        );

        stepResults.add(failureResult);

        if (config.verbose) {
          logDebug(
            '❌ ${step.name} failed with unexpected error: $e',
            forcePrint: true,
          );
        }

        // Stop on critical step failure
        if (_isCriticalStep(step)) break;
      }
    }

    overallStopwatch.stop();

    // --- Restore emoji-renamed source directories and clear the crash-recovery record ---
    if (hexToOriginal.isNotEmpty) {
      for (final entry in hexToOriginal.entries) {
        final dir = Directory(entry.key);
        if (await dir.exists()) {
          try {
            await dir.rename(entry.value);
          } catch (_) {}
        }
      }
      await StepProgressSaver.clearEmojiRenames(outputDirectory);
    }

    // Calculate final statistics
    final successfulSteps = stepResults
        .where((final StepResult r) => r.isSuccess)
        .length;
    final failedSteps = stepResults
        .where((final StepResult r) => !r.isSuccess)
        .length;
    final skippedSteps = stepResults
        .where((final StepResult r) => r.data['skipped'] == true)
        .length;
    final totalProcessingTime = overallStopwatch.elapsed;

    if (config.verbose && interactiveService != null) {
      // Display warnings and errors summary first
      await interactiveService!.showWarningsAndErrorsSummary(stepResults);

      // Display processing summary
      await interactiveService!.showProcessingSummary(
        totalTime: totalProcessingTime,
        successfulSteps: successfulSteps,
        failedSteps: failedSteps,
        skippedSteps: skippedSteps,
        mediaCount: mediaCollection.length,
      );

      // Display detailed step results
      await interactiveService!.showStepResults(stepResults, stepTimings);
    }

    // Extract low-level operation count from Move Files step if present
    int? operationCount;
    for (final r in stepResults) {
      if (r.stepName == 'Move Files') {
        final oc = r.data['operationCount'];
        if (oc is int) operationCount = oc;
      }
    }

    return ProcessingResult(
      totalProcessingTime: totalProcessingTime,
      stepTimings: stepTimings,
      stepResults: stepResults,
      mediaProcessed: mediaCollection.length,
      duplicatesRemoved: duplicatesRemoved,
      extrasSkipped: extrasSkipped,
      extensionsFixed: extensionsFixed,
      coordinatesWrittenToExif: coordinatesWrittenToExif,
      dateTimesWrittenToExif: dateTimesWrittenToExif,
      creationTimesUpdated: creationTimesUpdated,
      extractionMethodStats: extractionMethodStats,
      albumBehavior: config.albumBehavior,
      totalMoveOperations: operationCount,
      isSuccess: failedSteps == 0,
    );
  }

  /// Determine if a step is critical for processing
  ///
  /// Critical steps will stop the pipeline if they fail
  bool _isCriticalStep(final ProcessingStep step) =>
      step is DiscoverMediaStep || step is MoveMediaEntitiesStep;

  /// Extract statistics from individual step results
  void _extractStepStatistics(
    final ProcessingStep step,
    final StepResult result, {
    required final Function(int) duplicatesRemoved,
    required final Function(int) extrasSkipped,
    required final Function(int) extensionsFixed,
    required final Function(int) coordinatesWrittenToExif,
    required final Function(int) dateTimesWrittenToExif,
    required final Function(int) creationTimesUpdated,
    required final Map<DateTimeExtractionMethod, int> extractionMethodStats,
  }) {
    final data = result.data;

    if (step is DiscoverMediaStep) {
      extrasSkipped(data['extrasSkipped'] as int? ?? 0);
    } else if (step is MergeMediaEntitiesStep) {
      duplicatesRemoved(data['duplicatesRemoved'] as int? ?? 0);
    } else if (step is FixExtensionsStep) {
      extensionsFixed(data['extensionsFixed'] as int? ?? 0);
    } else if (step is WriteExifStep) {
      coordinatesWrittenToExif(data['coordinatesWritten'] as int? ?? 0);
      dateTimesWrittenToExif(data['dateTimesWritten'] as int? ?? 0);
    } else if (step is UpdateCreationTimeStep) {
      creationTimesUpdated(data['creationTimesUpdated'] as int? ?? 0);
    } else if (step is ExtractDatesStep) {
      // Robustly merge stats coming from Step 4:
      // - Keys may be DateTimeExtractionMethod (enum) or String ("json", or "DateTimeExtractionMethod.json").
      // - Always accumulate counts instead of overwriting.
      final stepStats = data['extractionStats'] as Map<dynamic, dynamic>? ?? {};
      for (final entry in stepStats.entries) {
        final dynamic rawKey = entry.key;
        final int count = entry.value as int? ?? 0;

        if (rawKey is DateTimeExtractionMethod) {
          final m = rawKey;
          extractionMethodStats[m] = (extractionMethodStats[m] ?? 0) + count;
        } else {
          final methodNameRaw = rawKey.toString();
          final normalized = methodNameRaw.contains('.')
              ? methodNameRaw.split('.').last
              : methodNameRaw;
          DateTimeExtractionMethod? mapped;
          for (final m in DateTimeExtractionMethod.values) {
            if (m.name == normalized) {
              mapped = m;
              break;
            }
          }
          mapped ??= DateTimeExtractionMethod.none;
          extractionMethodStats[mapped] =
              (extractionMethodStats[mapped] ?? 0) + count;
        }
      }
    }
  }
}
