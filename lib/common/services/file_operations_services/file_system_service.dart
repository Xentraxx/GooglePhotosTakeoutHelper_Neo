import 'dart:io';
import 'package:gpth_neo/gpth_lib_exports.dart';
import 'package:mime/mime.dart';
import 'package:path/path.dart' as path;

/// Service for file system operations and file type detection
///
/// Extracted from utils.dart to provide a clean, testable interface
/// for file system operations commonly used throughout the application.
///
/// NOTE: File size formatting and unique filename generation are now
/// available through ConsolidatedUtilityService (accessed via ServiceContainer).
/// This service focuses on file type detection and basic file operations.
class FileSystemService {
  /// Creates a new instance of FileSystemService
  const FileSystemService();

  /// Checks if a file is a photo or video based on MIME type and extension
  ///
  /// This method first checks MIME type using the dart:mime package, then
  /// checks for additional extensions not supported by dart:mime including
  /// RAW formats (.dng, .cr2) and Pixel motion photos (.mp, .mv).
  ///
  /// [file] File to check
  /// Returns true if the file is a photo or video
  bool isPhotoOrVideo(final File file) {
    final String mime = lookupMimeType(file.path) ?? '';
    final String fileExtension = path.extension(file.path).toLowerCase();

    return mime.startsWith('image/') ||
        mime.startsWith(
          'video/',
        ) || // Special handling for MTS files: dart-lang/mime package incorrectly
        // identifies .mts video files as 'model/vnd.mts' instead of 'video/mp2t'
        // See: https://github.com/TheLastGimbus/GooglePhotosTakeoutHelper/issues/223
        // See: https://github.com/dart-lang/mime/issues/102
        mime == 'model/vnd.mts' ||
        MediaExtensions.additional.contains(fileExtension) ||
        // Pixel motion-photo extensions not covered by dart:mime, including
        // the `.mp~<digits>` edited-alternate family (issue #138).
        MediaExtensions.isMotionPhotoExtension(file.path);
  }

  /// Filters a list of files to only include photos and videos
  ///
  /// [files] List of files to filter
  /// Returns filtered list containing only photo and video files
  List<File> filterPhotoVideoFiles(final List<File> files) =>
      files.where(isPhotoOrVideo).toList();

  /// Safely copies a file to a new location
  ///
  /// [source] Source file to copy
  /// [destination] Destination file path
  /// [overwrite] Whether to overwrite if destination exists
  /// Returns the destination file
  /// Throws [FileSystemException] if operation fails
  Future<File> copyFile(
    final File source,
    final File destination, {
    final bool overwrite = false,
  }) async {
    if (!source.existsSync()) {
      throw FileSystemException('Source file does not exist', source.path);
    }

    if (destination.existsSync() && !overwrite) {
      throw FileSystemException(
        'Destination file already exists',
        destination.path,
      );
    }

    // Ensure destination directory exists
    await destination.parent.create(recursive: true);

    return source.copy(destination.path);
  }

  /// Safely moves a file to a new location
  ///
  /// [source] Source file to move
  /// [destination] Destination file path
  /// [overwrite] Whether to overwrite if destination exists
  /// Returns the destination file
  /// Throws [FileSystemException] if operation fails
  Future<File> moveFile(
    final File source,
    final File destination, {
    final bool overwrite = false,
  }) async {
    if (!source.existsSync()) {
      throw FileSystemException('Source file does not exist', source.path);
    }

    if (destination.existsSync() && !overwrite) {
      throw FileSystemException(
        'Destination file already exists',
        destination.path,
      );
    }

    // Ensure destination directory exists
    await destination.parent.create(recursive: true);

    return source.rename(destination.path);
  }

  /// Gets the size of a file in bytes
  ///
  /// [file] File to get size of
  /// Returns file size in bytes
  /// Throws [FileSystemException] if file doesn't exist
  Future<int> getFileSize(final File file) async {
    if (!await file.exists()) {
      throw FileSystemException('File does not exist', file.path);
    }
    final stat = await file.stat();
    return stat.size;
  }

  /// Checks if a directory is empty
  ///
  /// [directory] Directory to check
  /// Returns true if directory is empty or doesn't exist
  Future<bool> isDirectoryEmpty(final Directory directory) async {
    if (!await directory.exists()) {
      return true;
    }

    await for (final _ in directory.list()) {
      return false; // Found at least one entity
    }
    return true;
  }

  /// Validates directory exists and is accessible
  ///
  /// [dir] Directory to validate
  /// [shouldExist] Whether the directory should exist (true) or not exist (false)
  /// Returns ValidationResult with success/failure status and message
  Future<FileSystemValidationResult> validateDirectory(
    final Directory dir, {
    final bool shouldExist = true,
  }) async {
    final exists = await dir.exists();
    if (shouldExist && !exists) {
      return FileSystemValidationResult.failure(
        'Directory does not exist: ${dir.path}',
      );
    }
    if (!shouldExist && exists) {
      return FileSystemValidationResult.failure(
        'Directory already exists: ${dir.path}',
      );
    }
    return const FileSystemValidationResult.success();
  }

  /// Safely creates directory with error handling
  ///
  /// [dir] Directory to create
  /// Returns true if creation was successful
  Future<bool> safeCreateDirectory(final Directory dir) async {
    final path = dir.path;
    if (path.trim().isEmpty) {
      // Silent failure for empty path to keep cross-platform tests consistent
      return false;
    }
    try {
      await dir.create(recursive: true);
      return true;
    } catch (e) {
      stderr.write('Failed to create directory $path: $e\n');
      return false;
    }
  }
}

/// Result of a validation operation
class FileSystemValidationResult {
  const FileSystemValidationResult._({required this.isSuccess, this.message});

  /// Creates a successful validation result
  const FileSystemValidationResult.success() : this._(isSuccess: true);

  /// Creates a failed validation result with message
  const FileSystemValidationResult.failure(final String message)
    : this._(isSuccess: false, message: message);

  /// Whether the validation was successful
  final bool isSuccess;

  /// Error message if validation failed
  final String? message;

  /// Whether the validation failed
  bool get isFailure => !isSuccess;
}
