import 'dart:async';
import 'package:gpth_neo/gpth_lib_exports.dart';

/// Service for grouping media files by content similarity
///
/// This service provides optimized algorithms for grouping media files
/// by their content (size and hash) for duplicate detection and
/// album organization purposes.
class ContentGroupingService with LoggerMixin {
  /// Creates a new content grouping service
  ContentGroupingService() : _hashService = MediaHashService();

  final MediaHashService _hashService;

  /// Maximum number of concurrent operations to prevent system overload
  int get _maxConcurrency =>
      ConcurrencyManager().concurrencyFor(ConcurrencyOperation.duplicate);

  /// Groups media entities by their content (size and hash)
  ///
  /// Returns a map where:
  /// - Key: Either "XXXbytes" for unique sizes, or hash string for duplicates
  /// - Value: List of MediaEntity objects sharing that size/hash
  ///
  /// Single-item groups indicate unique files, multi-item groups are duplicates
  Future<Map<String, List<MediaEntity>>> groupByContent(
    final List<MediaEntity> mediaList,
  ) async {
    if (mediaList.isEmpty) {
      return {};
    }

    logInfo('Grouping ${mediaList.length} media files by content');

    return _groupByContentParallel(mediaList);
  }

  /// Optimized parallel implementation with concurrency control
  Future<Map<String, List<MediaEntity>>> _groupByContentParallel(
    final List<MediaEntity> mediaList,
  ) async {
    final Map<String, List<MediaEntity>> output = {};

    // Step 1: Calculate all sizes in parallel with concurrency limit
    logInfo('Calculating file sizes in parallel...');
    final sizeResults = await _calculateSizesParallel(mediaList);

    // Group by size
    final sizeGroups = <int, List<MediaEntity>>{};
    for (final entry in sizeResults) {
      sizeGroups.putIfAbsent(entry.size, () => []).add(entry.entity);
    }

    logInfo('Found ${sizeGroups.length} unique file sizes');

    // Step 2: Calculate hashes for groups with multiple files
    logInfo('Calculating hashes for potential duplicates...');
    int hashCalculations = 0;

    for (final MapEntry<int, List<MediaEntity>> sameSize
        in sizeGroups.entries) {
      if (sameSize.value.length <= 1) {
        // Single file with this size - no duplicates
        output['${sameSize.key}bytes'] = sameSize.value;
      } else {
        // Multiple files with same size - calculate hashes
        hashCalculations += sameSize.value.length;
        final hashGroups = await _calculateHashesParallel(sameSize.value);
        output.addAll(hashGroups);
      }
    }

    logInfo('Calculated hashes for $hashCalculations files');
    logInfo('Grouping complete: ${output.length} content groups found');

    return output;
  }

  /// Calculates file sizes in parallel with concurrency control
  Future<List<({MediaEntity entity, int size})>> _calculateSizesParallel(
    final List<MediaEntity> mediaList,
  ) async {
    final results = <({MediaEntity entity, int size})>[];
    final concurrency = _maxConcurrency;

    // Log concurrency usage for consistency
    logDebug(
      'Starting $concurrency threads (duplicate size calculation concurrency)',
    );

    for (int i = 0; i < mediaList.length; i += _maxConcurrency) {
      final batch = mediaList.skip(i).take(_maxConcurrency);
      final futures = batch.map((final entity) async {
        final size = await entity.primaryFile.asFile().length();
        return (entity: entity, size: size);
      });

      final batchResults = await Future.wait(futures);
      results.addAll(batchResults);
    }

    return results;
  }

  /// Calculates hashes for media files in parallel
  Future<Map<String, List<MediaEntity>>> _calculateHashesParallel(
    final List<MediaEntity> mediaWithSameSize,
  ) async {
    final hashResults = <({MediaEntity entity, String hash})>[];
    final concurrency = _maxConcurrency;

    // Log concurrency usage for consistency
    logDebug(
      'Starting $concurrency threads (duplicate hash calculation concurrency)',
    );

    for (int i = 0; i < mediaWithSameSize.length; i += _maxConcurrency) {
      final batch = mediaWithSameSize.skip(i).take(_maxConcurrency);
      final futures = batch.map((final entity) async {
        final hash = await _calculateContentHash(entity);
        return (entity: entity, hash: hash);
      });

      final batchResults = await Future.wait(futures);
      hashResults.addAll(batchResults);
    }

    // Group by hash
    final hashGroups = <String, List<MediaEntity>>{};
    for (final entry in hashResults) {
      hashGroups.putIfAbsent(entry.hash, () => []).add(entry.entity);
    }

    return hashGroups;
  }

  /// Calculates content hash for a media entity
  Future<String> _calculateContentHash(final MediaEntity entity) =>
      _hashService.calculateFileHash(entity.primaryFile.asFile());

  /// Finds groups that contain duplicates (more than one file)
  Map<String, List<MediaEntity>> findDuplicateGroups(
    final Map<String, List<MediaEntity>> contentGroups,
  ) => Map.fromEntries(
    contentGroups.entries.where((final entry) => entry.value.length > 1),
  );

  /// Gets statistics about the grouping results
  GroupingStatistics getStatistics(
    final Map<String, List<MediaEntity>> contentGroups,
  ) {
    final duplicateGroups = findDuplicateGroups(contentGroups);
    final totalFiles = contentGroups.values.fold(
      0,
      (final sum, final group) => sum + group.length,
    );
    final duplicateFiles = duplicateGroups.values.fold(
      0,
      (final sum, final group) => sum + group.length,
    );
    final uniqueFiles = totalFiles - duplicateFiles;

    return GroupingStatistics(
      totalFiles: totalFiles,
      uniqueFiles: uniqueFiles,
      duplicateFiles: duplicateFiles,
      duplicateGroups: duplicateGroups.length,
      contentGroups: contentGroups.length,
    );
  }
}

/// Statistics about media grouping results
class GroupingStatistics {
  const GroupingStatistics({
    required this.totalFiles,
    required this.uniqueFiles,
    required this.duplicateFiles,
    required this.duplicateGroups,
    required this.contentGroups,
  });

  final int totalFiles;
  final int uniqueFiles;
  final int duplicateFiles;
  final int duplicateGroups;
  final int contentGroups;

  @override
  String toString() =>
      'GroupingStatistics('
      'total: $totalFiles, '
      'unique: $uniqueFiles, '
      'duplicates: $duplicateFiles in $duplicateGroups groups, '
      'content groups: $contentGroups'
      ')';
}
