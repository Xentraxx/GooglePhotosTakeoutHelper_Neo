// Step 6 (wrapper) - MoveMediaEntitiesStep
// ignore_for_file: unintended_html_in_doc_comment

import 'package:gpth_neo/gpth_lib_exports.dart';

/// Step 6: Move files to output directory
///
/// Delegates the moving logic to the selected strategy (Nothing, JSON, Shortcut,
/// Reverse-Shortcut, Duplicate-Copy, Ignore). Now we consider both primaryFile and
/// secondaryFiles per strategy requirements.
///
/// IMPORTANT (FileEntity model):
/// - After each move/copy/symlink, strategies MUST update the involved FileEntity:
///   fe.targetPath = <final path in output>;
///   fe.isShortcut = true when a shortcut is created (false otherwise).
class MoveMediaEntitiesStep extends ProcessingStep with LoggerMixin {
  const MoveMediaEntitiesStep() : super('Move Files');

  @override
  Future<StepResult> execute(final ProcessingContext context) async {
    const int stepId = 6;
    final resumed = await checkResume(context, stepId);
    if (resumed != null) {
      logPrint(
        '[Step $stepId/8] Auto-Resume enabled: step already completed previously, loading results from progress.json',
      );
      return resumed;
    }
    final stopWatch = Stopwatch()..start();

    try {
      final service = MoveMediaEntityService()
        ..logger = LoggingService.fromConfig(context.config);
      final MoveFilesSummary summary = await service.moveAll(context);

      stopWatch.stop();
      final stepResult = StepResult.success(
        stepName: name,
        duration: stopWatch.elapsed,
        data: {
          'entitiesProcessed': summary.entitiesProcessed,
          'transformedCount': summary.transformedCount,
          'albumBehavior':
              summary.albumBehaviorValue, // keep original behavior: String
          'primaryMovedCount': summary.primaryMovedCount,
          'nonPrimaryMoves': summary.nonPrimaryMoves,
          'symlinksCreated': summary.symlinksCreated,
          'deletes': summary.deletesCount,
        },
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
        message: 'Failed to move files: $e',
      );
    }
  }

  @override
  bool shouldSkip(final ProcessingContext context) =>
      context.mediaCollection.isEmpty;
}
