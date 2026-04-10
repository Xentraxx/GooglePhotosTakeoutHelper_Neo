import 'dart:io';

import 'package:console_bars/console_bars.dart';
import 'package:gpth_neo/gpth_lib_exports.dart';
import 'package:intl/intl.dart';
import 'package:meta/meta.dart' show visibleForTesting;
import 'package:mime/mime.dart' as mime;

/// NOTE (2025-09-07): No functional changes required in this module for items 1–6.
///  - (1) Argfile without `-common_args` and (2) adding `-m` and (4) timeouts are handled in ExifToolService.
///  - (3) PNG → XMP tag selection and (6) flush telemetry live in WriteExifStep.
///  - (5) Retry policy is managed by WriteExifStep (splitting batches / per-file).
/// Keeping this file intact preserves counters/telemetry and native JPEG paths.

/// Service that writes EXIF data (fast native JPEG path + adaptive exiftool batching).
/// Includes detailed instrumentation of counts and durations (seconds).
/// NEW: Orchestrator that encapsulates the whole Step 7 `execute()` logic inside the service module.
/// This class reuses WriteExifService for single-file/batch writes and preserves all behaviors.
class WriteExifProcessingService with LoggerMixin {
  WriteExifProcessingService({required this.exifTool});

  final Object? exifTool;

