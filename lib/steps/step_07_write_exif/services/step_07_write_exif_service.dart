import 'dart:io';
import 'dart:typed_data';

import 'package:console_bars/console_bars.dart';
import 'package:meta/meta.dart' show visibleForTesting;
import 'package:coordinate_converter/coordinate_converter.dart';
import 'package:gpth_neo/gpth_lib_exports.dart';
import 'package:image/image.dart';
// ignore: implementation_imports
import 'package:image/src/util/rational.dart';
import 'package:intl/intl.dart';
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
  Future<WriteExifRunOutcome> processCollection({
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

    String stableTagsetKey(final Map<String, dynamic> tags) {
      final keys = tags.keys.toList()..sort();
      final buf = StringBuffer();
      for (final k in keys) {
        buf.write(k);
        buf.write('=');
        final v = tags[k];
        buf.write(v is String ? v : v.toString());
        buf.write('\u0001');
      }
      return buf.toString();
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

    // SECOND progress bar for the final flush
    FillingBar? finalFlushBar;
    int finalFlushTotal = 0;
    int finalFlushDone = 0;

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
          try {
            await preserveMTime(entry.key, () async {
              await exifWriter.writeTagsWithExifToolSingle(
                entry.key,
                entry.value,
              );
            });
          } catch (e) {
            if (!shouldSilenceExiftoolError(e)) {
              logWarning(
                isVideoBatch
                    ? '[Step 7/8] Per-file video write failed: ${entry.key.path} -> $e'
                    : '[Step 7/8] Per-file write failed: ${entry.key.path} -> $e',
              );
            }
            await _tryDeleteTmp(entry.key);
          } finally {
            await restoreMtimes(snap);
          }
          if (finalFlushBar != null) {
            finalFlushDone += 1;
            finalFlushBar.update(finalFlushDone);
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
          final bool truncated = errStr.contains('Truncated InteropIFD');

          if (badPaths.isNotEmpty) {
            final List<MapEntry<File, Map<String, dynamic>>> bad =
                <MapEntry<File, Map<String, dynamic>>>[];
            final List<MapEntry<File, Map<String, dynamic>>> good =
                <MapEntry<File, Map<String, dynamic>>>[];
            for (final entry in chunk) {
              final lower = entry.key.path.toLowerCase();
              // Also check suffix in case the extracted path is a relative tail of the full path.
              final matched =
                  badPaths.contains(lower) ||
                  badPaths.any((final bp) => lower.endsWith(bp));
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
              if (truncated) {
                for (final b in bad) {
                  final lower = b.key.path.toLowerCase();
                  if (lower.endsWith('.jpg') || lower.endsWith('.jpeg')) {
                    forceJpegXmp.add(lower);
                    _retagEntryToXmpIfJpeg(b);
                  }
                }
              }

              await restoreMtimes(snap);

              if (good.isNotEmpty) {
                await writeBatchSafe(
                  good,
                  useArgFile: useArgFile,
                  isVideoBatch: isVideoBatch,
                );
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
                  if (!shouldSilenceExiftoolError(e2)) {
                    logWarning(
                      isVideoBatch
                          ? '[Step 7/8] Per-file video write failed: ${entry.key.path} -> $e2'
                          : '[Step 7/8] Per-file write failed: ${entry.key.path} -> $e2',
                    );
                  }
                  await _tryDeleteTmp(entry.key);
                } finally {
                  await restoreMtimes(singleSnap);
                }
                if (finalFlushBar != null) {
                  finalFlushDone += 1;
                  finalFlushBar.update(finalFlushDone);
                }
              }

              return;
            }
            // bad.isEmpty: path extraction found something in stderr but couldn't
            // match any queue entry — fall through to the binary split below.
          }

          if (!shouldSilenceExiftoolError(e)) {
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

        if (finalFlushBar != null) {
          finalFlushDone += chunk.length;
          finalFlushBar.update(finalFlushDone);
        }
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
      final int targetImageBatch = baseBatchSize
          .clamp(1, maxImageBatch)
          .toInt();
      final int targetVideoBatch = 12.clamp(1, maxVideoBatch).toInt();

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
        final bool isJpeg = lower.endsWith('.jpg') || lower.endsWith('.jpeg');
        final bool forceXmpJpeg = isJpeg && forceJpegXmp.contains(lower);

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
                  ),
                );
                if (ok) {
                  gpsWrittenThis = true;
                  dtWrittenThis = true;
                  if (treatUtc && exifToolAvailable) {
                    // Ensure ExifTool-visible DateTime* and explicit UTC offset.
                    // (Some native EXIF injection paths are not consistently recognized by ExifTool/viewers.)
                    final dt = formatExifClock(writeDate);
                    tagsToWrite['DateTimeOriginal'] = '"$dt"';
                    tagsToWrite['DateTimeDigitized'] = '"$dt"';
                    tagsToWrite['DateTime'] = '"$dt"';
                    addUtcOffsetTags(tagsToWrite);
                  }
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
                  () async =>
                      exifWriter.writeDateTimeNativeJpeg(file, writeDate),
                );
                if (ok) {
                  dtWrittenThis = true;
                  if (treatUtc && exifToolAvailable) {
                    // Ensure ExifTool-visible DateTime* and explicit UTC offset.
                    final dt = formatExifClock(writeDate);
                    tagsToWrite['DateTimeOriginal'] = '"$dt"';
                    tagsToWrite['DateTimeDigitized'] = '"$dt"';
                    tagsToWrite['DateTime'] = '"$dt"';
                    addUtcOffsetTags(tagsToWrite);
                  }
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

        // Write using exiftool (per-file or enqueue for batch)
        try {
          if (exifToolAvailable && tagsToWrite.isNotEmpty) {
            final bool isVideo = (mimeHeader ?? '').startsWith('video/');
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
            } else {
              if (!enableExifToolBatch) {
                try {
                  await preserveMTime(file, () async {
                    WriteExifAuxiliaryService.setPrimaryHint(
                      file,
                      markAsPrimary,
                    );
                    await exifWriter.writeTagsWithExifToolSingle(
                      file,
                      tagsToWrite,
                    );
                  });
                } catch (e) {
                  if (!shouldSilenceExiftoolError(e)) {
                    logWarning(
                      isVideo
                          ? '[Step 7/8] Per-file video write failed: ${file.path} -> $e'
                          : '[Step 7/8] Per-file write failed: ${file.path} -> $e',
                    );
                  }
                  await _tryDeleteTmp(file);
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
          }
        } catch (e) {
          if (!shouldSilenceExiftoolError(e)) {
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

    // Live progress bar (first bar): entities processed – kept for consistency
    final progressBar = FillingBar(
      desc: '[ INFO  ] [Step 7/8] Writing EXIF data',
      total: collection.length,
      width: 50,
      percentage: true,
    );

    int completedEntities = 0;
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

          dynamic coordsFromPrimary;
          try {
            final primarySourceFile = File(entity.primaryFile.sourcePath);
            coordsFromPrimary = await jsonCoordinatesExtractor(
              primarySourceFile,
            );
          } catch (_) {
            coordsFromPrimary = null;
          }

          final List<FileEntity> allFiles = <FileEntity>[
            entity.primaryFile,
            ...entity.secondaryFiles,
          ];

          for (final fe in allFiles) {
            final String? outPath = fe.targetPath;
            if (outPath == null || fe.isShortcut) continue;

            final outFile = File(outPath);
            if (!await outFile.exists()) continue;

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

          return {'gps': localGps, 'date': localDate};
        }),
      );

      for (final r in results) {
        gpsWrittenTotal += r['gps'] ?? 0;
        dateWrittenTotal += r['date'] ?? 0;
        completedEntities++;
        progressBar.update(completedEntities);
      }

      if (exifToolAvailable && enableExifToolBatch) {
        await maybeFlushThresholds();
      }
    }

    // Final flush telemetry + second bar (identical UX)
    if (exifToolAvailable && enableExifToolBatch) {
      final int imagesQueued = totalQueued(pendingImagesByTagset);
      final int videosQueued = totalQueued(pendingVideosByTagset);
      print('');
      logPrint(
        '[Step 7/8] Pending before final flush → Images: $imagesQueued, Videos: $videosQueued',
      );

      finalFlushTotal = imagesQueued + videosQueued;
      if (finalFlushTotal > 0) {
        finalFlushBar = FillingBar(
          desc: '[ INFO  ] [Step 7/8] Flushing pending EXIF writes',
          total: finalFlushTotal,
          width: 50,
          percentage: true,
        );
      }

      final bool flushImagesWithArg =
          imagesQueued > (Platform.isWindows ? 30 : 60);
      final bool flushVideosWithArg = videosQueued > 6;
      await flushImageBatch(useArgFile: flushImagesWithArg);
      await flushVideoBatch(useArgFile: flushVideosWithArg);

      if (finalFlushBar != null) {
        finalFlushDone = finalFlushTotal;
        finalFlushBar.update(finalFlushDone);
        print('');
      }
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

    // Provide outcome for StepResult mapping
    return WriteExifRunOutcome(
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
    if (pathLower.endsWith('.avi') ||
        pathLower.endsWith('.mpg') ||
        pathLower.endsWith('.mpeg') ||
        pathLower.endsWith('.bmp')) {
      return true;
    }
    if (mimeHeader == 'video/x-msvideo' || mimeExt == 'video/x-msvideo') {
      return true; // AVI
    }
    if ((mimeHeader ?? '').contains('mpeg') ||
        (mimeExt ?? '').contains('mpeg')) {
      return true; // MPG/MPEG
    }
    if ((mimeHeader ?? '') == 'image/bmp' || (mimeExt ?? '') == 'image/bmp') {
      return true; // BMP
    }
    return false;
  }

  String _describeUnsupported({
    final String? mimeHeader,
    final String? mimeExt,
    required final String pathLower,
  }) {
    if (pathLower.endsWith('.avi') ||
        mimeHeader == 'video/x-msvideo' ||
        mimeExt == 'video/x-msvideo') {
      return 'AVI';
    }
    if (pathLower.endsWith('.mpg') ||
        pathLower.endsWith('.mpeg') ||
        (mimeHeader ?? '').contains('mpeg') ||
        (mimeExt ?? '').contains('mpeg')) {
      return 'MPEG';
    }
    if (pathLower.endsWith('.bmp') ||
        mimeHeader == 'image/bmp' ||
        mimeExt == 'image/bmp') {
      return 'BMP';
    }
    return 'unsupported';
  }

  static bool shouldSilenceExiftoolError(final Object e) {
    final s = e.toString();
    if (s.contains('Truncated InteropIFD directory')) return true;
    return false;
  }

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
      if (p.length >= 3 && p[1] == ':' && (p[2] == '\\' || p[2] == '/'))
        return true; // Windows C:\ or C:/
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

  void _retagEntryToXmpIfJpeg(
    final MapEntry<File, Map<String, dynamic>> entry,
  ) {
    final lower = entry.key.path.toLowerCase();
    if (!(lower.endsWith('.jpg') || lower.endsWith('.jpeg'))) return;
    final tags = entry.value;

    final dynamic dtVal =
        tags['DateTimeOriginal'] ??
        tags['DateTimeDigitized'] ??
        tags['DateTime'];
    tags.remove('DateTimeOriginal');
    tags.remove('DateTimeDigitized');
    tags.remove('DateTime');
    if (dtVal != null) {
      tags['XMP:CreateDate'] = dtVal;
      tags['XMP:DateTimeOriginal'] = dtVal;
      tags['XMP:ModifyDate'] = dtVal;
    }

    double? toDouble(final v) {
      try {
        if (v == null) return null;
        final s = v.toString().trim().replaceAll('"', '');
        return double.tryParse(s);
      } catch (_) {
        return null;
      }
    }

    final latRef = (tags['GPSLatitudeRef'] ?? '').toString().toUpperCase();
    final lonRef = (tags['GPSLongitudeRef'] ?? '').toString().toUpperCase();
    double? lat = toDouble(tags['GPSLatitude']);
    double? lon = toDouble(tags['GPSLongitude']);
    if (lat != null && latRef == 'S') lat = -lat;
    if (lon != null && lonRef == 'W') lon = -lon;

    tags.remove('GPSLatitude');
    tags.remove('GPSLongitude');
    tags.remove('GPSLatitudeRef');
    tags.remove('GPSLongitudeRef');

    if (lat != null && lon != null) {
      tags['XMP:GPSLatitude'] = lat.toString();
      tags['XMP:GPSLongitude'] = lon.toString();
    }
  }
}

/// Auxiliary Service for WriteExifService
class WriteExifAuxiliaryService with LoggerMixin {
  WriteExifAuxiliaryService(this._exifTool);

  // Nullable: ExifTool backing service may be absent when running native-only.
  late final ExifToolService? _exifTool;

  // ───────────────────── Instrumentation (per-process static) ─────────────────
  // Calls
  // exiftoolCalls removed from public telemetry aggregation to avoid confusion in the new format.

  // Unique file tracking (authoritative for Step 5 final "files got …")
  static final Set<String> _touchedFiles = <String>{};
  static final Set<String> _dateTouchedFiles = <String>{};
  static final Set<String> _gpsTouchedFiles = <String>{};

  // NEW: split by primary/secondary so Step 5 can show the breakdown in parentheses.
  static final Set<String> _dateTouchedPrimary = <String>{};
  static final Set<String> _dateTouchedSecondary = <String>{};
  static final Set<String> _gpsTouchedPrimary = <String>{};
  static final Set<String> _gpsTouchedSecondary = <String>{};

  // NEW: hint registry (filled by Step 7) to know if a file is primary or secondary when ExifTool succeeds.
  static final Map<String, bool> _primaryHint = <String, bool>{};
  static void setPrimaryHint(final File file, final bool isPrimary) {
    _primaryHint[file.path] = isPrimary;
  }

  static bool? _consumePrimaryHint(final File file) =>
      _primaryHint.remove(file.path);

  static void _markTouched(
    final File file, {
    required final bool date,
    required final bool gps,
  }) {
    final p = file.path;
    _touchedFiles.add(p);
    if (date) _dateTouchedFiles.add(p);
    if (gps) _gpsTouchedFiles.add(p);
  }

  /// NEW: public helpers so Step 5 (who knows primary vs secondary) can annotate the unique sets accordingly.
  static void markDateTouchedFromStep5(
    final File file, {
    required final bool isPrimary,
  }) {
    final p = file.path;
    _touchedFiles.add(p);
    _dateTouchedFiles.add(p);
    if (isPrimary) {
      _dateTouchedPrimary.add(p);
      // If it was already in secondary set (shouldn't happen), keep unique semantics anyway.
      _dateTouchedSecondary.remove(p);
    } else {
      // Only add to secondary if not already marked as primary.
      if (!_dateTouchedPrimary.contains(p)) _dateTouchedSecondary.add(p);
    }
  }

  static void markGpsTouchedFromStep5(
    final File file, {
    required final bool isPrimary,
  }) {
    final p = file.path;
    _touchedFiles.add(p);
    _gpsTouchedFiles.add(p);
    if (isPrimary) {
      _gpsTouchedPrimary.add(p);
      _gpsTouchedSecondary.remove(p);
    } else {
      if (!_gpsTouchedPrimary.contains(p)) _gpsTouchedSecondary.add(p);
    }
  }

  static int get uniqueFilesTouchedCount => _touchedFiles.length;
  static int get uniqueDateFilesCount => _dateTouchedFiles.length;
  static int get uniqueGpsFilesCount => _gpsTouchedFiles.length;

  // NEW: getters for the split
  static int get uniqueDatePrimaryCount => _dateTouchedPrimary.length;
  static int get uniqueDateSecondaryCount => _dateTouchedSecondary.length;
  static int get uniqueGpsPrimaryCount => _gpsTouchedPrimary.length;
  static int get uniqueGpsSecondaryCount => _gpsTouchedSecondary.length;

  // Fallback marks to correctly classify ExifTool runs as "fallback" (after native failure)
  static final Set<String> _fallbackMarkedDate = <String>{};
  static final Set<String> _fallbackMarkedGps = <String>{};
  static final Set<String> _fallbackMarkedCombined = <String>{};

  static void _resetTouched() {
    _touchedFiles.clear();
    _dateTouchedFiles.clear();
    _gpsTouchedFiles.clear();
    _dateTouchedPrimary.clear();
    _dateTouchedSecondary.clear();
    _gpsTouchedPrimary.clear();
    _gpsTouchedSecondary.clear();
    _primaryHint.clear(); // clear hints as well

    _fallbackMarkedDate.clear();
    _fallbackMarkedGps.clear();
    _fallbackMarkedCombined.clear();

    // Reset new counters
    nativeDateSuccess = 0;
    nativeDateFail = 0;
    nativeDateDur = Duration.zero;

    nativeGpsSuccess = 0;
    nativeGpsFail = 0;
    nativeGpsDur = Duration.zero;

    nativeCombinedSuccess = 0;
    nativeCombinedFail = 0;
    nativeCombinedDur = Duration.zero;

    xtDateDirectSuccess = 0;
    xtDateDirectFail = 0;
    xtDateDirectDur = Duration.zero;

    xtGpsDirectSuccess = 0;
    xtGpsDirectFail = 0;
    xtGpsDirectDur = Duration.zero;

    xtCombinedDirectSuccess = 0;
    xtCombinedDirectFail = 0;
    xtCombinedDirectDur = Duration.zero;

    xtDateFallbackRecovered = 0;
    xtDateFallbackFail = 0;
    xtDateFallbackDur = Duration.zero;

    xtGpsFallbackRecovered = 0;
    xtGpsFallbackFail = 0;
    xtGpsFallbackDur = Duration.zero;

    xtCombinedFallbackRecovered = 0;
    xtCombinedFallbackFail = 0;
    xtCombinedFallbackDur = Duration.zero;
  }

  // Native path (success/fail split by type)
  // Counts are now grouped by category (DATE, GPS, DATE+GPS) and by Native Direct.
  static int nativeDateSuccess = 0;
  static int nativeDateFail = 0;
  static Duration nativeDateDur = Duration.zero;

  static int nativeGpsSuccess = 0;
  static int nativeGpsFail = 0;
  static Duration nativeGpsDur = Duration.zero;

  static int nativeCombinedSuccess = 0;
  static int nativeCombinedFail = 0;
  static Duration nativeCombinedDur = Duration.zero;

  // ExifTool path (success/fail split by type)
  // IMPORTANT: Fallbacks are counted separately from Direct so the total line excludes fallbacks.
  static int xtDateDirectSuccess = 0;
  static int xtDateDirectFail = 0;
  static Duration xtDateDirectDur = Duration.zero;

  static int xtGpsDirectSuccess = 0;
  static int xtGpsDirectFail = 0;
  static Duration xtGpsDirectDur = Duration.zero;

  static int xtCombinedDirectSuccess = 0;
  static int xtCombinedDirectFail = 0;
  static Duration xtCombinedDirectDur = Duration.zero;

  // Routing breakdown for ExifTool
  // Fallback metrics (files that reached ExifTool because native failed first).
  static int xtDateFallbackRecovered = 0;
  static int xtDateFallbackFail = 0;
  static Duration xtDateFallbackDur = Duration.zero;

  static int xtGpsFallbackRecovered = 0;
  static int xtGpsFallbackFail = 0;
  static Duration xtGpsFallbackDur = Duration.zero;

  static int xtCombinedFallbackRecovered = 0;
  static int xtCombinedFallbackFail = 0;
  static Duration xtCombinedFallbackDur = Duration.zero;

  // Durations helpers
  static String _fmtSec(final Duration d) =>
      '${(d.inMilliseconds / 1000.0).toStringAsFixed(3)}s';

  // NEW: Mirrors for GPS write stats so no dependency on any extractor.
  // These per-tag mirrors are no longer used in the final summary; preserved behaviorally by the unique-file sets above.

  /// Print instrumentation lines; reset counters optionally.
  static void dumpWriterStats({
    final bool reset = true,
    final LoggerMixin? logger,
  }) {
    // Helper for output respecting the original LoggerMixin pattern
    void out(final String s) {
      if (logger != null) {
        logger.logPrint(s);
      } else {
        LoggingService().info(s);
      }
    }

    // Category printer conforming to new format
    void printCategory({
      required final String title,
      required final int nativeOk,
      required final int nativeFail,
      required final Duration nativeDur,
      required final int xtDirectOk,
      required final int xtDirectFail,
      required final Duration xtDirectDur,
      required final int xtFallbackRecovered,
      required final int xtFallbackFail,
      required final Duration xtFallbackDur,
    }) {
      final totalNative = nativeOk + nativeFail;
      final totalDirect = xtDirectOk + xtDirectFail;
      final totalFallback = xtFallbackRecovered + xtFallbackFail;

      out('[Step 7/8]    $title');
      out(
        '[Step 7/8]         Native Direct    : Total: $totalNative (Success: $nativeOk, Fails: $nativeFail) - Time: ${_fmtSec(nativeDur)}',
      );
      out(
        '[Step 7/8]         Exiftool Direct  : Total: $totalDirect (Success: $xtDirectOk, Fails: $xtDirectFail) - Time: ${_fmtSec(xtDirectDur)}',
      );
      out(
        '[Step 7/8]         Exiftool Fallback: Total: $totalFallback (Recovered: $xtFallbackRecovered, Fails: $xtFallbackFail) - Time: ${_fmtSec(xtFallbackDur)}',
      );

      // Total excludes fallbacks to avoid double counting the same files twice.
      final totalOk = nativeOk + xtDirectOk;
      final totalFail = nativeFail + xtDirectFail;
      final total = totalOk + totalFail;
      final totalTime = _fmtSec(nativeDur + xtDirectDur);
      out(
        '[Step 7/8]         Total Files      : Total: $total (Success: $totalOk, Fails: $totalFail) - Time: $totalTime',
      );
    }

    // Header
    out('[Step 7/8] === Telemetry Summary ===');

    // DATE+GPS
    printCategory(
      title: '[WRITE DATE+GPS]:',
      nativeOk: nativeCombinedSuccess,
      nativeFail: nativeCombinedFail,
      nativeDur: nativeCombinedDur,
      xtDirectOk: xtCombinedDirectSuccess,
      xtDirectFail: xtCombinedDirectFail,
      xtDirectDur: xtCombinedDirectDur,
      xtFallbackRecovered: xtCombinedFallbackRecovered,
      xtFallbackFail: xtCombinedFallbackFail,
      xtFallbackDur: xtCombinedFallbackDur,
    );

    // ONLY DATE
    printCategory(
      title: '[WRITE ONLY DATE]:',
      nativeOk: nativeDateSuccess,
      nativeFail: nativeDateFail,
      nativeDur: nativeDateDur,
      xtDirectOk: xtDateDirectSuccess,
      xtDirectFail: xtDateDirectFail,
      xtDirectDur: xtDateDirectDur,
      xtFallbackRecovered: xtDateFallbackRecovered,
      xtFallbackFail: xtDateFallbackFail,
      xtFallbackDur: xtDateFallbackDur,
    );

    // ONLY GPS
    printCategory(
      title: '[WRITE ONLY GPS]:',
      nativeOk: nativeGpsSuccess,
      nativeFail: nativeGpsFail,
      nativeDur: nativeGpsDur,
      xtDirectOk: xtGpsDirectSuccess,
      xtDirectFail: xtGpsDirectFail,
      xtDirectDur: xtGpsDirectDur,
      xtFallbackRecovered: xtGpsFallbackRecovered,
      xtFallbackFail: xtGpsFallbackFail,
      xtFallbackDur: xtGpsFallbackDur,
    );

    if (reset) {
      _resetTouched();
    }
  }

  // ─────────────────────────── Internal helpers ──────────────────────────────

  /// Heuristic: determine if this exiftool write looks like a fallback after a native JPEG attempt.
  /// In current Step 5 implementation, tags for JPEG are only enqueued when native fails.
  static bool _looksLikeFallbackToExiftool(
    final File file,
    final Map<String, dynamic> tags,
  ) {
    final p = file.path.toLowerCase();
    if (!(p.endsWith('.jpg') || p.endsWith('.jpeg'))) return false;
    final keys = tags.keys;
    final hasDate = keys.any(
      (final k) =>
          k == 'DateTimeOriginal' ||
          k == 'DateTimeDigitized' ||
          k == 'DateTime',
    );
    final hasGps = keys.any(
      (final k) =>
          k == 'GPSLatitude' ||
          k == 'GPSLongitude' ||
          k == 'GPSLatitudeRef' ||
          k == 'GPSLongitudeRef',
    );
    return hasDate || hasGps;
  }

  /// Classify tag map into (date/gps/combined) for counters.
  static ({bool isDate, bool isGps, bool isCombined}) _classifyTags(
    final Map<String, dynamic> tags,
  ) {
    final keys = tags.keys;
    final hasDate = keys.any(
      (final k) =>
          k == 'DateTimeOriginal' ||
          k == 'DateTimeDigitized' ||
          k == 'DateTime',
    );
    final hasGps = keys.any(
      (final k) =>
          k == 'GPSLatitude' ||
          k == 'GPSLongitude' ||
          k == 'GPSLatitudeRef' ||
          k == 'GPSLongitudeRef',
    );
    return (
      isDate: hasDate && !hasGps,
      isGps: !hasDate && hasGps,
      isCombined: hasDate && hasGps,
    );
  }

  static bool _consumeMarkedFallback(
    final File file, {
    required final bool asDate,
    required final bool asGps,
    required final bool asCombined,
  }) {
    final p = file.path;
    if (asCombined && _fallbackMarkedCombined.remove(p)) return true;
    if (asDate && _fallbackMarkedDate.remove(p)) return true;
    if (asGps && _fallbackMarkedGps.remove(p)) return true;
    return false;
  }

  static bool _peekMarkedFallback(
    final File file, {
    required final bool asDate,
    required final bool asGps,
    required final bool asCombined,
  }) {
    final p = file.path;
    if (asCombined && _fallbackMarkedCombined.contains(p)) return true;
    if (asDate && _fallbackMarkedDate.contains(p)) return true;
    if (asGps && _fallbackMarkedGps.contains(p)) return true;
    return false;
  }

  // Public markers to be called when enqueueing ExifTool after a native failure.
  static void markFallbackDateTried(final File file) {
    _fallbackMarkedDate.add(file.path);
  }

  static void markFallbackCombinedTried(final File file) {
    _fallbackMarkedCombined.add(file.path);
  }

  static void markFallbackGpsTried(final File file) {
    _fallbackMarkedGps.add(file.path);
  }

  // ─────────────────────────── Public helpers ────────────────────────────────

  /// Single-exec write for arbitrary tags (counts success/fail and duration).
  /// Time and routing attribution preserved exactly as before.
  Future<bool> writeTagsWithExifToolSingle(
    final File file,
    final Map<String, dynamic> tags, {
    final bool countAsCombined =
        false, // kept for backward compat, but classification below is preferred
    final bool isDate = false, // kept for backward compat
    final bool isGps = false, // kept for backward compat
  }) async {
    if (tags.isEmpty) return false;

    final sw = Stopwatch()..start();
    final looksFallback = _looksLikeFallbackToExiftool(file, tags);
    final cls = _classifyTags(tags);
    final bool asCombined = countAsCombined || cls.isCombined;
    final bool asDate = isDate || cls.isDate;
    final bool asGps = isGps || cls.isGps;

    try {
      await _exifTool!.writeExifDataSingle(file, tags);

      final elapsed = sw.elapsed;
      final wasMarkedFallback = _consumeMarkedFallback(
        file,
        asDate: asDate,
        asGps: asGps,
        asCombined: asCombined,
      );

      // Routing breakdown and counters (unchanged behavior)
      if (asCombined) {
        if (wasMarkedFallback || looksFallback) {
          xtCombinedFallbackRecovered++;
          xtCombinedFallbackDur += elapsed;
          logDebug(
            '[Step 7/8] [WRITE-EXIF] Date+GPS written with ExifTool as Fallback of Native writter: ${file.path}',
          );
        } else {
          xtCombinedDirectSuccess++;
          xtCombinedDirectDur += elapsed;
        }
      } else if (asDate) {
        if (wasMarkedFallback || looksFallback) {
          xtDateFallbackRecovered++;
          xtDateFallbackDur += elapsed;
          logDebug(
            '[Step 7/8] [WRITE-EXIF] Date written with ExifTool as Fallback of Native writter: ${file.path}',
          );
        } else {
          xtDateDirectSuccess++;
          xtDateDirectDur += elapsed;
        }
      } else if (asGps) {
        if (wasMarkedFallback || looksFallback) {
          xtGpsFallbackRecovered++;
          xtGpsFallbackDur += elapsed;
          logDebug(
            '[Step 7/8] [WRITE-EXIF] GPS written with ExifTool as Fallback of Native writter: ${file.path}',
          );
        } else {
          xtGpsDirectSuccess++;
          xtGpsDirectDur += elapsed;
        }
      }

      // Touch unique sets (primary/secondary hint respected)
      final bool? hintIsPrimary = _consumePrimaryHint(file);
      if (asCombined) {
        if (hintIsPrimary != null) {
          markDateTouchedFromStep5(file, isPrimary: hintIsPrimary);
          markGpsTouchedFromStep5(file, isPrimary: hintIsPrimary);
        } else {
          _markTouched(file, date: true, gps: true);
        }
      } else if (asDate) {
        if (hintIsPrimary != null) {
          markDateTouchedFromStep5(file, isPrimary: hintIsPrimary);
        } else {
          _markTouched(file, date: true, gps: false);
        }
      } else if (asGps) {
        if (hintIsPrimary != null) {
          markGpsTouchedFromStep5(file, isPrimary: hintIsPrimary);
        } else {
          _markTouched(file, date: false, gps: true);
        }
      }

      return true;
    } catch (e) {
      final elapsed = sw.elapsed;
      final wasMarkedFallback = _consumeMarkedFallback(
        file,
        asDate: asDate,
        asGps: asGps,
        asCombined: asCombined,
      );

      if (asCombined) {
        if (wasMarkedFallback || _looksLikeFallbackToExiftool(file, tags)) {
          xtCombinedFallbackFail++;
          xtCombinedFallbackDur += elapsed;
        } else {
          xtCombinedDirectFail++;
          xtCombinedDirectDur += elapsed;
        }
      } else if (asDate) {
        if (wasMarkedFallback || _looksLikeFallbackToExiftool(file, tags)) {
          xtDateFallbackFail++;
          xtDateFallbackDur += elapsed;
        } else {
          xtDateDirectFail++;
          xtDateDirectDur += elapsed;
        }
      } else if (asGps) {
        if (wasMarkedFallback || _looksLikeFallbackToExiftool(file, tags)) {
          xtGpsFallbackFail++;
          xtGpsFallbackDur += elapsed;
        } else {
          xtGpsDirectFail++;
          xtGpsDirectDur += elapsed;
        }
      }

      logWarning(
        '[ExifToolService] Failed to write tags: ${tags.keys.toList()} to ${file.path}: $e',
      );
      return false;
    }
  }

  /// Batch write: list of (file -> tags). Counts one exiftool call.
  /// Time attribution is **proportional** across categories to avoid overcount.
  /// Also splits "direct vs fallback" using the same heuristic per entry.
  Future<void> writeTagsWithExifToolBatch(
    final List<MapEntry<File, Map<String, dynamic>>> batch, {
    required final bool useArgFileWhenLarge,
  }) async {
    if (batch.isEmpty) return;

    // Pre-classify entries for accurate proportional attribution and fallback/direct split.
    final entriesMeta =
        <
          ({
            File file,
            bool isDate,
            bool isGps,
            bool isCombined,
            bool isFallbackMarked,
          })
        >[];
    int countDateDirect = 0, countGpsDirect = 0, countCombinedDirect = 0;
    int countDateFallback = 0, countGpsFallback = 0, countCombinedFallback = 0;

    for (final entry in batch) {
      final cls = _classifyTags(entry.value);
      final isFallbackMarked = _peekMarkedFallback(
        entry.key,
        asDate: cls.isDate,
        asGps: cls.isGps,
        asCombined: cls.isCombined,
      );
      entriesMeta.add((
        file: entry.key,
        isDate: cls.isDate,
        isGps: cls.isGps,
        isCombined: cls.isCombined,
        isFallbackMarked: isFallbackMarked,
      ));

      if (cls.isCombined) {
        if (isFallbackMarked) {
          countCombinedFallback++;
        } else {
          countCombinedDirect++;
        }
      } else if (cls.isDate) {
        if (isFallbackMarked) {
          countDateFallback++;
        } else {
          countDateDirect++;
        }
      } else if (cls.isGps) {
        if (isFallbackMarked) {
          countGpsFallback++;
        } else {
          countGpsDirect++;
        }
      }
    }

    final totalTagged =
        (countDateDirect +
                countGpsDirect +
                countCombinedDirect +
                countDateFallback +
                countGpsFallback +
                countCombinedFallback)
            .clamp(1, 1 << 30);

    final sw = Stopwatch()..start();
    try {
      if (useArgFileWhenLarge) {
        await _exifTool!.writeExifDataBatchViaArgFile(batch);
      } else {
        await _exifTool!.writeExifDataBatch(batch);
      }

      final elapsed = sw.elapsed;

      // Attribute durations and successes proportionally
      if (countCombinedDirect > 0) {
        xtCombinedDirectSuccess += countCombinedDirect;
        xtCombinedDirectDur += elapsed * (countCombinedDirect / totalTagged);
      }
      if (countCombinedFallback > 0) {
        xtCombinedFallbackRecovered += countCombinedFallback;
        xtCombinedFallbackDur +=
            elapsed * (countCombinedFallback / totalTagged);
      }
      if (countDateDirect > 0) {
        xtDateDirectSuccess += countDateDirect;
        xtDateDirectDur += elapsed * (countDateDirect / totalTagged);
      }
      if (countDateFallback > 0) {
        xtDateFallbackRecovered += countDateFallback;
        xtDateFallbackDur += elapsed * (countDateFallback / totalTagged);
      }
      if (countGpsDirect > 0) {
        xtGpsDirectSuccess += countGpsDirect;
        xtGpsDirectDur += elapsed * (countGpsDirect / totalTagged);
      }
      if (countGpsFallback > 0) {
        xtGpsFallbackRecovered += countGpsFallback;
        xtGpsFallbackDur += elapsed * (countGpsFallback / totalTagged);
      }

      // Mark all entries as touched and consume fallback marks
      for (final m in entriesMeta) {
        final bool? hintIsPrimary = _consumePrimaryHint(m.file);
        if (m.isCombined) {
          if (hintIsPrimary != null) {
            markDateTouchedFromStep5(m.file, isPrimary: hintIsPrimary);
            markGpsTouchedFromStep5(m.file, isPrimary: hintIsPrimary);
          } else {
            _markTouched(m.file, date: true, gps: true);
          }
          _consumeMarkedFallback(
            m.file,
            asDate: false,
            asGps: false,
            asCombined: true,
          );
        } else if (m.isDate) {
          if (hintIsPrimary != null) {
            markDateTouchedFromStep5(m.file, isPrimary: hintIsPrimary);
          } else {
            _markTouched(m.file, date: true, gps: false);
          }
          _consumeMarkedFallback(
            m.file,
            asDate: true,
            asGps: false,
            asCombined: false,
          );
        } else if (m.isGps) {
          if (hintIsPrimary != null) {
            markGpsTouchedFromStep5(m.file, isPrimary: hintIsPrimary);
          } else {
            _markTouched(m.file, date: false, gps: true);
          }
          _consumeMarkedFallback(
            m.file,
            asDate: false,
            asGps: true,
            asCombined: false,
          );
        }
      }
    } catch (e) {
      final elapsed = sw.elapsed;
      // Single-element batch failure attribution (kept identical to your previous behavior)
      try {
        if (batch.length == 1 && entriesMeta.isNotEmpty) {
          final m = entriesMeta.first;
          if (m.isCombined) {
            if (m.isFallbackMarked) {
              xtCombinedFallbackFail++;
              xtCombinedFallbackDur += elapsed;
            } else {
              xtCombinedDirectFail++;
              xtCombinedDirectDur += elapsed;
            }
          } else if (m.isDate) {
            if (m.isFallbackMarked) {
              xtDateFallbackFail++;
              xtDateFallbackDur += elapsed;
            } else {
              xtDateDirectFail++;
              xtDateDirectDur += elapsed;
            }
          } else if (m.isGps) {
            if (m.isFallbackMarked) {
              xtGpsFallbackFail++;
              xtGpsFallbackDur += elapsed;
            } else {
              xtGpsDirectFail++;
              xtGpsDirectDur += elapsed;
            }
          }
        }
      } catch (_) {}
      logWarning('[Step 7/8] [WRITE-EXIF] Batch exiftool write failed: $e');
      rethrow;
    }
  }

  // ─────────────────────── Native JPEG implementations ───────────────────────
  /// Ensures we have an ExifData container and the required IFDs.
  /// If there is no EXIF block, creates a fresh one so we can inject tags.
  ExifData _ensureExifContainers(final ExifData? exif) {
    final ExifData data = exif ?? ExifData();

    // In `package:image`, EXIF sub-IFDs live under `ifd0.sub[...]`.
    // Ensure `ifd0` exists and that its sub-IFDs are created.
    data.imageIfd;
    data.exifIfd;
    data.gpsIfd;

    return data;
  }

  /// Build an EXIF rational triplet (deg/min/sec) for GPSLatitude/GPSLongitude.
  ///
  /// Important: `IfdDirectory.operator[]=` in `package:image` only knows about
  /// `exifImageTags` and therefore does not correctly type GPS tags.
  /// We must write GPS tags by inserting `IfdValue*` entries directly.
  List<Rational> _toExifGpsRationals(
    final int degrees,
    final int minutes,
    final double seconds,
  ) {
    const secScale = 10000;
    final secNumerator = (seconds * secScale).round();
    return <Rational>[
      Rational(degrees.abs(), 1),
      Rational(minutes, 1),
      Rational(secNumerator, secScale),
    ];
  }

  /// Native JPEG DateTime write (returns true if wrote; false if failed).
  Future<bool> writeDateTimeNativeJpeg(
    final File file,
    final DateTime dateTime,
  ) async {
    final sw = Stopwatch()..start();
    try {
      final Uint8List orig = await file.readAsBytes();
      final ExifData? exif = decodeJpgExif(orig);

      // Ensure EXIF container and required directories exist
      final ExifData data = _ensureExifContainers(exif);

      final fmt = DateFormat('yyyy:MM:dd HH:mm:ss');
      final dt = fmt.format(dateTime);

      // Write tags by name into proper directories
      data.imageIfd['DateTime'] = dt;
      data.exifIfd['DateTimeOriginal'] = dt;
      data.exifIfd['DateTimeDigitized'] = dt;

      final Uint8List? out = injectJpgExif(orig, data);
      if (out == null) {
        nativeDateFail++;
        nativeDateDur += sw.elapsed;
        return false;
      }

      await file.writeAsBytes(out);
      nativeDateSuccess++;
      nativeDateDur += sw.elapsed;
      _markTouched(file, date: true, gps: false);
      logDebug(
        '[Step 7/8] [WRITE-EXIF] Date written natively (JPEG): ${file.path}',
      );
      return true;
    } catch (e) {
      nativeDateFail++;
      nativeDateDur += sw.elapsed;
      logWarning(
        '[Step 7/8] [WRITE-EXIF] Native JPEG DateTime write failed for ${file.path}: $e',
      );
      return false;
    }
  }

  /// Native JPEG GPS write (returns true if wrote; false if failed).
  Future<bool> writeGpsNativeJpeg(
    final File file,
    final DMSCoordinates coords,
  ) async {
    final sw = Stopwatch()..start();
    try {
      final Uint8List orig = await file.readAsBytes();
      final ExifData? exif = decodeJpgExif(orig);

      // Ensure EXIF container and required directories exist
      final ExifData data = _ensureExifContainers(exif);

      // GPS IFD tag IDs (Exif GPS spec):
      //  0x0001 GPSLatitudeRef (ASCII)
      //  0x0002 GPSLatitude (RATIONAL[3])
      //  0x0003 GPSLongitudeRef (ASCII)
      //  0x0004 GPSLongitude (RATIONAL[3])
      final gps = data.gpsIfd;
      gps.data[0x0001] = IfdValueAscii(coords.latDirection.abbreviation);
      gps.data[0x0002] = IfdValueRational.list(
        _toExifGpsRationals(
          coords.latDegrees,
          coords.latMinutes,
          coords.latSeconds,
        ),
      );
      gps.data[0x0003] = IfdValueAscii(coords.longDirection.abbreviation);
      gps.data[0x0004] = IfdValueRational.list(
        _toExifGpsRationals(
          coords.longDegrees,
          coords.longMinutes,
          coords.longSeconds,
        ),
      );

      final Uint8List? out = injectJpgExif(orig, data);
      if (out == null) {
        nativeGpsFail++;
        nativeGpsDur += sw.elapsed;
        return false;
      }

      await file.writeAsBytes(out);
      nativeGpsSuccess++;
      nativeGpsDur += sw.elapsed;
      _markTouched(file, date: false, gps: true);
      logDebug(
        '[Step 7/8] [WRITE-EXIF] GPS written natively (JPEG): ${file.path}',
      );
      return true;
    } catch (e) {
      nativeGpsFail++;
      nativeGpsDur += sw.elapsed;
      logWarning(
        '[Step 7/8] [WRITE-EXIF] Native JPEG GPS write failed for ${file.path}: $e',
      );
      return false;
    }
  }

  /// Native JPEG combined write (Date+GPS). Returns true if wrote; false if failed.
  Future<bool> writeCombinedNativeJpeg(
    final File file,
    final DateTime dateTime,
    final DMSCoordinates coords,
  ) async {
    final sw = Stopwatch()..start();
    try {
      final Uint8List orig = await file.readAsBytes();
      final ExifData? exif = decodeJpgExif(orig);

      // Ensure EXIF container and required directories exist
      final ExifData data = _ensureExifContainers(exif);

      final fmt = DateFormat('yyyy:MM:dd HH:mm:ss');
      final dt = fmt.format(dateTime);

      data.imageIfd['DateTime'] = dt;
      data.exifIfd['DateTimeOriginal'] = dt;
      data.exifIfd['DateTimeDigitized'] = dt;

      final gps = data.gpsIfd;
      gps.data[0x0001] = IfdValueAscii(coords.latDirection.abbreviation);
      gps.data[0x0002] = IfdValueRational.list(
        _toExifGpsRationals(
          coords.latDegrees,
          coords.latMinutes,
          coords.latSeconds,
        ),
      );
      gps.data[0x0003] = IfdValueAscii(coords.longDirection.abbreviation);
      gps.data[0x0004] = IfdValueRational.list(
        _toExifGpsRationals(
          coords.longDegrees,
          coords.longMinutes,
          coords.longSeconds,
        ),
      );

      final Uint8List? out = injectJpgExif(orig, data);
      if (out == null) {
        nativeCombinedFail++;
        nativeCombinedDur += sw.elapsed;
        return false;
      }

      await file.writeAsBytes(out);
      nativeCombinedSuccess++;
      nativeCombinedDur += sw.elapsed;
      _markTouched(file, date: true, gps: true);
      logDebug(
        '[Step 7/8] [WRITE-EXIF] Date+GPS written natively (JPEG): ${file.path}',
      );
      return true;
    } catch (e) {
      nativeCombinedFail++;
      nativeCombinedDur += sw.elapsed;
      logWarning(
        '[Step 7/8] [WRITE-EXIF] Native JPEG combined write failed for ${file.path}: $e',
      );
      return false;
    }
  }

  // NOTE: GPS tags must be written with correct EXIF types.
  // We intentionally avoid dynamic setters here and use IfdDirectory's
  // tag-name mapping + value-type conversions instead.
}

/// Simple data holder for StepResult mapping (kept explicit for clarity).
class WriteExifRunOutcome {
  WriteExifRunOutcome({
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
