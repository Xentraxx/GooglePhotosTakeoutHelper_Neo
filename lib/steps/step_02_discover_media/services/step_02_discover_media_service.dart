import 'dart:io';

import 'package:console_bars/console_bars.dart';
import 'package:gpth_neo/gpth_lib_exports.dart';
import 'package:mime/mime.dart';
import 'package:path/path.dart' as path;

/// Service that encapsulates the full logic of Step 2 (Discover & classify media).
/// English note: this mirrors the original step behavior, including logging, filtering,
/// progress bar, and population of `context.mediaCollection`.
class DiscoverMediaService with LoggerMixin {
  const DiscoverMediaService();

  /// Runs discovery and returns aggregated counts used by the step wrapper.
  Future<DiscoverMediaResult> discover(final ProcessingContext context) async {
    final inputDir = Directory(context.config.inputPath);
    if (!await inputDir.exists()) {
      throw Exception(
        'Input directory does not exist: ${context.config.inputPath}',
      );
    }

    final scan = await _scanDirectoriesOptimized(inputDir, context);

    var extrasSkipped = 0;
    if (context.config.skipExtras) {
      const extrasService = EditedVersionDetectorService();
      final result = extrasService.removeExtras(context.mediaCollection);
      context.mediaCollection.clear();
      context.mediaCollection.addAll(result.collection.media);
      extrasSkipped = result.removedCount;

      if (context.config.verbose) {
        logDebug(
          '[Step 2/8] Skipped $extrasSkipped extra files due to skipExtras configuration',
          forcePrint: true,
        );
      }
    }

    return DiscoverMediaResult(
      yearFolderFiles: scan.yearFolderFiles,
      albumFolderFiles: scan.albumFolderFiles,
      extrasSkipped: extrasSkipped,
    );
  }

  /// Optimized single-pass directory scanning to avoid multiple traversals.
  Future<_ScanResult> _scanDirectoriesOptimized(
    final Directory inputDir,
    final ProcessingContext context,
  ) async {
    int yearFolderFiles = 0;
    int albumFolderFiles = 0;

    // Cache for directory classification to avoid repeated checks
    final directoryCache = <String, _DirectoryType>{};

    // Single pass through all entities in input directory
    final entities = await inputDir.list().toList();

    // Classify directories first (cheaper operations)
    final yearDirectories = <Directory>[];
    final albumDirectories = <Directory>[];

    for (final entity in entities) {
      if (entity is Directory) {
        final dirType = await _classifyDirectory(entity, directoryCache);
        switch (dirType) {
          case _DirectoryType.year:
            yearDirectories.add(entity);
            break;
          case _DirectoryType.album:
            albumDirectories.add(entity);
            break;
          case _DirectoryType.other:
            break;
        }
      }
    }

    // Pre-count total media files across year + album dirs to drive a precise progress bar.
    int plannedTotal = 0;
    for (final d in yearDirectories) {
      plannedTotal += await _countMediaFiles(d, context);
    }
    for (final d in albumDirectories) {
      plannedTotal += await _countMediaFiles(d, context);
    }
    final FillingBar? bar = (plannedTotal > 0)
        ? FillingBar(
            total: plannedTotal,
            width: 50,
            percentage: true,
            desc: '[ INFO  ] [Step 2/8] Indexing',
          )
        : null;
    int progressed = 0;

    // Process year directories
    for (final yearDir in yearDirectories) {
      if (context.config.verbose) {
        logDebug(
          '[Step 2/8] Scanning year folder: ${path.basename(yearDir.path)}',
          forcePrint: true,
        );
      }
      await for (final mediaFile in _getMediaFiles(
        yearDir,
        context,
        onEach: () {
          if (bar != null) {
            progressed++;
            if ((progressed % 500) == 0 || progressed == plannedTotal) {
              bar.update(progressed);
            }
          }
        },
      )) {
        final isPartnerShared = await jsonPartnerSharingExtractor(
          File(mediaFile.sourcePath),
        );

        final entity = MediaEntity.single(
          file: mediaFile,
          partnerShared: isPartnerShared,
        );

        context.mediaCollection.add(entity);
        yearFolderFiles++;
      }
    }

    // Process album directories
    for (final albumDir in albumDirectories) {
      // If the directory name was hex-encoded by the pipeline to handle emoji on
      // Windows, decode it back to the original emoji name so that album folders
      // in the output carry the user-visible name.
      final albumName = FilenameSanitizerService().decodeEmojiInText(
        path.basename(albumDir.path),
      );
      if (context.config.verbose) {
        logDebug(
          '[Step 2/8] Scanning album folder: $albumName',
          forcePrint: true,
        );
      }
      await for (final mediaFile in _getMediaFiles(
        albumDir,
        context,
        onEach: () {
          if (bar != null) {
            progressed++;
            if ((progressed % 500) == 0 || progressed == plannedTotal) {
              bar.update(progressed);
            }
          }
        },
      )) {
        final isPartnerShared = await jsonPartnerSharingExtractor(
          File(mediaFile.sourcePath),
        );

        final parentDir = path.dirname(mediaFile.sourcePath);
        final entity = MediaEntity.single(
          file: mediaFile,
          partnerShared: isPartnerShared,
          albumsMap: {
            albumName: AlbumEntity(
              name: albumName,
              sourceDirectories: {parentDir},
            ),
          },
        );

        context.mediaCollection.add(entity);
        albumFolderFiles++;
      }
    }

    if (bar != null) stdout.writeln();

    return _ScanResult(
      yearFolderFiles: yearFolderFiles,
      albumFolderFiles: albumFolderFiles,
    );
  }

