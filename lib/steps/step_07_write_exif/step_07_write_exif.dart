import 'package:gpth_neo/gpth_lib_exports.dart';

/// Step 7: Write EXIF data to output files (physical files only)
///
/// Single rule (no per-strategy branching here):
///   • Process every FileEntity whose `targetPath` is not null AND `isShortcut == false`.
///   • GPS sidecar JSON is resolved using the *primary* entity's `sourcePath`.
///   • The entity's `dateTaken`/`dateAccuracy` are the authoritative timestamp/quality.
///
/// Why this shape:
///   • Step 6 (Move Files) already performed all physical moves/copies/shortcuts and
///     annotated each FileEntity with `targetPath` and `isShortcut`.
///   • We trust those flags to decide what to embed. Shortcuts are never written.
///   • This keeps Step 7 independent from album strategies.
///
/// This step embeds GPS coordinates and datetime information directly into media file
/// EXIF metadata, ensuring that location and timing data is preserved permanently with
/// each photo and video, independent of external metadata files.
///
/// ## Purpose and Benefits
///
/// ### Metadata Preservation
/// - **Permanent Embedding**: GPS and datetime become part of the file itself
/// - **Software Compatibility**: Works with all photo viewers and editing applications
/// - **Future-Proofing**: Data remains accessible even if JSON files are lost
/// - **Standard Compliance**: Uses standard EXIF tags recognized by all photo software
///
/// ### Data Sources
/// - **GPS Coordinates**: Extracted from Google Photos JSON metadata files
/// - **DateTime Information**: Uses accurately extracted photo creation timestamps
/// - **Timezone Handling**: Properly handles timezone conversion and UTC timestamps
/// - **Precision Preservation**: Maintains full coordinate and timestamp precision
///
/// ## EXIF Writing Process
///
/// ### GPS Coordinate Processing
/// 1. **JSON Extraction**: Reads GPS data from associated `.json` metadata files
/// 2. **Coordinate Conversion**: Converts decimal degrees to EXIF DMS (Degrees/Minutes/Seconds) format
/// 3. **Reference Assignment**: Sets proper hemisphere references (N/S, E/W)
/// 4. **Precision Handling**: Maintains coordinate accuracy to GPS precision limits
/// 5. **Validation**: Verifies coordinates are within valid Earth coordinate ranges
///
/// ### DateTime Embedding
/// 1. **Source Selection**: Uses the most accurate datetime from extraction step
/// 2. **Format Conversion**: Converts to EXIF datetime format (YYYY:MM:DD HH:MM:SS)
/// 3. **Tag Assignment**: Writes to appropriate EXIF datetime tags
/// 4. **Timezone Preservation**: Includes timezone information when available
/// 5. **Consistency Check**: Ensures all datetime tags are synchronized
///
/// ### EXIF Tag Management
/// - **Standard Tags**: Uses industry-standard EXIF tag numbers and formats
/// - **Multiple Tags**: Writes to primary and subsecond datetime tags
/// - **GPS Tags**: Populates comprehensive GPS tag set (latitude, longitude, altitude, etc.)
/// - **Metadata Preservation**: Maintains existing EXIF data while adding new information
///
/// ## Configuration and Control
///
/// ### Processing Options
/// - **Enable/Disable**: Controlled by `writeExif` configuration setting
/// - **Selective Processing**: Only processes files that lack existing EXIF datetime
/// - **Overwrite Protection**: Avoids overwriting existing accurate EXIF data
/// - **Source Filtering**: Only writes data extracted from reliable sources
///
/// ### Quality Control
/// - **Data Validation**: Verifies GPS coordinates and datetime values before writing
/// - **Format Verification**: Ensures data meets EXIF standard requirements
/// - **Error Detection**: Identifies and reports files that cannot be processed
/// - **Integrity Checking**: Confirms EXIF data was written correctly
///
/// ## Technical Implementation
///
/// ### File Format Support
/// - **JPEG Files**: Full EXIF support with standard embedding
/// - **TIFF Files**: Native EXIF support with comprehensive tag coverage
/// - **RAW Formats**: Uses ExifTool for advanced RAW file EXIF writing
/// - **Video Files**: Limited metadata support where format allows
///
/// ### ExifTool Integration
/// - **External Tool**: Uses ExifTool for comprehensive format support
/// - **Fallback Support**: Uses built-in EXIF writing when ExifTool unavailable
/// - **Format Coverage**: Supports hundreds of image and video formats
/// - **Advanced Features**: Handles complex metadata scenarios and edge cases
///
/// ### Performance Optimization
/// - **Batch Processing**: Groups multiple files for efficient processing
/// - **Memory Management**: Processes files without loading full content
/// - **I/O Minimization**: Optimizes file read/write operations
///
/// - **Progress Tracking**: Provides user feedback for long-running operations
///
/// ## Error Handling and Recovery
///
/// ### File Access Issues
/// - **Permission Errors**: Gracefully handles read-only or protected files
/// - **File Locks**: Manages files locked by other applications
/// - **Corrupted Files**: Skips files with corrupted EXIF segments
/// - **Format Limitations**: Handles unsupported file formats appropriately
///
/// ### Data Integrity Protection
/// - **Backup Creation**: Optionally creates backups before modifying files
/// - **Rollback Capability**: Can restore original files if issues occur
/// - **Verification**: Confirms EXIF data was written correctly
/// - **Partial Failure Handling**: Continues processing when individual files fail
///
/// ### External Tool Dependencies
/// - **ExifTool Detection**: Automatically detects ExifTool availability
/// - **Fallback Mechanisms**: Uses alternative methods when ExifTool unavailable
/// - **Version Compatibility**: Works with different ExifTool versions
/// - **Error Recovery**: Handles ExifTool execution errors gracefully
///
/// ## Data Quality and Validation
///
/// ### GPS Coordinate Validation
/// - **Range Checking**: Ensures coordinates are within valid Earth bounds
/// - **Precision Limits**: Respects GPS precision limitations
/// - **Format Verification**: Validates coordinate format before writing
/// - **Reference Consistency**: Ensures hemisphere references match coordinate signs
///
/// ### DateTime Validation
/// - **Reasonable Dates**: Rejects obviously incorrect dates (future/prehistoric)
/// - **Format Compliance**: Ensures datetime meets EXIF standard requirements
/// - **Timezone Handling**: Properly manages timezone information
/// - **Accuracy Tracking**: Preserves information about date extraction accuracy
///
/// ## Integration and Dependencies
///
/// ### Prerequisites
/// - **Date Extraction**: Requires completed date extraction from Step 4
/// - **JSON Processing**: Needs JSON metadata files for GPS coordinate extraction
/// - **File Accessibility**: Files must be writable for EXIF modification
/// - **Tool Availability**: ExifTool recommended for best format support
///
/// ### Step Coordination
/// - **After Date Extraction**: Runs after accurate datetime determination
/// - **Before File Moving**: Embeds metadata before final file organization
/// - **Coordinate with Album Finding**: May benefit from consolidated file information
/// - **Performance Consideration**: Balances thoroughness with processing speed
///
/// ## User Benefits and Use Cases
///
/// ### Photo Management
/// - **Geotagging**: Enables location-based photo organization and mapping
/// - **Timeline Accuracy**: Ensures correct chronological sorting in all applications
/// - **Software Compatibility**: Works with Adobe Lightroom, Apple Photos, Google Photos web
/// - **Archive Longevity**: Creates self-contained files with embedded metadata
///
/// ### Professional Workflows
/// - **Client Delivery**: Photos delivered with proper embedded metadata
/// - **Stock Photography**: Images have complete location and timing information
/// - **Legal Documentation**: Embedded metadata provides verifiable timestamps
/// - **Scientific Research**: Preserves precise location and timing data
///
/// ## Statistics and Reporting
///
/// ### Processing Metrics
/// - **GPS Coordinates Written**: Count of files with GPS data successfully embedded
/// - **DateTime Updates**: Number of files with datetime information added
/// - **Processing Performance**: Files processed per second and total duration
/// - **Error Tracking**: Files that couldn't be processed and reasons why
///
/// ### Quality Metrics
/// - **Data Source Breakdown**: Statistics on GPS/datetime data sources
/// - **Format Coverage**: Which file formats were successfully processed
/// - **Tool Usage**: Whether ExifTool or built-in methods were used
/// - **Validation Results**: How many files passed data validation checks

