import 'package:gpth_neo/gpth_lib_exports.dart';

/// Step 1: Fix incorrect file extensions
///
/// This step identifies and fixes files where the extension doesn't match
/// the actual MIME type, which commonly occurs when Google Photos compresses
/// images but keeps original extensions or when web-downloaded images have
/// incorrect extensions.
///
/// ## Purpose
/// Google Photos Takeout often contains files with mismatched extensions:
/// - Images compressed to JPEG but keeping original extension (e.g., `.png`)
/// - HEIF files exported with `.jpeg` extension
/// - Web-downloaded images with generic extensions
/// - Files processed through various photo editing tools
///
/// ## Processing Logic
/// 1. Scans all photo/video files recursively in the input directory
/// 2. Reads first 128 bytes of each file to determine actual MIME type
/// 3. Compares with MIME type suggested by file extension
/// 4. Renames files with correct extensions when mismatch detected
/// 5. Also renames associated .json metadata files to maintain pairing
/// 6. Provides detailed logging of all changes made
///
/// ## Safety Features
/// - Skips TIFF-based files (RAW formats) as they're often misidentified
/// - Optional conservative mode skips actual JPEG files for maximum safety
/// - Validates target files don't already exist before renaming
/// - Preserves file content while only changing extension
/// - Maintains metadata file associations automatically
///
/// ## Configuration Options
/// - `ExtensionFixingMode.none`: No extension fixing
/// - `ExtensionFixingMode.standard`: Standard mode, skips TIFF-based files only
/// - `ExtensionFixingMode.conservative`: Conservative mode, also skips actual JPEG files
/// - `ExtensionFixingMode.solo`: Runs extension fixing only, then exits
///
/// ## Error Handling
/// - Gracefully handles filesystem permission errors
/// - Logs warnings for files that cannot be processed
/// - Continues processing other files when individual failures occur
/// - Provides detailed error messages for troubleshooting
class FixExtensionsStep extends ProcessingStep with LoggerMixin {
  const FixExtensionsStep() : super('Fix Extensions');

  @override
  Future<StepResult> execute(final ProcessingContext context) async {
    const int stepId = 1;
    final resumed = await checkResume(context, stepId);
    if (resumed != null) {
      logPrint(
        '[Step $stepId/8] Auto-Resume enabled: step already completed previously, loading results from progress.json',
      );
      return resumed;
    }

    final stopWatch = Stopwatch()..start();

    try {
      if (context.config.extensionFixing == ExtensionFixingMode.none) {
        stopWatch.stop();
        final stepResult = StepResult.success(
          stepName: name,
          duration: stopWatch.elapsed,
          data: {'fixedCount': 0, 'skipped': true},
          message: 'Extension fixing skipped per configuration',
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
      logPrint('[Step 1/8] Fixing file extensions...');
      final extensionFixingService = FixExtensionService()
        ..logger = LoggingService.fromConfig(context.config);
      final fixedCount = await extensionFixingService.fixIncorrectExtensions(
        // This is the method that contains all the logic for this step
        context.inputDirectory,
        skipJpegFiles:
            context.config.extensionFixing == ExtensionFixingMode.conservative,
        skipExtras: context.config.skipExtras,
      );

      final shouldContinue = context.config.shouldContinueAfterExtensionFix;

      stopWatch.stop();
      final stepResult = StepResult.success(
        stepName: name,
        duration: stopWatch.elapsed,
        data: {
          'fixedCount': fixedCount,
          'shouldContinue': shouldContinue,
          'skipped': false,
        },
        message: 'Fixed $fixedCount file extensions',
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
        message: 'Failed to fix extensions: $e',
      );
    }
  }

  @override
  bool shouldSkip(final ProcessingContext context) =>
      context.config.extensionFixing == ExtensionFixingMode.none;
}
