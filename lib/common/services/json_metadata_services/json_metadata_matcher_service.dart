import 'dart:io';

import 'package:collection/collection.dart';
import 'package:gpth_neo/gpth_lib_exports.dart';
import 'package:path/path.dart' as path;
import 'package:unorm_dart/unorm_dart.dart' as unorm;

/// Service for finding corresponding JSON metadata files for media files
///
/// Implements multiple strategies to locate JSON files, handling various
/// edge cases from Google Photos Takeout exports including filename
/// truncation, bracket swapping, and extra format removal.
///
/// Strategies are ordered from least to most aggressive to minimize
/// false matches while maximizing success rate.
class JsonMetadataMatcherService with LoggerMixin {
  /// EditedVersionDetectorService instance for handling extra format operations
  static const EditedVersionDetectorService _extrasService =
      EditedVersionDetectorService();

  /// Attempts to find the corresponding JSON file for a media file
  ///
  /// Tries multiple strategies to locate JSON files, including handling
  /// filename truncation, bracket swapping, and extra format removal.
  /// Strategies are ordered from least to most aggressive (issue #29).
  ///
  /// [file] Media file to find JSON for
  /// [tryhard] If true, uses more aggressive matching strategies
  /// Returns the JSON file if found, null otherwise
  static Future<File?> findJsonForFile(
    final File file, {
    required final bool tryhard,
  }) async {
    final Directory dir = Directory(
      PathResolverService.normalizePath(path.dirname(file.path)),
    );
    final String name = path.basename(file.path);

    // Get strategies based on tryhard setting
    final strategies = tryhard
        ? [..._basicStrategies, ..._aggressiveStrategies]
        : _basicStrategies; // Try each strategy in order of increasing aggressiveness
    for (final strategy in strategies) {
      final String processedName = strategy.transform(name);

      // Try supplemental-metadata format first — this is the format produced
      // by all current Google Takeout exports.  Standard .json is checked
      // afterwards as a backward-compatibility fallback for older exports.
      // The two formats never coexist for the same file, so whichever is
      // found first is the correct and only sidecar.
      final String fullSupplementalPath =
          '$processedName.supplemental-metadata.json';

      final File supplementalJsonFile = File(
        path.join(dir.path, fullSupplementalPath),
      );
      if (await supplementalJsonFile.exists()) {
        return supplementalJsonFile;
      }

      // If the full name would exceed 51, try truncated variants
      if (fullSupplementalPath.length > 51) {
        final List<String> truncatedSuffixes =
            _generateTruncatedSupplementalSuffixes(
              processedName,
              maxLength: 51,
            );

        for (final suffix in truncatedSuffixes) {
          final File truncatedFile = File(
            path.join(dir.path, '$processedName.$suffix'),
          );
          if (await truncatedFile.exists()) return truncatedFile;
        }
      }

      // Try numbered supplemental-metadata files for extension fixing scenarios
      final File? numberedSupplementalFile = await _tryNumberedJsonFiles(
        dir,
        processedName,
        name,
        '.supplemental-metadata.json',
      );
      if (numberedSupplementalFile != null) {
        return numberedSupplementalFile;
      }

      // Backward-compat fallback: older Takeout exports used plain .json
      final File jsonFile = File(path.join(dir.path, '$processedName.json'));
      if (await jsonFile.exists()) return jsonFile;

      // Try numbered standard JSON files
      final File? numberedJsonFile = await _tryNumberedJsonFiles(
        dir,
        processedName,
        name,
        '.json',
      );
      if (numberedJsonFile != null) {
        return numberedJsonFile;
      }
    }
    return null;
  }