class WriteExifStep extends ProcessingStep with LoggerMixin {
  const WriteExifStep() : super('Write EXIF Data');

  @override
  Future<StepResult> execute(final ProcessingContext context) async {
    const int stepId = 7;
    final resumed = await checkResume(context, stepId);
    if (resumed != null) {
      logPrint(
        '[Step $stepId/8] Auto-Resume enabled: step already completed previously, loading results from progress.json',
      );
      return resumed;
    }

    final stopWatch = Stopwatch()..start();

    try {
      logPrint(
        '[Step $stepId/8] Writing EXIF data on physical files in output (this may take a while)...',
      );
      if (!context.config.writeExif) {
        stopWatch.stop();
        final stepResult = StepResult.success(
          stepName: name,
          duration: stopWatch.elapsed,
          data: {
            'coordinatesWritten': 0,
            'dateTimesWritten': 0,
            'skipped': true,
          },
          message: 'EXIF writing skipped per configuration',
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

      // Use the new service-level orchestrator to run the whole logic.
      // This keeps Step7 thin and lets the service reuse helpers/state efficiently.
      final exifTool = ServiceContainer.instance.exifTool; // may be null
      final orchestrator = WriteExifProcessingService(exifTool: exifTool);

      final outcome = await orchestrator.processCollection(
        context: context,
        logger: this, // pass-through for consistent logging format
      );

      // Dump internal writer stats (resets counters) exactly as before.
      WriteExifAuxiliaryService.dumpWriterStats(logger: this);

      stopWatch.stop();
      final stepResult = StepResult.success(
        stepName: name,
        duration: stopWatch.elapsed,
        data: {
          'coordinatesWritten': outcome.coordinatesWritten,
          'dateTimesWritten': outcome.dateTimesWritten,
          'rawGpsWrites': outcome.rawGpsWrites,
          'rawDateWrites': outcome.rawDateWrites,
          'skipped': false,
        },
        message: 'Wrote EXIF data to ${outcome.filesTouched} files',
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
      if (!WriteExifProcessingService.shouldSilenceExiftoolError(e)) {
        logError(
          '[Step $stepId/8] Failed to write EXIF data: $e',
          forcePrint: true,
        );
      }
      return StepResult.failure(
        stepName: name,
        duration: stopWatch.elapsed,
        error: e is Exception ? e : Exception(e.toString()),
        message: 'Failed to write EXIF data',
      );
    }
  }

  @override
  bool shouldSkip(final ProcessingContext context) =>
      context.mediaCollection.isEmpty;
}
