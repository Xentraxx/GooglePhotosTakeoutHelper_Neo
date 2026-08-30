// ignore_for_file: unintended_html_in_doc_comment
import 'dart:convert';
import 'dart:io';

import 'package:args/args.dart';
import 'package:gpth_neo/gpth_lib_exports.dart';
import 'package:meta/meta.dart' show visibleForTesting;
import 'package:path/path.dart' as path;

// Parses hidden test-only flags from argv, applies them, and returns a list
// with those flags removed so ArgParser won't choke on unknown options.
// Supported examples:
//   --_test-standard-multiplier=2
//   --_test-conservative-multiplier=4
//   --_test-disk-optimized-multiplier=8
List<String> _applyAndStripTestMultipliers(final List<String> args) {
  final re = RegExp(r'^--_test-([a-z0-9-]+)=(\d+)$', caseSensitive: false);
  final cleaned = <String>[];
  for (final arg in args) {
    final m = re.firstMatch(arg);
    if (m == null) {
      cleaned.add(arg);
      continue;
    }
    final name = m.group(1)!.toLowerCase();
    final val = int.tryParse(m.group(2)!);
    if (val == null) continue; // silently ignore malformed
    switch (name) {
      case 'standard-multiplier':
        ConcurrencyManager.setMultipliers(standard: val);
        break;
      case 'conservative-multiplier':
        ConcurrencyManager.setMultipliers(conservative: val);
        break;
      case 'disk-optimized-multiplier':
        ConcurrencyManager.setMultipliers(diskOptimized: val);
        break;
      default:
        // Unknown hidden flag -> ignore (do not forward to parser)
        break;
    }
  }
  return cleaned;
}

// ─────────────────────────────────────────────────────────────────────────────
// ZIP extraction sentinel helpers
// The sentinel is stored as a "zip_extraction" key inside the output
// directory's progress.json so no extra file is needed.
// ─────────────────────────────────────────────────────────────────────────────

/// Merges a `zip_extraction` record into [outputDir]/progress.json.
/// The file is created if absent; existing keys are preserved via atomic write.
Future<void> _writeZipExtractionSentinel(
  final List<File> zips,
  final Directory outputDir,
) async {
  await outputDir.create(recursive: true);
  final progressFile = File(path.join(outputDir.path, 'progress.json'));
  Map<String, dynamic> existing = {};
  if (await progressFile.exists()) {
    try {
      existing =
          jsonDecode(await progressFile.readAsString()) as Map<String, dynamic>;
    } catch (_) {}
  }
  existing['zip_extraction'] = {
    'extracted_at': DateTime.now().toUtc().toIso8601String(),
    'source_zips': [
      for (final z in zips)
        {'name': path.basename(z.path), 'size_bytes': z.lengthSync()},
    ],
  };
  final tmp = File('${progressFile.path}.tmp');
  await tmp.writeAsString(const JsonEncoder.withIndent('  ').convert(existing));
  await tmp.rename(progressFile.path);
}

/// Reads the completed-step ids recorded in `<outputPath>/progress.json`.
///
/// Returns an empty list when the file is absent, unreadable, or holds no
/// step-resume state (e.g. only a ZIP extraction sentinel).
Future<List<int>> _readCompletedStepsFromProgress(
  final String outputPath,
) async {
  try {
    final File progressFile = File(path.join(outputPath, 'progress.json'));
    if (!await progressFile.exists()) return const [];
    final dynamic doc = jsonDecode(await progressFile.readAsString());
    if (doc is! Map<String, dynamic>) return const [];

    final Set<int> out = <int>{};
    final dynamic completed = doc['Completed steps'];
    if (completed is List) {
      for (final dynamic v in completed) {
        final int? n = int.tryParse('$v'.trim());
        if (n != null) out.add(n);
      }
    }
    final dynamic steps = doc['steps'];
    if (steps is Map) {
      for (final dynamic k in steps.keys) {
        final int? n = int.tryParse('$k'.trim());
        if (n != null) out.add(n);
      }
    }
    return out.toList()..sort();
  } catch (_) {
    return const [];
  }
}

/// Checks whether a previous extraction of [zips] into [extractDir] can be
/// reused, consulting [outputDir]/progress.json for the sentinel record.
///
/// Returns `true`  → sentinel matches current ZIPs → skip extraction.
/// Returns `false` → dir absent or empty → fresh extraction needed.
///
/// Throws [FileSystemException] for every unsafe situation:
///   - dir is non-empty but progress.json has no `zip_extraction` key
///   - progress.json is corrupt
///   - `zip_extraction` describes a different set of ZIPs
Future<bool> _shouldReuseZipExtraction(
  final List<File> zips,
  final Directory extractDir,
  final Directory outputDir,
) async {
  final bool dirExists = await extractDir.exists();
  if (!dirExists) return false;

  final bool isEmpty = await extractDir.list(followLinks: false).isEmpty;
  if (isEmpty) return false;

  // Directory is non-empty — only safe to reuse if progress.json records a
  // completed extraction for the same ZIP set.
  final progressFile = File(path.join(outputDir.path, 'progress.json'));
  if (!await progressFile.exists()) {
    throw FileSystemException(
      'The extraction directory is non-empty but progress.json does not exist '
      'in "${outputDir.path}", meaning a previous extraction was interrupted '
      'or was created by an older version of GPTH.\n'
      'To proceed safely:\n'
      '  • Delete "${extractDir.path}" and re-run (GPTH will re-extract), OR\n'
      '  • Pass "${extractDir.path}" directly as --input if the contents look complete.',
      extractDir.path,
    );
  }

  Map<String, dynamic> progressDoc;
  try {
    progressDoc =
        jsonDecode(await progressFile.readAsString()) as Map<String, dynamic>;
  } catch (e) {
    throw FileSystemException(
      'progress.json is corrupt ($e). '
      'Delete "${extractDir.path}" and re-run to perform a fresh extraction.',
      progressFile.path,
    );
  }

  final sentinel = progressDoc['zip_extraction'];
  if (sentinel == null) {
    throw FileSystemException(
      'The extraction directory is non-empty but progress.json has no '
      '"zip_extraction" key, meaning a previous extraction was interrupted.\n'
      'To proceed safely:\n'
      '  • Delete "${extractDir.path}" and re-run (GPTH will re-extract), OR\n'
      '  • Pass "${extractDir.path}" directly as --input if the contents look complete.',
      extractDir.path,
    );
  }

  final List<dynamic> prevList =
      (sentinel as Map<String, dynamic>)['source_zips'] as List<dynamic>? ?? [];
  final Map<String, int> prev = {
    for (final z in prevList)
      (z as Map<String, dynamic>)['name'] as String: (z['size_bytes'] as num)
          .toInt(),
  };
  final Map<String, int> curr = {
    for (final z in zips) path.basename(z.path): z.lengthSync(),
  };

  if (prev.length != curr.length ||
      curr.keys.any((final k) => prev[k] != curr[k])) {
    final prevNames = prev.keys.join(', ');
    final currNames = curr.keys.join(', ');
    throw FileSystemException(
      'The extraction directory "${extractDir.path}" was created from a different '
      'set of ZIPs and cannot be safely reused.\n'
      '  Previously extracted: $prevNames\n'
      '  Current ZIPs:         $currNames\n'
      'Delete "${extractDir.path}" and re-run to extract the current ZIPs.',
      extractDir.path,
    );
  }

  return true; // sentinel matches — safe to reuse
}

