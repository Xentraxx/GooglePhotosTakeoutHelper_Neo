import 'dart:async';
import 'dart:io';

import 'package:file_picker_desktop/file_picker_desktop.dart';
import 'package:gpth_neo/gpth_lib_exports.dart';
import 'package:path/path.dart' as p;

/// Consolidated interactive service that combines all user interaction functionality
///
/// This service consolidates functionality from:
/// - InteractiveUtilityService (sleep, pressEnter)
/// - UserPromptService (user input, prompts)
/// - InteractiveConfigurationService (validation logic)
/// - FileSelectionService (file/directory selection)
///
/// Provides a clean, single interface for all interactive operations.
class ConsolidatedInteractiveService with LoggerMixin {
  /// Creates a new ConsolidatedInteractiveService
  ConsolidatedInteractiveService({
    required this.globalConfig,
    final InteractivePresenterService? presenter,
  }) : _presenter = presenter ?? InteractivePresenterService(),
       _utility = const FormattingService();

  final GlobalConfigService globalConfig;
  final InteractivePresenterService _presenter;
  final FormattingService _utility;

  // ============================================================================
  // UTILITY OPERATIONS (from InteractiveUtilityService)
  // ============================================================================

  /// Pauses execution for specified number of seconds
  ///
  /// [seconds] Number of seconds to sleep (can be fractional)
  Future<void> sleep(final num seconds) =>
      Future<void>.delayed(Duration(milliseconds: (seconds * 1000).toInt()));

  /// Displays a prompt and waits for user to press enter
  void pressEnterToContinue() {
    _presenter.showPressEnterPrompt();
  }
  // ============================================================================
  // USER INPUT OPERATIONS (from UserPromptService)
  // ============================================================================

  /// Reads user input and normalizes it (removes brackets, lowercase, trim)
  Future<String> readUserInput() async => _presenter.readUserInput();

  /// Asks user how to organize photos by date folders
  ///
  /// Returns:
  /// - 0: One big folder
  /// - 1: Year folders
  /// - 2: Year/month folders
  /// - 3: Year/month/day folders
  Future<int> askDivideDates() async {
    await _presenter.promptForDateDivision();

    while (true) {
      final input = await readUserInput();
      switch (input) {
        case '0':
        case '':
          await _presenter.showUserSelection(input, 'one big folder');
          return 0;
        case '1':
          await _presenter.showUserSelection(input, 'year folders');
          return 1;
        case '2':
          await _presenter.showUserSelection(input, 'year/month folders');
          return 2;
        case '3':
          await _presenter.showUserSelection(input, 'year/month/day folders');
          return 3;
        default:
          await _presenter.showInvalidAnswerError();
          continue;
      }
    }
  }

  /// Asks user about album behavior preference
  ///
  /// Returns the selected album behavior option key
  Future<String> askAlbums() async {
    await _presenter.promptForAlbumBehavior();

    // Present album options to the user (numbering starts at 1).
    int i = 1;
    for (final MapEntry<String, String> entry
        in InteractivePresenterService.albumOptions.entries) {
      _presenter.showAlbumOption(i++, entry.key, entry.value);
    }

    while (true) {
      final input = await readUserInput();
      final int? answer = int.tryParse(input);

      if (answer != null &&
          answer >= 0 &&
          answer <= InteractivePresenterService.albumOptions.length) {
        final int index = (answer == 0) ? 0 : (answer - 1);
        final String choice = InteractivePresenterService.albumOptions.keys
            .elementAt(index);
        final String description =
            InteractivePresenterService.albumOptions[choice]!;
        await _presenter.showUserSelection(input, '$choice: $description');
        return choice;
      }
      await _presenter.showInvalidAnswerError();
    }
  }

  /// Asks if user wants to clean output directory
  Future<bool> askForCleanOutput() async {
    await _presenter.promptForOutputCleanup();

    while (true) {
      final input = await readUserInput();
      switch (input) {
        case '1':
          await _presenter.showUserSelection(
            input,
            'delete all files inside output folder and continue',
          );
          return true;
        case '2':
          await _presenter.showUserSelection(
            input,
            'continue as usual - put output files alongside existing',
          );
          return false;
        case '3':
          await _presenter.showUserSelection(
            input,
            'exit program to examine situation yourself',
          );
          _utility.exitProgram(0);
        default:
          await _presenter.showInvalidAnswerError();
          continue;
      }
    }
  }

