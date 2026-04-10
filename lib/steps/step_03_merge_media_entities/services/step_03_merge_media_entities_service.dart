import 'dart:collection';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:console_bars/console_bars.dart';
import 'package:gpth_neo/gpth_lib_exports.dart';
import 'package:path/path.dart' as path;
import 'package:xxh3/xxh3.dart';

/// Service for detecting duplicate media files based on content hash and size
///
/// This service provides efficient duplicate detection by first grouping files
/// by size (fast comparison), then calculating content hashes only for files
/// with matching sizes. Uses parallel processing with adaptive concurrency limits to
/// balance performance with system resource usage and automatically adjusts
/// batch sizes based on system performance.
class MergeMediaEntitiesService with LoggerMixin {
  /// Creates a new instance of DuplicateDetectionService
  MergeMediaEntitiesService({final MediaHashService? hashService})
    : _hashService = hashService ?? MediaHashService();

  final MediaHashService _hashService;

  /// Extensions treated as video/large-seek assets (low read-concurrency).
  static const Set<String> _videoExts = {
    'mp4',
    'mov',
    'm4v',
    'mkv',
    'avi',
    'hevc',
    'heif',
    'heic',
    'webm',
  };

  /// Performance monitoring for adaptive optimization
  final List<double> _recentPerformanceMetrics = [];
  static const int _maxPerformanceHistory = 10;

  /// Base concurrency multiplier based on CPU cores
  static int get baseConcurrency => ConcurrencyManager().cpuCoreCount;

  /// Adaptive concurrency based on recent performance
  int get adaptiveConcurrency => ConcurrencyManager().getAdaptiveConcurrency(
    _recentPerformanceMetrics,
    baseLevel: ConcurrencyManager().conservative,
  );

  /// Maximum number of concurrent operations to prevent overwhelming the system
  static int get maxConcurrency =>
      ConcurrencyManager().concurrencyFor(ConcurrencyOperation.duplicate);

  /// Records performance metric for adaptive optimization
  void _recordPerformance(final int filesProcessed, final Duration elapsed) {
    final filesPerSecond =
        filesProcessed / elapsed.inSeconds.clamp(1, double.infinity);
    _recentPerformanceMetrics.add(filesPerSecond);

    // Keep only recent metrics
    if (_recentPerformanceMetrics.length > _maxPerformanceHistory) {
      _recentPerformanceMetrics.removeAt(0);
    }

    // logDebug('[Step 3/8] Performance: ${filesPerSecond.toStringAsFixed(1)} files/sec, adaptive concurrency: $adaptiveConcurrency');
  }

  // ─────────────────────────────── NEW: full Step-3 logic moved from the wrapper's execute ───────────────────────────────
  /// Full Step 3 business logic moved from the wrapper:
  /// Orchestrator: keeps the public API stable and do the below actions.
  /// - Builds size/extension/quick buckets
  /// - Groups by content using groupIdenticalFast2/groupIdenticalFast/groupIdenticalLegacy (you can swap to groupIdenticalFast or groupIdenticalLegacy)
  /// - Verifies selected groups based on environment flag
  /// - Merges MediaEntity instances, removes merged-away entities from collection
  /// - Removes or quarantines duplicate files on disk based on configuration
  /// - Emits telemetry and detailed logs (printed here in the orchestrator)
  ///
  /// Returns a summary with all counters and timings expected by the wrapper.
  Future<MergeMediaEntitiesSummary> executeMergeMediaEntitiesLogic(
    final ProcessingContext context,
  ) async {
    final mediaCollection = context.mediaCollection;

    // Overall stopwatch for the whole merge step
    final Stopwatch totalSw = Stopwatch()..start();

    logPrint(
      '[Step 3/8] Merging identical media entities and removing duplicates (this may take a while)...',
    );
    if (context.config.keepDuplicates) {
      logPrint(
        "[Step 3/8] Flag '--keep-duplicates' detected. Duplicates will be moved to '_Duplicates' subfolder within output folder",
      );
    }

    // We will accumulate final telemetry here (grouping + merge + IO)
    final _Telemetry telem = _Telemetry();

    // ────────────────────────────────────────────────────────────────────────
    // Phase 1: identification & grouping (select ONE strategy)
    // NOTE: all grouping functions return a Map<String, List<MediaEntity>> with the same API.
    // To compare strategies, chose only one of the following 3 lines:
    // final Map<String, List<MediaEntity>> groups = await groupIdentical(mediaCollection.entities.toList(), telemetryObject: telem);
    // final Map<String, List<MediaEntity>> groups = await groupIdenticalFast(mediaCollection.entities.toList(), telemetryObject: telem);
    final Map<String, List<MediaEntity>> groups = await groupIdenticalFast2(
      mediaCollection.entities.toList(),
      telemetryObject: telem,
    );

    // ────────────────────────────────────────────────────────────────────────
    // Phase 2: apply merges into the collection (mutates collection)
    final Stopwatch mergeSw = Stopwatch()..start();
    final int mergedEntities = await mergeDuplicateEntities(
      mediaCollection,
      groups,
    );
    mergeSw.stop();
    telem.msMergeReplace = mergeSw.elapsedMilliseconds;
    telem.entitiesMergedByContent =
        mergedEntities; // feed classic telemetry field

    // ────────────────────────────────────────────────────────────────────────
    // Phase 3: move/delete within-folder duplicates (NO telemetry printed here)
    final Stopwatch ioSw = Stopwatch()..start();
    final removal = await removeQuarantineDuplicates(
      context,
      mediaCollection,
      telemetryObject: telem,
    );

    ioSw.stop();
    telem.msRemoveIO = ioSw.elapsedMilliseconds;

    // Primary counts (with canonical vs albums split)
    final int totalPrimaryFiles = mediaCollection.length;
    int primaryCanonical = 0;
    int primaryFromAlbums = 0;
    for (final e in mediaCollection.entities) {
      if (e.primaryFile.isCanonical) {
        primaryCanonical++;
      } else {
        primaryFromAlbums++;
      }
    }

    // Secondary counts (with canonical vs albums split)
    int totalSecondaryFiles = 0;
    int secondaryCanonical = 0;
    int secondaryFromAlbums = 0;
    for (final e in mediaCollection.entities) {
      for (final fe in e.secondaryFiles) {
        totalSecondaryFiles++;
        if (fe.isCanonical) {
          secondaryCanonical++;
        } else {
          secondaryFromAlbums++;
        }
      }
    }

    // Totals across ALL FileEntity (primary + secondary)
    final int canonicalAll = primaryCanonical + secondaryCanonical;
    final int nonCanonicalAll = primaryFromAlbums + secondaryFromAlbums;

    // Stop total and store before printing telemetry
    totalSw.stop();
    telem.msTotal = totalSw.elapsedMilliseconds;

    // Print telemetry once here (classic full block restored)
    if (ServiceContainer
        .instance
        .globalConfig
        .enableTelemetryInMergeMediaEntitiesStep) {
      _printTelemetryFull(
        telem,
        loggerMixin: this,
        secondaryFilesInCollection: totalSecondaryFiles,
        duplicateFilesRemovedIO: removal.duplicateFilesRemoved,
        primaryFilesInCollection: totalPrimaryFiles,
        canonicalFilesInCollection: canonicalAll,
        nonCanonicalFilesInCollection: nonCanonicalAll,
        printTelemetry: true, // screen on
      );
    }

    // Final “summary” block (NOT telemetry)
    logPrint('[Step 3/8] === Merge Media Entity Summary ===');
    logPrint(
      '[Step 3/8]     Initial Entities in collection               : ${mediaCollection.length + mergedEntities}',
    );
    logPrint(
      '[Step 3/8]         Duplicate files removed/moved            : ${removal.duplicateFilesRemoved}',
    );
    logPrint(
      '[Step 3/8]         Primary + Secondary files                : ${totalPrimaryFiles + totalSecondaryFiles}',
    );
    logPrint(
      '[Step 3/8]             Primary files in collection          : $totalPrimaryFiles ($primaryCanonical canonical | $primaryFromAlbums from albums)',
    );
    logPrint(
      '[Step 3/8]             Secondary files in collection        : $totalSecondaryFiles ($secondaryCanonical canonical | $secondaryFromAlbums from albums)',
    );
    logPrint(
      '[Step 3/8]         Canonical + Non-Canonical files          : ${canonicalAll + nonCanonicalAll}',
    );
    logPrint(
      '[Step 3/8]             Canonical files (within year folder) : $canonicalAll ($primaryCanonical primary | $secondaryCanonical secondary)',
    );
    logPrint(
      '[Step 3/8]             Non-Canonical files (Albums)         : $nonCanonicalAll ($primaryFromAlbums primary | $secondaryFromAlbums secondary)',
    );
    logPrint(
      '[Step 3/8]     Total Entities merged                        : $mergedEntities',
    );
    logPrint(
      '[Step 3/8]     Media Entities remain in collection          : ${mediaCollection.length}',
    );

    return MergeMediaEntitiesSummary(
      message: 'Media Entities remain in collection: ${mediaCollection.length}',
      entitiesMerged: mergedEntities,
      remainingMedia: mediaCollection.length,
      sizeBuckets: telem.sizeBuckets,
      quickBuckets: telem.quickBuckets,
      hashGroups: telem.hashGroups,
      msTotal: telem.msTotal,
      msSizeScan: telem.msSizeScan,
      msQuickSig: telem.msQuickSig,
      msHashGroups: telem.msHashGroups,
      msMergeReplace: telem.msMergeReplace,
      msRemoveIO: telem.msRemoveIO,
      primaryFilesCount: totalPrimaryFiles,
      secondaryFilesDetected: totalSecondaryFiles,
      duplicateFilesRemoved: removal.duplicateFilesRemoved,
      canonicalAll: canonicalAll,
      nonCanonicalAll: nonCanonicalAll,
      primaryCanonical: primaryCanonical,
      primaryFromAlbums: primaryFromAlbums,
      secondaryCanonical: secondaryCanonical,
      secondaryFromAlbums: secondaryFromAlbums,
    );
  }

