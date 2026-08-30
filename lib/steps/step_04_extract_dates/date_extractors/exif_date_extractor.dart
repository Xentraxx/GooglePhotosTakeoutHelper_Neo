import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:exif_reader/exif_reader.dart';
import 'package:gpth_neo/gpth_lib_exports.dart';
import 'package:mime/mime.dart';

class _SmartReadResult {
  _SmartReadResult(this.bytes, this.usedHeadOnly);
  final List<int> bytes;
  final bool usedHeadOnly;
}

/// Policy for naive datetimes (no timezone info found).
enum _NoOffsetPolicy {
  /// Keep DateTime as local time when the string has no timezone info.
  treatAsLocal,

  /// Treat naive datetimes as UTC by appending 'Z' (UTC).
  treatAsUtc,
}

/// Fast + instrumented EXIF Date extractor (4.2.2 behavior preserved),
/// with robust, timezone-aware ExifTool parsing and optional dictionary lookup.
class ExifDateExtractor with LoggerMixin {
  const ExifDateExtractor(this.exiftool);
  final ExifToolService? exiftool;

  // ────────────────────────────────────────────────────────────────────────────
  // Instrumentation (per-process static counters + timers)
  // ────────────────────────────────────────────────────────────────────────────
  static int _total = 0; // files attempted by this extractor
  static int _videoDirect = 0; // direct exiftool route due to video/*

  static int _dictTried = 0; // tries of dictionary lookups
  static int _dictHit = 0; // found a valid date
  static int _dictMiss = 0; // not found or not valid date

  static int _nativeSupported = 0; // files with a native-supported MIME
  static int _nativeUnsupported =
      0; // files routed to exiftool due to unsupported/unknown MIME
  static int _nativeHeadReads = 0; // native fast head-only reads
  static int _nativeFullReads = 0; // native full-file reads
  static int _nativeTried = 0; // equals _nativeSupported
  static int _nativeHit = 0; // native returned a valid DateTime
  static int _nativeMiss = 0; // native returned null

  static int _exiftoolDirectTried =
      0; // tried exiftool directly (videos/unsupported)
  static int _exiftoolDirectHit = 0; // exiftool direct found a date
  static int _exiftoolFallbackTried = 0; // native miss re-tried via exiftool
  static int _exiftoolFallbackHit = 0; // fallback succeeded

  static Duration _dictDuration = Duration.zero;
  static Duration _nativeDuration = Duration.zero;
  static Duration _exiftoolDuration = Duration.zero;
  static Duration _totalDuration =
      _dictDuration + _nativeDuration + _exiftoolDuration;

  // Helpers for Telemetry alligment
  static String _p6(final int v) => v.toString().padLeft(6);
  static String _secs(final Duration d) => '${d.inSeconds}s';

  // Cache of dictionary indices (one index per dictionary instance)
  static final Map<Map<String, dynamic>, Map<String, Map<String, dynamic>>>
  _dictIndexCache = {};