  /// Asks if user wants to transform Pixel motion photos
  Future<bool> askTransformPixelMP() async {
    await _presenter.promptForPixelMpTransform();

    while (true) {
      final input = await readUserInput();
      switch (input) {
        case 'y':
        case 'yes':
        case '1':
          await _presenter.showUserSelection(
            input,
            'yes, change extension to .mp4',
          );
          return true;
        case 'n':
        case 'no':
        case '':
        case '2':
          await _presenter.showUserSelection(
            input,
            'no, keep original extension',
          );
          return false;
        default:
          await _presenter.showInvalidAnswerError();
          continue;
      }
    }
  }

  /// Asks if user wants to change file creation time
  Future<bool> askChangeCreationTime() async {
    await _presenter.promptForCreationTimeUpdate();

    while (true) {
      final input = await readUserInput();
      switch (input) {
        case 'y':
        case 'yes':
        case '2':
          await _presenter.showUserSelection(
            input,
            'yes, update creation time to match modified time',
          );
          return true;
        case 'n':
        case 'no':
        case '':
        case '1':
          await _presenter.showUserSelection(
            input,
            'no, don\'t update creation time',
          );
          return false;
        default:
          await _presenter.showInvalidAnswerError();
          continue;
      }
    }
  }

  /// Asks if user wants to write EXIF data
  Future<bool> askIfWriteExif() async {
    await _presenter.promptForExifWriting(globalConfig.exifToolInstalled);

    while (true) {
      final input = await readUserInput();
      switch (input) {
        case '1':
        case '':
          await _presenter.showUserSelection(input, 'yes, write EXIF data');
          return true;
        case '2':
          await _presenter.showUserSelection(
            input,
            'no, don\'t write EXIF data',
          );
          return false;
        default:
          await _presenter.showInvalidAnswerError();
          continue;
      }
    }
  }

  /// Asks if user wants to limit file sizes
  Future<bool> askIfLimitFileSize() async {
    await _presenter.promptForFileSizeLimit();

    while (true) {
      final input = await readUserInput();
      switch (input) {
        case 'y':
          await _presenter.showUserSelection(input, 'yes, limit file sizes');
          return true;
        case 'yes':
          await _presenter.showUserSelection(input, 'yes, limit file sizes');
          return true;
        case '2':
          await _presenter.showUserSelection(input, 'yes, limit file sizes');
          return true;
        case 'n':
          await _presenter.showUserSelection(
            input,
            'no, don\'t limit file sizes',
          );
          return false;
        case 'no':
          await _presenter.showUserSelection(
            input,
            'no, don\'t limit file sizes',
          );
          return false;
        case '':
          await _presenter.showUserSelection(
            input,
            'no, don\'t limit file sizes',
          );
          return false;
        case '1':
          await _presenter.showUserSelection(
            input,
            'no, don\'t limit file sizes',
          );
          return false;
        default:
          await _presenter.showInvalidAnswerError('Invalid answer - try again');
          continue;
      }
    }
  }

  /// Asks about extension fixing mode
  Future<String> askFixExtensions() async {
    await _presenter.promptForExtensionFixing();

    while (true) {
      final input = await readUserInput();
      switch (input) {
        case '1':
        case '':
        case 'standard':
          await _presenter.showUserSelection(input, 'standard (recommended)');
          return 'standard';
        case '2':
        case 'conservative':
          await _presenter.showUserSelection(input, 'conservative');
          return 'conservative';
        case '3':
        case 'solo':
          await _presenter.showUserSelection(input, 'solo');
          return 'solo';
        case '4':
        case 'none':
          await _presenter.showUserSelection(input, 'none');
          return 'none';
        default:
          await _presenter.showInvalidAnswerError();
          continue;
      }
    }
  }

  /// Asks if user wants to unzip files
  Future<bool> askIfUnzip() async {
    await _presenter.promptForDataSource();

    while (true) {
      final input = await readUserInput();

      switch (input) {
        case '1':
        case '':
          await _presenter.showUserSelection(
            input,
            'select ZIP files from Google Takeout',
          );
          return true;
        case '2':
          await _presenter.showUserSelection(
            input,
            'use already extracted folder',
          );
          return false;
        default:
          await _presenter.showInvalidAnswerError(
            'Invalid answer - please type 1 or 2',
          );
          continue;
      }
    }
  }

  /// Prompts for user input with a custom message
  Future<String> promptUser(final String message) async {
    logInfo(message, forcePrint: true);
    return readUserInput();
  }

  /// Asks a yes/no question and returns boolean result
  Future<bool> askYesNo(final String question) async {
    logInfo('$question (y/n)', forcePrint: true);
    while (true) {
      final input = await readUserInput();
      if (input.startsWith('y')) return true;
      if (input.startsWith('n')) return false;
      logWarning('Please enter y or n:', forcePrint: true);
    }
  }

