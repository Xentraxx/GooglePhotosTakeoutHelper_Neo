import 'package:gpth_neo/gpth_lib_exports.dart';

/// Domain model representing the results and statistics of a complete GPTH processing run
///
/// This replaces the scattered variables like countDuplicates, exifccounter, etc.
/// with a single, comprehensive result object that can be easily tested and reported.
class ProcessingResult {
  const ProcessingResult({
    required this.totalProcessingTime,
    required this.stepTimings,
    required this.mediaProcessed,
    required this.duplicatesRemoved,
    required this.extrasSkipped,
    required this.extensionsFixed,
    required this.coordinatesWrittenToExif,
    required this.dateTimesWrittenToExif,
    required this.creationTimesUpdated,
    required this.extractionMethodStats,
    required this.stepResults,
    this.albumBehavior,
    this.totalMoveOperations,
    this.isSuccess = true,
    this.error,
  });

  /// Creates a failed result with an error
  ProcessingResult.failure(final Exception error)
    : this(
        totalProcessingTime: Duration.zero,
        stepTimings: {},
        stepResults: [],
        mediaProcessed: 0,
        duplicatesRemoved: 0,
        extrasSkipped: 0,
        extensionsFixed: 0,
        coordinatesWrittenToExif: 0,
        dateTimesWrittenToExif: 0,
        creationTimesUpdated: 0,
        extractionMethodStats: {},
        isSuccess: false,
        error: error,
      );
  final Duration totalProcessingTime;
  final Map<String, Duration> stepTimings;
  final List<StepResult> stepResults;
  final int mediaProcessed;
  final int duplicatesRemoved;
  final int extrasSkipped;
  final int extensionsFixed;
  final int coordinatesWrittenToExif;
  final int dateTimesWrittenToExif;
  final int creationTimesUpdated;
  final Map<DateTimeExtractionMethod, int> extractionMethodStats;
  final bool isSuccess;
  final Exception? error;
  // Album behavior used for the run (helps e2e validation)
  final AlbumBehavior? albumBehavior;
  // Total low-level move/copy/symlink operations performed (optional)
  final int? totalMoveOperations;

  /// Returns a user-friendly summary of the processing results
  String get summary {
    if (!isSuccess) {
      return 'Processing failed: ${error?.toString() ?? "Unknown error"}';
    }

    final buffer = StringBuffer();
    buffer.writeln('DONE! FREEEEEDOOOOM!!!');
    buffer.writeln('Some statistics for the achievement hunters:');

    if (duplicatesRemoved > 0) {
      buffer.writeln('\t$duplicatesRemoved duplicates were found and skipped');
    }
    if (coordinatesWrittenToExif > 0) {
      buffer.writeln(
        '\t$coordinatesWrittenToExif/$mediaProcessed files got their coordinates set in EXIF data (from json)',
      );
    }
    if (dateTimesWrittenToExif > 0) {
      buffer.writeln(
        '\t$dateTimesWrittenToExif/$mediaProcessed files got their DateTime set in EXIF data',
      );
    }
    if (extensionsFixed > 0) {
      buffer.writeln(
        '\t$extensionsFixed/$mediaProcessed files got their extensions fixed',
      );
    }
    if (creationTimesUpdated > 0) {
      buffer.writeln(
        '\t$creationTimesUpdated/$mediaProcessed files had their CreationDate updated',
      );
    }
    if (extrasSkipped > 0) {
      buffer.writeln('\t$extrasSkipped extras were skipped');
    }

    if (albumBehavior != null) {
      buffer.writeln('\tAlbum behavior: $albumBehavior');
    }
    if (totalMoveOperations != null) {
      buffer.writeln(
        '\tFile operations (move/copy/symlink/json): $totalMoveOperations',
      );
    }

    // DateTime extraction method statistics (always show all buckets, including zeros)
    buffer.writeln('\tDateTime extraction method statistics:');
    const ordered = [
      DateTimeExtractionMethod.json,
      DateTimeExtractionMethod.exif,
      DateTimeExtractionMethod.guess,
      DateTimeExtractionMethod.jsonTryHard,
      DateTimeExtractionMethod.folderYear,
      DateTimeExtractionMethod.none,
    ];
    for (final m in ordered) {
      final count = extractionMethodStats[m] ?? 0;
      buffer.writeln('\t\t${m.name}: $count files');
    }

    // Calculate Total Processing Time
    final d = totalProcessingTime;
    final hours = d.inHours;
    final minutes = d.inMinutes.remainder(60);
    final seconds = d.inSeconds.remainder(60);

    final durationPretty =
        '${hours}h '
        '${minutes.toString().padLeft(2, '0')}m '
        '${seconds.toString().padLeft(2, '0')}s';

    buffer.writeln('\nIn total the script took $durationPretty to complete');

    return buffer.toString();
  }
}
