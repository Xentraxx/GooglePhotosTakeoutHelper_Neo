import 'package:gpth_neo/gpth_lib_exports.dart';

/// Service for managing global application configuration and state
///
/// Replaces global variables with a proper service that can be injected
/// and tested. Provides thread-safe access to configuration values.
class GlobalConfigService {
  /// Constructor for dependency injection
  GlobalConfigService();

  /// Enable/Disable Log saving into file.
  bool saveLog = true;

  /// Whether verbose logging is enabled
  bool isVerbose = false;

  /// Whether file size limits should be enforced
  bool enforceMaxFileSize = false;

  /// Whether ExifTool is available and installed
  bool exifToolInstalled = false;

  /// Speeds up by avoiding costly ExifTool fallback when native claims support.
  bool fallbackToExifToolOnNativeMiss = true;

  // Seppeds up Step 7: Write EXIF by sending files by batches to ExifTool on evey ExifTool call
  bool enableExifToolBatch =
      true; // Disable this if you observe any abnormal dates in your output files.
  int maxExifImageBatchSize = 100;
  int maxExifVideoBatchSize = 24;

  /// DatesDictionary passed as argument (if ussed flag --json-dates)
  Map<String, Map<String, dynamic>>? jsonDatesDictionary;

  /// Local timezone offset (issue #145) for converting UTC photo dates to
  /// local time when re-uploading to Google Photos. `null` keeps UTC behaviour.
  TimezoneOffset? localTimezoneOffset;

  // ───────────────────────────────────────────────────────────────────────────
  // NEW: Unsupported-format handling policy for Step 7 (Write EXIF)
  // These flags let you temporarily disable pre-skip logic and/or silence warnings.
  // - forceProcessUnsupportedFormats: If true, do NOT pre-skip AVI/MPG/MPEG/BMP.
  //   Let ExifTool decide (and fail silently if it cannot write).
  // - silenceUnsupportedWarnings: If true, do not log "Skipping …" warnings when
  //   the pre-skip is active.
  // - maxExifImageBatchSize / maxExifVideoBatchSize: hard caps for ExifTool batch
  //   sizes to avoid catastrophic batch failures (can be overridden via config).
  bool forceProcessUnsupportedFormats = false;
  bool silenceUnsupportedWarnings = true;

  /// Flag to indicate if we want to conserve all Duplicates found during Step 2
  /// and move them to _Duplicates subfolder within output folder.
  bool moveDuplicatesToDuplicatesFolder = false;

  /// Flag to enable/disable telemetry statistics during Merge Media Entities step
  bool enableTelemetryInMergeMediaEntitiesStep = true;

  // ───────────────────────────────────────────────────────────────────────────
  // Initialization / lifecycle
  // ───────────────────────────────────────────────────────────────────────────

  /// Initializes configuration from processing config
  void initializeFrom(final ProcessingConfig config) {
    isVerbose = config.verbose;
    enforceMaxFileSize = config.limitFileSize;
    localTimezoneOffset = config.localTimezoneOffset;
    // exifToolInstalled is set separately by ExifTool detection
  }

  /// Resets all configuration to defaults
  void reset() {
    // saveLog = false;
    isVerbose = false;
    enforceMaxFileSize = false;
    exifToolInstalled = false;
    fallbackToExifToolOnNativeMiss = false;
    enableExifToolBatch = true;
    jsonDatesDictionary = null;
    localTimezoneOffset = null;

    // NEW: reset unsupported-policy and batch caps
    forceProcessUnsupportedFormats = false;
    silenceUnsupportedWarnings = true;
    maxExifImageBatchSize = 100;
    maxExifVideoBatchSize = 24;

    moveDuplicatesToDuplicatesFolder = false;
    enableTelemetryInMergeMediaEntitiesStep = true;
  }

  // ───────────────────────────────────────────────────────────────────────────
  // Optional helpers for integration
  // ───────────────────────────────────────────────────────────────────────────