  /// —————————————————————————————————————————————————————————————————————————————
  /// Phase 1: Identification & grouping of duplicates (buckets-based strategy).
  /// Same API as groupIdentical and groupIdenticalFast: returns a Map.
  /// This phase does NOT mutate the collection; it only builds groups.
  /// —————————————————————————————————————————————————————————————————————————————
  Future<Map<String, List<MediaEntity>>> groupIdenticalFast2(
    final List<MediaEntity> mediaList, {
    final TelemetryLike? telemetryObject,
  }) async {
    final _Telemetry telem = telemetryObject ?? _Telemetry();
    telem.filesTotal = mediaList.length;

    // Total time of grouping strategy
    final Stopwatch groupingSw = Stopwatch()..start();

    // ────────────────────────────────────────────────────────────────────────
    // 1) SIZE BUCKETS (cheap pre-partition — done concurrently)
    // NOTE (perf): async file.length() is non-blocking on every platform;
    //              batching with Future.wait saturates disk I/O much better
    //              than serial lengthSync() which stalls the event loop.
    // ────────────────────────────────────────────────────────────────────────
    final Stopwatch sizeSw = Stopwatch()..start();
    final int maxWorkersSizeScan = ConcurrencyManager()
        .concurrencyFor(ConcurrencyOperation.exif)
        .clamp(8, 64);
    final Map<int, List<MediaEntity>> sizeBuckets = <int, List<MediaEntity>>{};
    for (int i = 0; i < mediaList.length; i += maxWorkersSizeScan) {
      final batch = mediaList.skip(i).take(maxWorkersSizeScan);
      final results = await Future.wait(
        batch.map((final e) async {
          try {
            return (e: e, size: await e.primaryFile.asFile().length());
          } catch (_) {
            return (e: e, size: -1);
          }
        }),
      );
      for (final r in results) {
        (sizeBuckets[r.size] ??= <MediaEntity>[]).add(r.e);
      }
    }
    sizeSw.stop();
    telem.msSizeScan += sizeSw.elapsedMilliseconds;
    telem.sizeBuckets = sizeBuckets.length;

    // Concurrency caps (conservative but higher than previous 1..8)
    // - maxWorkersBuckets: parallelism across size buckets (mix of IO & CPU)
    // - maxWorkersQuick  : parallelism inside ext-buckets for quick signatures (I/O-bound)
    final int maxWorkersBuckets = ConcurrencyManager()
        .concurrencyFor(ConcurrencyOperation.exif)
        .clamp(4, 24);
    final int maxWorkersQuick = ConcurrencyManager()
        .concurrencyFor(ConcurrencyOperation.exif)
        .clamp(4, 32);

    // NEW (perf): parallelize hash grouping inside ext-buckets, capped to avoid CPU oversubscription.
    // If your ConcurrencyOperation doesn't have a dedicated "hash", we reuse EXIF channel safely.
    final int maxWorkersHash = ConcurrencyManager()
        .concurrencyFor(ConcurrencyOperation.exif)
        .clamp(2, 16);

    // Process buckets in slices
    // PERF: flush trivially-unique size buckets (only 1 file) directly into
    //       output without touching the ext/quick-sig/hash pipeline.
    final Map<String, List<MediaEntity>> output = <String, List<MediaEntity>>{};
    final List<int> multiFileBucketKeys = <int>[];
    for (final entry in sizeBuckets.entries) {
      if (entry.value.length == 1) {
        final MediaEntity u = entry.value.first;
        output['${entry.key}bytes|${u.primaryFile.sourcePath}'] = [u];
      } else {
        multiFileBucketKeys.add(entry.key);
      }
    }
    // PERF: process largest multi-file buckets first for early dedup wins
    multiFileBucketKeys.sort(
      (final a, final b) =>
          sizeBuckets[b]!.length.compareTo(sizeBuckets[a]!.length),
    );
    int processedGroups = 0;
    final int totalGroups = multiFileBucketKeys.length;

    Future<void> processSizeBucket(final int sizeKey) async {
      final Map<String, List<MediaEntity>> extBuckets =
          <String, List<MediaEntity>>{};
      final Stopwatch extSw = Stopwatch()..start();
      for (final e in sizeBuckets[sizeKey]!) {
        final String ext = _extOf(e.primaryFile.path);
        (extBuckets[ext] ??= <MediaEntity>[]).add(e);
      }
      extSw.stop();
      telem.msExtBucket += extSw.elapsedMilliseconds;
      telem.extBuckets += extBuckets.length;

      // Helper (perf): adaptive parallelism for quick signatures
      // English note:
      // - Big/video files suffer with high seek concurrency. We reduce workers for those,
      //   and use higher concurrency for small files to fully utilize I/O.
      int quickWorkersFor(final int sz, final bool isVideo) {
        if (isVideo || sz >= (64 << 20)) {
          return 2; // ≥ 64MiB or video → very low concurrency
        }
        if (sz >= (8 << 20)) return 4; // 8–64 MiB
        if (sz >= (1 << 20)) return 8; // 1–8 MiB
        return 24; // < 1 MiB
      }

      for (final entry in extBuckets.entries) {
        final String extKey = entry.key; // extension for this bucket
        final List<MediaEntity> extGroup = entry.value;
        if (extGroup.length <= 1) {
          // Unique by extension-bucket + size → keep as unique marker (no hash needed)
          output['${sizeKey}bytes|${extGroup.first.primaryFile.sourcePath}'] = [
            extGroup.first,
          ];
          continue;
        }

        // ────────────────────────────────────────────────────────────────
        // 3) QUICK SIGNATURE (tri-sample: head+middle+tail, 4 KiB each)
        //    NOTE (perf): drastically reduces IO vs reading 64-128 KiB head.
        //    We also reuse the known 'sizeKey' to avoid per-file stat().
        //    Computed concurrently in small batches (no env vars needed).
        //    MODIFIED: open file only once and use FNV-1a 32-bit + adaptive 2-point for video/large.
        // ────────────────────────────────────────────────────────────────
        final Stopwatch qsigSw = Stopwatch()..start();
        final Map<String, List<MediaEntity>> quickBuckets =
            <String, List<MediaEntity>>{};

        final bool isVideoExt = _videoExts.contains(extKey);
        final int localQuickWorkers = quickWorkersFor(
          sizeKey,
          isVideoExt,
        ).clamp(1, maxWorkersQuick);

        for (int i = 0; i < extGroup.length; i += localQuickWorkers) {
          final slice = extGroup.skip(i).take(localQuickWorkers).toList();
          await Future.wait(
            slice.map((final e) async {
              String sig;
              try {
                final String ext = _extOf(e.primaryFile.path);
                sig = await _quickSignature(
                  e.primaryFile.asFile(),
                  sizeKey,
                  ext,
                );
              } catch (_) {
                sig = 'qsig-err';
              }
              (quickBuckets[sig] ??= <MediaEntity>[]).add(e);
            }),
          );
        }

        qsigSw.stop();
        telem.msQuickSig += qsigSw.elapsedMilliseconds;
        telem.quickBuckets += quickBuckets.length;

        // ────────────────────────────────────────────────────────────────
        // 4) HASH GROUPING inside each quick-bucket
        // ────────────────────────────────────────────────────────────────
        final qbLists = quickBuckets.values
            .where((final q) => q.length > 1)
            .toList();
        for (int i = 0; i < qbLists.length; i += maxWorkersHash) {
          final slice = qbLists.skip(i).take(maxWorkersHash).toList();
          final results = await Future.wait(
            slice.map((final q) async {
              final Stopwatch hashSw = Stopwatch()..start();
              Map<String, List<MediaEntity>> groups;
              try {
                groups = await _fullHashGroup(q);
              } catch (_) {
                groups = await groupIdenticalLegacy(
                  q.toList(),
                  telemetryObject: telem,
                ); // safe fallback
              }
              hashSw.stop();
              return _HashBatchResult(groups, hashSw.elapsedMilliseconds);
            }),
          );

          for (final r in results) {
            telem.msHashGroups += r.ms;
            telem.hashGroups += r.groups.length;
            r.groups.forEach((final k, final v) => output[k] = v);
          }
        }

        // Unique quick-buckets → mark as unique (avoid hashing)
        for (final entryQB in quickBuckets.entries) {
          if (entryQB.value.length == 1) {
            final MediaEntity u = entryQB.value.first;
            output['${sizeKey}bytes|${u.primaryFile.sourcePath}'] = [u];
          }
        }
      }
    }

    if (totalGroups > 0) {
      final FillingBar pbarGroups = FillingBar(
        total: totalGroups,
        width: 50,
        percentage: true,
        desc: '[ INFO  ] [Step 3/8] Hashing size groups  ',
      );
      pbarGroups.update(0);

      for (int i = 0; i < multiFileBucketKeys.length; i += maxWorkersBuckets) {
        final slice = multiFileBucketKeys
            .skip(i)
            .take(maxWorkersBuckets)
            .toList(growable: false);
        await Future.wait(slice.map(processSizeBucket));

        processedGroups += slice.length;
        pbarGroups.update(processedGroups);
      }
      stdout.writeln();
    }

    // close groupingSw
    groupingSw.stop();
    telem.msGrouping += groupingSw.elapsedMilliseconds;

    return output;
  }