  /// Public outcome for Step7 result mapping.
  /// Keeps the same meaning as Step 7 data map keys.
  Future<WriteExifSummary> processCollection({
    required final ProcessingContext context,
    final LoggerMixin? logger,
  }) async {
    // --- Tooling and flags (exactly as in the step) ---
    final collection = context.mediaCollection;
    final bool exifToolAvailable = exifTool != null;
    if (!exifToolAvailable) {
      logWarning(
        '[Step 7/8] ExifTool not available, native-only support.',
        forcePrint: true,
      );
    } else {
      logPrint('[Step 7/8] ExifTool available');
    }

    // Concurrency selection is kept identical
    final int maxConcurrency = ConcurrencyManager().concurrencyFor(
      ConcurrencyOperation.exif,
    );
    logPrint('[Step 7/8] Starting $maxConcurrency threads (exif concurrency)');

    final bool enableExifToolBatch = _resolveBatchingPreference(exifTool);
    final _UnsupportedPolicy unsupportedPolicy = _resolveUnsupportedPolicy();

    // Always instantiate the auxiliary writer so native-only writes work
    // even when ExifTool is not available. ExifTool-backed operations remain
    // guarded by `exifToolAvailable` / `exifTool` checks elsewhere.
    final WriteExifAuxiliaryService exifWriter = WriteExifAuxiliaryService(
      exifTool as ExifToolService?,
    );

    // DateTime policy:
    // - EXIF classic date tags are "naive" clock timestamps.
    // - JSON `photoTakenTime.timestamp` yields a UTC instant.
    // Option A: when a DateTime is UTC (or produced by JSON extractors), write the UTC clock
    // *and* set OffsetTime* = +00:00 so ExifTool composites/viewers do not apply local offsets.
    bool shouldTreatAsUtc(
      final DateTimeExtractionMethod? method,
      final DateTime dt,
    ) {
      final m = method;
      return dt.isUtc ||
          m == DateTimeExtractionMethod.json ||
          m == DateTimeExtractionMethod.jsonTryHard;
    }

    String formatExifClock(final DateTime dt) {
      final exifFormat = DateFormat('yyyy:MM:dd HH:mm:ss');
      return exifFormat.format(dt);
    }

    void addUtcOffsetTags(final Map<String, dynamic> tags) {
      // EXIF 2.31 time zone offset tags
      tags['OffsetTime'] = '"+00:00"';
      tags['OffsetTimeOriginal'] = '"+00:00"';
      tags['OffsetTimeDigitized'] = '"+00:00"';
    }

    String formatXmpDateTime(final DateTime dt, {required final bool isUtc}) {
      final clock = formatExifClock(dt);
      // XMP datetime supports timezone offsets; use +00:00 for UTC.
      return isUtc ? '$clock+00:00' : clock;
    }

    // Batch queues and helpers (moved here from the step; unchanged logic)
    final bool isWindows = Platform.isWindows;
    final int baseBatchSize = isWindows ? 100 : 200;
    final int maxImageBatch = _resolveInt(
      'maxExifImageBatchSize',
      defaultValue: 500,
    );
    final int maxVideoBatch = _resolveInt(
      'maxExifVideoBatchSize',
      defaultValue: 24,
    );

    final Map<String, List<MapEntry<File, Map<String, dynamic>>>>
    pendingImagesByTagset = {};
    final Map<String, List<MapEntry<File, Map<String, dynamic>>>>
    pendingVideosByTagset = {};

    // Key on tag *names* only (not values), so every file needing the same
    // set of tags (e.g. DateTimeOriginal+DateTimeDigitized+DateTime) lands in
    // the same bucket regardless of its individual timestamp value.  ExifTool
    // batch mode already interleaves per-file tag values before each filename,
    // so different values within a batch are fully supported.
    String stableTagsetKey(final Map<String, dynamic> tags) {
      final keys = tags.keys.toList()..sort();
      return keys.join('\u0001');
    }

    int totalQueued(
      final Map<String, List<MapEntry<File, Map<String, dynamic>>>> byTagset,
    ) {
      int n = 0;
      for (final list in byTagset.values) {
        n += list.length;
      }
      return n;
    }

    // Preserve OS mtimes around writes
    Future<T> preserveMTime<T>(
      final File f,
      final Future<T> Function() op,
    ) async {
      DateTime? before;
      try {
        before = await f.lastModified();
      } catch (_) {}
      T out;
      try {
        out = await op();
      } finally {
        if (before != null) {
          try {
            await f.setLastModified(before);
          } catch (_) {}
        }
      }
      return out;
    }

    Map<File, DateTime> snapshotMtimes(
      final List<MapEntry<File, Map<String, dynamic>>> chunk,
    ) {
      final m = <File, DateTime>{};
      for (final e in chunk) {
        try {
          m[e.key] = e.key.lastModifiedSync();
        } catch (_) {}
      }
      return m;
    }

    Future<void> restoreMtimes(final Map<File, DateTime> snap) async {
      for (final kv in snap.entries) {
        try {
          await kv.key.setLastModified(kv.value);
        } catch (_) {}
      }
    }

    // Track JPEGs that must be written via XMP (Truncated InteropIFD) – same behavior
    final Set<String> forceJpegXmp = <String>{};

    // Safe batched write (split on failure, parse stderr for bad files)
    Future<void> writeBatchSafe(
      final List<MapEntry<File, Map<String, dynamic>>> queue, {
      required final bool useArgFile,
      required final bool isVideoBatch,
    }) async {
      if (queue.isEmpty) return;

      Future<void> splitAndWrite(
        final List<MapEntry<File, Map<String, dynamic>>> chunk,
      ) async {
        if (chunk.isEmpty) return;
        if (chunk.length == 1) {
          final entry = chunk.first;
          final snap = snapshotMtimes(chunk);
          // writeTagsWithExifToolSingle handles InteropIFD retries internally
          // (strip OffsetTime* → retry; XMP fallback for JPEGs → retry).
          try {
            await preserveMTime(entry.key, () async {
              await exifWriter.writeTagsWithExifToolSingle(
                entry.key,
                entry.value,
              );
            });
          } finally {
            await restoreMtimes(snap);
          }
          return;
        }

        final mid = chunk.length >> 1;
        final left = chunk.sublist(0, mid);
        final right = chunk.sublist(mid);

        final snap = snapshotMtimes(chunk);

        try {
          await exifWriter.writeTagsWithExifToolBatch(
            chunk,
            useArgFileWhenLarge: useArgFile,
          );
        } catch (e) {
          await _tryDeleteTmpForChunk(chunk);

          final String errStr = e.toString();
          final Set<String> badPaths = _extractBadPathsFromExifError(errStr);
          // Cover both known InteropIFD failure modes triggered by the
          // OffsetTime* tags added in v5.0.9:
          //   "Truncated InteropIFD directory"
          //   "Bad format (N) for InteropIFD entry M"
          final bool interopIfdError = isInteropIfdError(e);

          if (badPaths.isNotEmpty) {
            final List<MapEntry<File, Map<String, dynamic>>> bad =
                <MapEntry<File, Map<String, dynamic>>>[];
            final List<MapEntry<File, Map<String, dynamic>>> good =
                <MapEntry<File, Map<String, dynamic>>>[];
            for (final entry in chunk) {
              final lower = entry.key.path.toLowerCase();
              // Also check suffix in case the extracted path is a relative tail of the full path.
              final matched =
                  badPaths.contains(lower) || badPaths.any(lower.endsWith);
              if (matched) {
                bad.add(entry);
              } else {
                good.add(entry);
              }
            }

            // Only take the "identified bad files" fast path when we actually matched
            // at least one entry.  If nothing matched (e.g. path extraction produced a
            // partial path that still doesn't align with any entry), fall through to
            // the binary-split path below to avoid an infinite recursion where the
            // same failing chunk is re-queued to writeBatchSafe endlessly.
            if (bad.isNotEmpty) {
              // For any InteropIFD error (both "Truncated InteropIFD directory"
              // and "Bad format (N) for InteropIFD entry M"): retag JPEGs to
              // XMP so the per-file retry bypasses the broken IFD entirely.
              if (interopIfdError) {
                for (final b in bad) {
                  final lower = b.key.path.toLowerCase();
                  if (lower.endsWith('.jpg') || lower.endsWith('.jpeg')) {
                    forceJpegXmp.add(lower);
                    _retagEntryToXmpIfJpeg(b);
                  }
                }
              }

              // For any InteropIFD error: also strip the UTC timezone offset
              // tags (OffsetTime*) added in v5.0.9. These trigger IFD traversal
              // on corrupted files; removing them lets the per-file retry succeed
              // with the same behaviour as v5.0.8 and earlier.
              if (interopIfdError) {
                bad.forEach(_stripOffsetTags);
              }

              await restoreMtimes(snap);

              if (good.isNotEmpty) {
                await writeBatchSafe(
                  good,
                  useArgFile: useArgFile,
                  isVideoBatch: isVideoBatch,
                );
              }

              // Atom-too-large is a hard structural limit — ExifTool cannot
              // rewrite the file regardless of tags or batch size.  Skip the
              // per-file retry entirely and emit one clear warning per file.
              if (isAtomTooLargeError(e)) {
                for (final entry in bad) {
                  logWarning(
                    '[Step 7/8] ${entry.key.path}: metadata could not be written'
                    ' — the video file contains a data block too large for'
                    ' ExifTool to rewrite. The file was still sorted correctly.',
                  );
                  await _tryDeleteTmp(entry.key);
                }
                return;
              }

              for (final entry in bad) {
                final singleSnap = snapshotMtimes([entry]);
                try {
                  await preserveMTime(entry.key, () async {
                    await exifWriter.writeTagsWithExifToolSingle(
                      entry.key,
                      entry.value,
                    );
                  });
                } catch (e2) {
                  if (isInteropIfdError(e2)) {
                    logDebug(
                      '[Step 7/8] ${entry.key.path}: write still failed without offset tags '
                      '(corrupted InteropIFD / severe EXIF corruption). Error: $e2',
                    );
                  } else if (!shouldSilenceExiftoolError(e2)) {
                    logWarning(
                      isVideoBatch
                          ? '[Step 7/8] ${entry.key.path}: date/GPS metadata could not be written into this video file. The file was still sorted correctly. Error: $e2'
                          : '[Step 7/8] ${entry.key.path}: date/GPS metadata could not be written into this file. The file was still sorted correctly. Error: $e2',
                    );
                  }
                  await _tryDeleteTmp(entry.key);
                } finally {
                  await restoreMtimes(singleSnap);
                }
              }

              return;
            }
            // bad.isEmpty: path extraction found something in stderr but couldn't
            // match any queue entry — fall through to the binary split below.
          }

          if (isInteropIfdError(e)) {
            logDebug(
              '[Step 7/8] Batch (${chunk.length} files): corrupted InteropIFD detected — '
              'splitting for per-file retry with offset tags stripped. ($e)',
            );
          } else if (!shouldSilenceExiftoolError(e)) {
            logWarning(
              isVideoBatch
                  ? '[Step 7/8] Video batch flush failed (${chunk.length} files) - splitting: $e'
                  : '[Step 7/8] Batch flush failed (${chunk.length} files) - splitting: $e',
            );
          }
          await restoreMtimes(snap);
          await splitAndWrite(left);
          await splitAndWrite(right);
          return;
        }

        await restoreMtimes(snap);
      }

      await splitAndWrite(queue);
    }

    Future<void> flushMapByTagset(
      final Map<String, List<MapEntry<File, Map<String, dynamic>>>> byTagset, {
      required final bool useArgFile,
      required final bool isVideoBatch,
      required final int capPerChunk,
    }) async {
      if (!exifToolAvailable || !enableExifToolBatch) return;
      if (byTagset.isEmpty) return;

      final keys = byTagset.keys.toList();
      for (final k in keys) {
        final list = byTagset[k];
        if (list == null || list.isEmpty) {
          byTagset.remove(k);
          continue;
        }

        while (list.length > capPerChunk) {
          final sub = list.sublist(0, capPerChunk);
          await writeBatchSafe(
            sub,
            useArgFile: true,
            isVideoBatch: isVideoBatch,
          );
          list.removeRange(0, sub.length);
        }

        await writeBatchSafe(
          list,
          useArgFile: useArgFile,
          isVideoBatch: isVideoBatch,
        );
        byTagset.remove(k);
      }
    }

    Future<void> flushImageBatch({required final bool useArgFile}) =>
        flushMapByTagset(
          pendingImagesByTagset,
          useArgFile: useArgFile,
          isVideoBatch: false,
          capPerChunk: maxImageBatch,
        );
    Future<void> flushVideoBatch({required final bool useArgFile}) =>
        flushMapByTagset(
          pendingVideosByTagset,
          useArgFile: useArgFile,
          isVideoBatch: true,
          capPerChunk: maxVideoBatch,
        );

    Future<void> maybeFlushThresholds() async {
      if (!exifToolAvailable || !enableExifToolBatch) return;
      final int targetImageBatch = safeToInt(
        baseBatchSize.clamp(1, maxImageBatch).toDouble(),
        fallback: 100,
      );
      final int targetVideoBatch = safeToInt(
        12.clamp(1, maxVideoBatch).toDouble(),
        fallback: 12,
      );

      for (final entry in pendingImagesByTagset.entries.toList()) {
        if (entry.value.length >= targetImageBatch) {
          await writeBatchSafe(
            entry.value,
            useArgFile: true,
            isVideoBatch: false,
          );
          pendingImagesByTagset.remove(entry.key);
        }
      }
      for (final entry in pendingVideosByTagset.entries.toList()) {
        if (entry.value.length >= targetVideoBatch) {
          await writeBatchSafe(
            entry.value,
            useArgFile: true,
            isVideoBatch: true,
          );
          pendingVideosByTagset.remove(entry.key);
        }
      }
    }

    // Per-file EXIF/XMP writer using the same behavior as in the step.
    Future<Map<String, bool>> writeForFile({
      required final File file,
      required final bool markAsPrimary,
      required final DateTime? effectiveDate,
      required final DateTimeExtractionMethod? dateTimeExtractionMethod,
      required final coordsFromPrimary,
    }) async {
      bool gpsWrittenThis = false;
      bool dtWrittenThis = false;

      try {
        final lower = file.path.toLowerCase();

        // Cheap MIME guess identical to your code
        String? mimeHeader;
        String? mimeExt;
        if (lower.endsWith('.jpg') || lower.endsWith('.jpeg')) {
          mimeHeader = 'image/jpeg';
          mimeExt = 'image/jpeg';
        } else if (lower.endsWith('.heic')) {
          mimeHeader = 'image/heic';
          mimeExt = 'image/heic';
        } else if (lower.endsWith('.png')) {
          mimeHeader = 'image/png';
          mimeExt = 'image/png';
        } else if (lower.endsWith('.mp4')) {
          mimeHeader = 'video/mp4';
          mimeExt = 'video/mp4';
        } else if (lower.endsWith('.mov')) {
          mimeHeader = 'video/quicktime';
          mimeExt = 'video/quicktime';
        } else {
          try {
            final header = await file.openRead(0, 128).first;
            mimeHeader = mime.lookupMimeType(file.path, headerBytes: header);
            mimeExt = mime.lookupMimeType(file.path);
          } catch (_) {
            mimeHeader = mime.lookupMimeType(file.path);
            mimeExt = mimeHeader;
          }
        }

        final tagsToWrite = <String, dynamic>{};

        final bool isPng = mimeHeader == 'image/png' || lower.endsWith('.png');
        // Detect JPEG by content (mimeHeader) rather than extension alone so
        // that files whose extension doesn't match their content (e.g. a DJI
        // .DNG that is bytewise JPEG after Step 1 was unable to rename it due
        // to a collision with an existing .jpg) still use the fast native JPEG
        // write path instead of being sent to ExifTool as a DNG.
        final bool isJpeg =
            lower.endsWith('.jpg') ||
            lower.endsWith('.jpeg') ||
            mimeHeader == 'image/jpeg';
        final bool forceXmpJpeg = isJpeg && forceJpegXmp.contains(lower);
        final bool isVideo = (mimeHeader ?? '').startsWith('video/');

        // GPS handling: always attempt native JPEG writes first for JPEGs.
        try {
          final coords = coordsFromPrimary;
          if (coords != null) {
            if (isJpeg && !forceXmpJpeg) {
              // Try native combined (date+gps) or gps-only writes first.
              if (effectiveDate != null) {
                final bool treatUtc = shouldTreatAsUtc(
                  dateTimeExtractionMethod,
                  effectiveDate,
                );
                final DateTime writeDate = treatUtc
                    ? effectiveDate.toUtc()
                    : effectiveDate;
                final ok = await preserveMTime(
                  file,
                  () async => exifWriter.writeCombinedNativeJpeg(
                    file,
                    writeDate,
                    coords,
                    isUtc: treatUtc,
                  ),
                );
                if (ok) {
                  gpsWrittenThis = true;
                  dtWrittenThis = true;
                } else {
                  // Native failed — fall back to ExifTool only if available.
                  if (exifToolAvailable) {
                    final bool treatUtc = shouldTreatAsUtc(
                      dateTimeExtractionMethod,
                      effectiveDate,
                    );
                    final DateTime writeDate = treatUtc
                        ? effectiveDate.toUtc()
                        : effectiveDate;
                    final dt = formatExifClock(writeDate);
                    tagsToWrite['DateTimeOriginal'] = '"$dt"';
                    tagsToWrite['DateTimeDigitized'] = '"$dt"';
                    tagsToWrite['DateTime'] = '"$dt"';
                    if (treatUtc) addUtcOffsetTags(tagsToWrite);
                    tagsToWrite['GPSLatitude'] = coords
                        .toDD()
                        .latitude
                        .toString();
                    tagsToWrite['GPSLongitude'] = coords
                        .toDD()
                        .longitude
                        .toString();
                    tagsToWrite['GPSLatitudeRef'] = coords
                        .latDirection
                        .abbreviation
                        .toString();
                    tagsToWrite['GPSLongitudeRef'] = coords
                        .longDirection
                        .abbreviation
                        .toString();
                    WriteExifAuxiliaryService.markFallbackCombinedTried(file);
                  } else {
                    logWarning(
                      '[Step 7/8] Native combined write failed and ExifTool not available: ${file.path}',
                    );
                  }
                }
              } else {
                final ok = await preserveMTime(
                  file,
                  () async => exifWriter.writeGpsNativeJpeg(file, coords),
                );
                if (ok) {
                  gpsWrittenThis = true;
                } else {
                  if (exifToolAvailable) {
                    tagsToWrite['GPSLatitude'] = coords
                        .toDD()
                        .latitude
                        .toString();
                    tagsToWrite['GPSLongitude'] = coords
                        .toDD()
                        .longitude
                        .toString();
                    tagsToWrite['GPSLatitudeRef'] = coords
                        .latDirection
                        .abbreviation
                        .toString();
                    tagsToWrite['GPSLongitudeRef'] = coords
                        .longDirection
                        .abbreviation
                        .toString();
                    WriteExifAuxiliaryService.markFallbackGpsTried(file);
                  } else {
                    logWarning(
                      '[Step 7/8] Native GPS write failed and ExifTool not available: ${file.path}',
                    );
                  }
                }
              }
            } else {
              // Non-JPEGs or forced XMP: prepare tags for ExifTool when available.
              if (exifToolAvailable) {
                if (isPng || forceXmpJpeg) {
                  tagsToWrite['XMP:GPSLatitude'] = coords
                      .toDD()
                      .latitude
                      .toString();
                  tagsToWrite['XMP:GPSLongitude'] = coords
                      .toDD()
                      .longitude
                      .toString();
                } else {
                  tagsToWrite['GPSLatitude'] = coords
                      .toDD()
                      .latitude
                      .toString();
                  tagsToWrite['GPSLongitude'] = coords
                      .toDD()
                      .longitude
                      .toString();
                  tagsToWrite['GPSLatitudeRef'] = coords
                      .latDirection
                      .abbreviation
                      .toString();
                  tagsToWrite['GPSLongitudeRef'] = coords
                      .longDirection
                      .abbreviation
                      .toString();
                  // Also write XMP GPS tags for videos to overwrite any
                  // pre-existing XMP values and keep all tag groups consistent.
                  if (isVideo) {
                    tagsToWrite['XMP:GPSLatitude'] = tagsToWrite['GPSLatitude'];
                    tagsToWrite['XMP:GPSLongitude'] =
                        tagsToWrite['GPSLongitude'];
                  }
                }
              }
            }
          }
        } catch (e) {
          logWarning(
            '[Step 7/8] Failed to prepare GPS tags for ${file.path}: $e',
            forcePrint: true,
          );
        }

        // Date/time handling (always try native JPEG write first for JPEGs)
        try {
          if (effectiveDate != null) {
            final bool treatUtc = shouldTreatAsUtc(
              dateTimeExtractionMethod,
              effectiveDate,
            );
            final DateTime writeDate = treatUtc
                ? effectiveDate.toUtc()
                : effectiveDate;
            if (isJpeg && !forceXmpJpeg) {
              if (!dtWrittenThis) {
                final ok = await preserveMTime(
                  file,
                  () async => exifWriter.writeDateTimeNativeJpeg(
                    file,
                    writeDate,
                    isUtc: treatUtc,
                  ),
                );
                if (ok) {
                  dtWrittenThis = true;
                } else {
                  if (exifToolAvailable) {
                    final dt = formatExifClock(writeDate);
                    tagsToWrite['DateTimeOriginal'] = '"$dt"';
                    tagsToWrite['DateTimeDigitized'] = '"$dt"';
                    tagsToWrite['DateTime'] = '"$dt"';
                    if (treatUtc) addUtcOffsetTags(tagsToWrite);
                    WriteExifAuxiliaryService.markFallbackDateTried(file);
                  } else {
                    logWarning(
                      '[Step 7/8] Native DateTime write failed and ExifTool not available: ${file.path}',
                    );
                  }
                }
              }
            } else {
              if (exifToolAvailable) {
                if (isPng || forceXmpJpeg) {
                  final dt = formatXmpDateTime(writeDate, isUtc: treatUtc);
                  tagsToWrite['XMP:CreateDate'] = '"$dt"';
                  tagsToWrite['XMP:DateTimeOriginal'] = '"$dt"';
                  tagsToWrite['XMP:ModifyDate'] = '"$dt"';
                } else {
                  final dt = formatExifClock(writeDate);
                  tagsToWrite['DateTimeOriginal'] = '"$dt"';
                  tagsToWrite['DateTimeDigitized'] = '"$dt"';
                  tagsToWrite['DateTime'] = '"$dt"';
                  if (treatUtc) addUtcOffsetTags(tagsToWrite);
                  // Also write XMP date tags for videos to overwrite any
                  // pre-existing XMP values and keep all tag groups consistent.
                  if (isVideo) {
                    final xmpDt = formatXmpDateTime(writeDate, isUtc: treatUtc);
                    tagsToWrite['XMP:DateTimeOriginal'] = '"$xmpDt"';
                    tagsToWrite['XMP:DateTimeDigitized'] = '"$xmpDt"';
                    tagsToWrite['XMP:ModifyDate'] = '"$xmpDt"';
                  }
                }
              }
            }
          }
        } catch (e) {
          logWarning(
            '[Step 7/8] Failed to prepare DateTime tags for ${file.path}: $e',
            forcePrint: true,
          );
        }

        // Check for unsupported formats before attempting ExifTool writes.
        // This must be outside the tagsToWrite.isNotEmpty check so that
        // unsupported files are warned about even if they have no tags to write.
        try {
          final bool isUnsupported = _isDefinitelyUnsupportedForWrite(
            mimeHeader: mimeHeader,
            mimeExt: mimeExt,
            pathLower: lower,
          );

          if (isUnsupported &&
              !unsupportedPolicy.forceProcessUnsupportedFormats) {
            if (!unsupportedPolicy.silenceUnsupportedWarnings) {
              final detectedFmt = _describeUnsupported(
                mimeHeader: mimeHeader,
                mimeExt: mimeExt,
                pathLower: lower,
              );
              logWarning(
                '[Step 7/8] Skipping $detectedFmt file - ExifTool cannot write $detectedFmt: ${file.path}',
                forcePrint: true,
              );
            }
            // Clear any tags that were prepared — they can't be written.
            tagsToWrite.clear();
          }
        } catch (e) {
          logDebug(
            '[Step 7/8] Error checking unsupported format for ${file.path}: $e',
          );
        }

        // Write using exiftool (per-file or enqueue for batch)
        try {
          if (exifToolAvailable && tagsToWrite.isNotEmpty) {
            if (!enableExifToolBatch) {
              try {
                await preserveMTime(file, () async {
                  WriteExifAuxiliaryService.setPrimaryHint(file, markAsPrimary);
                  await exifWriter.writeTagsWithExifToolSingle(
                    file,
                    tagsToWrite,
                  );
                });
              } catch (e) {
                if (isInteropIfdError(e)) {
                  tagsToWrite
                    ..remove('OffsetTime')
                    ..remove('OffsetTimeOriginal')
                    ..remove('OffsetTimeDigitized');
                  try {
                    await preserveMTime(file, () async {
                      await exifWriter.writeTagsWithExifToolSingle(
                        file,
                        tagsToWrite,
                      );
                    });
                    logDebug(
                      '[Step 7/8] ${file.path}: corrupted InteropIFD — '
                      'UTC offset tags stripped, date/GPS written successfully.',
                    );
                  } catch (_) {
                    // writeTagsWithExifToolSingle handles InteropIFD retries
                    // (strip OffsetTime* → retry; XMP fallback for JPEGs)
                    // internally and returns false on permanent failure.
                    // Nothing more to do here.
                  }
                } else {
                  if (!shouldSilenceExiftoolError(e)) {
                    logWarning(
                      isVideo
                          ? '[Step 7/8] ${file.path}: date/GPS metadata could not be written into this video file. The file was still sorted correctly. Error: $e'
                          : '[Step 7/8] ${file.path}: date/GPS metadata could not be written into this file. The file was still sorted correctly. Error: $e',
                    );
                  }
                  await _tryDeleteTmp(file);
                }
              }
            } else {
              WriteExifAuxiliaryService.setPrimaryHint(file, markAsPrimary);
              final key = stableTagsetKey(tagsToWrite);
              if (isVideo) {
                (pendingVideosByTagset[key] ??=
                        <MapEntry<File, Map<String, dynamic>>>[])
                    .add(MapEntry(file, tagsToWrite));
              } else {
                (pendingImagesByTagset[key] ??=
                        <MapEntry<File, Map<String, dynamic>>>[])
                    .add(MapEntry(file, tagsToWrite));
              }
            }
          }
        } catch (e) {
          if (isInteropIfdError(e)) {
            logDebug(
              '[Step 7/8] ${file.path}: corrupted InteropIFD detected while preparing tags — '
              'UTC offset tags will be stripped on write. ($e)',
            );
          } else if (!shouldSilenceExiftoolError(e)) {
            logWarning(
              '[Step 7/8] Failed to enqueue EXIF tags for ${file.path}: $e',
            );
          }
        }

        if (gpsWrittenThis) {
          WriteExifAuxiliaryService.markGpsTouchedFromStep5(
            file,
            isPrimary: markAsPrimary,
          );
        }
        if (dtWrittenThis) {
          WriteExifAuxiliaryService.markDateTouchedFromStep5(
            file,
            isPrimary: markAsPrimary,
          );
        }
      } catch (e) {
        logError(
          '[Step 7/8] EXIF write failed for ${file.path}: $e',
          forcePrint: true,
        );
      }

      return {'gps': gpsWrittenThis, 'date': dtWrittenThis};
    }

    // Pre-count total output files for a single unified progress bar.
    int totalFiles = 0;
    for (final entity in collection.asList()) {
      for (final fe in [entity.primaryFile, ...entity.secondaryFiles]) {
        if (fe.targetPath != null && !fe.isShortcut) totalFiles++;
      }
    }

    final int progressTotal = totalFiles > 0
        ? totalFiles
        : (collection.length > 0 ? collection.length : 1);
    final progressBar = FillingBar(
      desc: '[ INFO  ] [Step 7/8] Writing EXIF data',
      total: progressTotal,
      width: 50,
      percentage: true,
    );

    int completedFiles = 0;
    int gpsWrittenTotal = 0;
    int dateWrittenTotal = 0;

    // Process with bounded concurrency (same pattern as in your step)
    for (int i = 0; i < collection.length; i += maxConcurrency) {
      final slice = collection
          .asList()
          .skip(i)
          .take(maxConcurrency)
          .toList(growable: false);

      final results = await Future.wait(
        slice.map((final entity) async {
          int localGps = 0;
          int localDate = 0;
          int localFiles = 0;

          // GPS coordinates were extracted and cached on the entity during
          // Step 4 (combined JSON read). No extra file I/O needed here.
          final coordsFromPrimary = entity.gpsCoordinates;

          final List<FileEntity> allFiles = <FileEntity>[
            entity.primaryFile,
            ...entity.secondaryFiles,
          ];

          for (final fe in allFiles) {
            final String? outPath = fe.targetPath;
            if (outPath == null || fe.isShortcut) continue;

            final outFile = File(outPath);
            if (!await outFile.exists()) continue;

            localFiles++;
            final r = await writeForFile(
              file: outFile,
              markAsPrimary: identical(fe, entity.primaryFile),
              effectiveDate: entity.dateTaken,
              dateTimeExtractionMethod: entity.dateTimeExtractionMethod,
              coordsFromPrimary: coordsFromPrimary,
            );
            if (r['gps'] == true) localGps++;
            if (r['date'] == true) localDate++;
          }

          return {'gps': localGps, 'date': localDate, 'files': localFiles};
        }),
      );

      for (final r in results) {
        gpsWrittenTotal += r['gps'] ?? 0;
        dateWrittenTotal += r['date'] ?? 0;
        completedFiles += r['files'] ?? 0;
        progressBar.update(completedFiles);
      }

      if (exifToolAvailable && enableExifToolBatch) {
        await maybeFlushThresholds();
      }
    }

    // Final flush (remaining batches not yet written by ExifTool)
    if (exifToolAvailable && enableExifToolBatch) {
      final int imagesQueued = totalQueued(pendingImagesByTagset);
      final int videosQueued = totalQueued(pendingVideosByTagset);
      logPrint(
        '[Step 7/8] Pending before final flush → Images: $imagesQueued, Videos: $videosQueued',
      );

      final bool flushImagesWithArg =
          imagesQueued > (Platform.isWindows ? 30 : 60);
      final bool flushVideosWithArg = videosQueued > 6;
      await flushImageBatch(useArgFile: flushImagesWithArg);
      await flushVideoBatch(useArgFile: flushVideosWithArg);
    } else {
      pendingImagesByTagset.clear();
      pendingVideosByTagset.clear();
    }

    // Unique-file metrics (same meaning/order)
    final gpsTotal = WriteExifAuxiliaryService.uniqueGpsFilesCount;
    final gpsPrim = WriteExifAuxiliaryService.uniqueGpsPrimaryCount;
    final gpsSec = WriteExifAuxiliaryService.uniqueGpsSecondaryCount;
    final dtTotal = WriteExifAuxiliaryService.uniqueDateFilesCount;
    final dtPrim = WriteExifAuxiliaryService.uniqueDatePrimaryCount;
    final dtSec = WriteExifAuxiliaryService.uniqueDateSecondaryCount;

    print('');
    if (gpsTotal > 0) {
      logPrint(
        '[Step 7/8] $gpsTotal files got GPS set in EXIF data (primary=$gpsPrim, secondary=$gpsSec)',
      );
    }
    if (dtTotal > 0) {
      logPrint(
        '[Step 7/8] $dtTotal files got DateTime set in EXIF data (primary=$dtPrim, secondary=$dtSec)',
      );
    }
    logPrint(
      '[Step 7/8] Processed ${collection.entities.length} entities; touched ${WriteExifAuxiliaryService.uniqueFilesTouchedCount} files',
    );

    // Warn once if any files had unrecoverable InteropIFD failures.
    final interopSkipped = WriteExifAuxiliaryService.interopIfdSkippedCount;
    if (interopSkipped > 0) {
      logWarning(
        '[Step 7/8] $interopSkipped file(s) had corrupted EXIF structure '
        '(InteropIFD) — some EXIF metadata could not be written (see per-file warnings above). '
        'Files were still organised into the correct date folder.',
        // Note: this may be UTC timezone offset tags only (date already written natively),
        // or actual date metadata in cases where native write also failed.
        forcePrint: true,
      );
    }

    // Provide outcome for StepResult mapping
    return WriteExifSummary(
      filesTouched: WriteExifAuxiliaryService.uniqueFilesTouchedCount,
      coordinatesWritten: gpsTotal,
      dateTimesWritten: dtTotal,
      rawGpsWrites: gpsWrittenTotal,
      rawDateWrites: dateWrittenTotal,
    );
  }

