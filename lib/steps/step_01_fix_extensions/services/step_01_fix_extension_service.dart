import 'dart:io';

import 'package:console_bars/console_bars.dart';
import 'package:gpth_neo/gpth_lib_exports.dart';
import 'package:mime/mime.dart';
import 'package:path/path.dart' as path;

/// Service for detecting and fixing incorrect file extensions
///
/// This service analyzes file headers to determine the actual MIME type
/// and renames files when their extensions don't match their content.
/// Common issues include:
/// - Google Photos compressing HEIC to JPEG but keeping original extension
/// - Files incorrectly renamed from AVI to .mp4 during export
/// - Web-downloaded images with generic or incorrect extensions
class FixExtensionService with LoggerMixin {
  /// Creates a new file extension corrector service
  FixExtensionService() : _mimeTypeService = const MimeTypeService();
  final MimeTypeService _mimeTypeService;
  static const EditedVersionDetectorService _extrasService =
      EditedVersionDetectorService();

  /// Fixes incorrectly named files by renaming them to match their actual MIME type
  ///
  /// [directory] Directory to scan recursively for media files
  /// [skipJpegFiles] If true, skips files that are actually JPEG (for conservative mode)
  /// [skipExtras] If true, skips files that are edited versions (e.g. -edited, -bearbeitet)
  ///
  /// Returns the number of files that were successfully renamed
  Future<int> fixIncorrectExtensions(
    final Directory directory, {
    final bool skipJpegFiles = false,
    final bool skipExtras = false,
  }) async {
    int fixedCount = 0;

    // Single-pass collect: gather all matching files once so we can both drive
    // the progress bar with a precise total AND process them in parallel.
    final allFiles = await directory
        .list(recursive: true)
        .wherePhotoVideo()
        .toList();
    final total = allFiles.length;

    final FillingBar? bar = (total > 0)
        ? FillingBar(
            total: total,
            width: 50,
            percentage: true,
            desc: '[ INFO  ] [Step 1/8] Fixing extensions',
          )
        : null;

    int done = 0;

    final maxConcurrency = ConcurrencyManager().concurrencyFor(
      ConcurrencyOperation.fileIO,
    );
    for (int i = 0; i < allFiles.length; i += maxConcurrency) {
      final batch = allFiles.skip(i).take(maxConcurrency).toList();
      final results = await Future.wait(
        batch.map((final file) async {
          try {
            return await _processFile(
              File(file.path),
              skipJpegFiles,
              skipExtras,
            );
          } catch (e) {
            logError('[Step 1/8] Failed to process file ${file.path}: $e');
            return false;
          }
        }),
      );
      fixedCount += results.where((final r) => r).length;
      done += batch.length;
      if (bar != null && ((done % 200) == 0 || done == total)) {
        bar.update(done);
      }
    }

    // Ensure the next logs start on a new line after the bar.
    if (bar != null) stdout.writeln();

    return fixedCount;
  }

  /// Processes a single file to check if extension fixing is needed
  Future<bool> _processFile(
    final File file,
    final bool skipJpegFiles,
    final bool skipExtras,
  ) async {
    // Read file header to determine actual MIME type
    final List<int> headerBytes = await file.openRead(0, 128).first;
    final String? actualMimeType = lookupMimeType(
      file.path,
      headerBytes: headerBytes,
    );

    // Skip if we can't determine the actual type
    if (actualMimeType == null) return false;

    // Skip JPEG files if in conservative mode
    if (skipJpegFiles && actualMimeType == 'image/jpeg') return false;

    final String? extensionMimeType = lookupMimeType(file.path);

    // Skip TIFF-based files (like RAW formats) as MIME detection often
    // misidentifies these formats, and renaming could break camera software compatibility
    if (actualMimeType == 'image/tiff') return false;

    // Check if extension matches content
    if (actualMimeType == extensionMimeType) {
      return false; // Extension is correct
    }

    // Log special cases
    if (extensionMimeType == 'video/mp4' &&
        actualMimeType == 'video/x-msvideo') {
      logDebug(
        '[Step 1/8] Detected AVI file incorrectly named as .mp4: ${path.basename(file.path)}',
      );
    }

    return _renameFileWithCorrectExtension(file, actualMimeType, skipExtras);
  }