  // ───────────────────────── Additional grouping methods APIs (non-breaking) ─────────────────────────
  /// Fast path duplicate grouping with tri-sample fingerprint prefilter.
  ///
  /// This reduces the number of full file hashes by first grouping by [size],
  /// then by a cheap fingerprint computed from three small slices (head/middle/tail).
  /// Only fingerprint-colliding subgroups get full content hashing.
  ///
  /// For tiny groups (≤3 files) we jump straight to full hashing to avoid overhead.
  Future<Map<String, List<MediaEntity>>> groupIdenticalFast(
    final List<MediaEntity> mediaList, {
    final TelemetryLike? telemetryObject,
    final int sampleSizeBytes = 64 * 1024,
  }) async {
    // 64 KiB per slice
    final _Telemetry telem = telemetryObject ?? _Telemetry();
    telem.filesTotal = mediaList.length;

    if (mediaList.isEmpty) return {};

    final Map<String, List<MediaEntity>> output = <String, List<MediaEntity>>{};
    final stopwatchTotal = Stopwatch()..start();

    // Phase 1: group by size (reuse existing logic but inline to avoid extra maps)
    final Stopwatch sizeSw = Stopwatch()..start();
    final sizeResults = <({MediaEntity media, int size})>[];
    final sizeBatch = (adaptiveConcurrency * 1.5).round();

    for (int i = 0; i < mediaList.length; i += sizeBatch) {
      final batch = mediaList.skip(i).take(sizeBatch);
      final futures = batch.map((final media) async {
        try {
          final size = await _hashService.calculateFileSize(
            File(media.primaryFile.sourcePath),
          );
          return (media: media, size: size);
        } catch (e) {
          logError(
            '[Step 3/8] Failed to get size for ${media.primaryFile.sourcePath}: $e',
          );
          return null;
        }
      });
      final res = await Future.wait(futures);
      sizeResults.addAll(res.whereType<({MediaEntity media, int size})>());

      if (mediaList.length > 1000) {
        final int processed = math.min(i + sizeBatch, mediaList.length).toInt();
        final double progress = (processed / mediaList.length * 100)
            .clamp(0, 100)
            .toDouble();
        logDebug(
          '[Step 3/8] Size calculation progress (FAST): ${progress.toStringAsFixed(1)}%',
        );
      }
    }
    sizeSw.stop();
    telem.msSizeScan += sizeSw.elapsedMilliseconds;

    final sizeGroups = <int, List<MediaEntity>>{};
    for (final entry in sizeResults) {
      sizeGroups
          .putIfAbsent(entry.size, () => <MediaEntity>[])
          .add(entry.media);
    }
    telem.sizeBuckets = sizeGroups.length;

    // Phase 2: inside each size group, tri-sample fingerprint, then full hash
    for (final MapEntry<int, List<MediaEntity>> sameSize
        in sizeGroups.entries) {
      final List<MediaEntity> group = sameSize.value;
      if (group.length <= 1) {
        output['${sameSize.key}bytes'] = group;
        continue;
      }

      if (group.length <= 3) {
        final Stopwatch hashSw = Stopwatch()..start();
        final Map<String, List<MediaEntity>> byHash = await _fullHashGroup(
          group,
        );
        hashSw.stop();
        telem.msHashGroups += hashSw.elapsedMilliseconds;
        telem.hashGroups += byHash.length;
        output.addAll(byHash);
        continue;
      }

      // 2a) fingerprint batching (cheap reads)
      final Stopwatch qsigSw = Stopwatch()..start();
      final Map<String, List<MediaEntity>> byFp = <String, List<MediaEntity>>{};
      final int fpBatch = math.max(1, adaptiveConcurrency);

      for (int i = 0; i < group.length; i += fpBatch) {
        final batch = group.skip(i).take(fpBatch);
        final futures = batch.map((final media) async {
          try {
            final f = File(media.primaryFile.sourcePath);
            final String fp = await _triSampleFingerprint(f, sampleSizeBytes);
            final key = '${sameSize.key}|$fp';
            return (media: media, key: key);
          } catch (e) {
            logError(
              '[Step 3/8] Fingerprint failed for ${media.primaryFile.sourcePath}: $e',
            );
            return (media: media, key: 'ERR|${media.primaryFile.sourcePath}');
          }
        });
        final res = await Future.wait(futures);
        for (final r in res) {
          (byFp[r.key] ??= <MediaEntity>[]).add(r.media);
        }
      }
      qsigSw.stop();
      telem.msQuickSig += qsigSw.elapsedMilliseconds;
      telem.quickBuckets += byFp.length;

      // 2b) only hash subgroups with >1
      for (final List<MediaEntity> fpSub in byFp.values) {
        if (fpSub.length == 1) {
          output['${sameSize.key}bytes|${fpSub.first.primaryFile.sourcePath}'] =
              [fpSub.first];
          continue;
        }
        final Stopwatch hashSw = Stopwatch()..start();
        final Map<String, List<MediaEntity>> byHash = await _fullHashGroup(
          fpSub,
        );
        hashSw.stop();
        telem.msHashGroups += hashSw.elapsedMilliseconds;
        telem.hashGroups += byHash.length;
        output.addAll(byHash);
      }
    }

    stopwatchTotal.stop();
    telem.msGrouping += stopwatchTotal.elapsedMilliseconds;

    _recordPerformance(mediaList.length, stopwatchTotal.elapsed);

    _hashService.getCacheStats();

    // Count and log duplicate groups found (debug)
    final duplicateGroups = output.values.where((final g) => g.length > 1);
    duplicateGroups.fold<int>(0, (final s, final g) => s + g.length - 1);

    return output;
  }