  /// Shows greeting and introduction
  Future<void> showGreeting() async {
    await _presenter.showGreeting();
  }

  /// Shows "nothing found" message
  Future<void> showNothingFoundMessage() async {
    await _presenter.showNothingFoundMessage();
  }

  /// Shows a disk space notice and checks if enough space is available
  ///
  /// [required] Required space in bytes
  /// [dir] Directory to check space for
  Future<void> freeSpaceNotice(final int required, final Directory dir) async {
    final int? freeSpace = await ServiceContainer.instance.diskSpaceService
        .getAvailableSpace(dir.path);

    await _presenter.showDiskSpaceNotice(
      'Required: ${_utility.formatFileSize(required)}, '
      'Directory: ${dir.path}, '
      'Free: ${freeSpace != null ? _utility.formatFileSize(freeSpace) : 'Unknown (unable to check)'}',
    );

    if (freeSpace != null && freeSpace < required) {
      logWarning('⚠️  INSUFFICIENT DISK SPACE WARNING');
      logWarning('Required: ${_utility.formatFileSize(required)}');
      logWarning('Available: ${_utility.formatFileSize(freeSpace)}');
      logWarning('Shortfall: ${_utility.formatFileSize(required - freeSpace)}');
      logWarning('');
      logWarning(
        'Continuing anyway - process may fail during extraction/processing!',
      );
      logWarning(
        'Consider freeing up disk space or choosing a different directory.',
      );
    } else if (freeSpace == null) {
      logWarning('⚠️  DISK SPACE CHECK UNAVAILABLE');
      logWarning('Required space: ${_utility.formatFileSize(required)}');
      logWarning('Directory: ${dir.path}');
      logWarning('');
      logWarning(
        'Unable to check available disk space (common in containers/minimal systems)',
      );
      logWarning(
        'Continuing anyway - please ensure you have sufficient space available.',
      );
    }

    _presenter.showPressEnterPrompt();
  }

  // ============================================================================
  // ZIP EXTRACTION OPERATIONS
  // ============================================================================
  /// Extracts all ZIP files to output directory
  ///
  /// [zipFiles] List of ZIP files to extract
  /// [outputDirectory] Directory to extract to
  Future<Directory> extractAll(
    final List<File> zipFiles,
    final Directory outputDirectory,
  ) async {
    // Delegate to the existing ZIP extraction service for now
    final zipService = ZipExtractionService(presenter: _presenter);
    await zipService.extractAll(zipFiles, outputDirectory);
    return outputDirectory;
  }

  // ============================================================================
  // FILE/DIRECTORY SELECTION (from FileSelectionService)
  // ============================================================================
  /// Prompts user to select input directory using file picker dialog
  Future<Directory> selectInputDirectory() async {
    await _presenter.promptForInputDirectory();
    // _presenter.showPressEnterPrompt();

    try {
      final String? selectedPath = await _showDirectoryPicker(
        'Select Google Photos Takeout folder',
      );

      if (selectedPath == null) {
        throw Exception('No directory selected');
      }

      final directory = Directory(selectedPath);
      final validation = _utility.validateDirectory(directory);

      if (validation.isFailure) {
        throw Exception(validation.message);
      }

      return directory;
    } catch (e) {
      logError('Failed to select input directory: $e');
      rethrow;
    }
  }

  /// Prompts user to select output directory
  Future<Directory> selectOutputDirectory() async {
    await _presenter.promptForOutputDirectory();
    // _presenter.showPressEnterPrompt();

    try {
      final String? selectedPath = await _showDirectoryPicker(
        'Select output folder for organized photos',
      );

      if (selectedPath == null) {
        throw Exception('No directory selected');
      }

      final directory = Directory(selectedPath);

      // Create directory if it doesn't exist
      if (!directory.existsSync()) {
        await directory.create(recursive: true);
      }

      return directory;
    } catch (e) {
      logError('Failed to select output directory: $e');
      rethrow;
    }
  }

