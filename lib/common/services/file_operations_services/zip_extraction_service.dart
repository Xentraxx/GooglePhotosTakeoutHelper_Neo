import 'dart:convert'; // Needed for utf8 and latin1
import 'dart:io';
import 'dart:math';

import 'package:archive/archive_io.dart';
import 'package:gpth_neo/gpth_lib_exports.dart';
import 'package:path/path.dart' as p;

/// Service for handling ZIP file extraction with safety checks and error handling.
///
/// This service provides secure ZIP extraction functionality with comprehensive
/// error handling, progress reporting, and security validation to prevent
/// common ZIP-based vulnerabilities like path traversal attacks (Zip Slip).
/// Filenames and directory names are sanitized with a policy that:
/// - Replaces invalid Windows filename characters [<>:"|?*] with '_'
/// - Keeps Unicode characters (Ñ, accents, emojis) untouched
/// - Handles Windows reserved device names by suffixing with `_file`
/// - Removes trailing dots/spaces on Windows
/// Additionally, a light heuristic fixes mojibake where 'Ñ/ñ' appears as '¥'.
class ZipExtractionService with LoggerMixin {
  /// Creates a new instance of ZipExtractionService
  ZipExtractionService({
    final InteractivePresenterService? presenter,
    this.enableNameDiagnostics = false, // set to false to silence name logs
  }) : _presenter = presenter ?? InteractivePresenterService();

  final InteractivePresenterService _presenter;
  final LoggingService _logger = LoggingService(
    saveLog: ServiceContainer.instance.globalConfig.saveLog,
  );

  /// When true, the extractor logs suspicious entry names (e.g., ones containing '¥', 'Ñ', 'ñ', '~')
  /// with their code points before and after sanitization to diagnose mojibake issues.
  final bool enableNameDiagnostics;

  // Cache for 7-Zip executable path — resolved once per instance to avoid redundant lookups.
  String? _sevenZipExecutable;
  bool _sevenZipLookupDone = false;
  // Per-process thread count for 7-Zip, adjusted for parallelism in extractAll.
  int _sevenZipThreads = 1;

  /// Extracts all ZIP files to the specified directory.
  ///
  /// Streamed extraction is used (archive v4 decodeStream). Memory fallback is guarded.
  Future<void> extractAll(final List<File> zips, final Directory dir) async {
    // SAFETY: Never delete an existing, non-empty extraction directory.
    // Users sometimes mistakenly pick a real photo library folder (e.g. "Pictures") as the
    // extraction target. Recursive deletion here would wipe unrelated data.
    if (await dir.exists()) {
      // If directory exists and contains anything, refuse to proceed.
      // (We intentionally do not offer an interactive confirmation here because this service
      // is used by both interactive and non-interactive flows.)
      final bool isEmpty = await dir.list(followLinks: false).isEmpty;
      if (!isEmpty) {
        throw FileSystemException(
          'Refusing to extract ZIPs into a non-empty directory for safety. '
          'Choose a NEW EMPTY folder for extraction (e.g. "GPTH_Extract").',
          dir.path,
        );
      }
    }

    // Create destination directory (no destructive cleanup).
    await dir.create(recursive: true);

    await _presenter.showUnzipStartMessage();

    // Pre-detect 7-Zip once before the per-file loop so the message appears
    // prominently at the start of extraction, not buried in per-file debug output.
    if (!_sevenZipLookupDone) {
      _sevenZipExecutable = Platform.isWindows
          ? await _find7zipWindows()
          : await _whichFirst(['7z', '7za', '7zz']);
      _sevenZipLookupDone = true;
      if (_sevenZipExecutable != null) {
        logPrint(
          '7-Zip detected at: $_sevenZipExecutable - will use for extraction',
        );
      } else {
        logPrint('7-Zip not found - falling back to native Dart extractor');
      }
    }

    // Determine parallelism. 7-Zip is CPU+I/O bound; run 2 concurrently and
    // halve the per-process thread count so total CPU usage stays the same.
    // Native Dart extraction is memory-heavy — keep it sequential to avoid
    // two large ZIPs competing for heap space simultaneously.
    final int concurrency = _sevenZipExecutable != null && zips.length > 1
        ? min(2, zips.length)
        : 1;
    _sevenZipThreads = max(1, Platform.numberOfProcessors ~/ concurrency);
    if (concurrency > 1) {
      logPrint(
        'Extracting $concurrency ZIPs in parallel ($_sevenZipThreads threads per 7-Zip process)',
      );
    }

    // Pre-check for very large files and warn user
    var hasLargeFiles = false;
    var totalSize = 0;
    for (final File zip in zips) {
      if (await zip.exists()) {
        final size = await zip.length();
        totalSize += size;
        if (size > 10 * 1024 * 1024 * 1024) {
          // > 10GB
          hasLargeFiles = true;
        }
      }
    }

    if (hasLargeFiles) {
      logWarning('⚠️  LARGE FILE WARNING');
      logWarning('Some ZIP files are very large (>10GB).');
      logWarning('Total size: ${totalSize ~/ (1024 * 1024 * 1024)}GB');
      logWarning('This may cause memory issues during extraction.');
      logWarning('');
      logWarning('If extraction fails with memory errors:');
      logWarning('1. Extract ZIP files manually');
      logWarning('2. Run GPTH on the extracted folder instead');
      logWarning('');
    }

    // Worker pool: up to `concurrency` ZIPs extracted simultaneously.
    // Dart's single-threaded model makes the index increment race-free.
    var nextIndex = 0;
    Future<void> worker() async {
      while (true) {
        final int i = nextIndex++;
        if (i >= zips.length) break;
        await _extractSingleZip(zips[i], dir);
      }
    }

    await Future.wait(List.generate(concurrency, (_) => worker()));

    await _presenter.showUnzipComplete();
  }