  /// Groups media entities by file size and hash for duplicate detection with caching
  ///
  /// Uses a three-phase approach for maximum efficiency:
  /// 1. Group by file size (fast comparison using existing file metadata)
  /// 2. For size-matching groups, calculate and compare content hashes (with caching)
  /// 3. Use batch processing with optimal concurrency to maximize throughput
  ///
  /// Returns a map where:
  /// - Key: Either "XXXbytes" for unique file sizes, or hash string for potential duplicates
  /// - Value: List of MediaEntity objects sharing that size/hash
  ///
  /// Single-item groups indicate unique files, multi-item groups are duplicates
  Future<Map<String, List<MediaEntity>>> groupIdenticalLegacy(
    final List<MediaEntity> mediaList, {
    final TelemetryLike? telemetryObject,
  }) async {
    final _Telemetry telem = telemetryObject ?? _Telemetry();
    telem.filesTotal = mediaList.length;

    if (mediaList.isEmpty) return {};

    final Map<String, List<MediaEntity>> output = <String, List<MediaEntity>>{};
    final stopwatch = Stopwatch()..start();

    // Step 1: Calculate all sizes in parallel with optimal batching
    final Stopwatch sizeSw = Stopwatch()..start();
    final sizeResults = <({MediaEntity media, int size})>[];
    final batchSize = (adaptiveConcurrency * 1.5)
        .round(); // Use adaptive concurrency

    logDebug(
      '[Step 3/8] Starting $batchSize threads (duplicate size batching concurrency)',
    );

    for (int i = 0; i < mediaList.length; i += batchSize) {
      final batch = mediaList.skip(i).take(batchSize);
      final futures = batch.map((final media) async {
        try {
          final size = await _hashService.calculateFileSize(
            File(media.primaryFile.sourcePath),
          );
          return (media: media, size: size);
        } catch (e) {
          logError(
            '[Step 3/8] Failed to get size for ${media.primaryFile.sourcePath}: $e',
          );
          return null;
        }
      });

      final batchResults = await Future.wait(futures);
      sizeResults.addAll(
        batchResults.whereType<({MediaEntity media, int size})>(),
      );

      // Progress reporting
      if (mediaList.length > 1000) {
        final int processed = math.min(i + batchSize, mediaList.length).toInt();
        final double progress = (processed / mediaList.length * 100)
            .clamp(0, 100)
            .toDouble();
        logDebug(
          '[Step 3/8] Size calculation progress: ${progress.toStringAsFixed(1)}%',
        );
      }
    }
    sizeSw.stop();
    telem.msSizeScan += sizeSw.elapsedMilliseconds;

    // Group by size
    final sizeGroups = <int, List<MediaEntity>>{};
    for (final entry in sizeResults) {
      sizeGroups
          .putIfAbsent(entry.size, () => <MediaEntity>[])
          .add(entry.media);
    }

    logDebug(
      '[Step 3/8] Grouped ${mediaList.length} files into ${sizeGroups.length} size groups',
    );
    telem.sizeBuckets = sizeGroups.length;

    // Step 2: Calculate hashes in parallel for groups with multiple files
    int hashCalculationsNeeded = 0;
    int uniqueSizeFiles = 0;

    final Stopwatch hashAllSw = Stopwatch()..start();
    for (final MapEntry<int, List<MediaEntity>> sameSize
        in sizeGroups.entries) {
      if (sameSize.value.length <= 1) {
        output['${sameSize.key}bytes'] = sameSize.value;
        uniqueSizeFiles++;
      } else {
        hashCalculationsNeeded += sameSize.value.length;

        // Calculate hashes in optimized parallel batches
        final hashResults = <({MediaEntity media, String hash})>[];
        final mediaWithSameSize = sameSize.value;

        // Use adaptive batch size for hash calculation
        final hashBatchSize = adaptiveConcurrency;

        logDebug(
          '[Step 3/8] Starting $hashBatchSize threads (duplicate hash batching concurrency)',
        );

        for (int i = 0; i < mediaWithSameSize.length; i += hashBatchSize) {
          final batch = mediaWithSameSize.skip(i).take(hashBatchSize);
          final futures = batch.map((final media) async {
            try {
              final hash = await _hashService.calculateFileHash(
                File(media.primaryFile.sourcePath),
              );
              return (media: media, hash: hash);
            } catch (e) {
              logError(
                '[Step 3/8] Failed to calculate hash for ${media.primaryFile.sourcePath}: $e',
              );
              return null;
            }
          });

          final batchResults = await Future.wait(futures);
          hashResults.addAll(
            batchResults.whereType<({MediaEntity media, String hash})>(),
          );

          // Progress reporting for large groups
          if (mediaWithSameSize.length > 100) {
            final int processed = math
                .min(i + hashBatchSize, mediaWithSameSize.length)
                .toInt();
            (processed / mediaWithSameSize.length * 100)
                .clamp(0, 100)
                .toDouble();
            // logDebug('[Step 3/8] Hash calculation progress for ${sameSize.key}bytes group: ${progress.toStringAsFixed(1)}%');
          }
        }

        // Group by hash
        final hashGroups = <String, List<MediaEntity>>{};
        for (final entry in hashResults) {
          hashGroups
              .putIfAbsent(entry.hash, () => <MediaEntity>[])
              .add(entry.media);
        }
        telem.hashGroups += hashGroups.length;
        output.addAll(hashGroups);
      }
    }
    hashAllSw.stop();
    telem.msHashGroups += hashAllSw.elapsedMilliseconds;

    stopwatch.stop();
    telem.msGrouping += stopwatch.elapsedMilliseconds;

    // Record performance metrics for adaptive optimization
    _recordPerformance(mediaList.length, stopwatch.elapsed);

    // Log performance statistics
    final cacheStats = _hashService.getCacheStats();
    logDebug(
      '[Step 3/8] Duplicate detection completed in ${stopwatch.elapsed.inMilliseconds}ms',
    );
    logDebug('[Step 3/8] Files with unique sizes: $uniqueSizeFiles');
    logDebug(
      '[Step 3/8] Files requiring hash calculation: $hashCalculationsNeeded',
    );
    logDebug('[Step 3/8] Cache statistics: $cacheStats');

    // // Count and log duplicate groups found
    // final duplicateGroups = output.values.where((final group) => group.length > 1);
    // final totalDuplicates =  duplicateGroups.fold<int>(0, (final sum, final group) => sum + group.length - 1);
    // if (duplicateGroups.isNotEmpty) {
    //   logInfo('[Step 3/8] Found ${duplicateGroups.length} duplicate groups with $totalDuplicates duplicate files');
    // }

    return output;
  }

