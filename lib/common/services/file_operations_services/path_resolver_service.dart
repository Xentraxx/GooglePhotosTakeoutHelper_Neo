import 'dart:io';

import 'package:gpth/gpth_lib_exports.dart';
import 'package:path/path.dart' as path;

/// **TAKEOUT PATH RESOLVER SERVICE**
///
/// Service responsible for normalizing Google Photos Takeout directory paths
/// to ensure processing always starts from the correct Google Photos folder,
/// regardless of where the user points the input directory.
///
/// **PATH NORMALIZATION LOGIC:**
/// Google Photos Takeout structure can vary, but typically follows this pattern:
/// ```
/// [User Input] → SomeFolder/
///   └── Takeout/
///       └── Google Photos/  ← Target: Always navigate here
///           ├── Photos from 2020/
///           ├── Photos from 2021/
///           ├── Album 1/
///           └── Album 2/
/// ```
///
/// **SUPPORTED INPUT SCENARIOS:**
/// 1. **Parent Directory**: User points to folder containing "Takeout" subfolder
/// 2. **Takeout Directory**: User points directly to "Takeout" folder
/// 3. **Google Photos Directory**: User points directly to "Google Photos" folder
/// 4. **Deep Structure**: Handles nested folder structures from different export methods
///
/// **VALIDATION:**
/// - Ensures the final path contains expected Google Photos Takeout structure
/// - Validates presence of "Photos from YYYY" folders or album directories
/// - Provides meaningful error messages for invalid or missing structures
///
/// **ERROR HANDLING:**
/// - Gracefully handles missing directories and permissions issues
/// - Provides clear feedback about what structure was expected vs found
/// - Suggests corrective actions for common path resolution problems
class PathResolverService {
  /// **RESOLVE GOOGLE PHOTOS DIRECTORY**
  ///
  /// Resolves the input path to point to the actual Google Photos directory
  /// containing media files, regardless of where the user initially pointed.
  ///
  /// **RESOLUTION ALGORITHM:**
  /// 1. Check if current path already contains Google Photos structure
  /// 2. Look for "Takeout" subfolder and navigate into it
  /// 3. Find the single subfolder within Takeout (Google Photos in various languages)
  /// 4. Validate that the final path contains expected media structure
  ///
  /// **PATH VALIDATION:**
  /// - Verifies presence of "Photos from YYYY" year folders
  /// - Checks for album directories with media files
  /// - Ensures the structure matches Google Photos Takeout format
  ///
  /// @param inputPath The user-provided input directory path
  /// @returns Normalized path pointing to the Google Photos directory
  /// @throws DirectoryNotFoundException when input path doesn't exist
  /// @throws InvalidTakeoutStructureException when structure doesn't match expected format
  static String resolveGooglePhotosPath(final String inputPath) {
    // NEW: normalize early to avoid trailing-space segments issues.
    // This trims trailing spaces from each segment and re-joins the path.
    final normalizedInput = normalizePath(inputPath);

    final inputDir = Directory(normalizedInput);

    if (!inputDir.existsSync()) {
      throw DirectoryNotFoundException(
        'Input directory does not exist: $normalizedInput',
      );
    }

    // Try the current path first - maybe it's already the Google Photos directory
    if (_isGooglePhotosDirectory(inputDir)) {
      return normalizePath(inputDir.path);
    }

    // Look for Takeout folder in current directory
    final takeoutDir = _findTakeoutDirectory(inputDir);
    if (takeoutDir != null) {
      final googlePhotosDir = _findGooglePhotosInTakeout(takeoutDir);
      if (googlePhotosDir != null) {
        return normalizePath(googlePhotosDir.path);
      }
    }

    // Check if the current directory IS a Takeout directory
    if (_looksLikeTakeoutDirectory(inputDir)) {
      final googlePhotosDir = _findGooglePhotosInTakeout(inputDir);
      if (googlePhotosDir != null) {
        return normalizePath(googlePhotosDir.path);
      }
    }

    // If we get here, we couldn't find a valid Google Photos structure
    throw InvalidTakeoutStructureException(
      'Could not find valid Google Photos Takeout structure in: $normalizedInput\n'
      'Expected structure: [path]/Takeout/Google Photos/Photos from YYYY/\n'
      'Make sure you have extracted the Google Takeout files correctly.',
    );
  }