/// ############################### GOOGLE PHOTOS TAKEOUT HELPER NEO #############################
///
/// **PROCESSING FLOW:**
/// 1. Parse command line arguments → ProcessingConfig
/// 2. Initialize dependencies (ExifTool, ServiceContainer)
/// 3. Execute ProcessingPipeline with 8 steps:
///    - Fix Extensions: Correct mismatched file extensions (optional)
///    - Discover Media: Find and classify all media files
///    - Merge Media Entities: Merge identical Media Entities from different folders into a single one
///      Also, eliminate duplicate files within the same folder using content hashing
///    - Extract Dates: Determine accurate timestamps from multiple sources
///    - Find Albums: Detect and merge album relationships
///    - Move Files: Organize files to output structure using selected album behavior
///    - Write EXIF: Embed metadata into files (when ExifTool available)
///    - Update Creation Time: Sync file creation timestamps (Windows only, optional)
/// 4. Display comprehensive results and statistics
///
/// **DESIGN PATTERNS USED:**
/// - Builder Pattern: For complex ProcessingConfig construction
/// - Template Method: ProcessingStep base class with consistent interface
/// - Pipeline Pattern: Sequential step execution with error handling
/// - Domain Models: Type-safe data structures replacing Maps
///
/// **MAINTAINABILITY FEATURES:**
/// - Each function has a single, clear responsibility
/// - All components are independently testable
/// - Configuration is type-safe and validated
/// - Error handling is consistent throughout
/// - Documentation covers both technical and business logic
///
/// ##############################################################################
/// **MAIN ENTRY POINT**
///
/// This is the main entry point for the Google Photos Takeout Helper Neo (GPTH).
/// It orchestrates the entire photo processing workflow using clean architecture principles.
///
/// **HIGH-LEVEL FLOW:**
/// 1. Parse and validate command line arguments
/// 2. Initialize external dependencies (ExifTool, global settings)
/// 3. Execute the main processing pipeline
/// 4. Display comprehensive results to the user
///
/// **ERROR HANDLING:**
/// - All exceptions are caught and handled gracefully
/// - Specific exit codes are used for different error types
/// - User-friendly error messages are displayed
///
/// **PERFORMANCE CONSIDERATIONS:**
/// - Asynchronous processing throughout the pipeline
/// - Memory-efficient streaming for large photo collections
/// - Progress reporting for long-running operations
///
/// @param arguments Command line arguments from the user
Future<void> main(final List<String> arguments) async {
  // Capture invocation details for the log header (written when file logging is enabled).
  LoggingService.setInvocation(
    args: arguments,
    executable: Platform.resolvedExecutable,
    cwd: Directory.current.path,
  );

  // Initialize logger early with default settings
  _logger = LoggingService();
  LoggerMixin.sharedDefaultLogger =
      _logger; // NEW: make this the shared default

  // Apply & strip hidden test-only concurrency multiplier flags before parsing normal args.
  final parsedArguments = _applyAndStripTestMultipliers(arguments);
  try {
    // Initialize ServiceContainer early to support interactive mode during argument parsing
    // await ServiceContainer.instance.initialize();
    await ServiceContainer.instance.initialize(
      loggingService: LoggingService(),
    );

    // IMPORTANT (Option A): ensure no early default logger opens a file in ./Logs
    // by forcing global saveLog OFF until we explicitly set it from CLI args later.
    ServiceContainer.instance.globalConfig.saveLog =
        false; // <- critical to avoid early file sink in ./Logs

    // Parse command line arguments
    final config = await _parseArguments(parsedArguments);
    if (config == null) {
      return; // Help was shown or other early exit
    }

    // Apply --save-log from args BEFORE creating the final logger (Option A)
    await _loadSaveLogIntoGlobalConfigFromArgs(
      parsedArguments,
      // NEW: tell the loader our output dir so it can preview and print the exact log path at startup.
      preferredLogDirForPreview: config.outputPath,
    ); // sets globalConfig.saveLog true/false only + prints the concrete path (no file I/O)

    // --- PRE-CLEAN OUTPUT DIR BEFORE OPENING THE NEW LOG FILE ---
    // Clean the output directory (if needed) *before* creating the logger that will place
    // the new log file inside that directory. This avoids file-lock errors on Windows.
    final Directory preCleanOut = Directory(config.outputPath);
    if (await preCleanOut.exists()) {
      final bool needsClean = await _needsCleanOutputDirectory(
        preCleanOut,
        config,
      );
      if (needsClean) {
        if (config.isInteractiveMode) {
          logWarning(
            '⚠️  DANGER: Output directory cleanup requested. This will DELETE files/folders inside: ${preCleanOut.path}',
            forcePrint: true,
          );
          logWarning(
            'Only the input folder (if it lives inside output), ".log" and ".json" files are preserved. Everything else will be removed recursively.',
            forcePrint: true,
          );
          if (await ServiceContainer.instance.interactiveService
              .askForCleanOutput()) {
            await _cleanOutputDirectory(preCleanOut, config);
          }
        } else {
          // SAFETY: Never auto-clean in non-interactive mode.
          // Cleaning can delete unrelated user files if --output points to a non-empty folder.
          _exitWithMessage(
            13,
            'Output directory contains items other than allowed ".log" and ".json" files. Refusing to auto-clean in non-interactive mode. '
            'Please choose an empty output directory, or clean it manually.',
          );
        }
      }
    }
    await preCleanOut.create(recursive: true);
    // --- END PRE-CLEAN ---

    // In interactive mode the raw argv is []. Update invocation args now that
    // the user's selections are known, so the log session header shows the
    // effective flags instead of an empty list.
    if (config.isInteractiveMode) {
      LoggingService.setInvocation(
        args: _interactiveEquivalentArgs(config),
        executable: Platform.resolvedExecutable,
        cwd: Directory.current.path,
      );
    }

    // Update logger with correct verbosity and reinitialize services with it
    _logger = LoggingService(
      isVerbose: config.verbose,
      saveLog: ServiceContainer
          .instance
          .globalConfig
          .saveLog, // now reflects CLI args
      preferredLogDir: config.outputPath,
    );

    LoggerMixin.sharedDefaultLogger =
        _logger; // NEW: propagate final logger to everyone

    // Reinitialize ServiceContainer with the properly configured logger
    await ServiceContainer.instance.initialize(loggingService: _logger);

    // Print the exact log file path once, after logger+file-sink are open (hits both console and file).
    if (ServiceContainer.instance.globalConfig.saveLog) {
      final plannedPath = LoggingService.previewLogFilePath(config.outputPath);
      _logger.printPlain('Messages Log will be saved to: $plannedPath');
    }

    // Log interactive selections after logger initialization so this section is
    // always present in the saved log file.
    if (config.isInteractiveMode) {
      _logInteractiveEquivalentArgs(config);
    }

    // Configure dependencies with the parsed config
    await _configureDependencies(config);

    // Load optional json-dates dictionary AFTER the second ServiceContainer initialization
    await _loadFileDatesIntoGlobalConfigFromArgs(parsedArguments);

    // Execute the processing pipeline
    final result = await _executeProcessing(config, precleanedOutput: true);

    // Show final results
    _showResults(config, result);

    // Cleanup services
    await ServiceContainer.instance.dispose();
  } catch (e) {
    logError('Fatal error: $e');
    _logger.quit();
  }
}

/// Global logger instance
late LoggingService _logger;

/// Print a helpful message and exit with given code.
/// Uses stderr and the logger when available. Optionally shows an interactive
/// prompt before exit when `showInteractivePrompt` is true and INTERACTIVE
/// environment variable is set.
///
/// Exit codes:
/// - 0: Success
/// - 1: General failure/processing error
/// - 11: Input validation error (folder doesn't exist, etc.)
/// - Other codes: Specific error conditions
Never _exitWithMessage(
  final int code,
  final String message, {
  final bool showInteractivePrompt = false,
}) {
  final errorType = switch (code) {
    0 => 'SUCCESS',
    1 => 'PROCESSING_ERROR',
    11 => 'INPUT_VALIDATION_ERROR',
    _ => 'ERROR_CODE_$code',
  };

  final fullMessage = '[$errorType] $message';

  try {
    stderr.writeln(fullMessage);
  } catch (_) {}
  try {
    // logger may not be set early in startup, guard against that
    logError(fullMessage);
  } catch (_) {}

  if (showInteractivePrompt && Platform.environment['INTERACTIVE'] == 'true') {
    logPrint(
      '[gpth ${code != 0 ? 'quitted :(' : 'finished :)'} (code $code) - press enter to close]',
    );
    stdin.readLineSync();
  }

  exit(code);
}

/// **ARGUMENT PARSING & CONFIGURATION BUILDING**
///
/// Converts raw command line arguments into a type-safe ProcessingConfig object.
/// This replaces the original unsafe Map<String, dynamic> approach with proper
/// domain models that provide validation and type safety.
///
/// **SUPPORTED MODES:**
/// - Normal processing: Full Google Photos Takeout organization
/// - Fix mode: Special mode to just fix dates on existing photos
/// - Interactive mode: Guided setup with user prompts
/// - CLI mode: Direct command line operation
///
/// **VALIDATION:**
/// - All required parameters are validated
/// - Invalid combinations are caught early
/// - Descriptive error messages guide the user
///
/// @param arguments Raw command line arguments
/// @returns ProcessingConfig object or null if help was shown
/// @throws FormatException for invalid argument formats
/// @throws ProcessExit for validation failures
Future<ProcessingConfig?> _parseArguments(final List<String> arguments) async {
  final parser = _createArgumentParser();

  try {
    final res = parser.parse(arguments);

    if (res['help']) {
      _showHelp(parser);
      return null;
    }

    if (res['hardlink'] == true && !Platform.isWindows) {
      _exitWithMessage(
        15,
        'The "--hardlink" option is currently supported on Windows only.',
      );
    }

    // Convert ArgResults to configuration
    return await _buildConfigFromArgs(res);
  } on FormatException catch (e) {
    logError('$e');
    _exitWithMessage(
      2,
      'Argument parsing failed: ${e.toString()}. Run `gpth --help` for usage.',
    );
  }
}