  /// Extracts a single ZIP file with full error handling and progress reporting.
  Future<void> _extractSingleZip(final File zip, final Directory dir) async {
    await _presenter.showUnzipProgress(p.basename(zip.path));

    try {
      // Validate ZIP file exists and is readable
      if (!await zip.exists()) {
        throw FileSystemException('ZIP file not found', zip.path);
      }
      final int zipSize = await zip.length();
      if (zipSize == 0) {
        throw FileSystemException('ZIP file is empty', zip.path);
      }

      // Log file size for large files
      if (zipSize > 1024 * 1024 * 1024) {
        // > 1GB
        logInfo(
          'Processing large ZIP file: ${p.basename(zip.path)} (${zipSize ~/ (1024 * 1024)}MB)',
        );
      }

      // ─────────────────────────────────────────────────────────────────────
      // Windows: 7-Zip (PATH + common locations + ./gpth_tool/7zip/7z.exe) -> Native (Dart)
      // macOS/Linux: Native (Dart) -> unzip (UTF-8 forced) -> 7-Zip (UTF-8 forced)
      // Rationale:
      // - On *nix, prefer native to keep Unicode intact; fall back to unzip/7-Zip only if needed.
      // - On Windows, 7-Zip often handles mixed encodings better than native; keep previous order.
      // ─────────────────────────────────────────────────────────────────────
      final extracted = await _extractZipWithStrategy(zip, dir);
      if (!extracted) {
        logWarning(
          'No external extractor succeeded; falling back to native streamed extractor (safety fallback).',
        );
        await _extractZipStreamed(zip, dir);
      }

      await _presenter.showUnzipSuccess(p.basename(zip.path));
    } on ArchiveException catch (e) {
      try {
        _handleExtractionError(zip, e, isArchiveError: true);
      } catch (extractionError) {
        logWarning('Failed to extract ${p.basename(zip.path)}: $e');
        logWarning('Continuing with remaining ZIP files...');
      }
    } on PathNotFoundException catch (e) {
      try {
        _handleExtractionError(zip, e, isPathError: true);
      } catch (extractionError) {
        logWarning('Failed to extract ${p.basename(zip.path)}: $e');
        logWarning('Continuing with remaining ZIP files...');
      }
    } on FileSystemException catch (e) {
      try {
        _handleExtractionError(zip, e, isFileSystemError: true);
      } catch (extractionError) {
        logWarning('Failed to extract ${p.basename(zip.path)}: $e');
        logWarning('Continuing with remaining ZIP files...');
      }
    } catch (e) {
      // Handle memory exhaustion specifically
      final errorMessage = e.toString().toLowerCase();
      if (errorMessage.contains('exhausted heap') ||
          errorMessage.contains('out of memory') ||
          errorMessage.contains('cannot allocate')) {
        _logger.error('');
        _logger.error('❌ MEMORY EXHAUSTION ERROR');
        _logger.error('ZIP file too large: ${p.basename(zip.path)}');
        _logger.error(
          'Available memory insufficient for processing this file.',
        );
        _logger.error('');
        _logger.error('🔧 SOLUTIONS:');
        _logger.error('1. Extract ZIP files manually using your system tools');
        _logger.error('2. Use smaller ZIP files (split large exports)');
        _logger.error('3. Run GPTH on the manually extracted folder');
        _logger.error('4. Increase available memory and try again');
        _logger.error('');
        _logger.error('Manual extraction guide:');
        _logger.error(
          'https://github.com/Xentraxx/GooglePhotosTakeoutHelper#manual-extraction',
        );
        logWarning('Continuing with remaining ZIP files...');
      } else {
        try {
          _handleExtractionError(zip, e);
        } catch (extractionError) {
          logWarning('Failed to extract ${p.basename(zip.path)}: $e');
          logWarning('Continuing with remaining ZIP files...');
        }
      }
    }
  }