  /// **CHECK IF DIRECTORY IS GOOGLE PHOTOS**
  ///
  /// Determines if a directory appears to be the Google Photos directory
  /// by checking for characteristic folder patterns.
  ///
  /// **IDENTIFICATION CRITERIA:**
  /// - Contains "Photos from YYYY" year folders
  /// - Contains album directories with media files
  /// - Has the typical Google Photos Takeout structure
  ///
  /// @param directory Directory to check
  /// @returns true if this appears to be a Google Photos directory
  static bool _isGooglePhotosDirectory(final Directory directory) {
    try {
      final contents = directory.listSync();

      // Look for "Photos from YYYY" pattern
      final hasYearFolders = contents.whereType<Directory>().any(_isYearFolder);

      if (hasYearFolders) {
        return true;
      }

      // Alternative: Check for album folders with media files
      final hasAlbumFolders = contents.whereType<Directory>().any(
        _hasMediaFiles,
      );

      return hasAlbumFolders;
    } catch (e) {
      return false;
    }
  }

  /// **FIND TAKEOUT DIRECTORY**
  ///
  /// Searches for a "Takeout" directory within the given directory.
  ///
  /// @param directory Directory to search in
  /// @returns Takeout directory if found, null otherwise
  static Directory? _findTakeoutDirectory(final Directory directory) {
    try {
      final contents = directory.listSync();

      for (final entity in contents) {
        if (entity is Directory) {
          // Robust compare: allow trailing spaces on disk names.
          final base = path.basename(entity.path).trimRight().toLowerCase();
          if (base == 'takeout') {
            return entity;
          }
        }
      }
      return null;
    } catch (e) {
      return null;
    }
  }

  /// **CHECK IF DIRECTORY LOOKS LIKE TAKEOUT**
  ///
  /// Determines if a directory appears to be a Takeout directory
  /// by checking its structure and contents.
  ///
  /// @param directory Directory to check
  /// @returns true if this looks like a Takeout directory
  static bool _looksLikeTakeoutDirectory(final Directory directory) {
    try {
      final contents = directory.listSync().whereType<Directory>();

      // Takeout should have exactly one subdirectory (Google Photos in various languages)
      // or should contain a directory that looks like Google Photos
      if (contents.length == 1) {
        return _isGooglePhotosDirectory(contents.first);
      }

      // Alternative: look for a directory that could be Google Photos
      return contents.any(_couldBeGooglePhotosDirectory);
    } catch (e) {
      return false;
    }
  }

  /// **FIND GOOGLE PHOTOS IN TAKEOUT**
  ///
  /// Finds the Google Photos directory within a Takeout directory.
  /// The Google Photos directory can have different names depending on language.
  ///
  /// @param takeoutDir Takeout directory to search in
  /// @returns Google Photos directory if found, null otherwise
  static Directory? _findGooglePhotosInTakeout(final Directory takeoutDir) {
    try {
      final contents = takeoutDir.listSync().whereType<Directory>();

      // First, try to find a directory that's clearly Google Photos
      for (final dir in contents) {
        if (_isGooglePhotosDirectory(dir)) {
          return dir;
        }
      }

      // If exactly one directory exists, assume it's Google Photos (common case)
      if (contents.length == 1) {
        final potentialGooglePhotos = contents.first;
        if (_couldBeGooglePhotosDirectory(potentialGooglePhotos)) {
          return potentialGooglePhotos;
        }
      }

      return null;
    } catch (e) {
      return null;
    }
  }

  /// **CHECK IF COULD BE GOOGLE PHOTOS**
  ///
  /// Checks if a directory could potentially be Google Photos directory
  /// with more lenient criteria than _isGooglePhotosDirectory.
  ///
  /// @param directory Directory to check
  /// @returns true if this could be Google Photos
  static bool _couldBeGooglePhotosDirectory(final Directory directory) {
    try {
      final contents = directory.listSync();

      // Look for any folders or media files
      final hasDirectories = contents.whereType<Directory>().isNotEmpty;
      final hasFiles = contents.whereType<File>().any(
        (final file) => _isMediaFile(file) || _isJsonFile(file),
      );

      return hasDirectories || hasFiles;
    } catch (e) {
      return false;
    }
  }

