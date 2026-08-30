// Step 5 (wrapper) - FindAlbumsStep
import 'package:gpth_neo/gpth_lib_exports.dart';

/// Step 5: Consolidate and normalize album memberships
///
/// In the new data model, Step 3 already consolidated duplicates and selected a
/// single primary per entity, so this step performs **no content-based merging**.
/// Instead, it consolidates and normalizes the album memberships already stored
/// in each `MediaEntity.albumsMap`:
/// - Sanitizes album names (trims whitespace).
/// - Merges `AlbumEntity` values that collide on the same sanitized key.
/// - Ensures each membership has at least one `sourceDirectory` (falling back to
///   the parent folder of `primaryFile` when none is recorded).
/// - Emits album statistics (`mergedCount`/`groupsMerged`/`albumsMerged`).
///
/// Album-behavior-specific work (shortcuts, duplicate copies, JSON output) is
/// performed later by Step 6 (Move Files) strategies, not here.
class FindAlbumsStep extends ProcessingStep with LoggerMixin {
  const FindAlbumsStep() : super('Find Albums');

  @override
  Future<StepResult> execute(final ProcessingContext context) async {
    const int stepId = 5;
    final resumed = await checkResume(context, stepId);
    if (resumed != null) {
      logPrint(
        '[Step $stepId/8] Auto-Resume enabled: step already completed previously, loading results from progress.json',
      );
      return resumed;
    }
    final stopWatch = Stopwatch()..start();

    try {
      if (context.mediaCollection.isEmpty) {
        stopWatch.stop();
        final stepResult = StepResult.success(
          stepName: name,
          duration: stopWatch.elapsed,
          data: {'mergedCount': 0, 'groupsMerged': 0, 'albumsMerged': 0},
          message: 'No media to process.',
        );
        // Persist progress.json only on success (do NOT save on failure)
        await StepProgressSaver.saveProgress(
          context: context,
          stepId: stepId,
          duration: stopWatch.elapsed,
          stepResult: stepResult,
        );
        return stepResult;
      }

      final service = const FindAlbumService()
        ..logger = LoggingService.fromConfig(context.config);
      final FindAlbumSummary summary = await service.findAlbums(context);

      stopWatch.stop();
      final stepResult = StepResult.success(
        stepName: name,
        duration: stopWatch.elapsed,
        data: summary.toMap(),
        message: summary.message,
      );

      // Persist progress.json only on success (do NOT save on failure)
      await StepProgressSaver.saveProgress(
        context: context,
        stepId: stepId,
        duration: stopWatch.elapsed,
        stepResult: stepResult,
      );

      return stepResult;
    } catch (e) {
      stopWatch.stop();
      return StepResult.failure(
        stepName: name,
        duration: stopWatch.elapsed,
        error: e is Exception ? e : Exception(e.toString()),
        message: 'Failed to find albums: $e',
      );
    }
  }

  @override
  bool shouldSkip(final ProcessingContext context) =>
      context.mediaCollection.isEmpty;
}