  /// dumpStats and Telemetry:
  static void dumpStats({
    final bool reset = false,
    final LoggerMixin? loggerMixin,
    final bool exiftoolFallbackEnabled = false,
  }) {
    // Prepare aligned values
    final String calls = _p6(_total);
    final String videos = _videoDirect.toString();
    final String nativeSup = _nativeSupported.toString();
    final String unsupported = _nativeUnsupported.toString();
    final String totalTimeS = _secs(_totalDuration);

    final String dictTried = _p6(_dictTried);
    final String dictHit = _p6(_dictHit);
    final String dictMiss = _p6(_dictMiss);
    final String dictTimeS = _secs(_dictDuration);

    final String nativeTried = _p6(_nativeTried);
    final String nativeHit = _p6(_nativeHit);
    final String nativeMiss = _p6(_nativeMiss);
    final String headReads = _nativeHeadReads.toString();
    final String fullReads = _nativeFullReads.toString();
    final String nativeTimeS = _secs(_nativeDuration);

    final String exifDirTried = _p6(_exiftoolDirectTried);
    final String exifDirHit = _p6(_exiftoolDirectHit);
    final int exifDirFailN = _exiftoolDirectTried - _exiftoolDirectHit;
    final String exifDirFail = _p6(exifDirFailN < 0 ? 0 : exifDirFailN);

    final String exifFbTried = _p6(_exiftoolFallbackTried);
    final String exifFbHit = _p6(_exiftoolFallbackHit);
    final int exifFbFailN = _exiftoolFallbackTried - _exiftoolFallbackHit;
    final String exifFbFail = _p6(exifFbFailN < 0 ? 0 : exifFbFailN);
    final String exifTimeS = _secs(_exiftoolDuration);

    final String exifTotTried = _p6(
      _exiftoolDirectTried + _exiftoolFallbackTried,
    );
    final String exifTotHit = _p6(_exiftoolDirectHit + _exiftoolFallbackHit);
    final String exifTotFail = _p6(
      (exifDirFailN < 0 ? 0 : exifDirFailN) +
          (exifFbFailN < 0 ? 0 : exifFbFailN),
    );

    // Only show the dictionary stats line when a global jsonDatesDictionary is present
    bool showDictLine = false;
    try {
      showDictLine =
          ServiceContainer.instance.globalConfig.jsonDatesDictionary != null;
    } catch (_) {
      showDictLine = false;
    }

    void out(final String s) {
      if (loggerMixin != null) {
        loggerMixin.logPrint(s);
      } else {
        LoggingService().info(s);
      }
    }

    // Output in the exact requested shape
    out('[Step 4/8] === Telemetry Summary ===');
    out('[Step 4/8]     [READ-EXIF]');
    out(
      '[Step 4/8]         Total Calls             : $calls (videos=$videos | nativeSupported=$nativeSup | unsupported=$unsupported) - Total Time: $totalTimeS',
    );
    if (showDictLine) {
      out(
        '[Step 4/8]         External Dict           : $dictTried (Success: $dictHit, Fails: $dictMiss) - Time: ${dictTimeS.padLeft(6)}',
      );
    }
    out(
      '[Step 4/8]         Native Direct           : $nativeTried (Success: $nativeHit, Fails: $nativeMiss) - Time: ${nativeTimeS.padLeft(6)} - (headReads: $headReads, fullReads: $fullReads)',
    );
    out(
      '[Step 4/8]         Exiftool Total          : $exifTotTried (Success: $exifTotHit, Fails: $exifTotFail) - Time: ${exifTimeS.padLeft(6)}',
    );
    out(
      '[Step 4/8]             Direct              : $exifDirTried (Success: $exifDirHit, Fails: $exifDirFail)',
    );
    if (exiftoolFallbackEnabled) {
      out(
        '[Step 4/8]             Fallback (enabled)  : $exifFbTried (Success: $exifFbHit, Fails: $exifFbFail)',
      );
    } else {
      out(
        '[Step 4/8]             Fallback (disabled) : $exifFbTried (Success: $exifFbHit, Fails: $exifFbFail)',
      );
    }

    if (reset) {
      _total = 0;
      _videoDirect = 0;

      _dictTried = 0;
      _dictHit = 0;
      _dictMiss = 0;
      _dictDuration = Duration.zero;

      _nativeSupported = 0;
      _nativeUnsupported = 0;
      _nativeHeadReads = 0;
      _nativeFullReads = 0;
      _nativeTried = 0;
      _nativeHit = 0;
      _nativeMiss = 0;

      _exiftoolDirectTried = 0;
      _exiftoolDirectHit = 0;
      _exiftoolFallbackTried = 0;
      _exiftoolFallbackHit = 0;

      _nativeDuration = Duration.zero;
      _exiftoolDuration = Duration.zero;
      _totalDuration = Duration.zero;

      _dictIndexCache.clear();
    }
  }