  /// Prompts user to select ZIP files for extraction
  Future<List<File>> selectZipFiles() async {
    await _presenter.promptForZipFiles();
    // _presenter.showPressEnterPrompt();

    try {
      final FilePickerResult? filePickerResult = await _showFilesPicker(
        'Select Google Photos Takeout ZIP files',
        allowedExtensions: ['zip'],
      );
      if (filePickerResult == null || filePickerResult.files.isEmpty) {
        await _presenter.showZipSelectionError();
        throw Exception('No ZIP files selected');
      }

      final files = filePickerResult.files
          .map((final PlatformFile e) => File(e.path!))
          .toList();

      // Validate all files exist and are accessible
      for (final file in files) {
        final validation = _utility.validateFile(file);
        if (validation.isFailure) {
          throw Exception('Invalid ZIP file: ${validation.message}');
        }
      }

      // Show appropriate user feedback based on file count
      final totalSize = files.fold<int>(
        0,
        (final sum, final file) => sum + file.lengthSync(),
      );

      if (files.length == 1) {
        await _presenter.showSingleZipWarning();
      }

      await _presenter.showZipSelectionSuccess(
        files.length,
        _utility.formatFileSize(totalSize),
      );

      return files;
    } catch (e) {
      logError('Failed to select ZIP files: $e');
      rethrow;
    }
  }

  /// Prompts user to select extraction directory for ZIP files
  Future<Directory> selectExtractionDirectory() async {
    await _presenter.promptForExtractionDirectory();
    // _presenter.showPressEnterPrompt();

    try {
      final String? selectedPath = await _showDirectoryPicker(
        'Select the folder to extract the ZIP files to',
      );

      if (selectedPath == null) {
        throw Exception('No directory selected');
      }

      final directory = Directory(selectedPath);

      // Create directory if it doesn't exist
      if (!directory.existsSync()) {
        await directory.create(recursive: true);
      }

      return directory;
    } catch (e) {
      logError('Failed to select extraction directory: $e');
      rethrow;
    }
  }

  // ============================================================================
  // CONFIGURATION BUILDING (from InteractiveConfigurationService)
  // ============================================================================
  /// Creates processing configuration from user choices
  ProcessingConfig createProcessingConfig({
    required final String inputPath,
    required final String outputPath,
    required final DateDivisionLevel dateDivision,
    required final AlbumBehavior albumBehavior,
    required final bool transformPixelMp,
    required final bool updateCreationTime,
    required final bool writeExif,
    required final bool limitFileSize,
    required final ExtensionFixingMode extensionFixing,
    final bool verbose = false,
    final bool skipExtras = false,
    final bool guessFromName = true,
    final bool keepInput =
        false, // mantiene el input intacto con copia temporal
    final bool keepDuplicates =
        false, // NUEVO: coherente con la pregunta interactiva
  }) => ProcessingConfig(
    inputPath: inputPath,
    outputPath: outputPath,
    dateDivision: dateDivision,
    albumBehavior: albumBehavior,
    transformPixelMp: transformPixelMp,
    updateCreationTime: updateCreationTime,
    writeExif: writeExif,
    limitFileSize: limitFileSize,
    extensionFixing: extensionFixing,
    verbose: verbose,
    skipExtras: skipExtras,
    guessFromName: guessFromName,
    keepInput: keepInput,
    keepDuplicates: keepDuplicates,
  );

  /// Validates input directory for processing
  FormattingValidationResult validateInputDirectory(final String path) {
    final directory = Directory(path);

    if (!directory.existsSync()) {
      return FormattingValidationResult.failure(
        'Input directory does not exist: $path',
      );
    }

    // Check if directory contains Google Photos takeout structure
    final hasPhotosFolder = Directory('$path/Google Photos').existsSync();
    final hasPhotosFolders = directory.listSync().whereType<Directory>().any(
      (final dir) => RegExp(
        '(${TakeoutFolderClassifierService.photosFromPattern})',
      ).hasMatch(p.basename(dir.path)),
    );

    if (!hasPhotosFolder && !hasPhotosFolders) {
      return const FormattingValidationResult.failure(
        'Directory does not appear to contain Google Photos takeout data',
      );
    }

    return const FormattingValidationResult.success();
  }

  /// Validates output directory for processing
  FormattingValidationResult validateOutputDirectory(final String path) {
    final directory = Directory(path);

    // Create directory if it doesn't exist
    if (!directory.existsSync()) {
      try {
        directory.createSync(recursive: true);
        return const FormattingValidationResult.success();
      } catch (e) {
        return FormattingValidationResult.failure(
          'Cannot create output directory: $e',
        );
      }
    }

    return const FormattingValidationResult.success();
  }

  // ============================================================================
  // PROCESSING SUMMARY DISPLAY OPERATIONS
  // ============================================================================

  /// Displays a summary of warnings and errors encountered during processing
  Future<void> showWarningsAndErrorsSummary(
    final List<StepResult> stepResults,
  ) async {
    await _presenter.showWarningsAndErrorsSummary(stepResults);
  }

  /// Displays detailed results for each processing step
  Future<void> showStepResults(
    final List<StepResult> stepResults,
    final Map<String, Duration> stepTimings,
  ) async {
    await _presenter.showStepResults(stepResults, stepTimings);
  }