/// **COMMAND LINE PARSER FACTORY**
///
/// Creates the argument parser with all supported options and flags.
/// This centralizes all CLI option definitions in one place for maintainability.
///
/// **OPTION CATEGORIES:**
/// - Input/Output: Specify source and destination directories
/// - Processing: Control how photos are processed (copy vs move, etc.)
/// - Organization: Album handling and date-based folder organization
/// - Metadata: EXIF writing, date extraction, coordinate handling
/// - Extensions: File extension fixing and transformation
/// - Platform: Windows-specific features like creation time updates
/// - Debugging: Verbose output and file size limits
///
/// **DEFAULTS:**
/// - Most options have sensible defaults for typical use cases
/// - Interactive mode is automatically enabled when no args provided
/// - Help flag shows comprehensive usage information
///
/// @returns Configured ArgParser instance
ArgParser _createArgumentParser() => ArgParser()
  ..addFlag('help', abbr: 'h', negatable: false)
  ..addOption('fix', help: 'Folder with any photos to fix dates (special mode)')
  ..addFlag('interactive', help: 'Use interactive mode')
  ..addFlag(
    'save-log',
    abbr: 'l',
    help: 'Save log messages into a log file within Logs folder',
    defaultsTo: true,
  )
  ..addFlag('verbose', abbr: 'v', help: 'Shows extensive output')
  ..addOption('input', abbr: 'i', help: 'Input folder with extracted takeouts')
  ..addOption('output', abbr: 'o', help: 'Output folder for organized photos')
  ..addOption(
    'albums',
    help: 'What to do about albums?',
    allowed: InteractivePresenterService.albumOptions.keys,
    allowedHelp: InteractivePresenterService.albumOptions,
    defaultsTo: 'shortcut',
  )
  ..addFlag(
    'hardlink',
    help:
        'Use hard links instead of symlinks for shortcut/reverse-shortcut album modes (Windows only)',
  )
  ..addOption(
    'divide-to-dates',
    help: 'Divide output to folders by nothing/year/month/day',
    allowed: ['0', '1', '2', '3'],
    defaultsTo: '2',
  )
  ..addFlag('skip-extras', help: 'Skip extra images (like -edited etc)')
  ..addFlag(
    'guess-from-name',
    help: 'Try to guess file dates from their names',
    defaultsTo: true,
  )
  ..addOption(
    'fix-extensions',
    help: 'Fix incorrect file extensions',
    allowed: ['none', 'standard', 'conservative', 'solo'],
    allowedHelp: {
      'none': 'No extension fixing',
      'standard': 'Fix extensions (skip TIFF-based files like RAW) - Default',
      'conservative': 'Fix extensions (skip TIFF and JPEG files)',
      'solo': 'Fix extensions then exit immediately',
    },
    defaultsTo: 'standard',
  )
  ..addOption(
    'transform-pixel-mp',
    help: 'Transform Pixel .MP/.MV to selected format',
    allowed: ['mp4', 'jpg', 'still'],
    allowedHelp: {
      'mp4': 'Rename Pixel .MP/.MV files to .mp4',
      'jpg': 'Create motion .jpg from Pixel .MP/.MV',
      'still':
          'Keep only still image for Pixel motion photos and remove .MP/.MV source files',
    },
  )
  ..addFlag(
    'update-creation-time',
    help: 'Set creation time equal to modification date (Windows only)',
    defaultsTo: true,
  )
  ..addFlag(
    'write-exif',
    help: 'Write geodata and DateTime to EXIF (requires ExifTool for non-JPEG)',
    defaultsTo: true,
  )
  ..addFlag(
    'limit-filesize',
    help: 'Enforces 64MB file size limit for low RAM systems',
  )
  ..addFlag(
    'divide-partner-shared',
    help: 'Move partner shared media to separate folder (PARTNER_SHARED)',
  )
  // NEW: allow a JSON with precomputed dates
  ..addOption(
    'json-dates',
    help: 'Path to a JSON file with a date dictionary (OldestDate per file)',
  )
  // NEW (issue #145): convert UTC photo dates to a local timezone offset so
  // re-uploading to Google Photos reproduces the original timeline.
  ..addOption(
    'local-timezone',
    help:
        'Convert UTC photo dates to this timezone offset (e.g. +08:00, -5, +05:30). '
        'Use when re-uploading to Google Photos: it ignores the EXIF OffsetTime tag '
        'and treats UTC timestamps as local time, causing photos to appear hours off. '
        'Format: ±HH:MM or ±H (no sign = positive).',
  )
  // NEW: keep the original input folder untouched by working on a sibling copy "<input>_tmp"
  ..addFlag(
    'keep-input',
    help:
        'Work on a temporary sibling copy of --input (suffix _tmp), keeping the original untouched',
  )
  ..addFlag(
    'keep-duplicates',
    help:
        'Keeps all duplicates files found in "_Duplicates" subfolder within in output folder instead of remove them totally',
  )
  ..addOption(
    'all-photos-dir',
    help:
        'Custom name for the output directory that receives all non-album photos (default: $kAllPhotosDirectoryName). '
        'Use this to rename "$kAllPhotosDirectoryName" or make album shortcuts more portable. '
        'Set it to an empty string (""), to disable that extra directory level.',
    defaultsTo: kAllPhotosDirectoryName,
  )
  ..addFlag(
    'resume',
    defaultsTo: true,
    help:
        'Resume a previous run recorded in "progress.json" inside the output folder (skips already completed steps). '
        'Use --no-resume to discard any previous progress and always start fresh.',
  );

/// **HELP TEXT DISPLAY**
///
/// Shows comprehensive help information including usage examples and setup instructions.
/// This guides users through the Google Photos Takeout process and GPTH usage.
///
/// **HELP CONTENT:**
/// - Overview of the Google Photos export process
/// - ExifTool installation requirements
/// - Basic usage examples with input/output folders
/// - Complete list of all available command line options
///
/// @param parser The configured argument parser for generating usage text
void _showHelp(final ArgParser parser) =>
    logPrint('''GooglePhotosTakeoutHelper v$version - The Dart successor

gpth is meant to help you with exporting your photos from Google Photos.

First, go to https://takeout.google.com/ , deselect all and select only Photos.
When ready, download all .zips, and extract them into *one* folder.
To read and write exif data, you have to install exiftool (e.g. from here https://exiftool.org)
for your OS and make sure the executable is in a folder in the \$PATH.

Then, run: gpth --input "folder/with/all/takeouts" --output "your/output/folder"
...and gpth will parse and organize all photos into one big chronological folder

${parser.usage}''');