  /// Renames a file to use the correct extension based on its MIME type
  Future<bool> _renameFileWithCorrectExtension(
    final File file,
    final String mimeType,
    final bool skipExtras,
  ) async {
    final String? newExtension = _getPreferredExtension(mimeType);

    if (newExtension == null) {
      logWarning(
        '[Step 1/8] Could not determine correct extension for MIME type $mimeType for file ${path.basename(file.path)}',
      );
      return false;
    }

    final String newFilePath =
        '${path.withoutExtension(file.path)}.$newExtension';
    final File newFile = File(newFilePath);

    // Check if target file already exists
    if (await newFile.exists()) {
      logWarning(
        '[Step 1/8] Skipped fixing extension because target file already exists: $newFilePath',
      );
      return false;
    }

    // Skip extra files (edited versions) when --skip-extras is set
    if (skipExtras && _extrasService.isExtra(file.path)) return false;

    // Find associated JSON file before any renaming
    final File? jsonFile = await _findJsonFile(file);

    // Perform atomic rename operation
    final bool success = await _performAtomicRename(
      file,
      newFilePath,
      jsonFile,
    );

    // Best-effort: also rename any supplemental-metadata JSON that references
    // the old extension (e.g. "x.heic.supplemental-metadata.json" → "x.jpg.supplemental-metadata.json")
    if (success) {
      await _renameSupplementalMetadataJson(file.path, newFilePath);
    }

    return success;
  }

  /// Renames supplemental-metadata JSON files whose names reference the old
  /// media extension. Scans the same directory for common Google Photos
  /// supplemental naming patterns: `<oldBasename>.supplemental-metadata.json`
  /// and `<oldBasename>.supplemental-metadata(<N>).json`.
  Future<void> _renameSupplementalMetadataJson(
    final String originalMediaPath,
    final String newMediaPath,
  ) async {
    final String dirPath = path.dirname(originalMediaPath);
    final String oldBase = path.basename(originalMediaPath); // e.g. IMG.HEIC
    final String newBase = path.basename(newMediaPath); // e.g. IMG.jpg
    final String prefixLower = '$oldBase.supplemental-metadata'.toLowerCase();

    try {
      final dir = Directory(dirPath);
      if (!await dir.exists()) return;
      for (final entity in dir.listSync(followLinks: false)) {
        if (entity is! File) continue;
        final String name = path.basename(entity.path);
        if (!name.toLowerCase().endsWith('.json')) continue;
        final String nameLower = name.toLowerCase();
        // Match "<oldBase>.supplemental-metadata.json" or
        //        "<oldBase>.supplemental-metadata(<N>).json"
        if (!nameLower.startsWith(prefixLower)) continue;
        // Compute the new name by replacing the old base with the new base
        final String suffix = name.substring(
          oldBase.length,
        ); // e.g. ".supplemental-metadata.json"
        final String newName = '$newBase$suffix';
        final String newPath = path.join(dirPath, newName);
        if (await File(newPath).exists()) continue;
        await entity.rename(newPath);
        logDebug('[Step 1/8] Renamed supplemental JSON: $name -> $newName');
      }
    } catch (_) {
      // Best-effort: failure to rename supplemental metadata is non-critical
    }
  }

  /// Returns true when [filePath] is a supplemental-metadata JSON.
  ///
  /// Supplemental-metadata JSONs (e.g. "photo.HEIC.supplemental-metadata.json"
  /// or "photo.HEIC.supplemental-metadata(1).json") belong to their *base*
  /// media file and must only be renamed by [_renameSupplementalMetadataJson].
  /// They must never be fed into [_performAtomicRename] — that code computes
  /// the new JSON path as `newMediaPath.json`, which drops the
  /// `.supplemental-metadata` infix and misattributes the file to a different
  /// media entry.
  static bool _isSupplementalMetadataJson(final String filePath) =>
      path.basename(filePath).toLowerCase().contains('.supplemental-metadata.');

