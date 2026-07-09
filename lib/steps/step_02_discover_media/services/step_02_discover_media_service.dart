import 'dart:convert';
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
      orphanJsonAssociations: scan.orphanJsonAssociations,
      orphanJsonUnmatched: scan.orphanJsonUnmatched,
    );
  }

  /// Optimized single-pass directory scanning to avoid multiple traversals.
  Future<_ScanResult> _scanDirectoriesOptimized(
    final Directory inputDir,
    final ProcessingContext context,
  ) async {
    int yearFolderFiles = 0;
    int albumFolderFiles = 0;
    int orphanJsonAssociations = 0;
    int orphanJsonUnmatched = 0;

    // Index of year-folder entities by lowercase basename, used to recover
    // album associations from orphaned album JSON sidecars (issue #133).
    final Map<String, List<int>> yearEntityIndexByBasename =
        <String, List<int>>{};

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

    final maxConcurrency = ConcurrencyManager().concurrencyFor(
      ConcurrencyOperation.fileIO,
    );

    // Process year directories
    for (final yearDir in yearDirectories) {
      if (context.config.verbose) {
        logDebug(
          '[Step 2/8] Scanning year folder: ${path.basename(yearDir.path)}',
          forcePrint: true,
        );
      }
      // Collect all files first (onEach updates the progress bar as files are found)
      final yearFiles = <FileEntity>[];
      await _getMediaFiles(
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
      ).forEach(yearFiles.add);
      // Parallel-batch the partner-sharing JSON checks
      for (int i = 0; i < yearFiles.length; i += maxConcurrency) {
        final batch = yearFiles.skip(i).take(maxConcurrency).toList();
        final partnerFlags = await Future.wait(
          batch.map(
            // tryhard=true: companion videos (MP4 paired with HEIC/JPG) need
            // cross-extension matching to find the still photo's JSON sidecar.
            (final f) =>
                jsonPartnerSharingExtractor(File(f.sourcePath), tryhard: true),
          ),
        );
        for (var j = 0; j < batch.length; j++) {
          context.mediaCollection.add(
            MediaEntity.single(file: batch[j], partnerShared: partnerFlags[j]),
          );
          final String basenameKey = path
              .basename(batch[j].sourcePath)
              .toLowerCase();
          (yearEntityIndexByBasename[basenameKey] ??= <int>[]).add(
            context.mediaCollection.length - 1,
          );
          yearFolderFiles++;
        }
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
      // Collect all files first (onEach updates the progress bar as files are found)
      final albumFiles = <FileEntity>[];
      await _getMediaFiles(
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
      ).forEach(albumFiles.add);
      // Parallel-batch the partner-sharing JSON checks
      for (int i = 0; i < albumFiles.length; i += maxConcurrency) {
        final batch = albumFiles.skip(i).take(maxConcurrency).toList();
        final partnerFlags = await Future.wait(
          batch.map(
            // tryhard=true: companion videos (MP4 paired with HEIC/JPG) need
            // cross-extension matching to find the still photo's JSON sidecar.
            (final f) =>
                jsonPartnerSharingExtractor(File(f.sourcePath), tryhard: true),
          ),
        );
        for (var j = 0; j < batch.length; j++) {
          final parentDir = path.dirname(batch[j].sourcePath);
          context.mediaCollection.add(
            MediaEntity.single(
              file: batch[j],
              partnerShared: partnerFlags[j],
              albumsMap: {
                albumName: AlbumEntity(
                  name: albumName,
                  sourceDirectories: {parentDir},
                ),
              },
            ),
          );
          albumFolderFiles++;
        }
      }

      // Issue #133: Takeout sometimes exports album folders that contain a
      // JSON sidecar but not the asset itself (the asset was deduplicated
      // into a year folder). Attach the album membership to the matching
      // year-folder entity so the album can still be reconstructed.
      final recovery = await _recoverOrphanAlbumAssociations(
        albumDir: albumDir,
        albumName: albumName,
        albumFiles: albumFiles,
        collection: context.mediaCollection,
        yearEntityIndexByBasename: yearEntityIndexByBasename,
      );
      orphanJsonAssociations += recovery.recovered;
      orphanJsonUnmatched += recovery.unmatched;
    }

    if (bar != null) stdout.writeln();

    if (orphanJsonAssociations > 0 || orphanJsonUnmatched > 0) {
      logPrint(
        '[Step 2/8] Album folders referenced $orphanJsonAssociations assets that only exist in year folders (album associations recovered from JSON sidecars)'
        '${orphanJsonUnmatched > 0 ? '; $orphanJsonUnmatched referenced assets could not be found anywhere' : ''}',
      );
    }

    return _ScanResult(
      yearFolderFiles: yearFolderFiles,
      albumFolderFiles: albumFolderFiles,
      orphanJsonAssociations: orphanJsonAssociations,
      orphanJsonUnmatched: orphanJsonUnmatched,
    );
  }

  /// Recovers album associations for orphaned album JSON sidecars (issue #133).
  ///
  /// A sidecar is orphaned when the media file it references is not present
  /// in the album folder. For each orphaned sidecar this method looks up the
  /// referenced asset among the year-folder entities by filename and attaches
  /// the album membership to it.
  ///
  /// Numbered sidecars ("….supplemental-metadata(1).json") reference the
  /// "(N)" duplicate of the asset, but Takeout records the plain original
  /// name in the JSON "title" field for every copy — so for those the
  /// numbered name (derived from the full-length title, which survives the
  /// 51-character sidecar filename truncation) is tried before the plain one.
  /// Because the "(N)" numbering is per-directory, a same-named numbered file
  /// in a year folder is only accepted when its year matches the sidecar's
  /// "photoTakenTime"; otherwise the lookup falls through to the plain name.
  Future<({int recovered, int unmatched})> _recoverOrphanAlbumAssociations({
    required final Directory albumDir,
    required final String albumName,
    required final List<FileEntity> albumFiles,
    required final MediaEntityCollection collection,
    required final Map<String, List<int>> yearEntityIndexByBasename,
  }) async {
    int recovered = 0;
    int unmatched = 0;

    // Media files physically present in this album folder (lowercase basenames).
    final Set<String> presentMediaNames = albumFiles
        .map((final f) => path.basename(f.sourcePath).toLowerCase())
        .toSet();

    try {
      await for (final entity in albumDir.list(recursive: true)) {
        if (entity is! File) continue;
        final String jsonName = path.basename(entity.path);
        if (!jsonName.toLowerCase().endsWith('.json')) continue;

        final List<String> nameCandidates =
            JsonMetadataMatcherService.getMediaNameCandidatesForJsonName(
              jsonName,
            );
        // Skip album-level JSONs (metadata.json, print-subscriptions.json, ...)
        if (nameCandidates.isEmpty ||
            !JsonMetadataMatcherService.isMediaJsonSidecarName(jsonName)) {
          continue;
        }

        // Not orphaned: the referenced asset exists in the album folder.
        if (nameCandidates.any(
          (final c) => presentMediaNames.contains(c.toLowerCase()),
        )) {
          continue;
        }

        // Read "title" and the capture year from the sidecar for exact matching.
        String? title;
        int? photoYear;
        try {
          final dynamic data = jsonDecode(await entity.readAsString());
          if (data is Map<String, dynamic>) {
            final dynamic t = data['title'];
            if (t is String && t.trim().isNotEmpty) title = t.trim();
            final dynamic taken = data['photoTakenTime'];
            if (taken is Map) {
              final dynamic ts = taken['timestamp'];
              final int? seconds = ts is String
                  ? int.tryParse(ts)
                  : (ts is int ? ts : null);
              if (seconds != null) {
                photoYear = DateTime.fromMillisecondsSinceEpoch(
                  seconds * 1000,
                  isUtc: true,
                ).year;
              }
            }
          }
        } catch (_) {
          // Unreadable/invalid JSON → fall back to filename-derived candidates.
        }

        // A numbered sidecar references the "(N)" duplicate of the asset,
        // but "title" holds the plain original name for every copy. Derive
        // the numbered name from the full-length title so the lookup targets
        // the right duplicate even when the sidecar filename was truncated.
        String? numberedTitle;
        final String? duplicateNumber =
            JsonMetadataMatcherService.getDuplicateNumberForJsonName(jsonName);
        if (duplicateNumber != null && title != null) {
          numberedTitle =
              JsonMetadataMatcherService.applyDuplicateNumberToMediaName(
                title,
                duplicateNumber,
              );
        }

        // Presence in the album folder is judged under the name the sidecar
        // actually references: for numbered sidecars that is the "(N)" copy —
        // a plain-named file in the album belongs to the plain sidecar.
        final String? referencedTitle = numberedTitle ?? title;
        if (referencedTitle != null &&
            presentMediaNames.contains(referencedTitle.toLowerCase())) {
          continue; // Asset present in the album folder.
        }

        // Look up the referenced asset among the year-folder entities, most
        // specific name first: numbered forms (title-derived, then filename-
        // derived), then the plain title, then the plain filename-derived
        // name. The set literal keeps insertion order and drops duplicates.
        final String? numberedCandidate = nameCandidates.length > 1
            ? nameCandidates.first
            : null;
        final List<String> lookupNames = <String>{
          ?numberedTitle,
          ?numberedCandidate,
          ?title,
          nameCandidates.last,
        }.toList();

        // The "(N)" numbering is per-directory: the album's "pic(1).jpg" and
        // a year folder's "pic(1).jpg" can be different photos. When the
        // sidecar carries a capture year, only accept a name whose files
        // include that year; when no name does, fall back to the first name
        // that matched at all (pre-existing behavior).
        List<int>? matches;
        List<int>? firstMatches;
        for (final name in lookupNames) {
          final List<int>? found =
              yearEntityIndexByBasename[name.toLowerCase()];
          if (found == null || found.isEmpty) continue;
          firstMatches ??= found;
          final int? year = photoYear;
          if (year == null) {
            matches = found;
            break;
          }
          final List<int> byYear = found
              .where(
                (final i) => _pathContainsYearFolder(
                  collection[i].primaryFile.sourcePath,
                  year,
                ),
              )
              .toList();
          if (byYear.isNotEmpty) {
            matches = byYear;
            break;
          }
        }
        matches ??= firstMatches;

        if (matches == null) {
          unmatched++;
          logWarning(
            '[Step 2/8] Album "$albumName": asset referenced by ${entity.path} was not found in the album folder nor in any year folder',
          );
          continue;
        }

        for (final idx in matches) {
          collection.replaceAt(
            idx,
            collection[idx].withAlbumInfo(albumName, sourceDir: albumDir.path),
          );
        }
        recovered++;
        logDebug(
          '[Step 2/8] Album "$albumName": recovered association for ${matches.map((final i) => collection[i].primaryFile.sourcePath).join(', ')} from orphaned sidecar $jsonName',
        );
      }
    } catch (e) {
      logWarning(
        '[Step 2/8] Failed to scan album folder ${albumDir.path} for orphaned JSON sidecars: $e',
      );
    }

    return (recovered: recovered, unmatched: unmatched);
  }

  /// Whether [filePath] contains a year-folder segment for [year]
  /// (a pure "2024" segment or a localized "Photos from 2024" segment).
  static bool _pathContainsYearFolder(final String filePath, final int year) {
    final RegExp localizedYear = RegExp(
      '^(?:$photosFromPrefixPattern) $year\$',
      caseSensitive: false,
    );
    for (final seg in filePath.replaceAll('\\', '/').split('/')) {
      final String s = seg.trim();
      if (s == '$year' || localizedYear.hasMatch(s)) return true;
    }
    return false;
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
    this.orphanJsonAssociations = 0,
    this.orphanJsonUnmatched = 0,
  });

  final int yearFolderFiles;
  final int albumFolderFiles;
  final int extrasSkipped;

  /// Album associations recovered from orphaned album JSON sidecars (issue #133).
  final int orphanJsonAssociations;

  /// Orphaned album JSON sidecars whose asset could not be found anywhere.
  final int orphanJsonUnmatched;
}

class _ScanResult {
  const _ScanResult({
    required this.yearFolderFiles,
    required this.albumFolderFiles,
    this.orphanJsonAssociations = 0,
    this.orphanJsonUnmatched = 0,
  });

  final int yearFolderFiles;
  final int albumFolderFiles;
  final int orphanJsonAssociations;
  final int orphanJsonUnmatched;
}

enum _DirectoryType { year, album, other }