  // ───────────────────────────────────────────────────────────────────────────
  // Cross-platform strategy orchestrator
  // ───────────────────────────────────────────────────────────────────────────

  /// Orchestrates extraction attempts depending on the OS.
  /// Returns true if any external/native strategy completed the extraction.
  Future<bool> _extractZipWithStrategy(
    final File zip,
    final Directory destinationDir,
  ) async {
    final String zipName = p.basename(zip.path);
    logDebug('Starting extraction strategy for $zipName');

    if (!Platform.isWindows) {
      // macOS / Linux (Try with Unzip first)
      // 1) Try unzip with UTF-8 override (-O UTF-8)
      try {
        final ok = await _timed(
          'unzip',
          () => _tryExtractWithUnzip(zip, destinationDir),
        );
        if (ok) {
          logDebug('Extraction succeeded for $zipName using Unzip extractor');
          return true;
        } else {
          logWarning('Unzip failed for $zipName, trying 7-Zip extractor...');
        }
      } catch (e) {
        logWarning('unzip extraction threw an error for $zipName: $e');
      }
    }

    // macOS / Linux / Windows (If Unzip fails or isWindows, try with 7-zip and then Native
    // 2) Try 7-Zip (force UTF-8 code page)
    try {
      final ok = await _timed(
        '7-Zip',
        () => _tryExtractWith7zip(zip, destinationDir),
      );
      if (ok) {
        logDebug('Extraction succeeded for $zipName using 7-Zip extractor');
        return true;
      } else {
        logWarning(
          '7-Zip failed or not found for $zipName, trying Native extractor...',
        );
      }
    } catch (e) {
      logWarning('7-Zip extraction threw an error for $zipName: $e');
    }

    // 3) Try Native (Dart) first to preserve Unicode names as-is
    try {
      final ok = await _timed('Native(Dart)', () async {
        await _extractZipStreamed(zip, destinationDir);
        return true;
      });
      if (ok) {
        logDebug('Extraction succeeded for $zipName using Native extractor');
        return true;
      } else {
        logWarning(
          'Native extractor failed for $zipName, extraction unsuccessful.',
        );
      }
    } catch (e) {
      logWarning('Native extractor threw an error for $zipName: $e');
    }

    return false;
  }

  /// Run an async action and log its duration.
  Future<bool> _timed(
    final String label,
    final Future<bool> Function() action,
  ) async {
    final sw = Stopwatch()..start();
    try {
      final ok = await action();
      sw.stop();
      logDebug(
        '[$label] completed in ${sw.elapsed.inMilliseconds} ms (success=$ok)',
      );
      return ok;
    } catch (e) {
      sw.stop();
      logDebug(
        '[$label] failed in ${sw.elapsed.inMilliseconds} ms with error: $e',
      );
      rethrow;
    }
  }