  /// Attempts to find numbered duplicate JSON files for extension fixing scenarios
  ///
  /// This handles cases where extension fixing creates files like IMG_2367(1).HEIC.jpg
  /// that should match JSON files like:
  /// - IMG_2367.HEIC.supplemental-metadata(1).json (number at end)
  /// - IMG_2367.HEIC(1).supplemental-metadata.json (number in middle)
  ///
  /// [dir] Directory to search in
  /// [processedName] The processed filename from the strategy
  /// [originalName] The original media filename
  /// [jsonSuffix] The JSON file suffix (.json or .supplemental-metadata.json)
  static Future<File?> _tryNumberedJsonFiles(
    final Directory dir,
    final String processedName,
    final String originalName,
    final String jsonSuffix,
  ) async {
    // Extract the duplicate marker — the last (N) immediately before the file
    // extension.  For "Käfersteige (10)(1).jpg" the extension is ".jpg" and the
    // last (N) before it is "(1)".  Using the *last* match avoids confusing a
    // content-identifier like "(10)" with the OS-appended duplicate suffix.
    final String ext = path.extension(originalName); // e.g. ".jpg"
    final String stem = ext.isNotEmpty
        ? originalName.substring(0, originalName.length - ext.length)
        : originalName;

    final RegExp numberPattern = RegExp(r'\((\d+)\)');
    final Iterable<RegExpMatch> allMatches = numberPattern.allMatches(stem);
    if (allMatches.isEmpty) return null;

    // Pick the last match in the stem — that is the duplicate marker.
    final RegExpMatch lastMatch = allMatches.last;
    final String number = lastMatch.group(1)!;

    // Build baseName by removing ONLY the last (N) from processedName's stem,
    // preserving any earlier (N) that are part of the real filename.
    final String processedExt = path.extension(processedName);
    final String processedStem = processedExt.isNotEmpty
        ? processedName.substring(0, processedName.length - processedExt.length)
        : processedName;

    final Iterable<RegExpMatch> processedMatches = numberPattern.allMatches(
      processedStem,
    );
    String baseStem;
    if (processedMatches.isNotEmpty) {
      final RegExpMatch lastProcessedMatch = processedMatches.last;
      baseStem =
          processedStem.substring(0, lastProcessedMatch.start) +
          processedStem.substring(lastProcessedMatch.end);
    } else {
      baseStem = processedStem;
    }
    final String baseName = '$baseStem$processedExt';

    // Pattern 1: Try numbered suffix at end - basename.suffix(number).json
    final File numberedJsonFile = File(
      path.join(
        dir.path,
        '$baseName$jsonSuffix'.replaceAll('.json', '($number).json'),
      ),
    );

    if (await numberedJsonFile.exists()) {
      return numberedJsonFile;
    }

    // Pattern 2: Try numbered suffix in middle - basename(number).suffix.json
    if (jsonSuffix == '.supplemental-metadata.json') {
      final File numberedMiddleJsonFile = File(
        path.join(dir.path, '$baseName($number).supplemental-metadata.json'),
      );

      if (await numberedMiddleJsonFile.exists()) {
        return numberedMiddleJsonFile;
      }
    }

    return null;
  }

  /// Basic strategies (always applied) - ordered from least to most aggressive
  static final List<JsonMatchingStrategy> _basicStrategies = [
    // Strategy 1: No modification (most conservative)
    JsonMatchingStrategy(
      name: 'No modification',
      description: 'Direct filename match without any transformation',
      transform: (final filename) => filename,
    ),

    // Strategy 2: Filename shortening (conservative, addresses filesystem limits)
    const JsonMatchingStrategy(
      name: 'Filename shortening',
      description: 'Handles filename truncation due to filesystem limits',
      transform: _shortenName,
    ),

    // Strategy 3: Bracket number swapping (conservative, known pattern)
    const JsonMatchingStrategy(
      name: 'Bracket number swapping',
      description: 'Swaps bracket position for files like "image(11).jpg"',
      transform: _bracketSwap,
    ),

    // Strategy 4: Remove file extension (moderate, handles Google's extension addition)
    const JsonMatchingStrategy(
      name: 'Remove file extension',
      description: 'Removes extension for cases where Google added one',
      transform: _noExtension,
    ),

    // Strategy 5: Remove known complete extra formats (moderate, safe list)
    const JsonMatchingStrategy(
      name: 'Remove complete extra formats',
      description: 'Removes known editing suffixes like "-edited"',
      transform: _removeExtraComplete,
    ),

    // Strategy 6: Handle MP files by looking for their MP.jpg JSON files
    const JsonMatchingStrategy(
      name: 'MP file JSON matching',
      description: 'Handles MP files by looking for their MP.jpg JSON files',
      transform: _handleMPFiles,
    ),
  ];