  // ------------------------------- Utilities (moved from step; unchanged behavior) --------------------------------

  bool _resolveBatchingPreference(final Object? exifTool) {
    if (exifTool == null) return false;
    try {
      final cfg = ServiceContainer.instance.globalConfig;
      final dyn = cfg as dynamic;
      final v = dyn.enableExifToolBatch;
      if (v is bool) return v;
    } catch (_) {}
    return true;
  }

  _UnsupportedPolicy _resolveUnsupportedPolicy() {
    bool force = false;
    bool silence = false;
    try {
      final cfg = ServiceContainer.instance.globalConfig;
      final dyn = cfg as dynamic;
      if (dyn.forceProcessUnsupportedFormats is bool) {
        force = dyn.forceProcessUnsupportedFormats as bool;
      }
      if (dyn.silenceUnsupportedWarnings is bool) {
        silence = dyn.silenceUnsupportedWarnings as bool;
      }
    } catch (_) {}
    return _UnsupportedPolicy(
      forceProcessUnsupportedFormats: force,
      silenceUnsupportedWarnings: silence,
    );
  }

  bool _isDefinitelyUnsupportedForWrite({
    final String? mimeHeader,
    final String? mimeExt,
    required final String pathLower,
  }) {
    final ext = _extensionOf(pathLower);
    if (ext != null && exifToolUnsupportedExtensionLabels.containsKey(ext)) {
      return true;
    }
    if (mimeHeader != null &&
        exifToolUnsupportedMimeLabels.containsKey(mimeHeader)) {
      return true;
    }
    if (mimeExt != null && exifToolUnsupportedMimeLabels.containsKey(mimeExt)) {
      return true;
    }
    return false;
  }