  /// Try 7-Zip (7z/7za/7zz). Returns true on success.
  /// Windows: searches PATH and common install locations (Program Files, Chocolatey, Scoop) and ./gpth_tool/7zip/7z.exe.
  /// NEW: forces UTF-8 filenames with -mcp=65001 and ensures UTF-8 locale on *nix to avoid mojibake.
  Future<bool> _tryExtractWith7zip(
    final File zip,
    final Directory destinationDir,
  ) async {
    if (!_sevenZipLookupDone) {
      _sevenZipExecutable = Platform.isWindows
          ? await _find7zipWindows()
          : await _whichFirst(['7z', '7za', '7zz']);
      _sevenZipLookupDone = true;
    }
    final String? sevenZip = _sevenZipExecutable;
    if (sevenZip == null) {
      logDebug(
        '7-Zip not found; skipping 7-Zip extraction. Hint: add 7-Zip to PATH or place it at ./gpth_tool/7zip/7z.exe',
      );
      return false;
    }

    final String zipPath = zip.path;
    final String outDir = destinationDir.path;

    // 7z x "<zip>" -o"<outDir>" -y -aoa -mmt=N -mcp=65001 -bso0 -bse0 -bsp0
    // -mmt=N    -> explicit thread count (faster than letting 7-Zip decide)
    // -mcp=65001 -> force UTF-8 for filenames (helps when archives lack proper UTF-8 flag)
    // -bso0 -bse0 -bsp0 -> suppress stdout/stderr/progress to reduce pipe I/O overhead
    // _sevenZipThreads is halved when running 2 ZIPs in parallel so total CPU stays the same.
    final int threads = _sevenZipThreads;
    final List<String> args = [
      'x',
      zipPath,
      '-o$outDir',
      '-y',
      '-aoa',
      '-mmt=$threads',
      '-mcp=65001',
      '-bso0',
      '-bse0',
      '-bsp0',
    ];
    logDebug('Running 7-Zip: $sevenZip ${args.join(' ')}');

    try {
      final Map<String, String> env = Map<String, String>.from(
        Platform.environment,
      );
      if (!Platform.isWindows) {
        env['LANG'] = env['LANG'] ?? 'C.UTF-8';
        env['LC_ALL'] = env['LC_ALL'] ?? 'C.UTF-8';
      }
      final ProcessResult result = await Process.run(
        sevenZip,
        args,
        runInShell: true,
        environment: env,
      );
      logDebug('7-Zip exitCode: ${result.exitCode}');
      final String so = (result.stdout ?? '').toString().trim();
      final String se = (result.stderr ?? '').toString().trim();
      if (so.isNotEmpty) logDebug('7-Zip stdout: $so');
      if (se.isNotEmpty) logDebug('7-Zip stderr: $se');
      return result.exitCode == 0;
    } catch (e) {
      logDebug('7-Zip invocation failed: $e');
      return false;
    }
  }

  /// Windows-specific deep search for 7-Zip executables.
  Future<String?> _find7zipWindows() async {
    // 1) PATH lookup
    final String? onPath = await _whichFirst(['7z.exe', '7za.exe', '7zz.exe']);
    if (onPath != null) return onPath;

    // 2) Common install locations
    final env = Platform.environment;
    final programFiles = env['ProgramFiles'];
    final programFilesX86 = env['ProgramFiles(x86)'];
    final chocolatey = env['ChocolateyInstall'];
    final scoop = env['SCOOP'];

    final List<String> candidates = <String>[
      if (programFiles != null) p.join(programFiles, '7-Zip', '7z.exe'),
      if (programFilesX86 != null) p.join(programFilesX86, '7-Zip', '7z.exe'),
      if (chocolatey != null) p.join(chocolatey, 'bin', '7z.exe'),
      if (scoop != null) p.join(scoop, 'apps', '7zip', 'current', '7z.exe'),
      // Project-relative bundled location (recommended to ship): ./gpth_tool/7zip/7z.exe
      p.normalize(
        p.join(Directory.current.path, 'gpth_tool', '7zip', '7z.exe'),
      ),
    ];

    for (final path in candidates) {
      final f = File(path);
      if (await f.exists()) {
        logDebug('Found 7-Zip at: $path');
        return path;
      }
    }
    return null;
  }

