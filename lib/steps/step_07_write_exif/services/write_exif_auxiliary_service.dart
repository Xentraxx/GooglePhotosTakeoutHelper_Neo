import 'dart:io';
import 'dart:typed_data';

import 'package:coordinate_converter/coordinate_converter.dart';
import 'package:gpth_neo/gpth_lib_exports.dart';
import 'package:image/image.dart';
// ignore: implementation_imports
import 'package:image/src/util/rational.dart';
import 'package:intl/intl.dart';

/// Converts EXIF-namespace date, GPS and timezone-offset tags in [tags] to
/// their XMP equivalents. Mutates [tags] in place.
///
/// Used by the InteropIFD XMP fallback tier and by
/// [WriteExifProcessingService._retagEntryToXmpIfJpeg].
void applyXmpConversionInPlace(final Map<String, dynamic> tags) {
  // Date
  final dtVal =
      tags['DateTimeOriginal'] ?? tags['DateTimeDigitized'] ?? tags['DateTime'];
  tags
    ..remove('DateTimeOriginal')
    ..remove('DateTimeDigitized')
    ..remove('DateTime')
    ..remove('OffsetTime')
    ..remove('OffsetTimeOriginal')
    ..remove('OffsetTimeDigitized');
  if (dtVal != null) {
    tags['XMP:CreateDate'] = dtVal;
    tags['XMP:DateTimeOriginal'] = dtVal;
    tags['XMP:ModifyDate'] = dtVal;
  }

  // GPS — convert from absolute-value + direction-ref to signed decimal.
  double? lat = parseTagDouble(tags['GPSLatitude']);
  double? lon = parseTagDouble(tags['GPSLongitude']);
  final latRef = (tags['GPSLatitudeRef'] ?? '').toString().toUpperCase();
  final lonRef = (tags['GPSLongitudeRef'] ?? '').toString().toUpperCase();
  if (lat != null && latRef == 'S') lat = -lat;
  if (lon != null && lonRef == 'W') lon = -lon;
  tags
    ..remove('GPSLatitude')
    ..remove('GPSLongitude')
    ..remove('GPSLatitudeRef')
    ..remove('GPSLongitudeRef');
  if (lat != null && lon != null) {
    tags['XMP:GPSLatitude'] = lat.toString();
    tags['XMP:GPSLongitude'] = lon.toString();
  }
}