  String _describeUnsupported({
    final String? mimeHeader,
    final String? mimeExt,
    required final String pathLower,
  }) {
    final ext = _extensionOf(pathLower);
    if (ext != null) {
      final label = exifToolUnsupportedExtensionLabels[ext];
      if (label != null) return label;
    }
    if (mimeHeader != null) {
      final label = exifToolUnsupportedMimeLabels[mimeHeader];
      if (label != null) return label;
    }
    if (mimeExt != null) {
      final label = exifToolUnsupportedMimeLabels[mimeExt];
      if (label != null) return label;
    }
    return 'unsupported';
  }

  /// Returns the lowercase dot-extension of [pathLower], or null if none.
  static String? _extensionOf(final String pathLower) {
    final int dot = pathLower.lastIndexOf('.');
    return dot >= 0 ? pathLower.substring(dot) : null;
  }

  // InteropIFD errors are no longer silenced — they are surfaced at verbose
  // (debug) level only, see [isInteropIfdError] and the call-sites below.
  static bool shouldSilenceExiftoolError(final Object e) => false;

  /// Returns true when [e] is an ExifTool error caused by a corrupted
  /// InteropIFD structure, which is common in Google Photos edited images
  /// and WhatsApp photos. Both known variants are covered:
  ///   "Truncated InteropIFD directory"
  ///   "Bad format (N) for InteropIFD entry M"
  /// Root cause: the OffsetTime* tags added in v5.0.9 trigger ExifTool's IFD
  /// traversal, which aborts on files with a malformed InteropIFD.
  /// Fix: strip those tags before the write (see [_stripOffsetTags]).
  static bool isInteropIfdError(final Object e) =>
      e.toString().contains('InteropIFD');