  /// —————————————————————————————————————————————————————————————————————————————
  /// Phase 2: Merge phase (apply replacements and remove merged-away entities from collection)
  /// NOTE: This function *does* mutate the collection:
  /// - Decides which entity to keep per group (accuracy → basename → prefer Year → full path len → lex)
  /// - Optionally verifies by hashing when big groups or very large files
  /// - Applies kept0 → kept replacements (attributes merged)
  /// - Removes merged-away entities from the collection
  /// All original logs and behavior are preserved.
  /// —————————————————————————————————————————————————————————————————————————————
  Future<int> mergeDuplicateEntities(
    final MediaEntityCollection mediaCollection,
    final Map<String, List<MediaEntity>> groups, {
    final bool? verify,
    final TelemetryLike? telemetryObject,
  }) async {
    // final _Telemetry telem = telemetryObject ?? _Telemetry();
    final bool verifyLocal = verify ?? _isVerifyEnabled();
    final MediaHashService verifier = verifyLocal
        ? MediaHashService()
        : MediaHashService(maxCacheSize: 1);

    final List<_Replacement> pendingReplacements = <_Replacement>[];
    final Set<MediaEntity> entitiesToMerge = HashSet<MediaEntity>.identity();

    for (final entry in groups.entries) {
      final List<MediaEntity> group = entry.value;
      if (group.length <= 1) continue;

      // Sort by: accuracy → basename length → prefer Year → full path len → path lex
      group.sort((final a, final b) {
        final aAcc = a.dateAccuracy?.value ?? 999;
        final bAcc = b.dateAccuracy?.value ?? 999;
        if (aAcc != bAcc) return aAcc.compareTo(bAcc);

        final aBaseLen = path.basename(a.primaryFile.path).length;
        final bBaseLen = path.basename(b.primaryFile.path).length;
        if (aBaseLen != bBaseLen) return aBaseLen.compareTo(bBaseLen);

        final aYear = a.albumsMap.isEmpty;
        final bYear = b.albumsMap.isEmpty;
        if (aYear != bYear) return aYear ? -1 : 1;

        final aPathLen = a.primaryFile.path.length;
        final bPathLen = b.primaryFile.path.length;
        if (aPathLen != bPathLen) return aPathLen.compareTo(bPathLen);

        return a.primaryFile.path.compareTo(b.primaryFile.path);
      });

      final MediaEntity kept0 = group.first;
      final List<MediaEntity> toRemove = group.sublist(1);
      MediaEntity kept = kept0;

      // PERF-aware verification:
      // - Only verify for big groups or very large files (saves double hashing).
      // - Reuse precomputed hash if 'entry.key' looks like a real hash (not "NNNbytes").
      int sizeKey = -1;
      try {
        sizeKey = kept.primaryFile.asFile().lengthSync();
      } catch (_) {}
      final bool verifyThisGroup =
          verifyLocal && (group.length >= 4 || sizeKey > (64 << 20));
      final String groupKey = entry.key;
      final bool keyIsHash = !groupKey.contains('bytes');
      final String? expectedHash = keyIsHash ? groupKey : null;

      if (verifyThisGroup) {
        try {
          final String keptHash =
              expectedHash ??
              await verifier.calculateFileHash(kept.primaryFile.asFile());

          if (expectedHash != null) {
            if (toRemove.isNotEmpty) {
              final d = toRemove.first;
              final String sampleHash = await verifier.calculateFileHash(
                d.primaryFile.asFile(),
              );
              if (sampleHash != keptHash) {
                logWarning(
                  '[Step 3/8] Verification sample mismatch for group $groupKey. Falling back to full verification.',
                  forcePrint: true,
                );
                for (final x in toRemove) {
                  final String xh = await verifier.calculateFileHash(
                    x.primaryFile.asFile(),
                  );
                  if (xh != keptHash) {
                    logWarning(
                      '[Step 3/8] Verification mismatch. Will NOT remove ${x.primaryFile.path} (hash differs from kept).',
                      forcePrint: true,
                    );
                    continue;
                  }
                  kept = kept.mergeWith(x);
                  entitiesToMerge.add(x);
                }
              } else {
                for (final x in toRemove) {
                  kept = kept.mergeWith(x);
                  entitiesToMerge.add(x);
                }
              }
            }
          } else {
            for (final d in toRemove) {
              try {
                final String dupHash = await verifier.calculateFileHash(
                  d.primaryFile.asFile(),
                );
                if (dupHash != keptHash) {
                  logWarning(
                    '[Step 3/8] Verification mismatch. Will NOT remove ${d.primaryFile.path} (hash differs from kept).',
                    forcePrint: true,
                  );
                  continue;
                }
                kept = kept.mergeWith(d);
                entitiesToMerge.add(d);
              } catch (e) {
                logWarning(
                  '[Step 3/8] Verification failed for ${d.primaryFile.path}: $e. Skipping removal for safety.',
                  forcePrint: true,
                );
              }
            }
          }
        } catch (e) {
          logWarning(
            '[Step 3/8] Could not hash kept file ${_safePath(kept.primaryFile.asFile())} for verification: $e. Skipping removals for this group.',
            forcePrint: true,
          );
        }
      } else {
        for (final d in toRemove) {
          kept = kept.mergeWith(d);
          entitiesToMerge.add(d);
        }
      }

      // Defer collection mutation: record replacement (kept0 → kept)
      pendingReplacements.add(_Replacement(kept0: kept0, kept: kept));
    }

    // Apply replacements sequentially (safe mutation of collection)
    // OPTIMIZATION: single pass over the collection using a mapping O(N)
    final Map<MediaEntity, MediaEntity> map =
        LinkedHashMap<MediaEntity, MediaEntity>.identity();
    for (final r in pendingReplacements) {
      map[r.kept0] = r.kept; // kept0 → kept
    }
    mediaCollection.applyReplacements(map);

    // Just before creating multi-path entities line
    final int initialEntitiesCount = mediaCollection.length;
    logPrint(
      '[Step 3/8] Processing $initialEntitiesCount media entities from media entities collection',
    );

    // Informative message before removing merged-away entities from the collection
    final int mergedEntities = entitiesToMerge.length;
    if (mergedEntities > 0) {
      logPrint(
        '[Step 3/8] $mergedEntities media entities will be merged (entities with multiple file paths for the same file content)',
      );
    }

    // Remove merged-away entities from the collection ONLY (do not delete files here)
    if (entitiesToMerge.isNotEmpty) {
      // NEW (progress): show a progress bar while compacting the collection.
      final FillingBar pbar = FillingBar(
        total: mergedEntities,
        width: 50,
        percentage: true,
        desc: '[ INFO  ] [Step 3/8] Merging entities',
      );

      // Keep visual progress (cheap) without doing O(R) removals one-by-one
      int done = 0;
      for (final _ in entitiesToMerge) {
        done++;
        if ((done % 250) == 0 || done == mergedEntities) pbar.update(done);
      }

      // Single-pass removal O(N + R)
      mediaCollection.removeAll(
        entitiesToMerge,
      ); // ← add this method to your collection (see apartado 2)
      stdout
          .writeln(); // note: ensure the next logs start in a new line after the bar.
    }

    logPrint(
      '[Step 3/8] ${mediaCollection.entities.length} final media entities left',
    );
    return mergedEntities;
  }

