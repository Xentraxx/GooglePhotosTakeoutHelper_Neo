import 'dart:async';
import 'dart:io';
import 'package:gpth_neo/gpth_lib_exports.dart';

/// Service for detecting and managing album relationships between media files
///
/// This service handles the complex logic of merging media files that appear
/// in both year-based folders and album folders, maintaining all file associations
/// while choosing the best metadata.
class AlbumRelationshipService with LoggerMixin {
  /// Creates a new album relationship service
  AlbumRelationshipService({final MediaHashService? hashService})
    : _hashService = hashService ?? MediaHashService();

  final MediaHashService _hashService;

  /// Finds and merges album relationships in a list of media entities
  ///
  /// This processes media files that appear in multiple locations (year folders
  /// and album folders) and merges them into single entities with all file
  /// associations preserved.
  ///
  /// Returns a new list with merged entities, where duplicates have been
  /// combined and the best metadata has been preserved.
  Future<List<MediaEntity>> detectAndMergeAlbums(
    final List<MediaEntity> mediaList,
  ) async {
    if (mediaList.isEmpty) {
      return [];
    }

    logInfo('Starting album detection for ${mediaList.length} media files');

    // Group identical media by content (optimized: pre-group by file size)
    final identicalGroups = await _groupIdenticalMediaOptimized(mediaList);

    final List<MediaEntity> mergedResults = [];
    int mergedCount = 0;

    // Process each group of identical media
    for (final group in identicalGroups.values) {
      if (group.length <= 1) {
        // No duplicates to merge
        mergedResults.addAll(group);
      } else {
        // Merge the group into a single entity
        final merged = _mergeMediaGroup(group);
        mergedResults.add(merged);
        mergedCount += group.length - 1; // Count how many were merged
      }
    }

    logInfo('Album detection complete: merged $mergedCount duplicate files');
    logInfo('Final result: ${mergedResults.length} unique media files');

    return mergedResults;
  }

  /// Optimized grouping strategy:
  /// 1) Pre-group by file size (cheap): unique sizes are not duplicates → no hash
  /// 2) For size groups with >1 items, compute SHA-256 via [MediaHashService]
  /// 3) Build content groups keyed by `<size>_<hash>`
  Future<Map<String, List<MediaEntity>>> _groupIdenticalMediaOptimized(
    final List<MediaEntity> mediaList,
  ) async {
    logInfo('Album detection: grouping by content');

    // 1) Collect file sizes concurrently
    final Map<int, List<MediaEntity>> sizeBuckets = <int, List<MediaEntity>>{};

    await Future.wait(
      mediaList.map((final entity) async {
        try {
          final File file = entity.primaryFile.asFile();
          final int size = await file.length();
          sizeBuckets.putIfAbsent(size, () => <MediaEntity>[]).add(entity);
        } catch (e) {
          logWarning(
            'Skipping file during size pass due to error: ${entity.primaryFile.path} - $e',
          );
          sizeBuckets.putIfAbsent(-1, () => <MediaEntity>[]).add(entity);
        }
      }),
    );

    // 2) For buckets with count == 1 → unique group per item (no hash needed)
    //    For buckets with count > 1 → compute hash and group by '<size>_<hash>'
    final Map<String, List<MediaEntity>> groups = <String, List<MediaEntity>>{};
    final List<Future<void>> hashingTasks = <Future<void>>[];

    sizeBuckets.forEach((final int size, final List<MediaEntity> bucket) {
      if (size <= 0) {
        // Unprocessable files (errors): group by unique path to avoid merging
        for (final entity in bucket) {
          final key = 'unprocessable_${entity.primaryFile.path}';
          groups.putIfAbsent(key, () => <MediaEntity>[]).add(entity);
        }
        return;
      }

      if (bucket.length == 1) {
        // Unique size → cannot be duplicate; keep as its own group
        final entity = bucket.first;
        final key = 'unique_${size}_${entity.primaryFile.path}';
        groups.putIfAbsent(key, () => <MediaEntity>[]).add(entity);
        return;
      }

      // Multiple files with the same size → potentially duplicates
      for (final entity in bucket) {
        hashingTasks.add(() async {
          try {
            final File file = entity.primaryFile.asFile();
            final String hashHex = await _hashService.calculateFileHash(file);
            final String contentKey = '${size}_$hashHex';
            groups.putIfAbsent(contentKey, () => <MediaEntity>[]).add(entity);
          } catch (e) {
            logWarning(
              'Hashing error, keeping as unique: ${entity.primaryFile.path} - $e',
            );
            final key = 'hash_error_${size}_${entity.primaryFile.path}';
            groups.putIfAbsent(key, () => <MediaEntity>[]).add(entity);
          }
        }());
      }
    });

    await Future.wait(hashingTasks);

    return groups;
  }

  /// Merges a group of identical media entities into a single entity
  ///
  /// Combines all file associations and preserves the best metadata
  /// from all entities in the group. The merging process:
  /// 1. Starts with the first entity as the base
  /// 2. Iteratively merges each additional entity
  /// 3. Combines file associations from all entities
  /// 4. Preserves all album relationships
  MediaEntity _mergeMediaGroup(final List<MediaEntity> group) {
    if (group.isEmpty) {
      throw ArgumentError('Cannot merge empty group');
    }
    if (group.length == 1) {
      return group.first;
    }
    // Start with the first entity and merge others into it
    MediaEntity result = group.first;
    for (int i = 1; i < group.length; i++) {
      result = result.mergeWith(group[i]);
    }

    return result;
  }

  /// Finds media entities that exist in albums
  List<MediaEntity> findAlbumMedia(final List<MediaEntity> mediaList) =>
      mediaList.where((final entity) => entity.hasAlbumAssociations).toList();

  /// Finds media entities that only exist in year-based organization
  List<MediaEntity> findYearOnlyMedia(final List<MediaEntity> mediaList) =>
      mediaList
          .where(
            (final entity) =>
                !entity.hasAlbumAssociations && entity.hasYearBasedFiles,
          )
          .toList();

  /// Gets statistics about album associations
  AlbumStatistics getAlbumStatistics(final List<MediaEntity> mediaList) {
    final albumMedia = findAlbumMedia(mediaList);
    final yearOnlyMedia = findYearOnlyMedia(mediaList);

    // Count unique albums
    final allAlbums = <String>{};
    for (final entity in albumMedia) {
      allAlbums.addAll(entity.albumNames);
    }

    // Count files with multiple album associations
    final multiAlbumFiles = albumMedia
        .where((final entity) => entity.albumNames.length > 1)
        .length;

    return AlbumStatistics(
      totalFiles: mediaList.length,
      albumFiles: albumMedia.length,
      yearOnlyFiles: yearOnlyMedia.length,
      uniqueAlbums: allAlbums.length,
      multiAlbumFiles: multiAlbumFiles,
      albumNames: allAlbums,
    );
  }
}

/// Statistics about album detection and organization
class AlbumStatistics {
  const AlbumStatistics({
    required this.totalFiles,
    required this.albumFiles,
    required this.yearOnlyFiles,
    required this.uniqueAlbums,
    required this.multiAlbumFiles,
    required this.albumNames,
  });

  final int totalFiles;
  final int albumFiles;
  final int yearOnlyFiles;
  final int uniqueAlbums;
  final int multiAlbumFiles;
  final Set<String> albumNames;

  @override
  String toString() =>
      'AlbumStatistics('
      'total: $totalFiles, '
      'in albums: $albumFiles, '
      'year-only: $yearOnlyFiles, '
      'albums: $uniqueAlbums, '
      'multi-album files: $multiAlbumFiles'
      ')';
}
