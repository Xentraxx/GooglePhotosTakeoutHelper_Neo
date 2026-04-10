import 'dart:convert';
import 'dart:io';

import 'package:console_bars/console_bars.dart';
import 'package:gpth_neo/gpth_lib_exports.dart';
import 'package:path/path.dart' as path;

/// Service for fixing truncated filenames using the JSON metadata 'title' field.
///
/// Google Photos Takeout sometimes truncates long filenames (typically to ~47 characters
/// for the base name when combined with ".json" suffix to stay under filesystem limits).
/// This service detects such cases by comparing the actual filename (without extension)
/// to the 'title' field in the associated JSON metadata file and renames the file
/// to restore the original filename.
///
/// ## How it works
/// 1. For each media file in the collection, finds its corresponding JSON metadata file
/// 2. Reads the 'title' field from the JSON (contains original filename, possibly with extension)
/// 3. Compares the current filename (without extension) to the title
/// 4. If different (truncated), renames both the media file and JSON file to use the full title
/// 5. Updates the FileEntity.sourcePath to reflect the new filename
///
/// ## When to use
/// This service should be called AFTER date extraction (Step 4) because:
/// - JSON matching has already been established and proven to work
/// - We can leverage the same tryhard logic used for date extraction
/// - Files haven't been moved yet (Step 6)
///
/// ## Safety Features
/// - Only renames if the current filename is a prefix of the JSON title (confirms truncation)
/// - Preserves the current file extension (which may have been fixed by extension fixing step)
/// - Handles special characters and Unicode properly
/// - Performs atomic rename with rollback on failure
/// - Updates MediaEntity paths so subsequent steps use correct paths
class TruncatedFilenameFixerService with LoggerMixin {
  const TruncatedFilenameFixerService();

  /// Fixes truncated filenames in the media collection by restoring names from JSON metadata.
  ///
  /// [context] The processing context containing the media collection
  ///
  /// Returns a summary with the number of files fixed
  Future<TruncatedFilenameFixerSummary> fixTruncatedFilenames(
    final ProcessingContext context,
  ) async {
    final collection = context.mediaCollection;
    int fixedCount = 0;
    int checkedCount = 0;
    int skippedNoJson = 0;
    int skippedNoTitle = 0;
    int skippedNotTruncated = 0;
    int skippedTargetExists = 0;
    int failedRename = 0;

    logPrint('[Step 4/8] Checking for truncated filenames...');

    // Initialize progress bar
    final total = collection.length;
    final FillingBar? bar = (total > 0)
        ? FillingBar(
            total: total,
            width: 50,
            percentage: true,
            desc: '[ INFO  ] [Step 4/8] Checking truncated names',
          )
        : null;

    int done = 0;

    for (int i = 0; i < collection.length; i++) {
      final media = collection.asList()[i];

      // Process primary file
      final primaryResult = await _processFileEntity(
        media.primaryFile,
        tryhard: true,
      );

      checkedCount++;

      if (primaryResult.status == _ProcessStatus.fixed) {
        fixedCount++;
      } else if (primaryResult.status == _ProcessStatus.noJson) {
        skippedNoJson++;
      } else if (primaryResult.status == _ProcessStatus.noTitle) {
        skippedNoTitle++;
      } else if (primaryResult.status == _ProcessStatus.notTruncated) {
        skippedNotTruncated++;
      } else if (primaryResult.status == _ProcessStatus.targetExists) {
        skippedTargetExists++;
      } else if (primaryResult.status == _ProcessStatus.renameFailed) {
        failedRename++;
      }

      // Process secondary files
      for (final secondary in media.secondaryFiles) {
        final secondaryResult = await _processFileEntity(
          secondary,
          tryhard: true,
        );

        checkedCount++;

        if (secondaryResult.status == _ProcessStatus.fixed) {
          fixedCount++;
        }
      }

      // Update progress bar
      if (bar != null) {
        done++;
        if ((done % 100) == 0 || done == total) {
          bar.update(done);
        }
      }
    }

    // Ensure next logs start on a new line after the bar
    if (bar != null) stdout.writeln();

    if (fixedCount > 0) {
      logPrint('[Step 4/8] Fixed $fixedCount truncated filename(s)');
    } else {
      logPrint('[Step 4/8] No truncated filenames found');
    }

    if (context.config.verbose) {
      logDebug(
        '[Step 4/8] Truncated filename check details:',
        forcePrint: true,
      );
      logDebug('[Step 4/8]   - Files checked: $checkedCount', forcePrint: true);
      logDebug('[Step 4/8]   - Fixed: $fixedCount', forcePrint: true);
      logDebug(
        '[Step 4/8]   - No JSON found: $skippedNoJson',
        forcePrint: true,
      );
      logDebug(
        '[Step 4/8]   - No title in JSON: $skippedNoTitle',
        forcePrint: true,
      );
      logDebug(
        '[Step 4/8]   - Not truncated: $skippedNotTruncated',
        forcePrint: true,
      );
      logDebug(
        '[Step 4/8]   - Target exists: $skippedTargetExists',
        forcePrint: true,
      );
      logDebug('[Step 4/8]   - Rename failed: $failedRename', forcePrint: true);
    }

    return TruncatedFilenameFixerSummary(
      fixedCount: fixedCount,
      checkedCount: checkedCount,
      skippedNoJson: skippedNoJson,
      skippedNoTitle: skippedNoTitle,
      skippedNotTruncated: skippedNotTruncated,
      skippedTargetExists: skippedTargetExists,
      failedRename: failedRename,
    );
  }