  /// Try unzip (macOS/Linux). Returns true on success.
  /// NEW: forces UTF-8 filenames with `-O UTF-8` to avoid locale-dependent decoding.
  Future<bool> _tryExtractWithUnzip(
    final File zip,
    final Directory destinationDir,
  ) async {
    if (Platform.isWindows) return false;
    final String? unzipCmd = await _which('unzip');
    if (unzipCmd == null) {
      logDebug('unzip not found on PATH; skipping unzip extraction');
      return false;
    }

    final String zipPath = zip.path;
    final String outDir = destinationDir.path;

    // unzip -O UTF-8 -o "<zip>" -d "<outDir>"
    final List<String> args = ['-O', 'UTF-8', '-o', zipPath, '-d', outDir];
    logDebug('Running unzip: $unzipCmd ${args.join(' ')}');

    try {
      final Map<String, String> env = Map<String, String>.from(
        Platform.environment,
      );
      env['LANG'] = env['LANG'] ?? 'C.UTF-8';
      env['LC_ALL'] = env['LC_ALL'] ?? 'C.UTF-8';
      final ProcessResult result = await Process.run(
        unzipCmd,
        args,
        runInShell: true,
        environment: env,
      );
      logDebug('unzip exitCode: ${result.exitCode}');
      final String so = (result.stdout ?? '').toString().trim();
      final String se = (result.stderr ?? '').toString().trim();
      if (so.isNotEmpty) logDebug('unzip stdout: $so');
      if (se.isNotEmpty) logDebug('unzip stderr: $se');
      return result.exitCode == 0;
    } catch (e) {
      logDebug('unzip invocation failed: $e');
      return false;
    }
  }

  /// which for a single binary name.
  Future<String?> _which(final String cmd) async {
    try {
      if (Platform.isWindows) {
        final ProcessResult res = await Process.run('where', [
          cmd,
        ], runInShell: true);
        if (res.exitCode == 0) {
          final String out = (res.stdout ?? '').toString().trim();
          if (out.isNotEmpty) {
            final String first = out.split(RegExp(r'[\r\n]+')).first.trim();
            return first.isEmpty ? null : first;
          }
        }
      } else {
        final ProcessResult res = await Process.run('which', [
          cmd,
        ], runInShell: true);
        if (res.exitCode == 0) {
          final String out = (res.stdout ?? '').toString().trim();
          return out.isEmpty ? null : out;
        }
      }
    } catch (_) {}
    return null;
  }

  /// Try multiple candidates; returns the first found.
  Future<String?> _whichFirst(final List<String> candidates) async {
    for (final c in candidates) {
      final String? found = await _which(c);
      if (found != null) return found;
    }
    return null;
  }