  /// Returns true when [e] is ExifTool's hard limit on QuickTime/MOV files
  /// whose internal data atom exceeds the rewrite threshold.  Retrying is
  /// pointless — the limit is structural and cannot be worked around by
  /// splitting batches or adjusting tags.
  static bool isAtomTooLargeError(final Object e) =>
      e.toString().contains('atom is too large for rewriting');

  Future<void> _tryDeleteTmp(final File f) async {
    try {
      final tmp = File('${f.path}_exiftool_tmp');
      if (await tmp.exists()) await tmp.delete();
    } catch (_) {}
  }

  Future<void> _tryDeleteTmpForChunk(
    final List<MapEntry<File, Map<String, dynamic>>> chunk,
  ) async {
    for (final e in chunk) {
      await _tryDeleteTmp(e.key);
    }
  }

  int _resolveInt(final String name, {required final int defaultValue}) {
    try {
      final cfg = ServiceContainer.instance.globalConfig;
      final dyn = cfg as dynamic;
      final v = dyn.toJson != null ? (dyn.toJson()[name]) : (dyn[name]);
      if (v is int) return v;
      if (v is String) return int.tryParse(v) ?? defaultValue;
    } catch (_) {}
    return defaultValue;
  }

  /// Visible for testing only — call [_extractBadPathsFromExifError] internally.
  @visibleForTesting
  Set<String> extractBadPathsFromExifErrorForTest(final Object error) =>
      _extractBadPathsFromExifError(error);