  /// —————————————————————————————————————————————————————————————————————————————
  /// Phase 3: I/O phase (move/delete within-folder duplicates).
  /// NOTE: This function gathers duplicatesFiles and performs I/O (move/delete).
  /// It does NOT print telemetry. It only logs operational messages and returns counts.
  /// —————————————————————————————————————————————————————————————————————————————
  Future<({bool moved, int duplicateFilesRemoved})> removeQuarantineDuplicates(
    final ProcessingContext context,
    final MediaEntityCollection mediaCollection, {
    final TelemetryLike? telemetryObject,
  }) async {
    // final _Telemetry telem = telemetryObject ?? _Telemetry();

    // Gather duplicate files across the collection for I/O
    final List<FileEntity> duplicateFiles = <FileEntity>[];
    for (final e in mediaCollection.entities) {
      if (e.duplicatesFiles.isNotEmpty) {
        duplicateFiles.addAll(e.duplicatesFiles);
      }
    }

    // Move/Delete only duplicatesFiles (depending on flag)
    int duplicateFilesRemoved = 0;
    bool moved = false;
    if (duplicateFiles.isNotEmpty) {
      logPrint(
        '[Step 3/8] Found ${duplicateFiles.length} duplicates files (within-folder duplicates). Processing them for removal/quarantine',
      );

      // NEW (progress): show a progress bar during duplicate I/O (remove/move).
      final FillingBar pbarIO = FillingBar(
        total: duplicateFiles.length,
        width: 50,
        percentage: true,
        desc: '[ INFO  ] [Step 3/8] Removing/moving duplicate files',
      );
      int doneIO = 0;

      moved = await _removeOrQuarantineDuplicateFiles(
        duplicateFiles,
        context,
        onRemoved: () {
          duplicateFilesRemoved++;
          doneIO++;
          if ((doneIO % 250) == 0 || doneIO == duplicateFiles.length) {
            pbarIO.update(doneIO);
          }
        },
      );
      stdout.writeln();

      if (moved) {
        logPrint(
          '[Step 3/8] Duplicates files moved to _Duplicates (flag --keep-duplicates = true)',
        );
      } else {
        logPrint('[Step 3/8] Duplicates files removed from input folder.');
      }
    } else {
      logPrint('[Step 3/8] No duplicates files (within-folder) to remove');
    }

    return (moved: moved, duplicateFilesRemoved: duplicateFilesRemoved);
  }

  // —————————————————————————————————————— NEW DTOs / helpers for this class ——————————————————————————————————————
  /// Full telemetry printer restored to the original complete output (always prints all fields).
  void _printTelemetryFull(
    final _Telemetry t, {
    final LoggerMixin? loggerMixin,
    required final int secondaryFilesInCollection,
    required final int duplicateFilesRemovedIO,
    required final int primaryFilesInCollection,
    required final int canonicalFilesInCollection,
    required final int nonCanonicalFilesInCollection,
    required final bool printTelemetry,
  }) {
    void out(final String s) {
      if (loggerMixin != null) {
        loggerMixin.logPrint(s, forcePrint: printTelemetry);
      } else {
        LoggingService().info(s);
      }
    }

    String ms(final num v) => '${v.toStringAsFixed(0)} ms';

    out('[Step 3/8] === Telemetry Summary ===');
    out('[Step 3/8]     Files total                        : ${t.filesTotal}');
    out('[Step 3/8]     Size buckets                       : ${t.sizeBuckets}');
    out('[Step 3/8]     Ext buckets                        : ${t.extBuckets}');
    out(
      '[Step 3/8]     Quick buckets                      : ${t.quickBuckets}',
    );
    out('[Step 3/8]     Hash groups                        : ${t.hashGroups}');
    out(
      '[Step 3/8]     Merged media entities (by content) : ${t.entitiesMergedByContent}',
    );
    out(
      '[Step 3/8]     Primary files in collection        : $primaryFilesInCollection',
    );
    out(
      '[Step 3/8]     Secondary files in collection      : $secondaryFilesInCollection',
    );
    out(
      '[Step 3/8]     Canonical files (ALL_PHOTOS/Year)  : $canonicalFilesInCollection',
    );
    out(
      '[Step 3/8]     Non-Canonical files (Albums)       : $nonCanonicalFilesInCollection',
    );
    out(
      '[Step 3/8]     Duplicate files removed (I/O)      : $duplicateFilesRemovedIO',
    );
    out('[Step 3/8]     Time total                         : ${ms(t.msTotal)}');
    out(
      '[Step 3/8]       - Find duplicates                : ${ms(t.msGrouping)}',
    );
    out(
      '[Step 3/8]         - Size scan                    : ${ms(t.msSizeScan)}',
    );
    out(
      '[Step 3/8]         - Ext bucketing                : ${ms(t.msExtBucket)}',
    );
    out(
      '[Step 3/8]         - Quick signature              : ${ms(t.msQuickSig)}',
    );
    out(
      '[Step 3/8]         - Hash grouping                : ${ms(t.msHashGroups)}',
    );
    out(
      '[Step 3/8]       - Merge/replace                  : ${ms(t.msMergeReplace)}',
    );
    out(
      '[Step 3/8]       - Remove/IO                      : ${ms(t.msRemoveIO)}',
    );
  }

  bool _isVerifyEnabled() {
    try {
      final v = Platform.environment['GPTH_VERIFY_DUPLICATES'];
      if (v == null) return false;
      final s = v.trim().toLowerCase();
      return s == '1' || s == 'true' || s == 'yes' || s == 'on';
    } catch (_) {
      return false;
    }
  }

  /// Reads the "move duplicates" flag from available configuration sources.
  /// Priority:
  /// 1) ServiceContainer.instance.globalConfig.moveDuplicatesToDuplicatesFolder (dynamic, if present)
  /// 2) Env var GPTH_MOVE_DUPLICATES_TO_DUPLICATES_FOLDER = 1/true/yes/on
  /// 3) Default false
  bool _shouldMoveDuplicatesToFolder(final ProcessingContext context) {
    try {
      final dynamic keepDuplicates = context.config.keepDuplicates;
      if (keepDuplicates is bool) return keepDuplicates;
    } catch (_) {}
    try {
      final env =
          Platform.environment['GPTH_MOVE_DUPLICATES_TO_DUPLICATES_FOLDER'];
      if (env != null) {
        final s = env.trim().toLowerCase();
        return s == '1' || s == 'true' || s == 'yes' || s == 'on';
      }
    } catch (_) {}
    return false;
  }

  String _safePath(final File f) {
    try {
      return f.path;
    } catch (_) {
      return '<unknown-file>';
    }
  }

  /// Move/delete only duplicate files (within-folder duplicates), never secondary files.
  Future<bool> _removeOrQuarantineDuplicateFiles(
    final List<FileEntity> duplicates,
    final ProcessingContext context, {
    final void Function()? onRemoved,
  }) async {
    final bool moveToDuplicates = _shouldMoveDuplicatesToFolder(context);

    final String inputRoot = context.inputDirectory.path;
    final String outputRoot = context.outputDirectory.path;

    for (final fe in duplicates) {
      final File f = fe.asFile();

      // Compute relative path inside input; if it fails, fallback to basename only
      String rel;
      try {
        rel = path.relative(f.path, from: inputRoot);
      } catch (_) {
        rel = path.basename(f.path);
      }

      try {
        if (moveToDuplicates) {
          final String destPath = path.join(outputRoot, '_Duplicates', rel);
          final Directory destDir = Directory(path.dirname(destPath));
          if (!await destDir.exists()) {
            await destDir.create(recursive: true);
          }
          try {
            await f.rename(destPath);
          } catch (_) {
            // Cross-device fallback: copy then delete
            await f.copy(destPath);
            await f.delete();
          }
        } else {
          await f.delete();
        }
        onRemoved?.call();
      } catch (ioe) {
        logWarning(
          '[Step 3/8] Failed to remove/move duplicate ${f.path}: $ioe',
          forcePrint: true,
        );
      }
    }
    return moveToDuplicates;
  }

  // Helper: lowercase extension
  String _extOf(final String p) {
    final int slash = p.lastIndexOf(Platform.pathSeparator);
    final String base = (slash >= 0) ? p.substring(slash + 1) : p;
    final int dot = base.lastIndexOf('.');
    if (dot <= 0) return '';
    return base.substring(dot + 1).toLowerCase();
  }