double? parseTagDouble(final Object? v) {
  if (v == null) return null;
  return double.tryParse(v.toString().trim().replaceAll('"', ''));
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

  /// Count of files where EXIF date embedding failed permanently due to
  /// corrupted InteropIFD structure. These files were still organised by date.
  static int _interopIfdSkippedCount = 0;
  static int get interopIfdSkippedCount => _interopIfdSkippedCount;

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

    _interopIfdSkippedCount = 0;

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

      // InteropIFD recovery: attempt strip-offset (tier 1) then XMP fallback
      // (tier 2) before counting the failure. This makes the retry work for
      // ALL callers — batch single-file, non-batch writeForFile, and binary-
      // split chunk==1 — without relying on callers to catch and re-issue.
      bool onlyOffsetTagsForIfd = false;
      if (WriteExifProcessingService.isInteropIfdError(e)) {
        onlyOffsetTagsForIfd = tags.keys.every(
          (final k) =>
              k == 'OffsetTime' ||
              k == 'OffsetTimeOriginal' ||
              k == 'OffsetTimeDigitized',
        );
        tags
          ..remove('OffsetTime')
          ..remove('OffsetTimeOriginal')
          ..remove('OffsetTimeDigitized');
        if (!onlyOffsetTagsForIfd && tags.isNotEmpty) {
          // Tier 1: retry without OffsetTime* — those tags trigger IFD
          // traversal on files with a corrupted InteropIFD.
          try {
            await _exifTool!.writeExifDataSingle(file, tags);
            logDebug(
              '[Step 7/8] ${file.path}: corrupted InteropIFD — '
              'UTC offset tags stripped, date/GPS written successfully.',
            );
            _markTouched(
              file,
              date: asDate || asCombined,
              gps: asGps || asCombined,
            );
            return true;
          } catch (e2) {
            if (WriteExifProcessingService.isInteropIfdError(e2)) {
              // Tier 2: XMP fallback for JPEG — XMP writes bypass InteropIFD.
              final lower = file.path.toLowerCase();
              if (lower.endsWith('.jpg') || lower.endsWith('.jpeg')) {
                applyXmpConversionInPlace(tags);
                if (tags.isNotEmpty) {
                  try {
                    await _exifTool!.writeExifDataSingle(file, tags);
                    logDebug(
                      '[Step 7/8] ${file.path}: corrupted InteropIFD — '
                      'retried via XMP, date/GPS written successfully.',
                    );
                    _markTouched(
                      file,
                      date: asDate || asCombined,
                      gps: asGps || asCombined,
                    );
                    return true;
                  } catch (_) {}
                }
              }
            }
          }
        }
      }

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

      if (WriteExifProcessingService.isInteropIfdError(e)) {
        _interopIfdSkippedCount++;
        if (onlyOffsetTagsForIfd) {
          logWarning(
            '[Step 7/8] ${file.path}: timezone tag (+00:00) could not be written '
            '— the file has a slightly damaged internal structure. '
            'The date was still embedded and the photo is sorted correctly. You can safely ignore this.',
          );
        } else {
          logWarning(
            '[Step 7/8] ${file.path}: date/GPS metadata could not be written into this file '
            '— it has a damaged internal metadata structure. '
            'The photo was still sorted correctly by date. No data was lost. You can safely ignore this.',
          );
        }
      } else {
        // Strip the 'Exception: ExifTool failed: ' prefix to keep the message readable.
        final msg = e.toString().replaceAll(
          RegExp(r'^Exception:\s*ExifTool failed:\s*'),
          '',
        );
        logWarning('[Step 7/8] Failed to write EXIF to ${file.path}: $msg');
      }
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
      // InteropIFD errors are retried per-file by writeBatchSafe; only truly
      // failed files get their own per-file warning after the retry. Logging
      // the whole batch here would show every file in the batch as "failed"
      // even though most will succeed on the per-file retry — so suppress for
      // InteropIFD. For all other errors keep the visible warning.
      //
      // Atom-too-large: writeBatchSafe identifies the specific file and emits
      // its own warning without retrying, so suppress the generic batch message.
      if (!WriteExifProcessingService.isInteropIfdError(e) &&
          !WriteExifProcessingService.isAtomTooLargeError(e)) {
        final batchMsg = e.toString().replaceAll(
          RegExp(r'^Exception:\s*ExifTool failed:\s*'),
          '',
        );
        logWarning(
          '[Step 7/8] Batch metadata write failed — retrying files individually. '
          'Technical detail: $batchMsg',
        );
      }
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
    final safeSeconds = seconds.isFinite ? seconds : 0.0;
    final secNumerator = (safeSeconds * secScale).round();
    return <Rational>[
      Rational(degrees.abs(), 1),
      Rational(minutes, 1),
      Rational(secNumerator, secScale),
    ];
  }

  /// Native JPEG DateTime write (returns true if wrote; false if failed).
  ///
  /// [offsetString] is the EXIF timezone offset (e.g. `+08:00`, `+00:00`)
  /// written to the OffsetTime* tags when [isUtc] is true. Defaults to
  /// `+00:00` (UTC) for backward compatibility.
  Future<bool> writeDateTimeNativeJpeg(
    final File file,
    final DateTime dateTime, {
    final bool isUtc = false,
    final String offsetString = '+00:00',
  }) async {
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
      if (isUtc) {
        data.exifIfd['OffsetTime'] = offsetString;
        data.exifIfd['OffsetTimeOriginal'] = offsetString;
        data.exifIfd['OffsetTimeDigitized'] = offsetString;
      }

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
  ///
  /// [offsetString] is the EXIF timezone offset (e.g. `+08:00`, `+00:00`)
  /// written to the OffsetTime* tags when [isUtc] is true. Defaults to
  /// `+00:00` (UTC) for backward compatibility.
  Future<bool> writeCombinedNativeJpeg(
    final File file,
    final DateTime dateTime,
    final DMSCoordinates coords, {
    final bool isUtc = false,
    final String offsetString = '+00:00',
  }) async {
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
      if (isUtc) {
        data.exifIfd['OffsetTime'] = offsetString;
        data.exifIfd['OffsetTimeOriginal'] = offsetString;
        data.exifIfd['OffsetTimeDigitized'] = offsetString;
      }

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