  Set<String> _extractBadPathsFromExifError(final Object error) {
    // This parser is designed to be robust across:
    //  • Unix/macOS and Windows
    //  • Absolute and relative paths
    //  • Filenames with spaces and non-ASCII chars
    //  • Paths that themselves contain " - " (e.g. album names like "Birthday Party - 14.8.2022")
    //
    // Strategy:
    //  1) Split the multi-line stderr.
    //  2) For lines that look like ExifTool diagnostics ("Error:" or "Warning:"),
    //     scan ALL occurrences of " - " left-to-right and prefer the FIRST one whose
    //     remainder starts like an absolute path (e.g. "/", "C:\", "\\").
    //     This avoids mistaking a " - " inside the path for the message/path separator.
    //  3) Fall back to the last " - " occurrence for relative paths (original behaviour).
    //  4) Sanitize: trim, strip surrounding quotes, strip trailing punctuation.
    //  5) Add multiple slash-style variants to maximise matching with queue entries.
    //
    // Note: we intentionally return LOWER-CASED strings because the caller compares
    // with entry.key.path.toLowerCase().
    final out = <String>{};
    final s = error.toString();

    // Quick extension whitelist to recognize simple 'filename.ext' cases
    final exts = <String>{
      '.jpg',
      '.jpeg',
      '.png',
      '.heic',
      '.tif',
      '.tiff',
      '.mp4',
      '.mov',
      '.avi',
      '.mpg',
      '.mpeg',
    };

    // Returns true if the candidate starts with an absolute-path prefix.
    bool looksLikeAbsolutePath(final String p) {
      if (p.startsWith('/')) return true; // Unix absolute
      if (p.startsWith(r'\\')) return true; // UNC or \\?\ prefix
      if (p.length >= 3 && p[1] == ':' && (p[2] == '\\' || p[2] == '/')) {
        return true; // Windows C:\ or C:/
      }
      return false;
    }

    bool looksLikePath(final String p) {
      final lp = p.toLowerCase();
      if (lp.contains('/') || lp.contains('\\')) return true; // has a separator
      if (lp.length >= 3 && lp[1] == ':' && (lp[2] == '\\' || lp[2] == '/')) {
        return true; // "c:\..."
      }
      for (final e in exts) {
        if (lp.endsWith(e)) return true;
      }
      return false;
    }

    String stripQuotesAndPunct(final String p) {
      var t = p.trim();

      // Strip surrounding single/double quotes
      if (t.length >= 2) {
        final c0 = t.codeUnitAt(0);
        final cN = t.codeUnitAt(t.length - 1);
        if ((c0 == 0x22 && cN == 0x22) || (c0 == 0x27 && cN == 0x27)) {
          t = t.substring(1, t.length - 1).trim();
        }
      }

      // Strip trailing punctuation commonly added by logs
      while (t.isNotEmpty) {
        final last = t.codeUnitAt(t.length - 1);
        // period, comma, semicolon, colon
        if (last == 0x2E || last == 0x2C || last == 0x3B || last == 0x3A) {
          t = t.substring(0, t.length - 1).trim();
        } else {
          break;
        }
      }
      return t;
    }

    for (final rawLine in s.split('\n')) {
      final line = rawLine.trim();
      if (line.isEmpty) continue;

      // Only consider typical diagnostic lines to reduce false positives
      final hasDiag =
          line.startsWith('Error:') ||
          line.startsWith('Warning:') ||
          line.contains('Error:') ||
          line.contains('Warning:');
      if (!hasDiag) continue;

      // ExifTool format usually:  "Error: <message> - <path>"
      // Paths may themselves contain " - " (e.g. album folders like "Taufe Milian - 14.8.2022").
      // Strategy: scan all " - " occurrences left-to-right; take the FIRST one whose
      // remainder looks like an absolute path.  Fall back to the last occurrence for
      // relative paths (original behaviour).
      const sep = ' - ';
      String? bestCandidate;

      // Pass 1: find first absolute-looking path
      int searchFrom = 0;
      while (true) {
        final idx = line.indexOf(sep, searchFrom);
        if (idx < 0 || idx + sep.length >= line.length) break;
        final candidate = stripQuotesAndPunct(line.substring(idx + sep.length));
        if (candidate.isNotEmpty && looksLikeAbsolutePath(candidate)) {
          bestCandidate = candidate;
          break;
        }
        searchFrom = idx + sep.length;
      }

      // Pass 2 (fallback): use last " - " occurrence, same as before
      if (bestCandidate == null) {
        final idx = line.lastIndexOf(sep);
        if (idx > 0 && idx + sep.length < line.length) {
          final candidate = stripQuotesAndPunct(
            line.substring(idx + sep.length),
          );
          if (candidate.isNotEmpty && looksLikePath(candidate)) {
            bestCandidate = candidate;
          }
        }
      }

      if (bestCandidate == null || bestCandidate.isEmpty) continue;

      // Lowercase for matching with entry.key.path.toLowerCase()
      final lower = bestCandidate.toLowerCase();

      // Add multiple variants to handle slash style mismatches between stderr and our queue
      out.add(lower);
      out.add(lower.replaceAll('\\', '/'));
      out.add(lower.replaceAll('/', '\\'));
    }

    return out;
  }