  /// Extract DateTime from EXIF for [file] using native fast-path and optional fallback.
  /// If [datesDict] is provided (or GlobalConfig has one), it tries to read "OldestDate" from there first.
  Future<DateTime?> exifDateTimeExtractor(
    final File file, {
    required final GlobalConfigService globalConfig,
    final Map<String, dynamic>? datesDict,
  }) async {
    _total++;

    // Prefer explicit dict, else use the one from global config if present.
    final Map<String, dynamic>? effectiveDict =
        datesDict ?? globalConfig.jsonDatesDictionary;

    // 1) Optional dictionary lookup (Unix-style key). If valid, short-circuit.
    if (effectiveDict != null) {
      _dictTried++;
      final swDict = Stopwatch()..start();
      final DateTime? jsonDt = _lookupOldestDateFromDict(file, effectiveDict);
      _dictDuration += swDict.elapsed;

      if (jsonDt != null) {
        _dictHit++;
        return jsonDt; // Already timezone-aware (we return UTC).
      } else {
        _dictMiss++;
        // Also print the path of the file that was not found in the dictionary
        logWarning('[Step 4/8] Dates dictionary miss for file: ${file.path}');
      }
    }

    // 2) Guard against large files only if dictionary did not resolve the date.
    if (await file.length() > defaultMaxFileSize &&
        globalConfig.enforceMaxFileSize) {
      logError(
        '[Step 4/8] The file is larger than the maximum supported file size of ${defaultMaxFileSize.toString()} bytes. File: ${file.path}',
      );
      return null;
    }

    // MIME detection uses only a tiny header
    final List<int> headerBytes = await File(file.path).openRead(0, 128).first;
    final String? mimeType = lookupMimeType(
      file.path,
      headerBytes: headerBytes,
    );

    DateTime? result;

    // For videos, go straight to ExifTool. Native reader doesn't support them.
    if (mimeType?.startsWith('video/') == true) {
      _videoDirect++;
      if (globalConfig.exifToolInstalled) {
        _exiftoolDirectTried++; // count direct attempts in video path
        final sw = Stopwatch()..start();
        result = await _exifToolExtractor(file);
        _exiftoolDuration += sw.elapsed;
        if (result != null) {
          _exiftoolDirectHit++;
          return result;
        } else {}
      }
      logDebug(
        '[Step 4/8] Reading exif from ${file.path} with mimeType $mimeType skipped. Only supported with ExifTool.',
      );
      return null;
    }

    if (supportedNativeExifMimeTypes.contains(mimeType)) {
      _nativeSupported++;
      _nativeTried++;

      final sw = Stopwatch()..start();
      result = await _nativeExifExtractor(file, mimeType: mimeType);
      _nativeDuration += sw.elapsed;

      if (result != null) {
        _nativeHit++;
        return result;
      }
      _nativeMiss++;

      // Optional fallback to ExifTool when native misses
      if (globalConfig.exifToolInstalled == true &&
          globalConfig.fallbackToExifToolOnNativeMiss == true &&
          exiftool != null) {
        _exiftoolFallbackTried++;
        logWarning(
          '[Step 4/8] Native exif_reader failed to extract DateTime from ${file.path} ($mimeType). Falling back to ExifTool.',
        );
        final sw2 = Stopwatch()..start();
        result = await _exifToolExtractor(file);
        _exiftoolDuration += sw2.elapsed;
        if (result != null) {
          _exiftoolFallbackHit++;
          return result;
        } else {}
      }
      return null;
    }

    // Unsupported or unknown MIME → ExifTool if available
    _nativeUnsupported++;
    if (globalConfig.exifToolInstalled == true && exiftool != null) {
      _exiftoolDirectTried++;
      final sw = Stopwatch()..start();
      result = await _exifToolExtractor(file);
      _exiftoolDuration += sw.elapsed;
      if (result != null) {
        _exiftoolDirectHit++;
        return result;
      } else {}
    }

    if (mimeType == 'image/jpeg') {
      logWarning(
        '[Step 4/8] ${file.path} has a mimeType of $mimeType. However, could not read it with exif_reader. The file may be corrupt.',
      );
    } else if (globalConfig.exifToolInstalled == true) {
      logError(
        '[Step 4/8] $mimeType is an unusual mime type we cannot handle natively. Please create an issue if you get this often.',
      );
    } else {
      logWarning(
        '[Step 4/8] Reading exif from ${file.path} with mimeType $mimeType skipped. Reading from this kind of file is likely only supported with exiftool.',
      );
    }
    return null;
  }