/// **CONFIGURATION BUILDER**
///
/// Transforms parsed command line arguments into a type-safe ProcessingConfig using
/// the builder pattern. This provides a fluent API for complex configuration setup
/// while ensuring all validation rules are applied.
///
/// **CONFIGURATION CATEGORIES:**
/// 1. **Mode Detection**: Normal vs Fix vs Interactive mode
/// 2. **Path Resolution**: Input/output directories from args or interactive prompts
/// 3. **Processing Options**: Copy/move, EXIF writing, duplicate handling
/// 4. **Organization**: Album behavior and date-based folder structure
/// 5. **Metadata**: Date extraction preferences and coordinate handling
/// 6. **Extensions**: File extension fixing and format transformations
/// 7. **Platform Features**: Windows creation time updates, file size limits
///
/// **VALIDATION:**
/// - Builder pattern ensures all required fields are set
/// - Invalid option combinations are caught during build()
/// - Interactive mode can override and enhance CLI arguments
///
/// @param res Parsed command line arguments
/// @returns Fully configured and validated ProcessingConfig
/// @throws ConfigurationException for invalid configurations
Future<ProcessingConfig> _buildConfigFromArgs(final ArgResults res) async {
  // Handle special fix mode
  if (res['fix'] != null) {
    return _handleFixMode(res);
  }
  // Set up interactive mode if needed
  final isInteractiveMode =
      res['interactive'] || (res.arguments.isEmpty && stdin.hasTerminal);
  // Get input/output paths (interactive or from args)
  final paths = await _getInputOutputPaths(res, isInteractiveMode);

  // Build configuration using the builder pattern
  final configBuilder = ProcessingConfig.builder(
    inputPath: paths.inputPath,
    outputPath: paths.outputPath,
  );
  // Apply all configuration options
  // if (res['save-log']) configBuilder.saveLog = true;

  // IMPORTANT (Option A): set the global flag explicitly from CLI args
  ServiceContainer.instance.globalConfig.saveLog = res['save-log'];
  if (!res['save-log']) configBuilder.saveLog = false;

  if (res['verbose']) configBuilder.verboseOutput = true;
  if (res['skip-extras']) configBuilder.skipExtras = true;
  if (!res['guess-from-name']) configBuilder.guessFromName = false;

  // Resume control: --no-resume discards any previous run state (progress.json)
  if (!(res['resume'] as bool)) configBuilder.disableResumeCheck = true;

  // Propagate if input comes from an internal ZIP extraction
  configBuilder.inputExtractedFromZip = paths.extractedFromZip;

  // Propagate the original user-provided root directory (before resolving subfolder)
  configBuilder.userInputRoot = paths.userInputRoot;

  // Set album behavior
  final albumBehavior = AlbumBehavior.fromString(res['albums']);
  configBuilder.albumBehavior = albumBehavior;
  if (res['hardlink'] == true) configBuilder.hardlink = true;

  // Set custom ALL_PHOTOS directory name (applies to both interactive and non-interactive runs).
  final rawAllPhotosDir =
      (res['all-photos-dir'] as String?) ?? kAllPhotosDirectoryName;
  final allPhotosDir = rawAllPhotosDir.trim();
  if (allPhotosDir != rawAllPhotosDir) {
    logWarning(
      '[Config] --all-photos-dir had leading/trailing spaces; using "$allPhotosDir".',
    );
  }
  configBuilder.allPhotosDirectoryName = allPhotosDir;

  // Set extension fixing mode
  ExtensionFixingMode extensionFixingMode;
  if (isInteractiveMode) {
    // Surface a previous run's resume state instead of silently resuming
    // (issue #131): when the output folder holds step progress from an
    // earlier run, ask whether to resume it or start fresh. The actual
    // discarding of the state happens at pipeline start based on
    // disableResumeCheck.
    if (res['resume'] as bool) {
      final List<int> completedSteps = await _readCompletedStepsFromProgress(
        paths.outputPath,
      );
      if (completedSteps.isNotEmpty) {
        print('');
        final bool resumePrevious = await ServiceContainer
            .instance
            .interactiveService
            .askResumeFromProgress(completedSteps);
        if (!resumePrevious) configBuilder.disableResumeCheck = true;
      }
    }

    // Ask whether to keep the original input (work on "<input>_tmp")
    print('');
    final keepInputFlag = await ServiceContainer.instance.interactiveService
        .askKeepInput();
    configBuilder.keepInput = keepInputFlag;

    // Ask whether to keep the original input (work on "<input>_tmp")
    print('');
    final keepDuplicates = await ServiceContainer.instance.interactiveService
        .askKeepDuplicates();
    configBuilder.keepDuplicates = keepDuplicates;

    // Ask user for date division preference in interactive mode
    print('');
    final dateDivision = await ServiceContainer.instance.interactiveService
        .askDivideDates();
    final divisionLevel = DateDivisionLevel.fromInt(dateDivision);
    configBuilder.dateDivision = divisionLevel;

    // Ask user for extension fixing preference in interactive mode
    print('');
    final extensionFixingChoice = await ServiceContainer
        .instance
        .interactiveService
        .askFixExtensions();
    extensionFixingMode = ExtensionFixingMode.fromString(extensionFixingChoice);

    // Ask user for EXIF writing preference in interactive mode
    print('');
    final writeExif = await ServiceContainer.instance.interactiveService
        .askIfWriteExif();
    configBuilder.exifWriting = writeExif;

    // Ask user for Album mode – loop until a filesystem-compatible choice is made.
    print('');
    AlbumBehavior albumBehaviour;
    while (true) {
      final String albumModeString = await ServiceContainer
          .instance
          .interactiveService
          .askAlbums();
      albumBehaviour = AlbumBehavior.fromString(albumModeString);
      if (albumBehaviour == AlbumBehavior.shortcut ||
          albumBehaviour == AlbumBehavior.reverseShortcut) {
        final String? fsType = await _detectFilesystemType(paths.outputPath);
        if (_isHardlinkUnsupportedFilesystem(fsType)) {
          logWarning(
            '\n⚠️  Your destination drive uses '
            '${fsType?.toUpperCase() ?? 'an unsupported filesystem'}, '
            'which does NOT support hard links or symlinks.\n'
            'The "${albumBehaviour.value}" mode requires hard links / symlinks '
            'and cannot work on this filesystem.\n'
            'Please choose "duplicate-copy" instead, or select a destination '
            'drive with a filesystem that supports hard links (NTFS, ext4, APFS, '
            'Btrfs, …).\n',
            forcePrint: true,
          );
          print('');
          continue; // ask again
        }
      }
      break;
    }
    configBuilder.albumBehavior = albumBehaviour;

    // Ask user for Pixel/MP file transformation in interactive mode
    print('');
    final pixelTransformMode = await ServiceContainer
        .instance
        .interactiveService
        .askTransformPixelMPMode();
    if (pixelTransformMode != null) {
      configBuilder.pixelTransformation = true;
      configBuilder.pixelTransformationFormat = pixelTransformMode;
    }

    // Ask user for file size limiting in interactive mode
    print('');
    final limitFileSize = await ServiceContainer.instance.interactiveService
        .askIfLimitFileSize();
    configBuilder.fileSizeLimit = limitFileSize;

    // Ask user for creation time update in interactive mode (Windows only)
    if (Platform.isWindows) {
      print('');
      final updateCreationTime = await ServiceContainer
          .instance
          .interactiveService
          .askChangeCreationTime();
      configBuilder.creationTimeUpdate = updateCreationTime;
    }

    // Ask user for local timezone conversion (issue #145). If --local-timezone
    // was already passed on the CLI, skip the prompt and use that value.
    final String? cliLocalTimezone = res['local-timezone'] as String?;
    if (cliLocalTimezone != null && cliLocalTimezone.trim().isNotEmpty) {
      try {
        configBuilder.localTimezoneOffset = TimezoneOffset.parse(
          cliLocalTimezone,
        );
      } on FormatException catch (e) {
        _exitWithMessage(2, 'Invalid --local-timezone value: ${e.message}');
      }
    } else {
      print('');
      final TimezoneOffset? tzOffset = await ServiceContainer
          .instance
          .interactiveService
          .askLocalTimezone();
      configBuilder.localTimezoneOffset = tzOffset;
    }
    configBuilder.interactiveMode = true;
  } else {
    // Set date division from command line arguments
    final divisionLevel = DateDivisionLevel.fromInt(
      int.parse(res['divide-to-dates']),
    );
    configBuilder.dateDivision = divisionLevel;

    // Use command line arguments or defaults
    final fixExtensionsArg = res['fix-extensions'] ?? 'standard';
    extensionFixingMode = ExtensionFixingMode.fromString(fixExtensionsArg);

    // Apply remaining configuration options from command line
    if (!res['write-exif']) configBuilder.exifWriting = false;
    final transformPixelMpOption = res['transform-pixel-mp'] as String?;
    if (transformPixelMpOption != null) {
      final pixelFormat = PixelMpTransformFormat.fromString(
        transformPixelMpOption,
      );
      configBuilder.pixelTransformation = true;
      configBuilder.pixelTransformationFormat = pixelFormat;
    }
    if (res['update-creation-time']) configBuilder.creationTimeUpdate = true;
    if (res['limit-filesize']) configBuilder.fileSizeLimit = true;
    if (res['divide-partner-shared']) configBuilder.dividePartnerShared = true;
    if (res['keep-input']) configBuilder.keepInput = true;
    if (res['keep-duplicates']) configBuilder.keepDuplicates = true;
    // Parse --local-timezone (issue #145) in non-interactive mode.
    final String? localTimezoneArg = res['local-timezone'] as String?;
    if (localTimezoneArg != null && localTimezoneArg.trim().isNotEmpty) {
      try {
        configBuilder.localTimezoneOffset = TimezoneOffset.parse(
          localTimezoneArg,
        );
      } on FormatException catch (e) {
        _exitWithMessage(2, 'Invalid --local-timezone value: ${e.message}');
      }
    }
    // if (res['keep-duplicates']) ServiceContainer.instance.globalConfig.moveDuplicatesToDuplicatesFolder = true;

    // Check filesystem compatibility when shortcut / reverse-shortcut is requested.
    if (albumBehavior == AlbumBehavior.shortcut ||
        albumBehavior == AlbumBehavior.reverseShortcut) {
      final String? fsType = await _detectFilesystemType(paths.outputPath);
      if (_isHardlinkUnsupportedFilesystem(fsType)) {
        _exitWithMessage(
          14,
          'The "--albums ${albumBehavior.value}" mode requires hard links / '
          'symlinks, but the destination drive uses '
          '${fsType?.toUpperCase() ?? 'an unsupported filesystem'} which does '
          'NOT support them.\n'
          'Use --albums duplicate-copy instead, or choose a destination drive '
          'with a filesystem that supports hard links (NTFS, ext4, APFS, '
          'Btrfs, …).',
        );
      }
    }
  }
  configBuilder.extensionFixing = extensionFixingMode;

  final config = configBuilder.build();
  return config;
}

/// Logs the equivalent CLI arguments for an interactive-mode run so that the
/// log file captures the user's selections in a reproducible form.
List<String> _interactiveEquivalentArgs(final ProcessingConfig config) =>
    <String>[
      '--input',
      config.inputPath,
      '--output',
      config.outputPath,
      '--albums',
      config.albumBehavior.value,
      '--divide-to-dates',
      config.dateDivision.value.toString(),
      '--fix-extensions',
      config.extensionFixing.value,
      if (!config.writeExif) '--no-write-exif',
      if (!config.guessFromName) '--no-guess-from-name',
      if (config.verbose) '--verbose',
      if (!config.saveLog) '--no-save-log',
      if (config.transformPixelMp) ...[
        '--transform-pixel-mp',
        config.pixelMpTransformFormat.value,
      ],
      if (config.updateCreationTime) '--update-creation-time',
      if (config.limitFileSize) '--limit-filesize',
      if (config.keepInput) '--keep-input',
      if (config.keepDuplicates) '--keep-duplicates',
      if (config.hardlink) '--hardlink',
      if (config.disableResumeCheck) '--no-resume',
      if (config.localTimezoneOffset != null) ...[
        '--local-timezone',
        config.localTimezoneOffset!.exifString,
      ],
    ];

void _logInteractiveEquivalentArgs(final ProcessingConfig config) {
  final args = _interactiveEquivalentArgs(config);
  logInfo('Interactive mode selections (equivalent CLI args):');
  logInfo('  ${args.join(' ')}');
}

