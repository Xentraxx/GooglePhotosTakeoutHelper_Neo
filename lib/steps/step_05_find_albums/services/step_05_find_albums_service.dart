// Service - FindAlbumService (new)
import 'dart:io';
import 'package:console_bars/console_bars.dart';
import 'package:gpth_neo/gpth_lib_exports.dart';

class FindAlbumService with LoggerMixin {
  const FindAlbumService();

  /// Executes the full Step 5 business logic (moved from the wrapper's execute).
  /// Preserves original behavior, logging, stats and outputs.
  Future<FindAlbumSummary> findAlbums(final ProcessingContext context) async {
    final sw = Stopwatch()..start();

    logPrint('[Step 5/8] Finding albums (this may take a while)...');

    final collection = context.mediaCollection;
    final initial = collection.length;

    if (collection.isEmpty) {
      sw.stop();
      return const FindAlbumSummary(
        message: 'No media to process.',
        initialCount: 0,
        finalCount: 0,
        mergedCount: 0,
        albumsMerged: 0,
        groupsMerged: 0,
        mediaWithAlbums: 0,
        distinctAlbums: 0,
        albumCounts: <String, int>{},
        enrichedAlbumInfos: 0,
      );
    }

    // Consolidation over current entities (no content merges; Step 3 already did it)
    int mediaWithAlbums = 0;
    int enrichedAlbumInfos = 0;
    final Map<String, int> albumCounts = <String, int>{};

    final progressBar = FillingBar(
      desc: '[ INFO  ] [Step 5/8] Processing album associations',
      total: collection.length,
      width: defaultBarWidth,
      percentage: true,
    );

    for (int i = 0; i < collection.length; i++) {
      final mediaEntity = collection[i];
      final Map<String, AlbumEntity> albumsMap = mediaEntity.albumsMap;

      if (albumsMap.isEmpty) continue;
      mediaWithAlbums++;

      Map<String, AlbumEntity> updatedAlbumsMap = albumsMap;
      bool changed = false;

      // 1) Sanitize album names (trim) and merge if the normalized key collides.
      for (final album in albumsMap.entries) {
        final String origName = album.key;
        final String sanitized = _sanitizeAlbumName(origName);
        if (sanitized != origName) {
          final AlbumEntity existing = album.value;
          final AlbumEntity merged = (updatedAlbumsMap[sanitized] == null)
              ? existing
              : updatedAlbumsMap[sanitized]!.merge(existing);
          if (identical(updatedAlbumsMap, albumsMap)) {
            updatedAlbumsMap = Map<String, AlbumEntity>.from(albumsMap)
              ..remove(origName)
              ..[sanitized] = merged;
          } else {
            updatedAlbumsMap
              ..remove(origName)
              ..[sanitized] = merged;
          }
          changed = true;
        }
      }

      // 2) Ensure at least one sourceDirectory per existing membership.
      for (final entry in updatedAlbumsMap.entries) {
        final AlbumEntity info = entry.value;
        if (info.sourceDirectories.isEmpty) {
          final String parent = _safeParentDir(mediaEntity.primaryFile);
          final AlbumEntity patched = info.addSourceDir(parent);
          if (!identical(updatedAlbumsMap, albumsMap) || changed) {
            updatedAlbumsMap = Map<String, AlbumEntity>.from(updatedAlbumsMap)
              ..[entry.key] = patched;
          } else {
            updatedAlbumsMap = Map<String, AlbumEntity>.from(albumsMap)
              ..[entry.key] = patched;
          }
          enrichedAlbumInfos++;
          changed = true;
        }
      }

      // Apply updates if any
      if (changed) {
        final updatedEntity = MediaEntity(
          primaryFile: mediaEntity.primaryFile,
          secondaryFiles: mediaEntity.secondaryFiles,
          albumsMap: updatedAlbumsMap,
          dateTaken: mediaEntity.dateTaken,
          dateAccuracy: mediaEntity.dateAccuracy,
          dateTimeExtractionMethod: mediaEntity.dateTimeExtractionMethod,
          partnershared: mediaEntity.partnerShared,
        );
        collection.replaceAt(i, updatedEntity);
      }

      // Stats (use sanitized keys from the possibly updated entity)
      for (final albumName in collection[i].albumsMap.keys) {
        if (albumName.trim().isEmpty) continue;
        albumCounts[albumName] = (albumCounts[albumName] ?? 0) + 1;
      }

      progressBar.update(i + 1);
    }

    final int totalAlbums = albumCounts.length;
    final int finalCount = collection.length;
    const int mergedCount = 0; // no entity-level merges in the new model

    logPrint('[Step 5/8] Media with album associations: $mediaWithAlbums');
    logPrint('[Step 5/8] Distinct album folders detected: $totalAlbums');

    sw.stop();
    return FindAlbumSummary(
      message:
          'Found $totalAlbums different albums ($mergedCount albums were merged)',
      initialCount: initial,
      finalCount: finalCount,
      mergedCount: mergedCount,
      albumsMerged: 0,
      groupsMerged: 0,
      mediaWithAlbums: mediaWithAlbums,
      distinctAlbums: totalAlbums,
      albumCounts: albumCounts,
      enrichedAlbumInfos: enrichedAlbumInfos,
    );
  }

  // ───────────────────────────── Helpers ─────────────────────────────

  String _sanitizeAlbumName(final String name) {
    final n = name.trim();
    return n.isEmpty ? name : n;
    // English note: keep a minimal normalization to avoid merging visually-equal names with leading/trailing spaces.
  }

  /// Returns parent directory path from a FileEntity effective path (targetPath if present, else sourcePath).
  String _safeParentDir(final FileEntity fe) {
    try {
      final String p = fe.path; // effective path (target if moved)
      return File(p).parent.path;
    } catch (_) {
      return '';
    }
  }
}

class FindAlbumSummary {
  const FindAlbumSummary({
    required this.message,
    required this.initialCount,
    required this.finalCount,
    required this.mergedCount,
    required this.albumsMerged,
    required this.groupsMerged,
    required this.mediaWithAlbums,
    required this.distinctAlbums,
    required this.albumCounts,
    required this.enrichedAlbumInfos,
  });

  final String message;
  final int initialCount;
  final int finalCount;
  final int mergedCount;
  final int albumsMerged;
  final int groupsMerged;
  final int mediaWithAlbums;
  final int distinctAlbums;
  final Map<String, int> albumCounts;
  final int enrichedAlbumInfos;

  Map<String, dynamic> toMap() => {
    'initialCount': initialCount,
    'finalCount': finalCount,
    'mergedCount': mergedCount,
    'albumsMerged': albumsMerged,
    'groupsMerged': groupsMerged,
    'mediaWithAlbums': mediaWithAlbums,
    'distinctAlbums': distinctAlbums,
    'albumCounts': albumCounts,
    'enrichedAlbumInfos': enrichedAlbumInfos,
  };
}