  /// Try to read "OldestDate" from a dictionary keyed by Unix-style paths.
  /// Returns UTC DateTime if present and valid; otherwise null.
  DateTime? _lookupOldestDateFromDict(
    final File file,
    final Map<String, dynamic> dict,
  ) {
    try {
      final idx = _getOrBuildDictIndex(dict);

      // Build candidate keys (all normalized to Unix paths).
      final String p1 = file.path.replaceAll('\\', '/');
      final String p2 = file.absolute.path.replaceAll('\\', '/');
      String? p3;
      try {
        p3 = File(file.path).resolveSymbolicLinksSync().replaceAll('\\', '/');
      } catch (_) {
        // ignore if cannot resolve symlinks
      }

      final candidates = <String>{p1, p2, if (p3 != null && p3.isNotEmpty) p3};

      for (final key in candidates) {
        final Map<String, dynamic>? entry = idx[key];
        if (entry == null) continue;

        final dynamic oldest = entry['OldestDate'];
        if (oldest == null) continue;
        if (oldest is! String || oldest.trim().isEmpty) continue;

        // Prefer DateTime.parse for ISO8601 with offset/Z.
        try {
          final DateTime dt = DateTime.parse(oldest.trim()).toUtc();
          if (_isInvalidOrSentinel(dt)) continue;
          return dt;
        } catch (_) {
          // Fallback to robust parser if string is not strictly ISO.
          final DateTime? p = _parseExifDateString(oldest.trim());
          if (p == null) continue;
          final DateTime utc = p.toUtc();
          if (_isInvalidOrSentinel(utc)) continue;
          return utc;
        }
      }

      // Not found
      return null;
    } catch (e) {
      logWarning(
        '[Step 4/8] Failed to read from dates dictionary for "${file.path}": $e. Continuing with normal extraction.',
      );
      return null;
    }
  }

  /// Build (or retrieve from cache) an index for quick lookups by path.
  /// The index contains:
  ///  - original top-level keys (normalized to Unix),
  ///  - "TargetFile" values (normalized),
  ///  - "SourceFile" values (normalized).
  static Map<String, Map<String, dynamic>> _getOrBuildDictIndex(
    final Map<String, dynamic> dict,
  ) {
    final cached = _dictIndexCache[dict];
    if (cached != null) return cached;

    final idx = <String, Map<String, dynamic>>{};

    void add(final String? k, final Map<String, dynamic> v) {
      if (k == null || k.isEmpty) return;
      idx[k.replaceAll('\\', '/')] = v;
    }

    dict.forEach((final String key, final val) {
      if (val is Map<String, dynamic>) {
        // original key
        add(key, val);

        // also index by TargetFile/SourceFile if present
        final tf = val['TargetFile'];
        final sf = val['SourceFile'];
        if (tf is String) add(tf, val);
        if (sf is String) add(sf, val);
      }
    });

    _dictIndexCache[dict] = idx;
    return idx;
  }

