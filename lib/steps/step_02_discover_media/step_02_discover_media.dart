import 'package:gpth_neo/gpth_lib_exports.dart';

/// Step 2: Discover and classify media files
///
/// This comprehensive step handles the discovery and initial classification of all media files
/// in the Google Photos Takeout structure. It processes both year-based organization and
/// album folders to build a complete inventory of media files.
///
/// ## Discovery Process
///
/// ### Year Folder Processing
/// - Scans "Photos from YYYY" directories for chronologically organized media
/// - Extracts individual media files (photos, videos) from these primary folders
/// - Handles various year folder naming patterns and international characters
/// - Processes nested directory structures within year folders
///
/// ### Album Folder Processing
/// - Identifies album directories that exist separately from year folders
/// - Creates media entries for album-specific files that may not exist in year folders
/// - Handles duplicate relationships between year and album folder files
/// - Preserves album metadata and relationship information for later processing
///
/// ### Media Classification
/// - Distinguishes between photos, videos, and other media types
/// - Identifies associated JSON metadata files for each media file
/// - Handles special file types like Live Photos, Motion Photos, and edited versions
/// - Filters out non-media files and system artifacts
///
/// ## Processing Logic
///
/// ### Comprehensive File Discovery
/// The step performs a deep scan of the input directory structure to identify:
/// - All valid media files (photos, videos) with supported extensions
/// - Associated JSON metadata files containing Google Photos metadata
/// - Album folder structures and their contained media files
/// - Relationship mapping between files in different locations
///
/// ### Duplicate Detection Setup
/// During discovery, the step identifies potential duplicate relationships:
/// - Files that appear in both year folders and album folders
/// - Multiple copies of the same file across different album locations
/// - Sets up the foundation for later duplicate resolution processing
///
/// ### Media Object Creation
/// For each discovered media file, creates appropriate Media objects:
/// - Associates files with their album context (if applicable)
/// - Links JSON metadata files with their corresponding media files
/// - Preserves original file paths for later processing steps
/// - Maintains album relationship information for organization
///
/// ## Configuration Handling
///
/// ### Input Validation
/// - Validates that the input directory exists and is accessible
/// - Ensures the directory structure matches expected Google Photos Takeout format
/// - Handles various Takeout export formats and structures
/// - Provides meaningful error messages for invalid input structures
///
/// ### Progress Reporting
/// - Reports discovery progress for large photo collections
/// - Provides detailed statistics about discovered media counts
/// - Shows breakdown of files found in year folders vs. album folders
/// - Estimates processing time based on collection size
///
/// ## Error Handling
///
/// ### Access and Permission Issues
/// - Gracefully handles files with restricted access permissions
/// - Skips corrupted or inaccessible files without stopping processing
/// - Reports permission issues for user awareness
/// - Continues processing when individual files cannot be accessed
///
/// ### Malformed Export Handling
/// - Detects and handles incomplete or corrupted Google Photos exports
/// - Adapts to various export formats and edge cases
/// - Provides fallback strategies for unusual directory structures
/// - Reports structural issues found in the export
///
/// ## Integration with Other Steps
///
/// ### Media Collection Population
/// - Populates the MediaCollection with all discovered media files
/// - Provides the foundation for all subsequent processing steps
/// - Ensures comprehensive coverage of all media in the export
/// - Sets up proper data structures for efficient processing
///
/// ### Album Relationship Setup
/// - Establishes the groundwork for album finding and merging
/// - Preserves album context information for later processing
/// - Creates the data structures needed for album organization options
/// - Enables proper handling of files that exist in multiple albums
class DiscoverMediaStep extends ProcessingStep with LoggerMixin {
  const DiscoverMediaStep() : super('Discover Media');

  @override
  Future<StepResult> execute(final ProcessingContext context) async {
    const int stepId = 2;
    final resumed = await checkResume(context, stepId);
    if (resumed != null) {
      logPrint(
        '[Step $stepId/8] Auto-Resume enabled: step already completed previously, loading results from progress.json',
      );
      return resumed;
    }
    final stopWatch = Stopwatch()..start();

    try {
      logPrint('[Step 2/8] Discovering media files (this may take a while)...');

      final result = await const DiscoverMediaService().discover(
        context,
      ); // This is the method that contains all the logic for this step

      final totalFiles = result.yearFolderFiles + result.albumFolderFiles;

      stopWatch.stop();

      // Build the StepResult first
      final stepResult = StepResult.success(
        stepName: name,
        duration: stopWatch.elapsed,
        data: {
          'yearFolderFiles': result.yearFolderFiles,
          'albumFolderFiles': result.albumFolderFiles,
          'totalFiles': totalFiles,
          'extrasSkipped': result.extrasSkipped,
        },
        message:
            'Discovered $totalFiles media files (${result.yearFolderFiles} from year folders, ${result.albumFolderFiles} from albums)${result.extrasSkipped > 0 ? ', skipped ${result.extrasSkipped} extra files' : ''}',
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
      // Do NOT persist progress on failure. Keep previous progress.json intact.
      return StepResult.failure(
        stepName: name,
        duration: stopWatch.elapsed,
        error: e is Exception ? e : Exception(e.toString()),
        message: 'Failed to discover media files: $e',
      );
    }
  }

  @override
  bool shouldSkip(final ProcessingContext context) => false;
}