/// Detects the filesystem type for the drive/volume containing [dirPath].
/// The path does not need to exist; the nearest existing ancestor is used.
/// Returns a lowercase filesystem type string (e.g. 'ntfs', 'fat32', 'exfat'),
/// or null if detection fails.
Future<String?> _detectFilesystemType(final String dirPath) async {
  try {
    if (Platform.isWindows) {
      // Extract drive letter (works even if path doesn't exist yet).
      final String resolved = path.absolute(dirPath);
      if (resolved.length >= 2 && resolved[1] == ':') {
        final String driveLetter = resolved[0].toUpperCase();
        final ProcessResult result = await Process.run('powershell', [
          '-NoProfile',
          '-NonInteractive',
          '-Command',
          '(Get-Volume -DriveLetter $driveLetter).FileSystemType',
        ]);
        if (result.exitCode == 0) {
          final String fs = result.stdout.toString().trim().toLowerCase();
          if (fs.isNotEmpty) return fs;
        }
      }
    } else {
      // macOS / Linux: walk up to the nearest existing ancestor.
      String probe = path.absolute(dirPath);
      while (true) {
        if (await Directory(probe).exists() || await File(probe).exists()) {
          break;
        }
        final String parent = path.dirname(probe);
        if (parent == probe) break; // reached filesystem root
        probe = parent;
      }

      if (Platform.isMacOS) {
        // Get the device node for the mount point, then ask diskutil.
        final ProcessResult dfResult = await Process.run('df', [probe]);
        if (dfResult.exitCode == 0) {
          final List<String> lines = dfResult.stdout.toString().trim().split(
            '\n',
          );
          if (lines.length >= 2) {
            final String device = lines[1].split(RegExp(r'\s+')).first;
            final ProcessResult diskutilResult = await Process.run('diskutil', [
              'info',
              device,
            ]);
            if (diskutilResult.exitCode == 0) {
              final String output = diskutilResult.stdout.toString();
              final RegExpMatch? match = RegExp(
                r'File System Personality\s*:\s*(\S+)',
                caseSensitive: false,
              ).firstMatch(output);
              if (match != null) return match.group(1)!.toLowerCase();
              final RegExpMatch? typeMatch = RegExp(
                r'Type \(Bundle\)\s*:\s*(\S+)',
                caseSensitive: false,
              ).firstMatch(output);
              if (typeMatch != null) return typeMatch.group(1)!.toLowerCase();
            }
          }
        }
      } else {
        // Linux: prefer findmnt, fall back to df -T.
        final ProcessResult findmntResult = await Process.run('findmnt', [
          '-n',
          '-o',
          'FSTYPE',
          '--target',
          probe,
        ]);
        if (findmntResult.exitCode == 0) {
          final String fs = findmntResult.stdout
              .toString()
              .trim()
              .toLowerCase();
          if (fs.isNotEmpty) return fs;
        }
        final ProcessResult dfResult = await Process.run('df', ['-T', probe]);
        if (dfResult.exitCode == 0) {
          final List<String> lines = dfResult.stdout.toString().trim().split(
            '\n',
          );
          if (lines.length >= 2) {
            final List<String> parts = lines[1].split(RegExp(r'\s+'));
            if (parts.length >= 2) return parts[1].toLowerCase();
          }
        }
      }
    }
  } catch (e) {
    logDebug('Filesystem type detection failed for $dirPath: $e');
  }
  return null;
}

/// Returns true if [fsType] identifies a filesystem that does NOT support
/// hard links or symlinks (FAT12, FAT16, FAT32, exFAT).
bool _isHardlinkUnsupportedFilesystem(final String? fsType) {
  if (fsType == null) return false;
  final String lower = fsType.toLowerCase();
  return lower == 'fat32' ||
      lower == 'fat' ||
      lower == 'fat16' ||
      lower == 'fat12' ||
      lower == 'vfat' ||
      lower == 'exfat' ||
      lower == 'msdos' ||
      lower.startsWith('fat') ||
      lower.contains('exfat');
}

/// **FIX MODE HANDLER**
///
/// Handles the special "fix mode" where GPTH only processes existing photos
/// to correct their dates without doing full Google Photos Takeout organization.
/// This is useful for post-processing photos that have been moved or copied
/// and lost their original timestamps.
///
/// **FIX MODE BEHAVIOR:**
/// - Uses the same directory as both input and output (in-place processing)
/// - Focuses only on date extraction and timestamp correction
/// - Skips album organization, duplicate removal, and file moving
/// - Applies date extraction heuristics to determine correct timestamps
/// - Updates file modification times to match extracted dates
///
/// **USE CASES:**
/// - Photos imported from various sources with incorrect timestamps
/// - Bulk date correction after file transfers
/// - Cleanup of manually organized photo collections
///
/// @param res Parsed command line arguments containing fix path
/// @returns ProcessingConfig configured for fix mode operation
Future<ProcessingConfig> _handleFixMode(final ArgResults res) async {
  final fixPath =
      res['fix']
          as String; // For fix mode, we use the same directory as input and output
  final builder = ProcessingConfig.builder(
    inputPath: fixPath,
    outputPath: fixPath,
  );
  builder.verboseOutput = res['verbose'];
  builder.guessFromName = res['guess-from-name'];
  return builder.build();
}

/// **INPUT/OUTPUT PATH RESOLUTION**
///
/// Determines the input and output directories from either command line arguments
/// or interactive mode prompts. Handles the complexity of Google Takeout ZIP files
/// and provides a unified interface for path resolution.
///
/// **PATH RESOLUTION MODES:**
/// 1. **CLI Mode**: Paths provided directly via --input and --output flags
/// 2. **Interactive Mode**: User-guided selection with validation
/// 3. **ZIP Processing**: User selects extraction location, then output location
/// 4. **Pre-extracted**: Direct processing of already extracted folders
///
/// **ZIP HANDLING:**
/// - Space requirement calculation and validation (double space needed since ZIPs remain)
/// - User-controlled extraction to chosen directory
/// - Transparent location for temporary files
/// - Cleanup responsibility lies with user
///
/// **VALIDATION:**
/// - Input directory existence verification
/// - Output directory creation and cleanup prompts
/// - Path accessibility and permission checks
/// - Automatic navigation to Google Photos directory within Takeout structure
///
/// @param res Parsed command line arguments
/// @returns InputOutputPaths object with resolved and validated paths
/// @throws ProcessExit for invalid or inaccessible paths

/// Strips a trailing path separator (/ or \) from a path string.
/// This prevents issues on Windows where a trailing backslash inside a
/// double-quoted argument (e.g. "path\") is interpreted by the C runtime as
/// an escaped quote, causing subsequent flags to be swallowed into the value.
String? _sanitizePath(final String? rawPath) {
  if (rawPath == null) return null;
  return rawPath.trimRight().replaceAll(RegExp(r'[/\\]+$'), '');
}