  /// Finds the JSON metadata file associated with a media file.
  ///
  /// Supplemental-metadata JSON files are intentionally excluded from the
  /// result: they are handled by [_renameSupplementalMetadataJson] after the
  /// atomic rename completes.  Returning them here would (a) drop the
  /// `.supplemental-metadata` infix in [_performAtomicRename] and (b) race
  /// with [_renameSupplementalMetadataJson] which may have already moved them.
  Future<File?> _findJsonFile(final File file) async {
    // Try quick lookup first
    File? jsonFile = await JsonMetadataMatcherService.findJsonForFile(
      file,
      tryhard: false,
    );
    // Reject supplemental-metadata matches — those belong to the base file and
    // are renamed separately by _renameSupplementalMetadataJson.
    if (jsonFile != null && _isSupplementalMetadataJson(jsonFile.path)) {
      jsonFile = null;
    }
    if (jsonFile != null) return jsonFile;

    // Try harder lookup if quick one failed
    jsonFile = await JsonMetadataMatcherService.findJsonForFile(
      file,
      tryhard: true,
    );
    if (jsonFile != null && _isSupplementalMetadataJson(jsonFile.path)) {
      jsonFile = null;
    }
    if (jsonFile != null) return jsonFile;

    // ─────────────────────────────────────────────────────────────────────────
    // Local robust fallbacks to handle edge cases (e.g., trailing spaces in folders)
    // 1) Direct candidate "<file>.json"
    final String directCandidate = '${file.path}.json';
    final File directJson = File(directCandidate);
    if (await directJson.exists()) return directJson;

    // 2) Scan current directory for "<basename>.<ext>.json" (case-insensitive + trim)
    final String dirPath = path.dirname(file.path);
    final String baseName = path.basename(file.path); // e.g. "IMG_0012.HEIC"
    try {
      final Directory dir = Directory(dirPath);
      if (await dir.exists()) {
        final List<FileSystemEntity> entries = dir.listSync(followLinks: false);
        final String targetLower = '$baseName.json'.toLowerCase();
        for (final FileSystemEntity e in entries) {
          if (e is! File) continue;
          final String name = path.basename(e.path);
          if (!name.toLowerCase().endsWith('.json')) continue;

          // Compare "<basename>.<ext>.json" ignoring trailing spaces around segments
          final String normalizedCandidate = _trimRight(name).toLowerCase();
          final String normalizedTarget = _trimRight(targetLower);
          if (normalizedCandidate == normalizedTarget) return File(e.path);

          // Also allow match by basenameWithoutExtension (for rare exports that drop the original extension)
          final String nameNoJson = name.substring(
            0,
            name.length - 5,
          ); // remove ".json"
          final String n1 = _trimRight(nameNoJson).toLowerCase();
          final String n2 = _trimRight(
            path.basenameWithoutExtension(baseName),
          ).toLowerCase();
          if (n1 == n2) return File(e.path);
        }
      }
    } catch (_) {
      // Ignore scan errors; we will continue with next fallback
    }

    // 3) Try same candidates but on a trimmed parent directory (if current ends with spaces)
    final String trimmedDirPath = _trimRight(dirPath);
    if (trimmedDirPath != dirPath) {
      final String candidateInTrimmed = path.join(
        trimmedDirPath,
        '$baseName.json',
      );
      final File trimmedJson = File(candidateInTrimmed);
      if (await trimmedJson.exists()) return trimmedJson;

      try {
        final Directory tdir = Directory(trimmedDirPath);
        if (await tdir.exists()) {
          final List<FileSystemEntity> entries = tdir.listSync(
            followLinks: false,
          );
          final String targetLower = '$baseName.json'.toLowerCase();
          for (final FileSystemEntity e in entries) {
            if (e is! File) continue;
            final String name = path.basename(e.path);
            if (!name.toLowerCase().endsWith('.json')) continue;

            final String normalizedCandidate = _trimRight(name).toLowerCase();
            final String normalizedTarget = _trimRight(targetLower);
            if (normalizedCandidate == normalizedTarget) return File(e.path);

            final String nameNoJson = name.substring(0, name.length - 5);
            final String n1 = _trimRight(nameNoJson).toLowerCase();
            final String n2 = _trimRight(
              path.basenameWithoutExtension(baseName),
            ).toLowerCase();
            if (n1 == n2) return File(e.path);
          }
        }
      } catch (_) {
        // Ignore
      }
    }

    // If we reached this point, emit the original warning once.
    logWarning(
      '[Step 1/8] Unable to find matching JSON for file: ${file.path}',
    );
    return null;
  }

  /// Returns the preferred file extension for a given MIME type
  String? _getPreferredExtension(final String mimeType) =>
      _mimeTypeService.getPreferredExtension(mimeType);