  /// Aggressive strategies (only with tryhard=true) - ordered from least to most aggressive
  static final List<JsonMatchingStrategy> _aggressiveStrategies = [
    // Strategy 7: Cross-extension matching (moderate, handles shared JSON files)
    const JsonMatchingStrategy(
      name: 'Cross-extension matching',
      description:
          'Matches MP4 files with HEIC JSON files and similar cross-format scenarios',
      transform: _crossExtensionMatching,
    ),

    // Strategy 8: Remove partial extra formats (moderate to aggressive, truncation handling)
    const JsonMatchingStrategy(
      name: 'Remove partial extra formats',
      description: 'Removes truncated editing suffixes like "-ed"',
      transform: _removeExtraPartial,
    ),

    // Strategy 9: Extension restoration after partial removal (aggressive, reconstruction)
    const JsonMatchingStrategy(
      name: 'Extension restoration after partial removal',
      description: 'Combines partial removal with extension restoration',
      transform: _removeExtraPartialWithExtensionRestore,
    ),

    // Strategy 10: Edge case pattern removal (very aggressive, heuristic-based)
    const JsonMatchingStrategy(
      name: 'Edge case pattern removal',
      description: 'Heuristic-based removal of edge case patterns',
      transform: _removeExtraEdgeCase,
    ),

    // Strategy 11: Remove digit patterns (most aggressive, broad pattern matching)
    //const JsonMatchingStrategy(
    //  name: 'Remove digit patterns',
    //  description: 'Removes digit patterns like "(1)" from filenames',
    //  transform: _removeDigit,
    //),
    //Not doing this anymore because it only caused problems but leaving it here just in case.
  ];

  /// Gets all available strategies for debugging/testing purposes
  static List<JsonMatchingStrategy> getAllStrategies({
    required final bool includeAggressive,
  }) => includeAggressive
      ? [..._basicStrategies, ..._aggressiveStrategies]
      : _basicStrategies;

  /// Generates all possible truncations of supplemental-metadata.json
  /// that would fit within the maxLength constraint
  static List<String> _generateTruncatedSupplementalSuffixes(
    final String baseName, {
    required final int maxLength,
  }) {
    final List<String> suffixes = [];
    // Fix: use the suffix without '.json' and append a single '.json' later
    const String fullSuffix = 'supplemental-metadata';
    final int baseLength = baseName.length + 1; // +1 for the dot
    final int maxSuffixLength = maxLength - baseLength;

    // Try progressively shorter versions of the suffix (longest first)
    for (int i = fullSuffix.length; i > 0; i--) {
      final String candidateCore = fullSuffix.substring(0, i);
      final String truncatedSuffix = '$candidateCore.json';
      if (truncatedSuffix.length <= maxSuffixLength) {
        suffixes.add(truncatedSuffix);
      }
    }
    return suffixes;
  }

  /// Removes partial extra format suffixes for truncated cases
  ///
  /// Handles cases where filename truncation results in partial suffix matches.
  /// Only removes partial matches of known extra formats from extraFormats list.
  static String _removeExtraPartial(final String filename) =>
      _extrasService.removePartialExtraFormats(filename);

  /// Removes partial extra formats and restores truncated extensions
  ///
  /// Combines partial suffix removal with extension restoration for cases
  /// where both the suffix and extension were truncated due to filename limits.
  static String _removeExtraPartialWithExtensionRestore(final String filename) {
    final String originalExt = path.extension(filename);
    final String cleanedFilename = _extrasService.removePartialExtraFormats(
      filename,
    );

    if (cleanedFilename != filename) {
      _logDebug(
        '$filename was renamed to $cleanedFilename by the removePartialExtraFormats function.',
      );

      // Try to restore truncated extension
      final String restoredFilename = _extrasService.restoreFileExtension(
        cleanedFilename,
        originalExt,
      );

      if (restoredFilename != cleanedFilename) {
        _logDebug(
          'Extension restored from ${path.extension(cleanedFilename)} to ${path.extension(restoredFilename)} for file: $restoredFilename',
        );
        return restoredFilename;
      }

      return cleanedFilename;
    }

    return filename;
  }

  /// Uses heuristic-based pattern matching for missed truncated suffixes.
  static String _removeExtraEdgeCase(final String filename) {
    final String? result = _extrasService.removeEdgeCaseExtraFormats(filename);
    if (result != null) {
      _logDebug(
        'Truncated suffix detected and removed by edge case handling: $filename -> $result',
      );
      return result;
    }
    return filename;
  }

  /// Handles MP files by looking for their MP.jpg JSON files
  ///
  /// For Pixel Motion Photos, the JSON file is often named after the MP.jpg version
  /// rather than the MP version. This function handles that case.
  static String _handleMPFiles(final String filename) {
    final String ext = path.extension(filename).toLowerCase();
    if (ext == '.mp') {
      final String nameWithoutExt = path.basenameWithoutExtension(filename);
      return '$nameWithoutExt.MP.jpg';
    }
    return filename;
  }

  /// Static debug logging for file transformation details
  ///
  /// Uses the global configuration to determine if verbose logging is enabled.
  /// These messages help debug JSON matching issues when verbose mode is active.
  static void _logDebug(final String message) {
    // Access global verbose setting and log accordingly
    if (ServiceContainer.instance.globalConfig.isVerbose) {
      // Use static logging since this is a static method
      final service = JsonMetadataMatcherService();
      service.logDebug(message);
    }
  }
}

