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

  /// Determines if a directory is a Google Photos year folder
  ///
  /// Checks if the folder name matches the pattern "Photos from YYYY" where YYYY is any 4-digit year.
  /// Supports multiple languages: English (Photos from), Spanish (Fotos del),
  /// German (Fotos von), Portuguese (Foto da), Dutch (Foto_s van).
  ///
  /// [dir] Directory to check
  /// Returns true if it's a year folder
  bool isYearFolder(final Directory dir) =>
      RegExp(photosFromYearFolderPattern).hasMatch(path.basename(dir.path));

  /// Determines if a directory is an album folder
  ///
  /// An album folder is one that contains at least one media file
  /// (photo or video) or at least one per-media JSON sidecar. Takeout
  /// sometimes exports album folders that contain only the JSON sidecars
  /// because the assets themselves were deduplicated into the year folders
  /// (issue #133) — those folders are still albums.
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
          // JSON sidecar referencing a media file (asset may be missing here)
          final String name = path.basename(entity.path);
          if (name.toLowerCase().endsWith('.json') &&
              JsonMetadataMatcherService.isMediaJsonSidecarName(name)) {
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