Future<InputOutputPaths> _getInputOutputPaths(
  final ArgResults res,
  final bool isInteractiveMode,
) async {
  // Strip trailing path separators to tolerate arguments like "path\output\"
  // which on Windows cause the C-runtime to misparse subsequent flags.
  String? inputPath = _sanitizePath(res['input'] as String?);
  String? outputPath = _sanitizePath(res['output'] as String?);

  // Detect the Windows trailing-backslash quoting issue:
  // If a path value contains what looks like embedded CLI flags, it almost
  // certainly means a quoted argument like "path\" swallowed the rest of the
  // command line (because \" escapes the closing quote in Win32 argv parsing).
  for (final entry in [('--input', inputPath), ('--output', outputPath)]) {
    final flag = entry.$1;
    final value = entry.$2;
    if (value != null && RegExp(r'\s--\w').hasMatch(value)) {
      _exitWithMessage(
        10,
        'The $flag value appears to contain extra flags — this is usually caused '
        'by a trailing backslash inside a quoted path on Windows (e.g. "$flag \\"path\\\\"").\n'
        'Remove the trailing backslash or replace it with a forward slash:\n'
        '  $flag "path/to/folder"',
      );
    }
  }

  var extractedFromZip = false; // NEW
  String? userInputRoot; // NEW: keep the original root before resolve

  if (isInteractiveMode) {
    // Interactive mode handles path collection
    await ServiceContainer.instance.interactiveService.showGreeting();
    print('');

    final bool shouldUnzip = await ServiceContainer.instance.interactiveService
        .askIfUnzip();
    print('');

    late Directory inDir;
    if (shouldUnzip) {
      final zips = await ServiceContainer.instance.interactiveService
          .selectZipFiles();
      print('');

      Directory extractDir = await ServiceContainer.instance.interactiveService
          .selectExtractionDirectory();
      print('');

      final out = await ServiceContainer.instance.interactiveService
          .selectOutputDirectory();
      print('');

      // Validate the chosen extraction directory before extracting
      // (issue #131). A completed previous extraction of the SAME ZIP set
      // (recorded via the zip_extraction sentinel in <output>/progress.json)
      // is reused; any unsafe state (leftover data from another run, a
      // different ZIP set, an interrupted extraction) is explained and the
      // user is re-prompted for another folder instead of aborting the run
      // with a fatal error.
      bool reuseExtraction = false;
      while (true) {
        try {
          reuseExtraction = await _shouldReuseZipExtraction(
            zips,
            extractDir,
            Directory(out.path),
          );
          break;
        } on FileSystemException catch (e) {
          logWarning(
            'The selected extraction folder cannot be used:\n${e.message}',
            forcePrint: true,
          );
          logWarning(
            'Please select a different extraction folder (a new, empty folder is recommended).',
            forcePrint: true,
          );
          print('');
          extractDir = await ServiceContainer.instance.interactiveService
              .selectExtractionDirectory();
          print('');
        }
      }

      inDir = extractDir;
      outputPath = out.path;

      if (reuseExtraction) {
        logPrint(
          'Previous extraction validated via progress.json '
          '- reusing "${extractDir.path}" (ZIP extraction skipped).',
        );
        print('');
      } else {
        // Calculate space requirements
        final cumZipsSize = zips
            .map((final e) => e.lengthSync())
            .reduce((final a, final b) => a + b);
        final requiredSpace =
            (cumZipsSize * 2) +
            256 * 1024 * 1024; // Double because original ZIPs remain
        await ServiceContainer.instance.interactiveService.freeSpaceNotice(
          requiredSpace,
          extractDir,
        );
        print('');

        await ServiceContainer.instance.interactiveService.extractAll(
          zips,
          extractDir,
        );
        await _writeZipExtractionSentinel(zips, Directory(out.path));
        print('');
      }
      extractedFromZip = true;
    } else {
      try {
        inDir = await ServiceContainer.instance.interactiveService
            .selectInputDirectory();
      } catch (e) {
        logWarning('⚠️  INTERACTIVE DIRECTORY SELECTION FAILED');
        logWarning(
          'Interactive selecting input dir crashed... \n'
          "It looks like you're running headless/on Synology/NAS...\n"
          "If so, you have to use cli options - run 'gpth --help' to see them",
        );
        logWarning('');
        logWarning('Please restart the program with CLI options instead.');
        logError('No input directory could be selected');
        _exitWithMessage(
          2,
          'Interactive input directory selection failed. If you are running headless or on a NAS, run with CLI options: `gpth --input <path> --output <path>`',
        );
      }
      print('');
      final out = await ServiceContainer.instance.interactiveService
          .selectOutputDirectory();
      outputPath = out.path;
      print('');
    }

    inputPath = inDir.path;
    userInputRoot = inputPath; // keep original root before resolving
  }

  // If running in non-interactive CLI mode and the provided input path
  // points to a ZIP file or contains ZIP files, automatically extract them
  // into a local `.gpth-unzipped` directory and use that as the input.
  if (!isInteractiveMode && inputPath != null) {
    try {
      final provided = File(inputPath);
      final Directory extractDir;
      final List<File> zips = [];

      if (await provided.exists() &&
          provided.statSync().type == FileSystemEntityType.file &&
          path.extension(provided.path).toLowerCase() == '.zip') {
        // Single zip file provided as --input
        zips.add(provided);
        extractDir = Directory(
          path.join(path.dirname(provided.path), '.gpth-unzipped'),
        );
      } else {
        final providedDir = Directory(inputPath);
        if (await providedDir.exists()) {
          // Find zip files in directory (non-recursive)
          for (final ent in providedDir.listSync()) {
            if (ent is File &&
                path.extension(ent.path).toLowerCase() == '.zip') {
              zips.add(ent);
            }
          }
        }
        extractDir = Directory(path.join(inputPath, '.gpth-unzipped'));
      }

      if (zips.isNotEmpty) {
        logPrint(
          'Detected ${zips.length} ZIP file(s) in input path - extracting before processing...',
        );

        // Compute rough required space and warn
        var cumZipsSize = 0;
        for (final z in zips) {
          try {
            cumZipsSize += z.lengthSync();
          } catch (_) {}
        }
        final requiredSpace = (cumZipsSize * 2) + 256 * 1024 * 1024;
        logPrint(
          'Estimated required temporary space for extraction: ${requiredSpace ~/ (1024 * 1024)} MB',
        );

        // Check the extraction sentinel in progress.json: reuse a validated
        // previous extraction, or extract fresh.
        // _shouldReuseZipExtraction throws on unsafe states (partial extraction,
        // mismatched ZIP set) so no stale data is ever used silently.
        try {
          final Directory outDir = Directory(outputPath!);
          final bool reuse = await _shouldReuseZipExtraction(
            zips,
            extractDir,
            outDir,
          );
          if (reuse) {
            logPrint(
              'Previous extraction validated via progress.json '
              '- reusing "${extractDir.path}" to resume processing.',
            );
          } else {
            await ServiceContainer.instance.interactiveService.extractAll(
              zips,
              extractDir,
            );
            await _writeZipExtractionSentinel(zips, outDir);
            logPrint(
              'Extraction complete. Using extracted folder: ${extractDir.path}',
            );
          }
          inputPath = extractDir.path;
          userInputRoot = inputPath;
          extractedFromZip = true;
        } catch (e) {
          logError('Automatic ZIP extraction failed: $e');
          _exitWithMessage(
            12,
            'Automatic ZIP extraction failed: ${e.toString()}. Try extracting manually and run again with the extracted folder as --input.',
          );
        }
      } else {
        // No ZIPs detected in CLI mode: remember original root as provided
        userInputRoot ??= inputPath;
      }
    } catch (e) {
      // Non-fatal: log and continue; failure here will be caught later by path resolution
      logWarning('ZIP auto-detection/extraction encountered an error: $e');
      // Still remember the original root as provided
      userInputRoot ??= inputPath;
    }
  }

  // Validate required paths
  if (inputPath == null) {
    logError('No --input folder specified :/');
    _exitWithMessage(
      10,
      'Missing required --input path. Provide --input <folder> or run interactive mode.',
    );
  }
  if (outputPath == null) {
    logError('No --output folder specified :/');
    _exitWithMessage(
      10,
      'Missing required --output path. Provide --output <folder> or run interactive mode.',
    );
  }
  // Resolve input path to Google Photos directory using the domain service
  try {
    inputPath = PathResolverService.resolveGooglePhotosPath(inputPath);
  } catch (e) {
    logError('Path resolution failed: $e');
    _exitWithMessage(
      12,
      'Could not resolve Google Photos directory from input path: ${e.toString()}. Make sure the folder contains a Takeout/Google Photos structure or pass the correct --input path.',
    );
  }

  return InputOutputPaths(
    inputPath: inputPath,
    outputPath: outputPath,
    extractedFromZip: extractedFromZip,
    userInputRoot: userInputRoot ?? inputPath, // fallback if not set
  );
}

/// **DEPENDENCY INITIALIZATION**
///
/// Sets up external dependencies and global application state before processing begins.
/// This ensures all required tools and configurations are properly initialized.
///
/// **INITIALIZATION TASKS:**
/// 1. **Debug/Verbose Mode**: Enable detailed logging based on configuration
/// 2. **Global State**: Set file size limits and processing constraints
/// 3. **ExifTool Integration**: Verify ExifTool availability for metadata operations
/// 4. **Performance Settings**: Configure memory limits and processing constraints
///
/// **EXIFTOOL INTEGRATION:**
/// - Checks for ExifTool installation in system PATH
/// - Gracefully handles missing ExifTool (disables EXIF features)
/// - Provides clear feedback about metadata processing capabilities
///
/// **GLOBAL STATE MANAGEMENT:**
/// - Sets verbose logging flag for detailed output
/// - Configures file size limits for low-memory systems
/// - Initializes performance monitoring and progress tracking
///
/// @param config Processing configuration with user preferences
Future<void> _configureDependencies(final ProcessingConfig config) async {
  // Ensure canonical detection and path generation use the same configurable
  // non-album folder name across the whole pipeline.
  FileEntity.allPhotosDirectoryName = config.allPhotosDirectoryName;

  // Set up global verbose mode
  bool isDebugMode = false;
  assert(() {
    isDebugMode = true;
    return true;
  }(), 'Debug mode assertion');
  if (config.verbose || isDebugMode) {
    ServiceContainer.instance.globalConfig.isVerbose = true;
    logDebug('Verbose mode active!');
  }
  // Set global file size enforcement
  if (config.limitFileSize) {
    ServiceContainer.instance.globalConfig.enforceMaxFileSize = true;
  }

  // Propagate the local timezone offset (issue #145) to the global config so
  // Steps 6 and 7 can read it at runtime without threading config through.
  ServiceContainer.instance.globalConfig.localTimezoneOffset =
      config.localTimezoneOffset;

  // Log ExifTool status (already set during ServiceContainer initialization)
  if (ServiceContainer.instance.exifTool != null) {
    logPrint('Exiftool found! Continuing with EXIF support...');
  } else {
    logPrint('Exiftool not found! Continuing without EXIF support...');
  }

  // EXTRA: let the user know if we have a file dates dictionary loaded
  final dict = ServiceContainer.instance.globalConfig.jsonDatesDictionary;
  if (dict != null) {
    logPrint('JSON Dates Dictionary is loaded with ${dict.length} entries.');
  } else {
    logPrint(
      'JSON Dates Dictionary not loaded. Missing JSON dates will be extracted from EXIF info or other fallback methods.',
    );
  }
}