  /// Processes a single FileEntity to check if filename truncation fix is needed.
  ///
  /// Returns the processing result with status and new path if renamed.
  Future<_ProcessResult> _processFileEntity(
    final FileEntity fileEntity, {
    required final bool tryhard,
  }) async {
    final file = fileEntity.asFile();

    // Find associated JSON file using the established matching logic
    final File? jsonFile = await JsonMetadataMatcherService.findJsonForFile(
      file,
      tryhard: tryhard,
    );

    if (jsonFile == null) {
      return const _ProcessResult(_ProcessStatus.noJson);
    }

    // Read JSON and extract title
    String? title;
    try {
      final String jsonContent = await jsonFile.readAsString();
      final dynamic data = jsonDecode(jsonContent);
      if (data is Map<String, dynamic> && data.containsKey('title')) {
        title = data['title'] as String?;
      }
    } on FormatException catch (_) {
      // Invalid JSON
      return const _ProcessResult(_ProcessStatus.noTitle);
    } on FileSystemException catch (_) {
      // Can't read file
      return const _ProcessResult(_ProcessStatus.noTitle);
    }

    if (title == null || title.isEmpty) {
      return const _ProcessResult(_ProcessStatus.noTitle);
    }

    // Get current filename without extension
    final String currentBasename = path.basename(file.path);

    // Handle Pixel-style double extensions like .PANO.jpg, .MP.mp4, .NIGHT.jpg, .vr.jpg
    // These are natural Google Pixel naming conventions (not from extension fixing).
    // We need to preserve the full suffix but extract the true stem for truncation comparison.
    final String currentExtension;
    final String currentNameWithoutExt;

    final doubleExtMatch = RegExp(
      r'\.([a-zA-Z0-9]{2,5})\.([a-zA-Z0-9]{2,5})$',
    ).firstMatch(currentBasename);
    if (doubleExtMatch != null) {
      currentExtension = currentBasename.substring(doubleExtMatch.start);
      currentNameWithoutExt = currentBasename.substring(
        0,
        doubleExtMatch.start,
      );
    } else {
      currentExtension = path.extension(file.path);
      currentNameWithoutExt = path.basenameWithoutExtension(file.path);
    }

    // Get expected name from title (title may or may not include extension)
    // Use the same double-extension logic for Pixel suffixes to avoid
    // duplication of .PANO, .MP, .NIGHT, .vr
    String expectedNameWithoutExt = title;

    final titleDoubleExtMatch = RegExp(
      r'\.([a-zA-Z0-9]{2,5})\.([a-zA-Z0-9]{2,5})$',
    ).firstMatch(title);
    if (titleDoubleExtMatch != null) {
      expectedNameWithoutExt = title.substring(0, titleDoubleExtMatch.start);
    } else {
      final titleExtMatch = RegExp(r'\.[a-zA-Z0-9]{2,5}$').firstMatch(title);
      if (titleExtMatch != null) {
        expectedNameWithoutExt = title.substring(0, titleExtMatch.start);
      }
    }

    // Normalize both strings for comparison
    final String normalizedCurrent = _normalizeForComparison(
      currentNameWithoutExt,
    );
    final String normalizedExpected = _normalizeForComparison(
      expectedNameWithoutExt,
    );

    // If names match (or current is not truncated), no fix needed
    if (normalizedCurrent == normalizedExpected) {
      return const _ProcessResult(_ProcessStatus.notTruncated);
    }

    // Check if current name is a prefix/truncation of expected name
    // This confirms it's actually a truncation case and not a different file
    if (!_isTruncationOf(normalizedCurrent, normalizedExpected)) {
      // Current filename is not a truncated version of the title
      // This could be a renamed file or different naming convention, skip it
      return const _ProcessResult(_ProcessStatus.notTruncated);
    }

    // Construct new filename: use the title but keep the current extension
    // (extension may have been corrected by extension fixing step)
    final String sanitizedName = _sanitizeFilename(expectedNameWithoutExt);
    final String newBasename = sanitizedName + currentExtension;
    final String newFilePath = path.join(path.dirname(file.path), newBasename);

    // Check if target already exists
    if (await File(newFilePath).exists()) {
      logDebug(
        '[Step 4/8] Skipped truncated filename fix: target already exists: $newFilePath',
      );
      return const _ProcessResult(_ProcessStatus.targetExists);
    }

    // Calculate new JSON path
    final String currentJsonBasename = path.basename(jsonFile.path);
    String newJsonPath;

    // Handle different JSON naming patterns
    if (currentJsonBasename.contains('.supplemental-metadata.')) {
      // Pattern: filename.ext.supplemental-metadata.json
      newJsonPath = path.join(
        path.dirname(jsonFile.path),
        '$newBasename.supplemental-metadata.json',
      );
    } else {
      // Pattern: filename.ext.json
      newJsonPath = path.join(path.dirname(jsonFile.path), '$newBasename.json');
    }

    // Check if new JSON path already exists
    if (await File(newJsonPath).exists()) {
      logDebug(
        '[Step 4/8] Skipped truncated filename fix: JSON target already exists: $newJsonPath',
      );
      return const _ProcessResult(_ProcessStatus.targetExists);
    }

    // Perform atomic rename
    final success = await _performAtomicRename(
      file,
      newFilePath,
      jsonFile,
      newJsonPath,
      fileEntity,
    );

    if (success) {
      return _ProcessResult(_ProcessStatus.fixed, newPath: newFilePath);
    } else {
      return const _ProcessResult(_ProcessStatus.renameFailed);
    }
  }