  /// Performs atomic rename of both media file and its JSON metadata file
  ///
  /// Either both files are renamed successfully, or both operations are rolled back
  /// to maintain consistency between media files and their metadata.
  Future<bool> _performAtomicRename(
    final File mediaFile,
    final String newMediaPath,
    final File? jsonFile,
  ) async {
    final String originalMediaPath = mediaFile.path;
    final String? originalJsonPath = jsonFile?.path;
    final String? newJsonPath = jsonFile != null ? '$newMediaPath.json' : null;

    // Check if JSON target already exists
    if (newJsonPath != null && await File(newJsonPath).exists()) {
      logWarning(
        '[Step 1/8] Skipped fixing extension because target JSON file already exists: $newJsonPath',
      );
      return false;
    }

    File? renamedMediaFile;
    File? renamedJsonFile;

    try {
      // Step 1: Rename the media file
      renamedMediaFile = await mediaFile.rename(newMediaPath);

      // Step 2: Rename the JSON file if it exists
      if (jsonFile != null && newJsonPath != null) {
        if (await jsonFile.exists()) {
          renamedJsonFile = await jsonFile.rename(newJsonPath);
        }
      }

      // Step 3: Verify cleanup of original files
      await _verifyOriginalFilesRemoved(originalMediaPath, originalJsonPath);

      logDebug(
        '[Step 1/8] Fixed extension: ${path.basename(originalMediaPath)} -> ${path.basename(newMediaPath)}',
      );
      return true;
    } catch (e) {
      // Rollback: Attempt to restore original state
      logError('[Step 1/8] Extension fixing failed, attempting rollback: $e');
      await _rollbackAtomicRename(
        originalMediaPath,
        originalJsonPath,
        renamedMediaFile,
        renamedJsonFile,
      );
      return false;
    }
  }

  /// Attempts to rollback a failed atomic rename operation
  Future<void> _rollbackAtomicRename(
    final String originalMediaPath,
    final String? originalJsonPath,
    final File? renamedMediaFile,
    final File? renamedJsonFile,
  ) async {
    try {
      // Rollback JSON file rename if it was attempted
      if (renamedJsonFile != null && originalJsonPath != null) {
        if (await renamedJsonFile.exists()) {
          await renamedJsonFile.rename(originalJsonPath);
          logInfo('[Step 1/8] Rolled back JSON file rename: $originalJsonPath');
        }
      }

      // Rollback media file rename
      if (renamedMediaFile != null) {
        if (await renamedMediaFile.exists()) {
          await renamedMediaFile.rename(originalMediaPath);
          logInfo(
            '[Step 1/8] Rolled back media file rename: $originalMediaPath',
          );
        }
      }
    } catch (rollbackError) {
      logError(
        '[Step 1/8] Failed to rollback atomic rename operation. Manual cleanup may be required. Original media: $originalMediaPath, Original JSON: $originalJsonPath. Error: $rollbackError',
      );
    }
  }

  /// Verifies that original files were properly removed after rename
  Future<void> _verifyOriginalFilesRemoved(
    final String originalMediaPath,
    final String? originalJsonPath,
  ) async {
    // Check if original media file still exists
    if (await File(originalMediaPath).exists()) {
      logWarning(
        '[Step 1/8] Original media file still exists after rename. Attempting manual cleanup: $originalMediaPath',
      );
      try {
        await File(originalMediaPath).delete();
        logInfo(
          '[Step 1/8] Manually cleaned up original media file: $originalMediaPath',
        );
      } catch (deleteError) {
        throw Exception(
          '[Step 1/8] Failed to delete original media file: $deleteError',
        );
      }
    }

    // Check if original JSON file still exists
    if (originalJsonPath != null && await File(originalJsonPath).exists()) {
      logWarning(
        '[Step 1/8] Original JSON file still exists after rename. Attempting manual cleanup: $originalJsonPath',
      );
      try {
        await File(originalJsonPath).delete();
        logInfo(
          '[Step 1/8] Successfully cleaned up original JSON file: $originalJsonPath',
        );
      } catch (deleteError) {
        logWarning(
          '[Step 1/8] Failed to delete original JSON file: $deleteError',
        );
        // Do not throw here as this is less critical than media file consistency
      }
    }
  }

  // ───────────────────────────────────────────────────────────────────────────
  // Small helpers
  // ───────────────────────────────────────────────────────────────────────────

  /// Trims only trailing ASCII/Unicode spaces and tabs from a path segment or filename.
  /// We avoid full normalization to keep behavior minimal and predictable.
  static String _trimRight(final String s) => s.replaceFirst(
    RegExp(r'[\u0020\u0009]+$'),
    '',
  ); // Remove trailing spaces and tabs (common offenders for folder names)
}
