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

    logPrint('[Step 5/8] Finding albums...');

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
      width: 50,
      percentage: true,
    );

    final int total = collection.length;
    int lastBarUpdate = -1;

    void tickBar(final int i) {
      // Update at most once per 0.5 % step (every ~200 items for a 40k
      // collection) to avoid locking the TTY on every entity.
      final int pct = ((i + 1) * 200) ~/ total; // 0..200 range
      if (pct != lastBarUpdate || i + 1 == total) {
        lastBarUpdate = pct;
        progressBar.update(i + 1);
      }
    }

    for (int i = 0; i < total; i++) {
      final mediaEntity = collection[i];
      final Map<String, AlbumEntity> albumsMap = mediaEntity.albumsMap;

      if (albumsMap.isEmpty) {
        tickBar(i);
        continue;
      }
      mediaWithAlbums++;

      // Single pass: sanitize album names + enrich source directories together
      // to avoid iterating albumsMap entries twice and to make only one
      // Map.from copy when mutations are needed.
      Map<String, AlbumEntity> updatedAlbumsMap = albumsMap;
      bool changed = false;

      for (final entry in albumsMap.entries) {
        String key = entry.key;
        // Use the current value from updatedAlbumsMap so that sanitized-key
        // collisions from earlier iterations are not overwritten.
        AlbumEntity info = identical(updatedAlbumsMap, albumsMap)
            ? entry.value
            : (updatedAlbumsMap[key] ?? entry.value);

        // 1) Sanitize album name
        final String sanitized = _sanitizeAlbumName(key);
        if (sanitized != key) {
          if (identical(updatedAlbumsMap, albumsMap)) {
            updatedAlbumsMap = Map<String, AlbumEntity>.from(albumsMap);
          }
          final AlbumEntity? existing = updatedAlbumsMap[sanitized];
          info = existing == null ? entry.value : existing.merge(entry.value);
          updatedAlbumsMap
            ..remove(key)
            ..[sanitized] = info;
          key = sanitized;
          changed = true;
        }

        // 2) Enrich source directory
        if (info.sourceDirectories.isEmpty) {
          if (identical(updatedAlbumsMap, albumsMap)) {
            updatedAlbumsMap = Map<String, AlbumEntity>.from(albumsMap);
          }
          final String parent = _safeParentDir(mediaEntity.primaryFile);
          updatedAlbumsMap[key] = info.addSourceDir(parent);
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

      // Stats: use updatedAlbumsMap directly — avoids a collection re-index.
      for (final albumName in updatedAlbumsMap.keys) {
        if (albumName.trim().isEmpty) continue;
        albumCounts[albumName] = (albumCounts[albumName] ?? 0) + 1;
      }

      tickBar(i);
    }

    // Ensure the next logs start on a new line after the bar.
    // FillingBar writes "\r" + frame on every update(); without a trailing
    // newline the last frame bleeds into subsequent output (and when stdout
    // is not a TTY, "\r" doesn't return the cursor so frames concatenate).
    stdout.writeln();

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