/// **MAIN PROCESSING PIPELINE EXECUTION**
///
/// Executes the core photo processing workflow using the ProcessingPipeline.
/// This is where the actual work happens - transforming Google Photos Takeout
/// data into an organized photo library.
///
/// **PRE-PROCESSING VALIDATION:**
/// - Input directory existence verification
/// - Output directory preparation and cleanup handling
/// - User confirmation for destructive operations
///
/// **PIPELINE EXECUTION:**
/// The ProcessingPipeline orchestrates 8 sequential steps:
/// 1. Fix Extensions - Correct mismatched file extensions
/// 2. Discover Media - Find and classify all media files
/// 3. Merge Media Entities - Merge identical Media Entities from different folders into a single one
/// 4. Extract Dates - Determine accurate timestamps
/// 5. Write EXIF - Embed metadata into files
/// 6. Find Albums - Merge album relationships
/// 7. Move Files - Organize files to output structure
/// 8. Update Creation Time - Sync timestamps (Windows only)
///
/// **ERROR HANDLING:**
/// - Each step can fail independently with proper error reporting
/// - Critical steps halt processing on failure
/// - Non-critical steps continue processing with warnings
/// - Comprehensive error logging for troubleshooting
///
/// **PROGRESS TRACKING:**
/// - Real-time progress reporting for each step
/// - Timing information for performance analysis
/// - Statistics collection throughout processing
///
/// @param config Validated processing configuration
/// @returns ProcessingResult with comprehensive statistics and status
Future<ProcessingResult> _executeProcessing(
  final ProcessingConfig config, {
  final bool precleanedOutput = false, // If true, skip internal output cleaning
}) async {
  Directory inputDir = Directory(config.inputPath);
  final outputDir = Directory(config.outputPath);

  // Validate directories
  if (!await inputDir.exists()) {
    logError('Input folder does not exist :/');
    _exitWithMessage(11, 'Input folder does not exist: ${inputDir.path}');
  }

  // ─────────────────────────────────────────────────────────────────────────────
  // Early ZIP auto-extraction inside execute() to prevent wrong cloning decision
  // This is a safety net for scenarios where the config still has inputExtractedFromZip=false
  // but the userInputRoot actually contains ZIP files that must be extracted first.
  // ─────────────────────────────────────────────────────────────────────────────

  bool extractedNow = false;
  String effectiveUserRoot = config.userInputRoot;
  if (!config.inputExtractedFromZip) {
    try {
      final root = Directory(config.userInputRoot);
      if (await root.exists()) {
        final zips = <File>[];
        await for (final ent in root.list(followLinks: false)) {
          if (ent is File && path.extension(ent.path).toLowerCase() == '.zip') {
            zips.add(ent);
          }
        }
        if (zips.isNotEmpty) {
          final extractDir = Directory(path.join(root.path, '.gpth-unzipped'));
          logPrint(
            'Found ${zips.length} ZIP file(s) under userInputRoot - extracting to ${extractDir.path} before processing',
          );

          // Compute rough required space and log
          var cumZipsSize = 0;
          for (final z in zips) {
            try {
              cumZipsSize += z.lengthSync();
            } catch (_) {}
          }
          final requiredSpace = (cumZipsSize * 2) + 256 * 1024 * 1024;
          logPrint(
            'Estimated required temporary space for extraction: ${requiredSpace ~/ (1024 * 1024)} MB',
          );

          // Check the extraction sentinel in progress.json: reuse a validated
          // previous extraction, or extract fresh. Throws on unsafe states.
          final bool reuse = await _shouldReuseZipExtraction(
            zips,
            extractDir,
            outputDir,
          );
          if (reuse) {
            logPrint(
              'Previous extraction validated via progress.json '
              '- reusing "${extractDir.path}" to resume processing.',
            );
          } else {
            await ServiceContainer.instance.interactiveService.extractAll(
              zips,
              extractDir,
            );
            await _writeZipExtractionSentinel(zips, outputDir);
          }
          effectiveUserRoot = extractDir.path;

          // Re-resolve Google Photos path inside the extraction dir
          final resolvedInside = PathResolverService.resolveGooglePhotosPath(
            extractDir.path,
          );
          inputDir = Directory(resolvedInside);
          extractedNow = true;
          logPrint(
            'Extraction completed in execute(); effective input is now $resolvedInside',
          );
        }
      }
    } catch (e) {
      logError(
        'Late ZIP extraction failed inside execute(): $e',
        forcePrint: true,
      );
      _exitWithMessage(12, 'Late ZIP extraction failed: ${e.toString()}');
    }
  }

  // NEW: honor keep-input but avoid cloning when input was (now) extracted from ZIPs
  final bool inputExtractedFromZipFlag =
      config.inputExtractedFromZip || extractedNow;

  // Diagnostic Log to veryfy if we should clone InputDir
  final bool shouldClone = config.keepInput && !inputExtractedFromZipFlag;
  logPrint(
    '--keep-input = ${config.keepInput}, inputExtractedFromZip = $inputExtractedFromZipFlag => shouldClone = $shouldClone',
  );

  Directory effectiveInputDir = inputDir;

  if (shouldClone) {
    logPrint(
      'Input folder will be cloned as working copy because --keep-input = ${config.keepInput} and input does not come from ZIP extraction (inputExtractedFromZip = $inputExtractedFromZipFlag).',
    );
    final cloner = InputCloneService();
    // Clone the **original user root**, not the already resolved Google Photos subfolder
    final Directory clonedRoot = await cloner.cloneToSiblingTmp(
      Directory(effectiveUserRoot),
    );
    logPrint('Using temporary input copy root: ${clonedRoot.path}');
    effectiveUserRoot = clonedRoot.path;

    // Now resolve the Google Photos subfolder INSIDE the clone for the pipeline
    final String resolvedInsideClone =
        PathResolverService.resolveGooglePhotosPath(clonedRoot.path);
    effectiveInputDir = Directory(resolvedInsideClone);
    logPrint('Effective input inside clone: $resolvedInsideClone');
  } else if (config.keepInput && inputExtractedFromZipFlag) {
    // Explicit message explaining why we skip clone
    logWarning(
      'Skipping clone input folder because input comes from ZIP extraction (inputExtractedFromZip = $inputExtractedFromZipFlag).',
      forcePrint: true,
    );
  } else {
    logDebug(
      'Skipping clone input folder (--keep-input = ${config.keepInput}, inputExtractedFromZip = $inputExtractedFromZipFlag).',
      forcePrint: true,
    );
  }

  // IMPORTANT: from here on, use a runtimeConfig that reflects the effective input dir
  final ProcessingConfig runtimeConfig = (shouldClone || extractedNow)
      ? config.copyWith(
          inputPath: effectiveInputDir.path,
          userInputRoot: effectiveUserRoot,
          inputExtractedFromZip: inputExtractedFromZipFlag,
        )
      : config;

  // Skip internal cleaning if it was already done before logger creation
  if (!precleanedOutput) {
    if (await outputDir.exists() &&
        await _needsCleanOutputDirectory(outputDir, runtimeConfig)) {
      if (runtimeConfig.isInteractiveMode) {
        logWarning(
          '⚠️  DANGER: Output directory cleanup requested. This will DELETE files/folders inside: ${outputDir.path}',
          forcePrint: true,
        );
        logWarning(
          'Only the input folder (if it lives inside output), ".log" and ".json" files are preserved. Everything else will be removed recursively.',
          forcePrint: true,
        );
        if (await ServiceContainer.instance.interactiveService
            .askForCleanOutput()) {
          await _cleanOutputDirectory(outputDir, runtimeConfig);
        }
      } else {
        // SAFETY: Never auto-clean in non-interactive mode.
        _exitWithMessage(
          13,
          'Output directory contains items other than allowed ".log" and ".json" files. Refusing to auto-clean in non-interactive mode. '
          'Please choose an empty output directory, or clean it manually.',
        );
      }
    }
  }

  await outputDir.create(recursive: true);

  // Execute the processing pipeline
  final pipeline = ProcessingPipeline(
    interactiveService: ServiceContainer.instance.interactiveService,
  );
  return pipeline.execute(
    config: runtimeConfig,
    inputDirectory: Directory(
      runtimeConfig.inputPath,
    ), // passes the effective folder (cloned/extracted if applies)
    outputDirectory: outputDir,
  );
}

/// **OUTPUT DIRECTORY VALIDATION**
///
/// Determines whether the output directory **requires cleaning** before processing.
///
/// **Decision rules:**
/// - Returns **false** immediately if a `progress.json` exists in `outputDir` (resume mode enabled).
/// - Otherwise, returns **true** if `outputDir` contains any entry **other than** the configured input folder, `.log` files, or `.json` files.
/// - Returns **false** if `outputDir` is empty or contains **only** allowed preserved entries.
///
/// **Rationale:**
/// - Having `progress.json` indicates the directory holds a valid resume state; we avoid forcing a clean.
/// - We ignore the input folder living inside the output directory (common layout).
/// - Existing `.log` and `.json` files are safe to keep between runs.
/// - Absolute paths are compared to avoid relative-path edge cases.
///
/// @param outputDir The output directory to inspect.
/// @param config The processing configuration (used to resolve `inputPath`).
/// @returns `true` if cleaning is required; `false` otherwise (or if `progress.json` exists).
Future<bool> _needsCleanOutputDirectory(
  final Directory outputDir,
  final ProcessingConfig config,
) async {
  // In --fix mode the output directory IS the input directory (in-place processing).
  // Never attempt to clean it — those photos are exactly what we want to keep.
  if (path.absolute(outputDir.path) == path.absolute(config.inputPath)) {
    return false;
  }
  final File progressFile = File(path.join(outputDir.path, 'progress.json'));
  if (await progressFile.exists() && !config.disableResumeCheck) return false;
  await for (final entry in outputDir.list()) {
    if (!_isAllowedExistingOutputEntry(entry, config)) {
      return true;
    }
  }
  return false;
}

