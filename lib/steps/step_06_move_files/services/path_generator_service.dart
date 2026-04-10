import 'dart:io';

import 'package:gpth_neo/gpth_lib_exports.dart';
import 'package:path/path.dart' as path;

/// Service responsible for generating file and directory paths
///
/// This service handles all path generation logic for the moving operations,
/// including date-based folder structures and album-specific paths.
class PathGeneratorService {
  /// Generates the target directory for a file based on album and date information
  ///
  /// [albumKey] The album name (null for ALL_PHOTOS)
  /// [dateTaken] The date the photo was taken
  /// [context] The moving context with configuration
  /// [isPartnerShared] Whether the media is from partner sharing
  /// Returns the target directory path
  Directory generateTargetDirectory(
    final String? albumKey,
    final DateTime? dateTaken,
    final MovingContext context, {
    final bool isPartnerShared = false,
  }) {
    // On Windows, hex-encode any emoji in the album name so that filesystem
    // operations never see raw emoji characters.
    final String? safeAlbumKey = albumKey != null && Platform.isWindows
        ? FilenameSanitizerService.encodeEmojiInText(albumKey.trim())
        : albumKey?.trim();

    // For Albums folder we use 'Albums' as subfolder. For no Albums folder we use 'ALL_PHOTOS' as subfolder
    final String folderName = safeAlbumKey != null
        ? path.join(
            'Albums',
            safeAlbumKey,
          ) // Now All Album's folders will be moved to 'Albums'
        : 'ALL_PHOTOS';

    // Only apply date division to ALL_PHOTOS, not to Albums
    final String dateFolder = albumKey == null
        ? _generateDateFolder(dateTaken, context.dateDivision)
        : '';

    // If partner shared separation is enabled and this is partner shared media,
    // mirror the normal structure under PARTNER_SHARED.
    if (context.dividePartnerShared && isPartnerShared) {
      return Directory(
        path.join(
          context.outputDirectory.path,
          'PARTNER_SHARED',
          folderName,
          dateFolder,
        ),
      );
    }

    return Directory(
      path.join(context.outputDirectory.path, folderName, dateFolder),
    );
  }

  /// Generates the date-based folder structure
  String _generateDateFolder(
    final DateTime? date,
    final DateDivisionLevel divideToDates,
  ) {
    if (divideToDates == DateDivisionLevel.none) {
      return '';
    }

    if (date == null) {
      return 'date-unknown';
    }

    switch (divideToDates) {
      case DateDivisionLevel.day:
        return path.join(
          '${date.year}',
          date.month.toString().padLeft(2, '0'),
          date.day.toString().padLeft(2, '0'),
        );
      case DateDivisionLevel.month:
        return path.join('${date.year}', date.month.toString().padLeft(2, '0'));
      case DateDivisionLevel.year:
        return '${date.year}';
      case DateDivisionLevel.none:
        return '';
    }
  }

  /// Generates the albums-info.json file path
  String generateAlbumsInfoJsonPath(final Directory outputDirectory) =>
      path.join(outputDirectory.path, 'albums-info.json');

  /// Generates ALL_PHOTOS directory path
  Directory generateAllPhotosDirectory(final Directory outputDirectory) =>
      Directory(path.join(outputDirectory.path, 'ALL_PHOTOS'));

  /// Sanitizes a filename to ensure cross-platform compatibility
  String sanitizeFileName(final String fileName) => fileName
      .replaceAll(RegExp(r'[<>:"/\\|?*]'), '_')
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim();

  /// Gets the target file path for a specific file in a directory
  String generateTargetFilePath(
    final File sourceFile,
    final Directory targetDirectory,
  ) {
    final sanitizedName = sanitizeFileName(path.basename(sourceFile.path));
    return path.join(targetDirectory.path, sanitizedName);
  }
}