  /// Displays a processing summary header and statistics
  Future<void> showProcessingSummary({
    required final Duration totalTime,
    required final int successfulSteps,
    required final int failedSteps,
    required final int skippedSteps,
    required final int mediaCount,
  }) async {
    await _presenter.showProcessingSummary(
      totalTime: totalTime,
      successfulSteps: successfulSteps,
      failedSteps: failedSteps,
      skippedSteps: skippedSteps,
      mediaCount: mediaCount,
    );
  }

  // ============================================================================
  // NEW: KEEP-INPUT INTERACTIVE QUESTION
  // ============================================================================
  /// Asks if the user wants to keep the original input folder untouched by
  /// working on a temporary sibling copy named "<input>_tmp".
  ///
  /// Returns:
  /// - true  -> work on a cloned "<input>_tmp" directory
  /// - false -> work directly on the original input directory
  Future<bool> askKeepInput() async {
    // Keeping style consistent with other prompts: we print here directly,
    // then reuse presenter helpers for selection/validation feedback.
    print(
      'Do you want to keep your original --input folder untouched by working on a temporary sibling copy (suffix _tmp)?',
    );
    print('[1] (Default) - No, work directly on the original input');
    print('[2] - Yes, create and use "<input>_tmp" as the working directory');
    print('(Type 1 or 2, or press enter for default):');

    while (true) {
      final input = await readUserInput();
      switch (input) {
        case '':
        case '1':
        case 'n':
        case 'no':
          await _presenter.showUserSelection(
            input,
            'work directly on the original input folder',
          );
          return false;
        case '2':
        case 'y':
        case 'yes':
          await _presenter.showUserSelection(
            input,
            'use a temporary sibling copy "<input>_tmp"',
          );
          return true;
        default:
          await _presenter.showInvalidAnswerError();
          continue;
      }
    }
  }

  // ============================================================================
  // NEW: KEEP-DUPLICATES INTERACTIVE QUESTION
  // ============================================================================
  /// Asks if the user wants to keep duplicates files in the output folder
  ///
  /// Returns:
  /// - true  -> Duplicates will be move to "_Duplicates" directory within output directory.
  /// - false -> Duplicates will be removed totally
  Future<bool> askKeepDuplicates() async {
    print(
      'Do you want to keep duplicates files in `_Duplicates` subfolder within output folder?',
    );
    print('[1] (Default) - No, you can remove all duplicates found');
    print(
      '[2] - Yes, create a `_Duplicates` subfolder within output folder (slower)',
    );
    print('(Type 1 or 2, or press enter for default):');

    while (true) {
      final input = await readUserInput();
      switch (input) {
        case '':
        case '1':
        case 'n':
        case 'no':
          await _presenter.showUserSelection(
            input,
            'remove all duplicates found',
          );
          return false;
        case '2':
        case 'y':
        case 'yes':
          await _presenter.showUserSelection(
            input,
            'create a `_Duplicates` subfolder within output folder (slower)',
          );
          return true;
        default:
          await _presenter.showInvalidAnswerError();
          continue;
      }
    }
  }

  // ============================================================================
  // PRIVATE HELPER METHODS
  // ============================================================================

  /// Shows platform-specific directory picker dialog
  Future<String?> _showDirectoryPicker(final String title) async =>
      getDirectoryPath(dialogTitle: title);

  /// Shows platform-specific file picker dialog
  Future<FilePickerResult?> _showFilesPicker(
    final String title, {
    final List<String>? allowedExtensions,
  }) async => pickFiles(
    dialogTitle: title,
    type: FileType.custom,
    allowedExtensions: allowedExtensions,
    allowMultiple: true,
  );
}

/// Extension methods for enum conversion
extension AlbumBehaviorExtension on AlbumBehavior {
  // ignore: prefer_expression_function_bodies
  static AlbumBehavior fromString(final String value) {
    // We delegate to the enum's own method to maintain a single source of truth.
    return AlbumBehavior.fromString(value);
  }
}

extension ExtensionFixingModeExtension on ExtensionFixingMode {
  static ExtensionFixingMode fromString(final String value) {
    switch (value.toLowerCase()) {
      case 'none':
        return ExtensionFixingMode.none;
      case 'standard':
        return ExtensionFixingMode.standard;
      case 'conservative':
        return ExtensionFixingMode.conservative;
      case 'solo':
        return ExtensionFixingMode.solo;
      default:
        throw ArgumentError('Unknown extension fixing mode: $value');
    }
  }
}
