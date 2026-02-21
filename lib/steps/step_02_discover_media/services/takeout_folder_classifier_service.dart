import 'dart:io';

import 'package:gpth_neo/gpth_lib_exports.dart';
import 'package:path/path.dart' as path;

/// Service for classifying directories in Google Photos Takeout exports
///
/// This service determines whether directories are year folders, album folders,
/// or other types based on their structure and contents.
class TakeoutFolderClassifierService {
  /// Creates a new takeout folder classifier service
  const TakeoutFolderClassifierService();

  /// Regex pattern for multilingual "Photos from" folder prefixes
  /// Supports English (Photos from), Spanish (Fotos del), and German (Fotos von)
  static const String photosFromPattern = r'Photos from|Fotos del|Fotos von';

  /// Complete regex pattern for year folders with multilingual support
  /// Matches "Photos from YYYY", "Fotos del YYYY", "Fotos von YYYY" where YYYY is any 4-digit year
  static const String yearFolderPattern =
      r'^(Photos from|Fotos del|Fotos von) \d{4}$';

  /// Case-insensitive regex pattern for localized folder names with whitespace handling
  /// Used for matching folder names like "Photos from", "Fotos del", "Fotos von"
  static const String localizedYearPattern =
      r'photos\s+from|fotos\s+del|fotos\s+von';

  /// Determines if a directory is a Google Photos year folder
  ///
  /// Checks if the folder name matches the pattern "Photos from YYYY" where YYYY is any 4-digit year.
  /// Supports multiple languages: English (Photos from), Spanish (Fotos del), German (Fotos von).
  ///
  /// [dir] Directory to check
  /// Returns true if it's a year folder
  bool isYearFolder(final Directory dir) =>
      RegExp(yearFolderPattern).hasMatch(path.basename(dir.path));

  /// Determines if a directory is an album folder
  ///
  /// An album folder is one that contains at least one media file
  /// (photo or video). Uses the wherePhotoVideo extension to check
  /// for supported media formats.
  ///
  /// [dir] Directory to check
  /// Returns true if it's an album folder
  Future<bool> isAlbumFolder(final Directory dir) async {
    try {
      await for (final entity in dir.list()) {
        if (entity is File) {
          // Check if it's a media file using the existing extension
          final mediaFiles = [entity].wherePhotoVideo();
          if (mediaFiles.isNotEmpty) {
            return true;
          }
        }
      }
      return false;
    } catch (e) {
      // Handle permission denied or other errors
      return false;
    }
  }
}

// Legacy exports for backward compatibility - will be removed in next major version
bool isYearFolder(final Directory dir) =>
    const TakeoutFolderClassifierService().isYearFolder(dir);

Future<bool> isAlbumFolder(final Directory dir) async =>
    const TakeoutFolderClassifierService().isAlbumFolder(dir);