  /// Checks if [truncated] is a truncated version of [full].
  ///
  /// Returns true if [truncated] is a prefix of [full] and [full] is longer.
  bool _isTruncationOf(final String truncated, final String full) {
    if (truncated.length >= full.length) return false;
    return full.toLowerCase().startsWith(truncated.toLowerCase());
  }

  /// Normalizes a string for comparison (handles Unicode normalization).
  /// Simple normalization: lowercase and remove common variations.
  String _normalizeForComparison(final String s) => s.toLowerCase().trim();

  /// Sanitizes a filename to be safe for the filesystem.
  ///
  /// Removes or replaces characters that are invalid in Windows/macOS/Linux filenames.
  /// Replaces invalid characters with underscores and removes control characters.
  String _sanitizeFilename(final String filename) => filename
      .replaceAll(RegExp(r'[<>:"/\\|?*]'), '_')
      .replaceAll(RegExp(r'[\x00-\x1f]'), '')
      .trim();

  /// Performs atomic rename of both media file and its JSON metadata file.
  /// Also updates the FileEntity.sourcePath to reflect the new path.
  Future<bool> _performAtomicRename(
    final File mediaFile,
    final String newMediaPath,
    final File jsonFile,
    final String newJsonPath,
    final FileEntity fileEntity,
  ) async {
    final String originalMediaPath = mediaFile.path;
    final String originalJsonPath = jsonFile.path;

    File? renamedMediaFile;
    File? renamedJsonFile;

    try {
      // Step 1: Rename the media file
      renamedMediaFile = await mediaFile.rename(newMediaPath);

      // Verify media file rename was successful
      if (!await renamedMediaFile.exists()) {
        throw Exception(
          'Media file does not exist after rename: $newMediaPath',
        );
      }

      // Step 2: Rename the JSON file
      if (await jsonFile.exists()) {
        renamedJsonFile = await jsonFile.rename(newJsonPath);

        // Verify JSON file rename was successful
        if (!await renamedJsonFile.exists()) {
          throw Exception(
            'JSON file does not exist after rename: $newJsonPath',
          );
        }
      }

      // Step 3: Update the FileEntity.sourcePath to reflect new path
      fileEntity.sourcePath = newMediaPath;

      logDebug(
        '[Step 4/8] Fixed truncated filename: ${path.basename(originalMediaPath)} -> ${path.basename(newMediaPath)}',
      );
      return true;
    } catch (e) {
      // Rollback: Attempt to restore original state
      logError(
        '[Step 4/8] Truncated filename fix failed, attempting rollback: $e',
      );
      await _rollbackAtomicRename(
        originalMediaPath,
        originalJsonPath,
        renamedMediaFile,
        renamedJsonFile,
      );
      return false;
    }
  }

