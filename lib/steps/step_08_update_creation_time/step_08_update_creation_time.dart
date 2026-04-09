// Step 8 wrapper module: UpdateCreationTimeStep
import 'dart:async';

import 'package:gpth_neo/gpth_lib_exports.dart';

/// Step 8: Update creation times (Windows only)
///
/// This Windows-specific final step synchronizes file creation timestamps with their
/// modification times to ensure proper chronological sorting in Windows Explorer and
/// other file managers that rely on creation time for organization.
///
/// ## Purpose and Rationale
///
/// ### Windows File System Behavior
/// - **Creation vs Modification Time**: Windows tracks both creation and modification timestamps
/// - **File Manager Sorting**: Windows Explorer often sorts by creation time by default
/// - **Photo Viewer Behavior**: Many photo viewers use creation time for chronological display
/// - **Backup Software**: Some backup tools rely on creation time for change detection
///
/// ### Google Photos Export Issues
/// - **Incorrect Creation Times**: Exported files often have creation time = export time
/// - **Chronological Confusion**: Photos appear in wrong order due to export timestamps
/// - **Date Mismatch**: Creation time doesn't match actual photo date
/// - **User Experience**: Confusing timeline when browsing organized photos
///
/// ## Processing Logic
///
/// ### Timestamp Synchronization
/// 1. **Source Timestamp**: Uses the entity's authoritative `dateTaken`
/// 2. **Target Timestamp**: Sets both CreationTime and LastWriteTime to `dateTaken`
/// 3. **Preservation**: Keeps LastAccessTime unchanged
/// 4. **Verification**: Confirms timestamp update was successful (treated as updated on success)
///
/// ### Platform Detection
/// - **Windows Only**: Operation is only performed on Windows systems
/// - **Graceful Skipping**: Silently skips on non-Windows platforms
/// - **Cross-Platform Compatibility**: Uses Dart's Platform detection for safety
///
/// ## Configuration and Control
///
/// ### User Options
/// - **Enable/Disable**: Controlled by `updateCreationTime` configuration flag
/// - **Verbose Logging**: Provides detailed progress when verbose mode enabled
/// - **Error Reporting**: Reports any files that couldn't be updated
/// - **Statistics**: Tracks number of files successfully updated
///
/// ### Safety Features
/// - **Non-Destructive**: Only modifies timestamps, never file content
/// - **Error Recovery**: Continues processing if individual files fail
/// - **Permission Respect**: Skips files that can't be modified due to permissions
///
/// ### Step Sequencing
/// - **Final Step**: Runs as the last step after all file operations complete
/// - **Post-Processing**: Applied after files are in their final locations
/// - **Non-Critical**: Failure doesn't affect core functionality
/// - **Optional**: Can be safely skipped without affecting main workflow
///
/// ### Prerequisites
/// - **Completed File Organization**: Files must be in final output locations
/// - **Windows Platform**: Only runs on Windows operating systems
/// - **Configuration Flag**: Must be explicitly enabled by user
/// - **File Accessibility**: Files must be writable for timestamp modification
///
/// ## Benefits and Use Cases
///
/// ### User Experience Improvements
/// - **Chronological Browsing**: Photos appear in correct order in Windows Explorer
/// - **Date-Based Organization**: File managers can properly sort by creation date
/// - **Photo Viewer Compatibility**: Improves experience with Windows photo applications
/// - **Backup Software**: Ensures backup tools see correct file dates
///
/// ### Professional Workflows
/// - **Digital Asset Management**: Supports professional photo management workflows
/// - **Archive Organization**: Improves long-term photo archive organization
/// - **Client Delivery**: Ensures photos are properly timestamped for client delivery
/// - **System Integration**: Better integration with Windows-based photo workflows
///
/// ## Technical Considerations
///
/// ### File System Impact
/// - **Minimal Overhead**: Very low impact on file system performance
/// - **Journal Updates**: May trigger file system journal updates
/// - **Index Updates**: May cause Windows Search index updates
/// - **Backup Impact**: May affect incremental backup change detection
///
/// ### Security and Permissions
/// - **User Permissions**: Respects current user's file permissions
/// - **Administrator Rights**: May require elevated permissions for some files
/// - **Security Descriptors**: Preserves file security information
/// - **Audit Trails**: May generate file system audit events
class UpdateCreationTimeStep extends ProcessingStep with LoggerMixin {
  const UpdateCreationTimeStep() : super('Update Creation Time');

  @override
  Future<StepResult> execute(final ProcessingContext context) async {
    const int stepId = 8;
    final resumed = await checkResume(context, stepId);
    if (resumed != null) {
      logPrint(
        '[Step $stepId/8] Auto-Resume enabled: step already completed previously, loading results from progress.json',
      );
      return resumed;
    }
    final stopWatch = Stopwatch()..start();

    try {
      final service = UpdateCreationTimeService()
        ..logger = LoggingService.fromConfig(context.config);
      final UpdateCreationTimeSummary s = await service.updateCreationTimes(
        context,
      );

      stopWatch.stop();
      final stepResult = StepResult.success(
        stepName: name,
        duration: stopWatch.elapsed,
        data: {
          'updatedCount': s.updatedCount,
          'failedCount': s.failedCount,
          'updatedPhysical': s.updatedPhysical,
          'updatedShortcuts': s.updatedShortcuts,
          'failedPhysical': s.failedPhysical,
          'failedShortcuts': s.failedShortcuts,
          'skipped': s.skipped,
        },
        message: s.message,
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
        message: 'Failed to update creation times: $e',
      );
    }
  }

  @override
  bool shouldSkip(final ProcessingContext context) {
    final shouldSkipStep = !context.config.updateCreationTime;

    if (shouldSkipStep) {
      const reason = 'disabled in configuration';
      logWarning(
        '[Step 8/8] Skipping creation time update ($reason).',
        forcePrint: true,
      );
    }

    return shouldSkipStep;
  }
}