  /// Streamed extraction using archive v4 `decodeStream` API.
  ///
  /// Applies a mojibake fix (¥ -> Ñ/ñ) before sanitizing, then standard sanitization.
  /// NEW: also applies two conservative repairs when typical mojibake markers are found:
  ///   1) UTF-8-from-Latin1 reverse repair (handles "Ã±", "Ã¡", etc.)
  ///   2) CP437-from-Latin1 repair for Spanish letters (fixes "a¤o"->"año", "mam "->"mamá")
  Future<void> _extractZipStreamed(
    final File zip,
    final Directory destinationDir,
  ) async {
    final String destCanonical = p.canonicalize(destinationDir.path);

    final input = InputFileStream(zip.path);
    Archive archive;
    try {
      archive = ZipDecoder().decodeStream(input);
    } finally {
      await input.close();
    }

    for (final ArchiveFile entry in archive) {
      // Diagnostics: log decoder-provided name
      if (enableNameDiagnostics && _looksSuspicious(entry.name)) {
        _logNameDiagnostics('decoder', entry.name);
      }

      // Heuristic fix for mojibake where Ñ/ñ became ¥
      final fixedYen = _fixMojibakeYenToEnye(entry.name);

      // Conservative UTF-8-from-Latin1 reverse repair (handles "Ãñ", "Ã¡", etc.)
      final fixedUtf8 = _attemptUtf8FromLatin1(fixedYen);

      // CP437-from-Latin1 repair for common Spanish letters (fixes "a¤o", "mam ", etc.)
      final fixedCp437 = _attemptCp437FromLatin1(fixedUtf8);

      // Diagnostics: log fixed form(s)
      if (enableNameDiagnostics &&
          fixedCp437 != entry.name &&
          _looksSuspicious(fixedCp437)) {
        _logNameDiagnostics('fixed', fixedCp437);
      }

      // Sanitize after fixing
      final String sanitizedRelative = _sanitizeFileName(fixedCp437);

      if (enableNameDiagnostics && _looksSuspicious(sanitizedRelative)) {
        _logNameDiagnostics('sanitized', sanitizedRelative);
      }

      final String fullPath = p.join(destinationDir.path, sanitizedRelative);

      // Zip Slip protection
      final String entryDirCanonical = p.canonicalize(p.dirname(fullPath));
      if (!entryDirCanonical.startsWith(destCanonical)) {
        throw SecurityException(
          'Path traversal attempt detected: ${entry.name} -> $fullPath',
        );
      }

      if (entry.isFile) {
        // Ensure parent directory exists
        final Directory parent = Directory(p.dirname(fullPath));
        await parent.create(recursive: true);

        // Streamed write using OutputFileStream
        final output = OutputFileStream(fullPath);
        try {
          entry.writeContent(output);
        } finally {
          await output.close();
        }

        // Preserve file modification time if available
        try {
          await File(fullPath).setLastModified(
            DateTime.fromMillisecondsSinceEpoch(entry.lastModTime * 1000),
          );
        } catch (e) {
          logWarning(
            'Warning: Could not set modification time for $fullPath: $e',
          );
        }
      } else if (entry.isDirectory) {
        final Directory outDir = Directory(fullPath);
        await outDir.create(recursive: true);
      }
    }
  }

  /// Heuristic to fix mojibake where 'Ñ/ñ' shows up as '¥'.
  ///
  /// Rules:
  /// - Replace U+00A5 with 'Ñ' if surrounded by uppercase context.
  /// - Replace U+00A5 with 'ñ' otherwise.
  /// - This is conservative and only touches the yen sign.
  String _fixMojibakeYenToEnye(final String name) {
    if (!name.contains('¥')) return name;

    final runes = name.runes.toList();
    final buffer = StringBuffer();

    bool isLatinUpper(final int r) =>
        (r >= 0x41 && r <= 0x5A) || r == 0x00D1; // A-Z or Ñ
    for (int i = 0; i < runes.length; i++) {
      final r = runes[i];
      if (r == 0x00A5) {
        final prev = i > 0 ? runes[i - 1] : null;
        final next = i + 1 < runes.length ? runes[i + 1] : null;
        final upperContext =
            (prev != null && isLatinUpper(prev)) ||
            (next != null && isLatinUpper(next));
        buffer.write(upperContext ? 'Ñ' : 'ñ');
      } else {
        buffer.write(String.fromCharCode(r));
      }
    }
    return buffer.toString();
  }

  /// Conservative UTF-8-from-Latin1 repair for typical mojibake like "Ãñ", "Ã¡", "Ã©", "Â·", etc.
  /// It only triggers when the string contains clear mojibake markers and the round-trip produces a "cleaner" string.
  String _attemptUtf8FromLatin1(final String name) {
    // Fast-path: if it doesn't look like classic UTF-8-as-Latin1 mojibake, return as is.
    if (!name.contains('Ã') && !name.contains('Â')) return name;

    try {
      // Re-interpret current Unicode scalars as Latin-1 bytes, then decode as UTF-8.
      final bytes = latin1.encode(name);
      final decoded = utf8.decode(bytes, allowMalformed: true);

      // Accept only if it actually removes mojibake markers and keeps length sensible.
      final looksBetter =
          (decoded != name) && !decoded.contains('Ã') && !decoded.contains('Â');
      return looksBetter ? decoded : name;
    } catch (_) {
      return name;
    }
  }

