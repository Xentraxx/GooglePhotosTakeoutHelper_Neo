// ignore_for_file: unintended_html_in_doc_comment

import 'dart:collection';
import 'package:gpth_neo/gpth_lib_exports.dart';

/// Modern domain model representing a collection of media entities (slim version).
/// This class is now a pure container; the heavy logic for steps 3–6
/// lives inside each step's `execute`.
class MediaEntityCollection with LoggerMixin {
  MediaEntityCollection([final List<MediaEntity>? initial])
    : _media = initial?.toList(growable: true) ?? <MediaEntity>[];

  final List<MediaEntity> _media;

  /// Read-only snapshot
  List<MediaEntity> get media => List.unmodifiable(_media);

  /// Number of media items in the collection
  int get length => _media.length;

  /// Whether the collection is empty
  bool get isEmpty => _media.isEmpty;

  bool get isNotEmpty => _media.isNotEmpty;

  /// Iterable view
  Iterable<MediaEntity> get entities => _media;

  /// Indexer (read)
  MediaEntity operator [](final int index) => _media[index];

  /// Indexer (write/replace one)
  void operator []=(final int index, final MediaEntity entity) {
    _media[index] = entity;
  }

  /// Append one
  void add(final MediaEntity entity) => _media.add(entity);

  /// Append many
  void addAll(final Iterable<MediaEntity> entities) => _media.addAll(entities);

  /// Remove one (by identity/equality)
  bool remove(final MediaEntity entity) => _media.remove(entity);

  /// Clear all
  void clear() => _media.clear();

  /// Replace at index
  void replaceAt(final int index, final MediaEntity entity) {
    _media[index] = entity;
  }

  /// Replace entire content in one shot
  void replaceAll(final List<MediaEntity> newList) {
    _media
      ..clear()
      ..addAll(newList);
  }

  /// Return a modifiable copy of the internal list
  List<MediaEntity> asList() => List<MediaEntity>.from(_media);

  // Backward compat helpers (used by some steps)
  void addOrReplaceAt(final int index, final MediaEntity entity) {
    if (index >= 0 && index < _media.length) {
      _media[index] = entity;
    } else if (index == _media.length) {
      _media.add(entity);
    } else {
      throw RangeError.index(index, _media, 'index', null, _media.length);
    }
  }

  // ───────────────────────────────────────────────────────────────────────────
  // Statistics (restored): provides collection-level processing statistics
  // ───────────────────────────────────────────────────────────────────────────

  /// Get processing statistics for the collection
  ///
  /// Returns comprehensive statistics about the media collection including
  /// file counts, date information, and extraction method distribution.
  ProcessingStatistics getStatistics() {
    var mediaWithDates = 0;
    var mediaWithAlbums = 0;
    var totalFiles = 0;
    final extractionMethodDistribution = <DateTimeExtractionMethod, int>{};

    for (final mediaEntity in _media) {
      // Count media with dates
      if (mediaEntity.dateTaken != null) {
        mediaWithDates++;
      }

      // Count media with album associations (metadata)
      if (mediaEntity.albumsMap.isNotEmpty) {
        mediaWithAlbums++;
      }

      // Count total files: primary + secondaries
      totalFiles += 1 + mediaEntity.secondaryFiles.length;

      // Track extraction method distribution
      final method =
          mediaEntity.dateTimeExtractionMethod ?? DateTimeExtractionMethod.none;
      extractionMethodDistribution[method] =
          (extractionMethodDistribution[method] ?? 0) + 1;
    }

    return ProcessingStatistics(
      totalMedia: _media.length,
      mediaWithDates: mediaWithDates,
      mediaWithAlbums: mediaWithAlbums,
      totalFiles: totalFiles,
      extractionMethodDistribution: extractionMethodDistribution,
    );
  }

  // Remove a set of entities in a single pass O(N + R)
  void removeAll(final Iterable<MediaEntity> items) {
    // Convert to Set for O(1) membership checks
    final Set<MediaEntity> s = HashSet<MediaEntity>.identity()..addAll(items);
    // IMPORTANT: operate over the internal mutable list
    _media.removeWhere(s.contains);
  }

  // Apply kept0 → kept replacements in one linear scan O(N)
  void applyReplacements(final Map<MediaEntity, MediaEntity> mapping) {
    for (int i = 0; i < _media.length; i++) {
      final MediaEntity current = _media[i];
      final MediaEntity? repl = mapping[current];
      if (repl != null) {
        _media[i] = repl;
      }
    }
  }
}

/// Statistics about processed media collection
class ProcessingStatistics {
  const ProcessingStatistics({
    required this.totalMedia,
    required this.mediaWithDates,
    required this.mediaWithAlbums,
    required this.totalFiles,
    required this.extractionMethodDistribution,
  });

  final int totalMedia;
  final int mediaWithDates;
  final int mediaWithAlbums;
  final int totalFiles;
  final Map<DateTimeExtractionMethod, int> extractionMethodDistribution;
}
