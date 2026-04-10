import 'dart:io';
import 'package:gpth_neo/gpth_lib_exports.dart';

/// Domain service for handling interactive configuration logic
///
/// This service contains the business logic for configuring the processing
/// pipeline based on user choices, without any UI concerns.
///
/// NOTE: File size formatting has been moved to ConsolidatedUtilityService.
class InteractiveConfigurationService {
  /// Creates processing configuration from user choices
  ///
  /// This method encapsulates all the business logic for converting
  /// user selections into a proper ProcessingConfig object.
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
    isInteractiveMode: true,
  );

  /// Validates input directory and returns validation result
  InteractiveValidationResult validateInputDirectory(final String path) {
    final directory = Directory(path);

    if (!directory.existsSync()) {
      return InteractiveValidationResult.failure(
        'Directory does not exist: $path',
      );
    }

    final takeoutDir = Directory('$path/Takeout');
    if (!takeoutDir.existsSync()) {
      return InteractiveValidationResult.failure(
        'No "Takeout" folder found in $path. '
        'Make sure you\'ve extracted your Google Photos Takeout ZIP files '
        'and merged them into a single "Takeout" folder.',
      );
    }

    return InteractiveValidationResult.success();
  }

  /// Validates output directory and returns validation result
  InteractiveValidationResult validateOutputDirectory(final String path) {
    final directory = Directory(path);

    // Create directory if it doesn't exist
    if (!directory.existsSync()) {
      try {
        directory.createSync(recursive: true);
        return InteractiveValidationResult.success();
      } catch (e) {
        return InteractiveValidationResult.failure(
          'Cannot create output directory: $e',
        );
      }
    }

    return InteractiveValidationResult.success();
  }

  /// Checks if output directory is empty and returns appropriate action
  OutputDirectoryStatus checkOutputDirectoryStatus(final String path) {
    final directory = Directory(path);

    if (!directory.existsSync()) {
      return OutputDirectoryStatus.empty;
    }

    final contents = directory.listSync();
    if (contents.isEmpty) {
      return OutputDirectoryStatus.empty;
    }

    return OutputDirectoryStatus.notEmpty;
  }

  /// Validates ZIP files for processing
  InteractiveValidationResult validateZipFiles(final List<File> zipFiles) {
    if (zipFiles.isEmpty) {
      return InteractiveValidationResult.failure('No ZIP files selected');
    }

    for (final zip in zipFiles) {
      if (!zip.existsSync()) {
        return InteractiveValidationResult.failure(
          'ZIP file does not exist: ${zip.path}',
        );
      }

      if (zip.lengthSync() == 0) {
        return InteractiveValidationResult.failure(
          'ZIP file is empty: ${zip.path}',
        );
      }
    }

    return InteractiveValidationResult.success();
  }

  /// Calculates required disk space for processing
  DiskSpaceRequirement calculateDiskSpaceRequirement({
    required final List<File> zipFiles,
    required final AlbumBehavior albumBehavior,
  }) {
    int totalZipSize = 0;
    for (final zip in zipFiles) {
      totalZipSize += zip.lengthSync();
    }

    // Estimate extraction space (typically 1.2x compressed size)
    final extractionSpace = safeRoundToInt(
      totalZipSize * 1.2,
    ); // Estimate output space based on album behavior
    double outputMultiplier;
    switch (albumBehavior) {
      case AlbumBehavior.shortcut:
      case AlbumBehavior.reverseShortcut:
      case AlbumBehavior.json:
      case AlbumBehavior.nothing:
      case AlbumBehavior.ignoreAlbums:
        outputMultiplier = 0.0; // Move mode - no extra space needed
        break;
      case AlbumBehavior.duplicateCopy:
        outputMultiplier = 2.0; // Albums duplicate files
        break;
    }

    final outputSpace = safeRoundToInt(extractionSpace * outputMultiplier);
    final totalRequired = extractionSpace + outputSpace;

    return DiskSpaceRequirement(
      extractionSpace: extractionSpace,
      outputSpace: outputSpace,
      totalRequired: totalRequired,
    );
  }
}

/// Result of a validation operation
class InteractiveValidationResult {
  const InteractiveValidationResult._({
    required this.isValid,
    this.errorMessage,
  });

  factory InteractiveValidationResult.success() =>
      const InteractiveValidationResult._(isValid: true);

  factory InteractiveValidationResult.failure(final String message) =>
      InteractiveValidationResult._(isValid: false, errorMessage: message);

  final bool isValid;
  final String? errorMessage;

  bool get isFailure => !isValid;
}

/// Status of output directory
enum OutputDirectoryStatus { empty, notEmpty }

/// Disk space requirement calculation
class DiskSpaceRequirement {
  const DiskSpaceRequirement({
    required this.extractionSpace,
    required this.outputSpace,
    required this.totalRequired,
  });

  final int extractionSpace;
  final int outputSpace;
  final int totalRequired;

  static const _utility = FormattingService();

  /// Human-readable total required space
  String get totalRequiredFormatted => _utility.formatFileSize(totalRequired);

  /// Human-readable extraction space
  String get extractionSpaceFormatted =>
      _utility.formatFileSize(extractionSpace);

  /// Human-readable output space
  String get outputSpaceFormatted => _utility.formatFileSize(outputSpace);
}