  Future<DateTime?> _exifToolExtractor(final File file) async {
    if (exiftool == null) return null;
    try {
      final tags = await exiftool!.readExifData(file);

      // Keys to probe; we will keep "earliest date wins" policy across them.
      final List<String> keys = [
        'DateTimeOriginal',
        'DateTime',
        'CreateDate',
        'DateCreated',
        'CreationDate',
        'MediaCreateDate',
        'TrackCreateDate',
        'EncodedDate',
        'MetadataDate',
        'ModifyDate',
      ];

      DateTime? bestUtc;
      for (final k in keys) {
        final dynamic v = tags[k];
        if (v == null) continue;

        final String raw = v.toString().trim();
        if (raw.isEmpty) continue;

        // Fast reject for obvious bogus values
        final lower = raw.toLowerCase();
        if (lower.startsWith('0000:00:00') ||
            lower.startsWith('0000-00-00') ||
            lower.startsWith('0000/00/00')) {
          continue;
        }

        // First try strict ISO8601 parser (handles Z/±HH:MM and converts to UTC).
        DateTime? parsed;
        try {
          parsed = DateTime.parse(raw);
        } catch (_) {
          // Fallback to robust normalizer that preserves timezone.
          parsed = _parseExifDateString(raw);
        }

        if (parsed == null) continue;

        final DateTime pUtc = parsed.toUtc();
        if (_isInvalidOrSentinel(pUtc)) continue;

        if (bestUtc == null || pUtc.isBefore(bestUtc)) {
          bestUtc = pUtc;
        }
      }

      if (bestUtc == null) {
        logWarning(
          '[Step 4/8] ExifTool did not return an acceptable DateTime for ${file.path}.',
        );
        return null;
      }

      return bestUtc; // return UTC-aware value
    } catch (e) {
      logWarning('[Step 4/8] Exiftool read failed: $e');
      return null;
    }
  }

  /// Extract DateTime using native exif_reader with smart reads (head-only vs full).
  Future<DateTime?> _nativeExifExtractor(
    final File file, {
    required final String? mimeType,
  }) async {
    final read = await _smartReadBytes(file, mimeType);
    if (read.usedHeadOnly) {
      _nativeHeadReads++;
    } else {
      _nativeFullReads++;
    }

    final ExifData exifData = await readExifFromBytes(
      Uint8List.fromList(read.bytes),
    );

    final ordered = <String, String?>{
      'EXIF DateTimeOriginal':
          exifData.tags['EXIF DateTimeOriginal']?.printable,
      'Image DateTime': exifData.tags['Image DateTime']?.printable,
      'EXIF CreateDate': exifData.tags['EXIF CreateDate']?.printable,
      'EXIF DateCreated': exifData.tags['EXIF DateCreated']?.printable,
      'EXIF CreationDate': exifData.tags['EXIF CreationDate']?.printable,
      'EXIF MediaCreateDate': exifData.tags['EXIF MediaCreateDate']?.printable,
      'EXIF TrackCreateDate': exifData.tags['EXIF TrackCreateDate']?.printable,
      'EXIF EncodedDate': exifData.tags['EXIF EncodedDate']?.printable,
      'EXIF MetadataDate': exifData.tags['EXIF MetadataDate']?.printable,
      'EXIF ModifyDate': exifData.tags['EXIF ModifyDate']?.printable,
    };

    for (final entry in ordered.entries) {
      final v = entry.value;
      if (v == null || v.isEmpty) continue;

      var s = v;
      if (s.startsWith('0000:00:00') || s.startsWith('0000-00-00')) continue;

      s = s
          .replaceAll('-', ':')
          .replaceAll('/', ':')
          .replaceAll('.', ':')
          .replaceAll('\\', ':')
          .replaceAll(': ', ':0')
          .substring(0, math.min(s.length, 19))
          .replaceFirst(':', '-')
          .replaceFirst(':', '-');

      final parsed = DateTime.tryParse(s);
      if (parsed != null) {
        if (parsed == DateTime.parse('2036-01-01T23:59:59.000000Z')) {
          return null;
        }
        return parsed;
      }
    }
    return null;
  }

  Future<_SmartReadResult> _smartReadBytes(
    final File file,
    final String? mimeType,
  ) async {
    const int head = 64 * 1024;
    final int len = await file.length();

    final bool likelyTail =
        mimeType == 'image/png' ||
        mimeType == 'image/webp' ||
        mimeType == 'image/heic' ||
        mimeType == 'image/jxl';

    if (len <= head || likelyTail) {
      final bytes = await file.readAsBytes();
      return _SmartReadResult(bytes, false);
    }

    final builder = BytesBuilder(copy: false);
    await file.openRead(0, head).forEach(builder.add);
    return _SmartReadResult(builder.takeBytes(), true);
  }