  /// CP437-from-Latin1 repair focused on Spanish letters seen as Latin-1 symbols.
  /// This fixes cases like:
  ///   - "a¤o" -> "año"  (Latin1 '¤' U+00A4 is CP437 0xA4 -> 'ñ')
  ///   - "mam " -> "mamá" (Latin1 NBSP U+00A0 is CP437 0xA0 -> 'á')
  /// Also maps a few other common bytes for í/ó/ú/Ñ when they appear as Latin-1 symbols.
  String _attemptCp437FromLatin1(final String name) {
    // Fast path: only run if we detect likely CP437-bytes-shown-as-Latin1.
    final bool likely =
        name.contains('\u00A0') ||
        name.contains('\u00A4') ||
        name.contains('¢') ||
        name.contains('£');
    if (!likely) return name;

    // Minimal targeted map for Spanish letters (extend if more cases appear).
    const Map<String, String> latin1ToCp437Spanish = <String, String>{
      '\u00A0': 'á', // 0xA0 -> á
      '\u00A1': 'í', // 0xA1 -> í (if it ever appears)
      '\u00A2': 'ó', // 0xA2 -> ó
      '\u00A3': 'ú', // 0xA3 -> ú
      '\u00A4': 'ñ', // 0xA4 -> ñ
      // Note: U+00A5 is '¥' which we already handle in _fixMojibakeYenToEnye; include here as safety:
      '\u00A5': 'Ñ', // 0xA5 -> Ñ
    };

    var changed = false;
    final sb = StringBuffer();
    for (final int r in name.runes) {
      final String ch = String.fromCharCode(r);
      final String? mapped = latin1ToCp437Spanish[ch];
      if (mapped != null) {
        sb.write(mapped);
        changed = true;
      } else {
        sb.write(ch);
      }
    }
    return changed ? sb.toString() : name;
  }

  /// Sanitizes file and directory names inside the archive path.
  ///
  /// Keeps Unicode characters (Ñ, accents, emojis) untouched. Only replaces
  /// characters invalid on Windows file systems and handles reserved names.
  /// Trailing dots/spaces are removed on Windows.
  ///
  /// NEW (cross-platform hardening):
  /// - Trim **trailing spaces and dots** on **every path segment** for *all* OS.
  ///   Google Takeout sometimes produces folder names with a trailing space
  ///   (e.g., `"Fotos de "`). We normalize those here to avoid later “No such file
  ///   or directory” when other modules compose paths.
  String _sanitizeFileName(final String fileName) {
    // The ZIP format uses forward slashes. Normalize, then sanitize each segment.
    final String unified = fileName.replaceAll('\\', '/');
    final List<String> rawSegments = unified.split('/');

    if (rawSegments.isEmpty) return fileName;

    final List<String> sanitizedSegments = <String>[];

    for (int i = 0; i < rawSegments.length; i++) {
      var seg = rawSegments[i];
      if (seg.isEmpty) continue; // skip empty (avoid accidental //)

      // Replace invalid characters (keep Unicode intact)
      seg = seg.replaceAll(RegExp(r'[<>:"|?*]'), '_');

      // Remove ASCII control characters from the segment
      seg = seg.replaceAll(RegExp(r'[\x00-\x1F]'), '_');

      // IMPORTANT: trim trailing spaces/dots on *all* platforms (Takeout quirk)
      // This is the only behavior change vs before; it prevents creating folders
      // ending with a space which later break path resolution.
      seg = seg.replaceAll(RegExp(r'[. ]+$'), '');

      // Windows reserved device names — we keep original behavior (apply on last segment).
      if (Platform.isWindows && i == rawSegments.length - 1) {
        final List<String> reservedNames = <String>[
          'CON',
          'PRN',
          'AUX',
          'NUL',
          'COM1',
          'COM2',
          'COM3',
          'COM4',
          'COM5',
          'COM6',
          'COM7',
          'COM8',
          'COM9',
          'LPT1',
          'LPT2',
          'LPT3',
          'LPT4',
          'LPT5',
          'LPT6',
          'LPT7',
          'LPT8',
          'LPT9',
        ];
        final String baseName = p.basenameWithoutExtension(seg);
        final String ext = p.extension(seg);
        if (reservedNames.contains(baseName.toUpperCase())) {
          seg = '${baseName}_file$ext';
        }
      }

      // Do not produce empty path components after trimming; substitute a safe marker.
      if (seg.isEmpty) seg = '_';

      sanitizedSegments.add(seg);
    }

    // Join using the platform separator so later p.join(...) remains consistent.
    return sanitizedSegments.join(Platform.pathSeparator);
  }