  /// Attempts to rollback a failed atomic rename operation.
  Future<void> _rollbackAtomicRename(
    final String originalMediaPath,
    final String originalJsonPath,
    final File? renamedMediaFile,
    final File? renamedJsonFile,
  ) async {
    try {
      // Rollback JSON file rename if it was attempted
      if (renamedJsonFile != null) {
        if (await renamedJsonFile.exists()) {
          await renamedJsonFile.rename(originalJsonPath);
          logInfo('[Step 4/8] Rolled back JSON file rename: $originalJsonPath');
        }
      }

      // Rollback media file rename
      if (renamedMediaFile != null) {
        if (await renamedMediaFile.exists()) {
          await renamedMediaFile.rename(originalMediaPath);
          logInfo(
            '[Step 4/8] Rolled back media file rename: $originalMediaPath',
          );
        }
      }
    } catch (rollbackError) {
      logError(
        '[Step 4/8] Failed to rollback truncated filename fix. Manual cleanup may be required. '
        'Original media: $originalMediaPath, Original JSON: $originalJsonPath. Error: $rollbackError',
      );
    }
  }
}

/// Internal enum for processing status
enum _ProcessStatus {
  fixed,
  noJson,
  noTitle,
  notTruncated,
  targetExists,
  renameFailed,
}

/// Internal class for processing result
class _ProcessResult {
  const _ProcessResult(this.status, {this.newPath});

  final _ProcessStatus status;
  final String? newPath;
}

/// Summary of truncated filename fixing operation
class TruncatedFilenameFixerSummary {
  const TruncatedFilenameFixerSummary({
    required this.fixedCount,
    required this.checkedCount,
    required this.skippedNoJson,
    required this.skippedNoTitle,
    required this.skippedNotTruncated,
    required this.skippedTargetExists,
    required this.failedRename,
  });

  final int fixedCount;
  final int checkedCount;
  final int skippedNoJson;
  final int skippedNoTitle;
  final int skippedNotTruncated;
  final int skippedTargetExists;
  final int failedRename;

  Map<String, dynamic> toMap() => {
    'fixedCount': fixedCount,
    'checkedCount': checkedCount,
    'skippedNoJson': skippedNoJson,
    'skippedNoTitle': skippedNoTitle,
    'skippedNotTruncated': skippedNotTruncated,
    'skippedTargetExists': skippedTargetExists,
    'failedRename': failedRename,
  };
}