  // Helper: quick signature (tri-sample XXH3 of 3×4 KiB at head/mid/tail)
  // NOTE (perf): this replaces a large head-read (e.g. 64–128 KiB) with only 12 KiB total,
  // while being more discriminative for formats with heavy headers (JPEG/MP4/etc.).
  //
  // MODIFIED IMPLEMENTATION (English explanation):
  // - Open the file ONCE and reuse the same RandomAccessFile for head/mid/tail → dramatically fewer syscalls.
  // - Use XXH3 (via package:xxh3) — ~10× faster than SHA-256 and better quality than FNV.
  // - For very large files and typical video containers, use a 2-point strategy (head+tail) to reduce random seeks.
  Future<String> _quickSignature(
    final File file,
    final int size,
    final String ext,
  ) async {
    const int chunk = 4096; // 4 KiB per sample (head/mid/tail)
    final int sz = size > 0 ? size : (await file.length());

    // Heuristic: videos or very large files → fewer seeks (2-point)
    final bool isVideo = _videoExts.contains(ext);
    final bool twoPointOnly = isVideo || sz >= (64 << 20); // ≥ 64MiB

    const int headOff = 0;
    final int midOff = (!twoPointOnly && sz > chunk) ? (sz ~/ 2) : 0;
    final int tailOff = (sz > chunk) ? (sz - chunk) : 0;

    RandomAccessFile? raf;
    try {
      raf = await file.open();

      // Head
      await raf.setPosition(headOff);
      final head = await raf.read(chunk);
      final int h1 = xxh3(head);

      // Mid (optional)
      int h2 = 0;
      if (midOff != 0) {
        await raf.setPosition(midOff);
        final mid = await raf.read(chunk);
        h2 = xxh3(mid);
      }

      // Tail
      await raf.setPosition(tailOff);
      final tail = await raf.read(chunk);
      final int h3 = xxh3(tail);

      // Combine size + ext + three partial hashes in the key
      return '$size|$ext|$h1|$h2|$h3';
    } catch (_) {
      // Keep a deterministic key on I/O errors (preserves bucketing behavior)
      return '$size|$ext|0|0|0';
    } finally {
      try {
        await raf?.close();
      } catch (_) {}
    }
  }

  // ——— ADDED: tri-sample fingerprint used by groupIdenticalFast ——————————
  /// Compute a compact fingerprint from three small slices of the file.
  /// This is NOT a cryptographic hash; it is only used to pre-cluster and reduce
  /// the number of full hashes needed. Collisions are acceptable because we will
  /// still verify with full file hashes inside each fingerprint subgroup.
  Future<String> _triSampleFingerprint(
    final File f,
    final int sampleSize,
  ) async {
    final int size = await _hashService.calculateFileSize(f);
    if (size <= 0) return 'SZ0';

    final RandomAccessFile raf = await f.open();
    try {
      final int headLen = math.min(sampleSize, size).toInt();
      final Uint8List head = await _readSlice(raf, 0, headLen);

      final int midStart = math.max(0, (size ~/ 2) - (sampleSize ~/ 2));
      final int midLen = math.min(sampleSize, size - midStart).toInt();
      final Uint8List mid = await _readSlice(raf, midStart, midLen);

      final int tailStart = math.max(0, size - sampleSize);
      final int tailLen = math.min(sampleSize, size - tailStart).toInt();
      final Uint8List tail = await _readSlice(raf, tailStart, tailLen);

      // XXH3 over each slice (fast, high-quality 64-bit)
      final int h1 = xxh3(head);
      final int h2 = xxh3(mid);
      final int h3 = xxh3(tail);

      // Include size to strengthen the key and reduce cross-size collisions
      // Format: size|h1|h2|h3 (hex)
      return '${size}b:${_toHex64(h1)}:${_toHex64(h2)}:${_toHex64(h3)}';
    } finally {
      await raf.close();
    }
  }

  Future<Map<String, List<MediaEntity>>> _fullHashGroup(
    final List<MediaEntity> files,
  ) async {
    final Map<String, List<MediaEntity>> byHash = <String, List<MediaEntity>>{};
    final int hashBatch = adaptiveConcurrency;

    for (int i = 0; i < files.length; i += hashBatch) {
      final batch = files.skip(i).take(hashBatch);
      final futures = batch.map((final media) async {
        try {
          final h = await _hashService.calculateFileHash(
            File(media.primaryFile.sourcePath),
          );
          return (media: media, hash: h);
        } catch (e) {
          logError(
            '[Step 3/8] Failed to calculate hash for ${media.primaryFile.sourcePath}: $e',
          );
          return (media: media, hash: 'ERR|${media.primaryFile.sourcePath}');
        }
      });
      final res = await Future.wait(futures);
      for (final r in res) {
        (byHash[r.hash] ??= <MediaEntity>[]).add(r.media);
      }
    }
    return byHash;
  }

  Future<Uint8List> _readSlice(
    final RandomAccessFile raf,
    final int start,
    final int length,
  ) async {
    await raf.setPosition(start);
    return raf.read(length);
  }

  String _toHex64(final int v) {
    final s = v.toUnsigned(64).toRadixString(16);
    return s.padLeft(16, '0');
  }

  // —————————————————————————————————————— Following methods kept for legacy API compatibility for Tests ——————————————————————————————————————
  /// Removes duplicate media from list of media entities with enhanced logging
  ///
  /// This method is designed for early-stage processing before album merging.
  /// It preserves duplicated files that have different album associations,
  /// ensuring no album relationships are lost during deduplication.
  ///
  /// [mediaList] List of media entities to deduplicate
  /// [progressCallback] Optional callback for progress updates (processed, total)
  /// Returns list with duplicates removed, keeping the highest quality version
  Future<List<MediaEntity>> removeDuplicates(
    final List<MediaEntity> mediaList, {
    final void Function(int processed, int total)? progressCallback,
  }) async {
    if (mediaList.length <= 1) return mediaList;

    logInfo(
      '[Step 3/8] Starting duplicate removal for ${mediaList.length} media entities...',
    );

    // final grouped = await groupIdentical(mediaList);
    final grouped = await groupIdenticalLegacy(mediaList);
    final result = <MediaEntity>[];
    int processed = 0;
    int duplicatesRemoved = 0;

    for (final group in grouped.values) {
      if (group.length == 1) {
        // No duplicates, keep the single file
        result.add(group.first);
      } else {
        // Multiple files with same content, keep the best one
        final best = _selectBestMedia(group);
        MediaEntity merged = best;
        for (final m in group) {
          if (!identical(m, best)) merged = merged.mergeWith(m);
        }
        result.add(merged);

        // Log which duplicates are being removed
        final duplicatesToRemove = group
            .where((final media) => media != best)
            .toList();
        duplicatesRemoved += duplicatesToRemove.length;

        if (duplicatesToRemove.isNotEmpty) {
          final keptFile = best.primaryFile.sourcePath;
          logDebug(
            '[Step 3/8] Found ${group.length} identical files, keeping: $keptFile',
          );
          for (final duplicate in duplicatesToRemove) {
            logDebug(
              '[Step 3/8]   Removing duplicate: ${duplicate.primaryFile.sourcePath}',
            );
          }
        }
      }

      processed++;
      progressCallback?.call(processed, grouped.length);
    }

    logInfo(
      '[Step 3/8] Duplicate removal completed: removed $duplicatesRemoved files, kept ${result.length}',
    );

    // Log cache performance
    final cacheStats = _hashService.getCacheStats();
    logDebug('[Step 3/8] Final cache statistics: $cacheStats');

    return result;
  }

  /// Selects the best media entity from a group of duplicates
  ///
  /// Priority order:
  /// 1. Media with most accurate date information
  /// 2. Media with more album associations (metadata-only, as a proxy for richer context)
  /// 3. Media with shorter file path (likely original location)
  MediaEntity _selectBestMedia(final List<MediaEntity> duplicates) {
    if (duplicates.length == 1) {
      return duplicates.first;
    }
    // Sort by quality criteria (adapted to the new model)
    final sorted = duplicates.toList()
      ..sort((final a, final b) {
        // 1. Prefer media with more accurate date
        final aHasDate = a.dateTaken != null && a.dateAccuracy != null;
        final bHasDate = b.dateTaken != null && b.dateAccuracy != null;

        if (aHasDate && bHasDate) {
          final dateComparison = a.dateTakenAccuracy!.compareTo(
            b.dateTakenAccuracy!,
          );
          if (dateComparison != 0) return dateComparison;
        } else if (aHasDate && !bHasDate) {
          return -1; // a is better
        } else if (!aHasDate && bHasDate) {
          return 1; // b is better
        }

        // 2. Prefer media with more album associations (metadata)
        final albumComparison = b.albumsMap.length.compareTo(
          a.albumsMap.length,
        );
        if (albumComparison != 0) return albumComparison;

        // 3. Prefer media with shorter path (likely more original)
        final pathA = a.primaryFile.sourcePath;
        final pathB = b.primaryFile.sourcePath;
        return pathA.length.compareTo(pathB.length);
      });

    return sorted.first;
  }