  /// Returns true if the name contains characters that usually indicate encoding issues.
  // ignore: prefer_expression_function_bodies
  bool _looksSuspicious(final String name) {
    return name.contains('¥') ||
        name.contains('�') ||
        name.contains('~') ||
        name.contains('Ã') ||
        name.contains('Â') ||
        name.contains('\u00A0') ||
        name.contains('\u00A4');
    // The tilde (~) often appears in DOS 8.3 short names (e.g., RESIDE~4).
  }

  /// Logs the name with code points for diagnostics.
  void _logNameDiagnostics(final String stage, final String name) {
    final codePoints = name.runes
        .map(
          (final r) => 'U+${r.toRadixString(16).toUpperCase().padLeft(4, '0')}',
        )
        .join(' ');
    logInfo('[NameDiag][$stage] "$name"  ->  $codePoints', forcePrint: true);
  }

  /// Handles extraction errors with detailed error messages and user guidance.
  Never _handleExtractionError(
    final File zip,
    final Object errorObject, {
    final bool isArchiveError = false,
    final bool isPathError = false,
    final bool isFileSystemError = false,
  }) {
    final String zipName = p.basename(zip.path);

    logError('');
    logError('===============================================');
    logError('❌ ERROR: Failed to extract $zipName');
    logError('===============================================');

    if (isArchiveError) {
      logError('💥 ZIP Archive Error:');
      logError(
        'The ZIP file appears to be corrupted or uses an unsupported format.',
      );
      logError('');
      logError('🔧 Suggested Solutions:');
      logError('• Re-download the ZIP file from Google Takeout');
      logError('• Verify the file wasn\'t corrupted during download');
      logError(
        '• Try extracting manually with your system\'s built-in extractor',
      );
    } else if (isPathError) {
      logError('📁 Path/File Error:');
      logError('There was an issue accessing files or creating directories.');
      logError('');
      logError('🔧 Suggested Solutions:');
      logError(
        '• Ensure you have sufficient permissions in the target directory',
      );
      logError(
        '• Check that the target path is not too long (Windows limitation)',
      );
      logError('• Verify sufficient disk space is available');
    } else if (isFileSystemError) {
      logError('💾 File System Error:');
      logError('Unable to read the ZIP file or write extracted files.');
      logError('');
      logError('🔧 Suggested Solutions:');
      logError('• Check file permissions on the ZIP file');
      logError(
        '• Ensure the ZIP file is not currently open in another program',
      );
      logError('• Verify the target directory is writable');
    } else {
      logError('⚠️  Unexpected Error:');
      logError('An unexpected error occurred during extraction.');
    }

    logError('');
    logError('📋 Error Details: $errorObject');
    logError('');
    logError('🔄 Alternative Options:');
    logError('• Extract ZIP files manually using your system tools');
    logError('• Use GPTH with command-line options on pre-extracted files');
    logError(
      '• See manual extraction guide: https://github.com/Xentraxx/GooglePhotosTakeoutHelper?tab=readme-ov-file#command-line-usage',
    );
    logError('');
    logError('===============================================');
    logError('');
    logError('⚠️  ZIP EXTRACTION FAILED - CONTINUING WITH PROCESSING');
    logError('The ZIP extraction failed, but GPTH will continue processing');
    logError('any files that were successfully extracted before the error.');
    logError('Please check the extraction directory for partial results.');

    // Propagate to caller
    throw Exception('ZIP extraction failed: $errorObject');
  }
}

/// Custom exception for security-related extraction issues
class SecurityException implements Exception {
  /// Creates a security exception with the given message
  const SecurityException(this.message);

  /// The error message describing the security issue
  final String message;

  @override
  String toString() => 'SecurityException: $message';
}
