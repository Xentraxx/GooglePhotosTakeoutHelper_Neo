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

  /// Returns detailed timing information for performance analysis
  String get timingDetails {
    final buffer = StringBuffer();
    buffer.writeln('Processing Step Timings:');

    for (final entry in stepTimings.entries) {
      final minutes = entry.value.inMinutes;
      final seconds = entry.value.inSeconds;
      buffer.writeln('${entry.key}: ${minutes}m ${seconds}s');
    }

    return buffer.toString();
  }
}

/// Builder class for constructing ProcessingResult incrementally during processing
class ProcessingResultBuilder {
  final Map<String, Duration> _stepTimings = {};
  final Map<DateTimeExtractionMethod, int> _extractionStats = {};

  int _mediaProcessed = 0;
  int _duplicatesRemoved = 0;
  int _extrasSkipped = 0;
  int _extensionsFixed = 0;
  int _coordinatesWrittenToExif = 0;
  int _dateTimesWrittenToExif = 0;
  int _creationTimesUpdated = 0;
  DateTime? _startTime;

  void startProcessing() {
    _startTime = DateTime.now();
  }

  void addStepTiming(final String stepName, final Duration duration) {
    _stepTimings[stepName] = duration;
  }

  set mediaProcessed(final int count) => _mediaProcessed = count;
  set duplicatesRemoved(final int count) => _duplicatesRemoved = count;
  set extrasSkipped(final int count) => _extrasSkipped = count;
  set extensionsFixed(final int count) => _extensionsFixed = count;
  set coordinatesWrittenToExif(final int count) =>
      _coordinatesWrittenToExif = count;
  set dateTimesWrittenToExif(final int count) =>
      _dateTimesWrittenToExif = count;
  set creationTimesUpdated(final int count) => _creationTimesUpdated = count;

  void addExtractionMethodStats(
    final Map<DateTimeExtractionMethod, int> stats,
  ) {
    _extractionStats.addAll(stats);
  }

  ProcessingResult build() {
    final totalTime = _startTime != null
        ? DateTime.now().difference(_startTime!)
        : Duration.zero;
    return ProcessingResult(
      totalProcessingTime: totalTime,
      stepTimings: Map.unmodifiable(_stepTimings),
      stepResults: [], // Not used in builder pattern
      mediaProcessed: _mediaProcessed,
      duplicatesRemoved: _duplicatesRemoved,
      extrasSkipped: _extrasSkipped,
      extensionsFixed: _extensionsFixed,
      coordinatesWrittenToExif: _coordinatesWrittenToExif,
      dateTimesWrittenToExif: _dateTimesWrittenToExif,
      creationTimesUpdated: _creationTimesUpdated,
      extractionMethodStats: Map.unmodifiable(_extractionStats),
    );
  }
}