  // ────────────────────────────────────────────────────────────────────────────
  // Robust helpers for timezone-aware parsing and sentinel filtering
  // ────────────────────────────────────────────────────────────────────────────

  /// Returns true if the datetime is a known invalid/sentinel value to skip.
  /// Compare in UTC to avoid local/UTC mismatches.
  bool _isInvalidOrSentinel(final DateTime dtUtc) {
    // ExifTool sentinel for pre-1970
    final DateTime sentinelUtc = DateTime.parse('2036-01-01T23:59:59Z');
    if (dtUtc.isAtSameMomentAs(sentinelUtc)) return true;

    // Discard weird lower bounds (paranoid guards)
    if (dtUtc.year < 1901) return true;

    // Some devices placeholder (HFS epoch)
    if (dtUtc.year == 1904 && dtUtc.month == 1 && dtUtc.day == 1) return true;

    // Exact Unix epoch start is often a placeholder when info is missing.
    if (dtUtc.year == 1970 &&
        dtUtc.month == 1 &&
        dtUtc.day == 1 &&
        dtUtc.hour == 0 &&
        dtUtc.minute == 0 &&
        dtUtc.second == 0) {
      return true;
    }
    return false;
  }

  /// Parse a wide range of ExifTool datetime formats into a DateTime.
  /// - Preserves timezone if present (Z or ±HH, ±HHMM, ±HH:MM).
  /// - If no timezone info is present, applies [_NoOffsetPolicy.treatAsLocal].
  /// Returns null if parsing fails or the value is clearly invalid.
  DateTime? _parseExifDateString(
    final String raw, {
    final _NoOffsetPolicy noOffsetPolicy = _NoOffsetPolicy.treatAsLocal,
  }) {
    if (raw.isEmpty) return null;

    // Quick invalid guards (common bogus values)
    final String low = raw.toLowerCase();
    if (low.startsWith('0000:00:00') ||
        low.startsWith('0000-00-00') ||
        low.startsWith('0000/00/00') ||
        low.startsWith('0001') ||
        low.startsWith('1899') ||
        low.startsWith('1900-01-01') ||
        low.startsWith('1900:01:01')) {
      return null;
    }

    // Normalize whitespace
    final String s = raw.trim();

    // If string is already ISO 8601, try fast path first.
    try {
      final dt = DateTime.parse(s);
      return dt;
    } catch (_) {
      // continue to normalization
    }

    // Extract potential timezone suffix: Z, ±HH, ±HHMM, ±HH:MM
    final tzMatch = RegExp(
      r'(Z|[+\-]\d{2}:\d{2}|[+\-]\d{4}|[+\-]\d{2})$',
    ).firstMatch(s.replaceAll(' ', ''));
    String? tz = tzMatch?.group(1);

    if (tz == null) {
      final tzSpaceMatch = RegExp(
        r'(Z|[+\-]\d{2}:\d{2}|[+\-]\d{4}|[+\-]\d{2})$',
      ).firstMatch(s);
      tz = tzSpaceMatch?.group(1);
    }

    // Remove the TZ from the core string temporarily (to normalize date/time cleanly)
    String core = s;
    if (tz != null && core.endsWith(tz)) {
      core = core.substring(0, core.length - tz.length).trimRight();
    }

    // Replace 'T' with space to have a uniform separator between date and time
    core = core.replaceFirst('T', ' ');

    // Now split into date and time parts (time is optional)
    final parts = core.split(RegExp(r'\s+'));
    final String datePart = parts.isNotEmpty ? parts[0] : '';
    final String timePart = parts.length > 1 ? parts.sublist(1).join(' ') : '';

    if (datePart.isEmpty) return null;

    // Normalize date: allow ':', '/', '.', '-', '\' as separators; allow single digits for M/D.
    final dateNums = datePart
        .replaceAll(RegExp(r'[\/\.\:\\-]'), '-')
        .split('-')
        .where((final x) => x.trim().isNotEmpty)
        .toList();

    if (dateNums.length < 3) return null;

    final String yRaw = dateNums[0];
    final String mRaw = dateNums[1];
    final String dRaw = dateNums[2];

    if (yRaw.length < 4) return null; // need a 4-digit year

    final int? year = int.tryParse(yRaw);
    final int? month = int.tryParse(mRaw);
    final int? day = int.tryParse(dRaw);

    if (year == null || month == null || day == null) return null;
    if (year < 1901) return null; // discard ultra-early/placeholder dates
    if (month < 1 || month > 12) return null;
    if (day < 1 || day > 31) return null;

    final String yyyy = year.toString().padLeft(4, '0');
    final String mm = month.toString().padLeft(2, '0');
    final String dd = day.toString().padLeft(2, '0');

    // Normalize time if present
    String hh = '00', min = '00', ss = '00', fraction = '';
    if (timePart.isNotEmpty) {
      // Accept formats like "H", "H:M", "H:M:S", with separators ": / . -"
      final t = timePart.replaceAll(RegExp(r'[\/\.\-]'), ':').trim();

      // Extract hh:mm:ss(.fraction)?
      final timeRe = RegExp(
        r'^(\d{1,2})(?::(\d{1,2}))?(?::(\d{1,2}))?(?:\.(\d+))?$',
      );
      final m = timeRe.firstMatch(t);
      if (m != null) {
        hh = (int.tryParse(m.group(1) ?? '0') ?? 0).toString().padLeft(2, '0');
        min = (int.tryParse(m.group(2) ?? '0') ?? 0).toString().padLeft(2, '0');
        ss = (int.tryParse(m.group(3) ?? '0') ?? 0).toString().padLeft(2, '0');
        if (m.group(4) != null && m.group(4)!.isNotEmpty) {
          // Keep up to 6 fractional digits to be safe for microseconds
          fraction =
              '.${m.group(4)!.substring(0, math.min(6, m.group(4)!.length))}';
        }
      } else {
        // If time is present but not parseable, consider the whole value invalid.
        return null;
      }
    }

    // Canonicalize timezone string if present
    String? tzIso;
    if (tz != null) {
      if (tz == 'Z') {
        tzIso = 'Z';
      } else {
        // Normalize ±HH, ±HHMM, ±HH:MM to ±HH:MM
        final tzClean = tz.replaceAll(' ', '');
        final sign = tzClean.startsWith('-') ? '-' : '+';
        final digits = tzClean.replaceAll(RegExp(r'[+\-:]'), '');
        if (digits.length == 2) {
          tzIso = '$sign${digits.padLeft(2, '0')}:00';
        } else if (digits.length == 4) {
          tzIso = '$sign${digits.substring(0, 2)}:${digits.substring(2, 4)}';
        } else if (RegExp(r'^[+\-]\d{2}:\d{2}$').hasMatch(tzClean)) {
          tzIso = tzClean;
        } else {
          // Unknown tz format; ignore it (safer than mis-parsing).
          tzIso = null;
        }
      }
    }

    // If no timezone provided, apply policy (default: treat as local).
    if (tzIso == null) {
      switch (noOffsetPolicy) {
        case _NoOffsetPolicy.treatAsLocal:
          // Leave without TZ; DateTime.parse will treat it as local time.
          break;
        case _NoOffsetPolicy.treatAsUtc:
          tzIso = 'Z';
          break;
      }
    }

    // Build ISO 8601 string
    final iso = StringBuffer()
      ..write(yyyy)
      ..write('-')
      ..write(mm)
      ..write('-')
      ..write(dd)
      ..write('T')
      ..write(hh)
      ..write(':')
      ..write(min)
      ..write(':')
      ..write(ss)
      ..write(fraction);
    if (tzIso != null) iso.write(tzIso);

    final String isoStr = iso.toString();

    try {
      final dt = DateTime.parse(isoStr);
      return dt;
    } catch (_) {
      return null;
    }
  }
}