  /// NEW: Update only a subset of fields from a loose map (e.g., CLI/JSON overrides).
  /// Unknown keys are ignored. Values are validated and coerced when safe.
  void applyOverrides(final Map<String, dynamic> overrides) {
    // Booleans
    if (overrides.containsKey('isVerbose')) {
      isVerbose = _asBool(overrides['isVerbose'], isVerbose);
    }
    if (overrides.containsKey('enforceMaxFileSize')) {
      enforceMaxFileSize = _asBool(
        overrides['enforceMaxFileSize'],
        enforceMaxFileSize,
      );
    }
    if (overrides.containsKey('exifToolInstalled')) {
      exifToolInstalled = _asBool(
        overrides['exifToolInstalled'],
        exifToolInstalled,
      );
    }
    if (overrides.containsKey('fallbackToExifToolOnNativeMiss')) {
      fallbackToExifToolOnNativeMiss = _asBool(
        overrides['fallbackToExifToolOnNativeMiss'],
        fallbackToExifToolOnNativeMiss,
      );
    }
    if (overrides.containsKey('enableExifToolBatch')) {
      enableExifToolBatch = _asBool(
        overrides['enableExifToolBatch'],
        enableExifToolBatch,
      );
    }
    // if (overrides.containsKey('moveDuplicatesToDuplicatesFolder')) moveDuplicatesToDuplicatesFolder = _asBool(overrides['moveDuplicatesToDuplicatesFolder'], moveDuplicatesToDuplicatesFolder);

    // Ints
    if (overrides.containsKey('maxExifImageBatchSize')) {
      maxExifImageBatchSize = _asInt(
        overrides['maxExifImageBatchSize'],
        maxExifImageBatchSize,
      );
    }
    if (overrides.containsKey('maxExifVideoBatchSize')) {
      maxExifVideoBatchSize = _asInt(
        overrides['maxExifVideoBatchSize'],
        maxExifVideoBatchSize,
      );
    }

    // NEW flags
    if (overrides.containsKey('forceProcessUnsupportedFormats')) {
      forceProcessUnsupportedFormats = _asBool(
        overrides['forceProcessUnsupportedFormats'],
        forceProcessUnsupportedFormats,
      );
    }
    if (overrides.containsKey('silenceUnsupportedWarnings')) {
      silenceUnsupportedWarnings = _asBool(
        overrides['silenceUnsupportedWarnings'],
        silenceUnsupportedWarnings,
      );
    }

    // Dates dictionary (allow pass-through if structure matches)
    if (overrides.containsKey('jsonDatesDictionary')) {
      final v = overrides['jsonDatesDictionary'];
      if (v is Map<String, dynamic>) {
        // Best-effort cast; the writer only reads the expected shape.
        jsonDatesDictionary = v.map(
          (final k, final val) => MapEntry(
            k,
            (val is Map<String, dynamic>) ? val : <String, dynamic>{},
          ),
        );
      }
    }

    if (overrides.containsKey('moveDuplicatesToDuplicatesFolder')) {
      moveDuplicatesToDuplicatesFolder = _asBool(
        overrides['moveDuplicatesToDuplicatesFolder'],
        moveDuplicatesToDuplicatesFolder,
      );
    }

    if (overrides.containsKey('enableTelemetryInMergeMediaEntitiesStep')) {
      enableTelemetryInMergeMediaEntitiesStep = _asBool(
        overrides['enableTelemetryInMergeMediaEntitiesStep'],
        enableTelemetryInMergeMediaEntitiesStep,
      );
    }
  }

  /// NEW: Expose as a plain JSON-like map so other modules can read flags
  /// without tight coupling (used by Step 7 _resolveInt/_resolveUnsupportedPolicy).
  Map<String, dynamic> toJson() => <String, dynamic>{
    'saveLog': saveLog,
    'isVerbose': isVerbose,
    'enforceMaxFileSize': enforceMaxFileSize,
    'exifToolInstalled': exifToolInstalled,
    'fallbackToExifToolOnNativeMiss': fallbackToExifToolOnNativeMiss,
    'enableExifToolBatch': enableExifToolBatch,
    'maxExifImageBatchSize': maxExifImageBatchSize,
    'maxExifVideoBatchSize': maxExifVideoBatchSize,
    'forceProcessUnsupportedFormats': forceProcessUnsupportedFormats,
    'silenceUnsupportedWarnings': silenceUnsupportedWarnings,
    'moveDuplicatesToDuplicatesFolder': moveDuplicatesToDuplicatesFolder,
    'enableTelemetryInMergeMediaEntitiesStep':
        enableTelemetryInMergeMediaEntitiesStep,
    // NOTE: jsonDatesDictionary can be very large; usually not needed here.
  };

  // ───────────────────────────────────────────────────────────────────────────
  // Private helpers
  // ───────────────────────────────────────────────────────────────────────────

  // ignore: strict_top_level_inference
  bool _asBool(final v, final bool fallback) {
    if (v is bool) return v;
    if (v is String) {
      final s = v.toLowerCase().trim();
      if (s == 'true' || s == '1' || s == 'yes' || s == 'y') return true;
      if (s == 'false' || s == '0' || s == 'no' || s == 'n') return false;
    }
    return fallback;
  }

  // ignore: strict_top_level_inference
  int _asInt(final v, final int fallback) {
    if (v is int) return v;
    if (v is String) {
      final parsed = int.tryParse(v.trim());
      if (parsed != null) return parsed;
    }
    return fallback;
  }
}