  /// Removes the UTC timezone offset tags added in v5.0.9
  /// (OffsetTime, OffsetTimeOriginal, OffsetTimeDigitized).
  /// Those tags trigger ExifTool's InteropIFD traversal, which aborts on
  /// files with a corrupted InteropIFD. Stripping them allows the write
  /// to succeed for date/GPS data, matching the v5.0.8 behaviour.
  void _stripOffsetTags(final MapEntry<File, Map<String, dynamic>> entry) {
    entry.value
      ..remove('OffsetTime')
      ..remove('OffsetTimeOriginal')
      ..remove('OffsetTimeDigitized');
  }

  void _retagEntryToXmpIfJpeg(
    final MapEntry<File, Map<String, dynamic>> entry,
  ) {
    final lower = entry.key.path.toLowerCase();
    if (!(lower.endsWith('.jpg') || lower.endsWith('.jpeg'))) return;
    applyXmpConversionInPlace(entry.value);
  }
}

/// Simple data holder for StepResult mapping (kept explicit for clarity).
class WriteExifSummary {
  WriteExifSummary({
    required this.filesTouched,
    required this.coordinatesWritten,
    required this.dateTimesWritten,
    required this.rawGpsWrites,
    required this.rawDateWrites,
  });

  final int filesTouched;
  final int coordinatesWritten;
  final int dateTimesWritten;
  final int rawGpsWrites;
  final int rawDateWrites;
}

/// _UnsupportedPolicy
class _UnsupportedPolicy {
  const _UnsupportedPolicy({
    required this.forceProcessUnsupportedFormats,
    required this.silenceUnsupportedWarnings,
  });
  final bool forceProcessUnsupportedFormats;
  final bool silenceUnsupportedWarnings;
}