  Future<_DirectoryType> _classifyDirectory(
    final Directory directory,
    final Map<String, _DirectoryType> cache,
  ) async {
    final dirPath = directory.path;
    if (cache.containsKey(dirPath)) {
      return cache[dirPath]!;
    }

    _DirectoryType type;
    if (isYearFolder(directory)) {
      type = _DirectoryType.year;
    } else if (await isAlbumFolder(directory)) {
      type = _DirectoryType.album;
    } else {
      type = _DirectoryType.other;
    }

    cache[dirPath] = type;
    return type;
  }

  /// Get media files from a directory, respecting extension fixing configuration.
  Stream<FileEntity> _getMediaFiles(
    final Directory directory,
    final ProcessingContext context, {
    final void Function()? onEach, // Invoked per yielded file.
  }) async* {
    if (context.config.extensionFixing == ExtensionFixingMode.none) {
      await for (final entity in directory.list(recursive: true)) {
        if (entity is File) {
          try {
            const headerSize = 512;
            final fileSize = await entity.length();
            final bytesToRead = fileSize < headerSize ? fileSize : headerSize;

            final headerBytes = await entity.openRead(0, bytesToRead).first;
            final String? mimeType = lookupMimeType(
              entity.path,
              headerBytes: headerBytes,
            );

            if (mimeType != null &&
                (mimeType.startsWith('image/') ||
                    mimeType.startsWith('video/'))) {
              onEach?.call();
              yield FileEntity(sourcePath: entity.path);
              continue;
            }

            final metadataFile = File('${entity.path}.json');
            if (await metadataFile.exists()) {
              onEach?.call();
              yield FileEntity(sourcePath: entity.path);
            }
          } catch (_) {
            continue;
          }
        }
      }
    } else {
      await for (final file
          in directory.list(recursive: true).wherePhotoVideo()) {
        onEach?.call();
        yield FileEntity(sourcePath: file.path);
      }
    }
  }

  /// Counts media files in a directory using the same inclusion logic as `_getMediaFiles`.
  Future<int> _countMediaFiles(
    final Directory directory,
    final ProcessingContext context,
  ) async {
    int count = 0;
    if (context.config.extensionFixing == ExtensionFixingMode.none) {
      await for (final entity in directory.list(recursive: true)) {
        if (entity is File) {
          try {
            const headerSize = 512;
            final fileSize = await entity.length();
            final bytesToRead = fileSize < headerSize ? fileSize : headerSize;

            final headerBytes = await entity.openRead(0, bytesToRead).first;
            final String? mimeType = lookupMimeType(
              entity.path,
              headerBytes: headerBytes,
            );

            if (mimeType != null &&
                (mimeType.startsWith('image/') ||
                    mimeType.startsWith('video/'))) {
              count++;
              continue;
            }

            final metadataFile = File('${entity.path}.json');
            if (await metadataFile.exists()) {
              count++;
            }
          } catch (_) {
            continue;
          }
        }
      }
    } else {
      await for (final _ in directory.list(recursive: true).wherePhotoVideo()) {
        count++;
      }
    }
    return count;
  }
}

/// Result object returned by the discovery service for aggregation in the step.
class DiscoverMediaResult {
  const DiscoverMediaResult({
    required this.yearFolderFiles,
    required this.albumFolderFiles,
    required this.extrasSkipped,
  });

  final int yearFolderFiles;
  final int albumFolderFiles;
  final int extrasSkipped;
}

class _ScanResult {
  const _ScanResult({
    required this.yearFolderFiles,
    required this.albumFolderFiles,
  });

  final int yearFolderFiles;
  final int albumFolderFiles;
}

enum _DirectoryType { year, album, other }