  /// **CHECK IF YEAR FOLDER**
  ///
  /// Determines if a directory follows the "Photos from YYYY" pattern.
  ///
  /// @param directory Directory to check
  /// @returns true if this is a year folder
  static bool _isYearFolder(final Directory directory) {
    // Robust to trailing spaces in folder names extracted from zips
    final name = path.basename(directory.path).trimRight();
    final yearRegex = RegExp(TakeoutFolderClassifierService.yearFolderPattern);
    return yearRegex.hasMatch(name);
  }

  /// **CHECK IF DIRECTORY HAS MEDIA FILES**
  ///
  /// Checks if a directory contains media files (photos/videos).
  ///
  /// @param directory Directory to check
  /// @returns true if directory contains media files
  static bool _hasMediaFiles(final Directory directory) {
    try {
      final contents = directory.listSync();
      return contents.whereType<File>().any(_isMediaFile);
    } catch (e) {
      return false;
    }
  }

  /// **CHECK IF FILE IS MEDIA**
  ///
  /// Determines if a file is a media file based on its extension.
  ///
  /// @param file File to check
  /// @returns true if this is a media file
  static bool _isMediaFile(final File file) {
    final extension = path.extension(file.path).toLowerCase();
    const mediaExtensions = {
      '.jpg',
      '.jpeg',
      '.png',
      '.gif',
      '.bmp',
      '.tiff',
      '.tif',
      '.heic',
      '.heif',
      '.webp',
      '.avif',
      '.mp4',
      '.mov',
      '.avi',
      '.mkv',
      '.webm',
      '.m4v',
      '.3gp',
      '.cr2',
      '.nef',
      '.arw',
      '.dng',
      '.raw',
    };
    return mediaExtensions.contains(extension);
  }

  /// **CHECK IF FILE IS JSON METADATA**
  ///
  /// Determines if a file is a JSON metadata file.
  ///
  /// @param file File to check
  /// @returns true if this is a JSON metadata file
  static bool _isJsonFile(final File file) =>
      path.extension(file.path).toLowerCase() == '.json';

  // ─────────────────────────────────────────────────────────────────────────────
  // NEW: Public path normalizer
  // ─────────────────────────────────────────────────────────────────────────────
  /// Normalizes a filesystem path by:
  /// - Splitting into segments with `package:path`
  /// - Trimming trailing whitespace from each segment (to fix Takeout names like "Fotos de ")
  /// - Re-joining with `path.joinAll`
  ///
  /// This does **not** change case, does **not** touch leading spaces, and does **not**
  /// remove valid trailing separators from roots (e.g., Windows drive roots).
  static String normalizePath(final String input) {
    try {
      // Fast path: if there are no spaces at end of the string, still normalize separators
      final ctx = path.context;
      final segments = ctx.split(input);

      if (segments.isEmpty) return input;

      final List<String> fixed = <String>[];
      for (int i = 0; i < segments.length; i++) {
        final seg = segments[i];
        // Keep root segments untouched (e.g., "C:" or "/" or "\\server\share")
        if (i == 0 &&
            (seg.isEmpty || seg == ctx.separator || seg.endsWith(':'))) {
          fixed.add(seg);
          continue;
        }
        // Trim **trailing** spaces only; do not touch leading spaces on purpose.
        fixed.add(seg.replaceFirst(RegExp(r'\s+$'), ''));
      }

      final joined = ctx.joinAll(fixed);
      return joined;
    } catch (_) {
      // If anything goes wrong, return the original path unchanged.
      return input;
    }
  }
}

/// **EXCEPTION: DIRECTORY NOT FOUND**
///
/// Thrown when the specified input directory does not exist.
class DirectoryNotFoundException implements Exception {
  const DirectoryNotFoundException(this.message);
  final String message;

  @override
  String toString() => 'DirectoryNotFoundException: $message';
}

/// **EXCEPTION: INVALID TAKEOUT STRUCTURE**
///
/// Thrown when the directory structure doesn't match expected Google Photos Takeout format.
class InvalidTakeoutStructureException implements Exception {
  const InvalidTakeoutStructureException(this.message);
  final String message;

  @override
  String toString() => 'InvalidTakeoutStructureException: $message';
}