bool _isAllowedExistingOutputEntry(
  final FileSystemEntity entry,
  final ProcessingConfig config,
) {
  if (path.absolute(entry.path) == path.absolute(config.inputPath)) {
    return true;
  }

  if (entry is! File) return false;

  final ext = path.extension(entry.path).toLowerCase();
  return ext == '.log' || ext == '.json';
}

@visibleForTesting
Future<bool> needsCleanOutputDirectoryForTest(
  final Directory outputDir,
  final ProcessingConfig config,
) => _needsCleanOutputDirectory(outputDir, config);

@visibleForTesting
Future<void> cleanOutputDirectoryForTest(
  final Directory outputDir,
  final ProcessingConfig config,
) => _cleanOutputDirectory(outputDir, config);

/// **OUTPUT DIRECTORY CLEANUP**
///
/// Safely removes existing content from the output directory while preserving
/// the input folder if it exists inside the output directory. This handles
/// the common case where users extract Google Takeout files directly into
/// their desired output location.
///
/// **SAFETY MEASURES:**
/// - Only removes items that are not the input directory
/// - Preserves `.log` and `.json` files
/// - Uses absolute path comparison to prevent accidental deletion
/// - Removes both files and directories recursively
/// - Called only after user confirmation
///
/// @param outputDir The output directory to clean
/// @param config Processing configuration with input path
Future<void> _cleanOutputDirectory(
  final Directory outputDir,
  final ProcessingConfig config,
) async {
  await for (final entry in outputDir.list()) {
    if (_isAllowedExistingOutputEntry(entry, config)) {
      continue;
    }
    await entry.delete(recursive: true);
  }
}

/// **FINAL RESULTS DISPLAY**
///
/// Presents comprehensive processing results and statistics to the user.
/// This provides transparency about what was accomplished and helps users
/// understand the scope and success of the processing operation.
///
/// **STATISTICS CATEGORIES:**
/// - **File Operations**: Creation time updates, duplicate removal
/// - **Metadata Processing**: EXIF coordinate and timestamp writing
/// - **File Corrections**: Extension fixes and format transformations
/// - **Content Filtering**: Extra files skipped during processing
/// - **Date Extraction**: Statistics by extraction method used
/// - **Performance**: Total processing time and efficiency metrics
///
/// **DISPLAY LOGIC:**
/// - Only shows statistics for operations that actually occurred
/// - Groups related statistics for easier reading
/// - Provides clear labels and units for all metrics
/// - Uses consistent formatting for professional appearance
///
/// **EXIT HANDLING:**
/// - Success: Exit code 0 for successful processing
/// - Failure: Exit code 1 for processing failures
/// - Provides clear indication of overall operation success
///
/// **ACKNOWLEDGMENTS:**
/// - Shows appreciation message and donation links
/// - Recognizes the significant development effort invested
/// - Encourages user support for continued development
///
/// @param config Processing configuration for context
/// @param result Comprehensive processing results and statistics
void _showResults(
  final ProcessingConfig config,
  final ProcessingResult result,
) {
  const barWidth = 100;

  logPrint('');
  logPrint('=' * barWidth);
  logPrint('DONE! FREEEEEDOOOOM!!!');
  logPrint('Your Processed Takeout can be found on: ${config.outputPath}');
  logPrint('');
  logPrint('Some statistics for the achievement hunters:');

  if (result.creationTimesUpdated > 0) {
    logPrint(
      '\t${result.creationTimesUpdated} files had their CreationDate updated',
    );
  }
  if (result.duplicatesRemoved > 0) {
    if (config.keepDuplicates) {
      logPrint(
        '\t${result.duplicatesRemoved} duplicates were found and moved to `_Duplicates` subfolder',
      );
    } else {
      logPrint(
        '\t${result.duplicatesRemoved} duplicates were found and removed',
      );
    }
  }
  if (result.dateTimesWrittenToExif > 0) {
    logPrint(
      '\t${result.dateTimesWrittenToExif}/${result.mediaProcessed} files got their DateTime set in EXIF data',
    );
  }
  if (result.coordinatesWrittenToExif > 0) {
    logPrint(
      '\t${result.coordinatesWrittenToExif}/${result.mediaProcessed} files got their coordinates set in EXIF data (from json)',
    );
  }
  if (result.extensionsFixed > 0) {
    logPrint(
      '\t${result.extensionsFixed}/${result.mediaProcessed} files got their extensions fixed',
    );
  }
  if (result.extrasSkipped > 0) {
    logPrint('\t${result.extrasSkipped} extras were skipped');
  }

  // Show extraction method statistics (always show all buckets, including zeros)
  logPrint('\tDateTime extraction method statistics:');
  const ordered = [
    DateTimeExtractionMethod.json,
    DateTimeExtractionMethod.exif,
    DateTimeExtractionMethod.guess,
    DateTimeExtractionMethod.jsonTryHard,
    DateTimeExtractionMethod.folderYear,
    DateTimeExtractionMethod.none,
  ];
  for (final m in ordered) {
    final count = result.extractionMethodStats[m] ?? 0;
    logPrint('\t\t${m.name}: $count files');
  }

  // Calculate Total Processing Time
  final d = result.totalProcessingTime;
  final hours = d.inHours;
  final minutes = d.inMinutes.remainder(60);
  final seconds = d.inSeconds.remainder(60);

  final durationPretty =
      '${hours}h '
      '${minutes.toString().padLeft(2, '0')}m '
      '${seconds.toString().padLeft(2, '0')}s';

  logPrint('');
  logPrint('In total GPTH took $durationPretty to complete');

  logPrint('=' * barWidth);

  // Final exit with descriptive message based on processing result
  final exitCode = result.isSuccess ? 0 : 1;
  final exitMessage = result.isSuccess
      ? 'Processing completed successfully'
      : 'Processing completed with errors - check logs above for details';

  if (!result.isSuccess) {
    stderr.writeln('[PROCESSING_RESULT] $exitMessage');
  } else {
    logPrint('[SUCCESS] $exitMessage');
  }

  exit(exitCode);
}

/// Helper to load the optional flag --save-log into GlobalConfig
/// after the ServiceContainer has been re-initialized with the final logger.
Future<void> _loadSaveLogIntoGlobalConfigFromArgs(
  final List<String> parsedArguments, {
  // NEW: allow previewing the exact log path and show it at startup without touching disk.
  final String? preferredLogDirForPreview,
}) async {
  final parser = _createArgumentParser();
  final res = parser.parse(parsedArguments);
  try {
    // Option A: only set the flag here; do not attempt to open any file or read logFilePath yet.
    ServiceContainer.instance.globalConfig.saveLog = res['save-log'];
    if (res['save-log']) {
      // If we know the output dir, preview the exact file path using the same timestamp
      // the logger will reuse later (no I/O performed here).
      if (preferredLogDirForPreview == null) {
        logPrint('Messages Log enabled by default (will use output folder).');
      }
      // Exact path is printed once after logger+file-sink are initialised (see below).
    } else {
      logPrint(
        '--no-save-log flag detected; skipping save log messages into disk.',
      );
    }
  } catch (e) {
    logError(
      'Failed to load --save-log flag into GlobalConfig: $e',
      forcePrint: true,
    );
  }
}

/// Helper to load the optional external dates dictionary into GlobalConfig
/// after the ServiceContainer has been re-initialized with the final logger.
Future<void> _loadFileDatesIntoGlobalConfigFromArgs(
  final List<String> parsedArguments,
) async {
  try {
    final parser = _createArgumentParser();
    final res = parser.parse(parsedArguments);
    final String? jsonPath = res['json-dates'] as String?;
    if (jsonPath == null) {
      logPrint(
        '--json-dates argument not given; skipping external dates dictionary load.',
      );
      return;
    }

    logPrint('Attempting to load JSON Dates Dictionary from: $jsonPath');

    final file = File(jsonPath);
    if (!await file.exists()) {
      logWarning(
        'Failed to load JSON Dates Dictionary: file does not exist at "$jsonPath"',
        forcePrint: true,
      );
      return;
    }

    final jsonString = await file.readAsString();
    final dynamic raw = jsonDecode(jsonString);
    if (raw is! Map<String, dynamic>) {
      throw const FormatException(
        'Top-level JSON must be an object/dictionary.',
      );
    }

    // Ensure Map<String, Map<String, dynamic>>-like structure (skip non-map values)
    final Map<String, Map<String, dynamic>> normalized = {};
    raw.forEach((final k, final v) {
      if (v is Map<String, dynamic>) {
        normalized[k] = v;
      } else if (v is Map) {
        final m = <String, dynamic>{};
        v.forEach((final kk, final vv) => m[kk.toString()] = vv);
        normalized[k] = m;
      } else {
        // skip non-map entries
      }
    });

    ServiceContainer.instance.globalConfig.jsonDatesDictionary = normalized;
    logPrint('Loaded ${normalized.length} entries from $jsonPath');
  } catch (e) {
    logWarning('Failed to load JSON Dates Dictionary: $e', forcePrint: true);
  }
}