  /// Finds exact duplicates based on file content
  ///
  /// Returns a list of duplicate groups, where each group contains
  /// media entities with identical file content.
  Future<List<List<MediaEntity>>> findDuplicateGroups(
    final List<MediaEntity> mediaList,
  ) async {
    // Chose only one of the following 3 methods:
    // final grouped = await groupIdentical(mediaList);
    // final grouped = await groupIdenticalFast(mediaList);
    final grouped = await groupIdenticalFast2(mediaList);
    return grouped.values.where((final group) => group.length > 1).toList();
  }

  /// Checks if two media entities are duplicates based on content
  Future<bool> areDuplicates(
    final MediaEntity media1,
    final MediaEntity media2,
  ) async {
    // Quick size check first
    final size1 = await _hashService.calculateFileSize(
      File(media1.primaryFile.sourcePath),
    );
    final size2 = await _hashService.calculateFileSize(
      File(media2.primaryFile.sourcePath),
    );

    if (size1 != size2) return false;

    // If sizes match, compare hashes
    final hash1 = await _hashService.calculateFileHash(
      File(media1.primaryFile.sourcePath),
    );
    final hash2 = await _hashService.calculateFileHash(
      File(media2.primaryFile.sourcePath),
    );

    return hash1 == hash2;
  }

  /// Statistics about duplicate detection results
  DuplicateStats calculateStats(
    final Map<String, List<MediaEntity>> groupedResults,
  ) {
    int totalFiles = 0;
    int uniqueFiles = 0;
    int duplicateGroups = 0;
    int duplicateFiles = 0;
    int spaceWastedBytes = 0;

    for (final group in groupedResults.values) {
      totalFiles += group.length;

      if (group.length == 1) {
        uniqueFiles++;
      } else {
        duplicateGroups++;
        duplicateFiles += group.length;

        // Calculate wasted space (all but one file in each group)
        for (int i = 1; i < group.length; i++) {
          // Note: This is an approximation - we'd need to actually calculate sizes
          // For now, we'll use the file size from the first file as estimate
          try {
            final size = File(group.first.primaryFile.sourcePath).lengthSync();
            spaceWastedBytes += size;
          } catch (e) {
            // Ignore files that can't be read
          }
        }
      }
    }

    return DuplicateStats(
      totalFiles: totalFiles,
      uniqueFiles: uniqueFiles,
      duplicateGroups: duplicateGroups,
      duplicateFiles: duplicateFiles,
      spaceWastedBytes: spaceWastedBytes,
    );
  }

  /// Optional convenience alias if you prefer this name in callers.
  Future<String> computeSha256(final MediaEntity media) =>
      _hashService.calculateFileHash(File(media.primaryFile.sourcePath));
}

/// Statistics about duplicate detection results
class DuplicateStats {
  const DuplicateStats({
    required this.totalFiles,
    required this.uniqueFiles,
    required this.duplicateGroups,
    required this.duplicateFiles,
    required this.spaceWastedBytes,
  });

  /// Total number of files processed
  final int totalFiles;

  /// Number of unique files (no duplicates)
  final int uniqueFiles;

  /// Number of groups containing duplicates
  final int duplicateGroups;

  /// Total number of duplicate files
  final int duplicateFiles;

  /// Estimated wasted space in bytes
  final int spaceWastedBytes;

  /// Percentage of files that are duplicates
  double get duplicatePercentage =>
      totalFiles > 0 ? (duplicateFiles / totalFiles) * 100 : 0;

  /// Human readable summary
  String get summary =>
      '[Step 3/8] Found $duplicateGroups duplicate groups with $duplicateFiles files. '
      '[Step 3/8] Space wasted: ${(spaceWastedBytes / (1024 * 1024)).toStringAsFixed(1)} MB';
}

typedef TelemetryLike = _Telemetry;

// ──────────────────────────────────────────────────────────────────────────────
// Telemetry support types (kept as in original execute(), moved here)
// ──────────────────────────────────────────────────────────────────────────────

class _Telemetry {
  int filesTotal = 0;
  int sizeBuckets = 0;
  int extBuckets = 0;
  int quickBuckets = 0;
  int hashGroups = 0;
  int entitiesMergedByContent = 0;

  num msTotal = 0;
  num msSizeScan = 0;
  num msExtBucket = 0;
  num msQuickSig = 0;
  num msHashGroups = 0;
  num msMergeReplace = 0;
  num msRemoveIO = 0;

  num msGrouping = 0;

  void addStats(final _BucketStats s) {
    extBuckets += s.extBuckets;
    quickBuckets += s.quickBuckets;
    hashGroups += s.hashGroups;
    entitiesMergedByContent += s.entitiesMergedByContent;
    msExtBucket += s.msExtBucket;
    msQuickSig += s.msQuickSig;
    msHashGroups += s.msHashGroups;
    msMergeReplace += s.msMergeReplace;
  }
}

class _BucketStats {
  int extBuckets = 0;
  int quickBuckets = 0;
  int hashGroups = 0;
  int entitiesMergedByContent = 0;

  num msExtBucket = 0;
  num msQuickSig = 0;
  num msHashGroups = 0;
  num msMergeReplace = 0;
}

// ignore: unused_element
class _BucketOutcome {
  _BucketOutcome(this.stats, this.replacements, this.toRemove);
  final _BucketStats stats;
  final List<_Replacement> replacements;
  final Set<MediaEntity> toRemove;
}

class _Replacement {
  _Replacement({required this.kept0, required this.kept});
  final MediaEntity kept0;
  final MediaEntity kept;
}

// NEW: small helper to carry hash grouping results in parallel batches
// English note: returning both the groups and elapsed ms keeps per-batch
// telemetry accurate after parallelization.
class _HashBatchResult {
  _HashBatchResult(this.groups, this.ms);
  final Map<String, List<MediaEntity>> groups;
  final int ms;
}

/// Summary DTO returned by mergeMediaEntities(...) to feed StepResult without changing step responsibilities.
class MergeMediaEntitiesSummary {
  const MergeMediaEntitiesSummary({
    required this.message,
    required this.entitiesMerged,
    required this.remainingMedia,
    required this.sizeBuckets,
    required this.quickBuckets,
    required this.hashGroups,
    required this.msTotal,
    required this.msSizeScan,
    required this.msQuickSig,
    required this.msHashGroups,
    required this.msMergeReplace,
    required this.msRemoveIO,
    required this.primaryFilesCount,
    required this.secondaryFilesDetected,
    required this.duplicateFilesRemoved,
    required this.canonicalAll,
    required this.nonCanonicalAll,
    required this.primaryCanonical,
    required this.primaryFromAlbums,
    required this.secondaryCanonical,
    required this.secondaryFromAlbums,
  });

  final String message;
  final int entitiesMerged;
  final int remainingMedia;
  final int sizeBuckets;
  final int quickBuckets;
  final int hashGroups;
  final num msTotal;
  final num msSizeScan;
  final num msQuickSig;
  final num msHashGroups;
  final num msMergeReplace;
  final num msRemoveIO;
  final int primaryFilesCount;
  final int secondaryFilesDetected;
  final int duplicateFilesRemoved;
  final int canonicalAll;
  final int nonCanonicalAll;
  final int primaryCanonical;
  final int primaryFromAlbums;
  final int secondaryCanonical;
  final int secondaryFromAlbums;
}