/// Represents a single JSON file matching strategy
class JsonMatchingStrategy {
  const JsonMatchingStrategy({
    required this.name,
    required this.description,
    required this.transform,
  });

  /// Human-readable name of the strategy
  final String name;

  /// Description of what this strategy does
  final String description;

  /// Function that transforms the filename
  final String Function(String filename) transform;
}

// Strategy Implementation Functions

/// Shortens filename to handle filesystem length limits
///
/// This resolves years of bugs and head-scratches 😆
/// e.g: https://github.com/TheLastGimbus/GooglePhotosTakeoutHelper/issues/8#issuecomment-736539592
String _shortenName(final String filename) => '$filename.json'.length > 51
    ? filename.substring(0, 51 - '.json'.length)
    : filename;

/// Handles bracket number swapping in filenames
///
/// Thanks @casualsailo and @denouche for bringing attention!
/// https://github.com/TheLastGimbus/GooglePhotosTakeoutHelper/issues/188
/// and https://github.com/TheLastGimbus/GooglePhotosTakeoutHelper/issues/175
///
/// Some files have patterns like "image(11).jpg" with JSON "image.jpg(11).json"
/// This function swaps the bracket position to match.
String _bracketSwap(final String filename) {
  // this is with the dot - more probable that it's just before the extension
  final RegExpMatch? match = RegExp(
    r'\(\d+\)\.',
  ).allMatches(filename).lastOrNull;
  if (match == null) return filename;
  final String bracket = match.group(0)!.replaceAll('.', ''); // remove dot
  // remove only last to avoid errors with filenames like:
  // 'image(3).(2)(3).jpg' <- "(3)." repeats twice
  final String withoutBracket = filename.replaceLast(bracket, '');
  return '$withoutBracket$bracket';
}

/// Removes file extension from filename
///
/// Handles cases where original file had no extension but Google added one.
String _noExtension(final String filename) =>
    path.basenameWithoutExtension(File(filename).path);

/// Handles cross-extension matching for shared JSON files
///
/// This handles cases where MP4 files share JSON metadata files with HEIC files.
/// For example: IMG_2367.MP4 should match IMG_2367.HEIC.supplemental-metadata.json
/// Common patterns: MP4 ↔ HEIC, JPG ↔ HEIC, etc.
String _crossExtensionMatching(final String filename) {
  final String ext = path.extension(filename).toLowerCase();
  final String nameWithoutExt = path.basenameWithoutExtension(filename);

  // Map of cross-extension patterns (source → target)
  // Use uppercase to match typical Google Photos naming
  const Map<String, List<String>> crossExtensions = {
    '.mp4': ['.HEIC', '.HEIF'],
    '.mov': ['.HEIC', '.HEIF'],
    '.jpg': ['.HEIC', '.HEIF'],
    '.jpeg': ['.HEIC', '.HEIF'],
    '.mp': ['.HEIC', '.HEIF'],
    '.mv': ['.HEIC', '.HEIF'],
  };

  // If current extension has cross-extension patterns, try the first alternative
  if (crossExtensions.containsKey(ext) && crossExtensions[ext]!.isNotEmpty) {
    final String alternativeExt = crossExtensions[ext]!.first;
    return '$nameWithoutExt$alternativeExt';
  }

  return filename;
}

/// Removes "extra" format suffixes safely using predefined list
///
/// Only removes suffixes from the known safe list in extraFormats.
/// This is the safe, conservative approach that only matches known formats.
/// Handles Unicode normalization for cross-platform compatibility.
String _removeExtraComplete(final String filename) {
  // MacOS uses NFD that doesn't work with our accents 🙃🙃
  // https://github.com/TheLastGimbus/GooglePhotosTakeoutHelper/pull/247
  final String normalizedFilename = unorm.nfc(filename);
  final String ext = path.extension(normalizedFilename);
  final String nameWithoutExt = path.basenameWithoutExtension(
    normalizedFilename,
  );

  for (final String extra in extraFormats) {
    // Check for exact suffix match with optional digit pattern
    final RegExp exactPattern = RegExp(
      RegExp.escape(extra) + r'(\(\d+\))?$',
      caseSensitive: false,
    );

    if (exactPattern.hasMatch(nameWithoutExt)) {
      final String cleanedName = nameWithoutExt.replaceAll(exactPattern, '');
      return cleanedName + ext;
    }
  }
  return normalizedFilename;
}
