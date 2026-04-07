import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:gpth_neo/gpth_lib_exports.dart';
import 'package:path/path.dart' as path;

// ─────────────────────────────────────────────────────────────────────────────
// Shim to use LoggerMixin.logPrint from top-level code in this file
// (lets us replace print(...) with logPrint(...))
class _TopLevelLogger with LoggerMixin {
  const _TopLevelLogger();
}

const _TopLevelLogger _kTopLogger = _TopLevelLogger();
void logPrint(final String message, {final bool forcePrint = true}) =>
    _kTopLogger.logPrint(message, forcePrint: forcePrint);
void logDebug(final String message, {final bool forcePrint = false}) =>
    _kTopLogger.logDebug(message, forcePrint: forcePrint);
void logInfo(final String message, {final bool forcePrint = false}) =>
    _kTopLogger.logInfo(message, forcePrint: forcePrint);
void logWarning(final String message, {final bool forcePrint = false}) =>
    _kTopLogger.logWarning(message, forcePrint: forcePrint);
void logError(final String message, {final bool forcePrint = false}) =>
    _kTopLogger.logError(message, forcePrint: forcePrint);
// ─────────────────────────────────────────────────────────────────────────────

/// Infrastructure service for ExifTool external process management.
/// Keeps 4.2.2 performance behavior while restoring robust path discovery
/// (binary/script dir, parent dirs, PATH, common install paths) and
/// adds safe batch write via classic argv and via argfile (-@ file).
class ExifToolService with LoggerMixin {
  ExifToolService(this.exiftoolPath);

  final String exiftoolPath;

  // Persistent process plumbing (kept for future use; batch uses one-shot).
  Process? _persistentProcess;
  StreamSubscription<String>? _outputSubscription;
  StreamSubscription<String>? _errorSubscription;
  final Map<int, Completer<String>> _pendingCommands = {};
  final Map<int, String> _commandOutputs = {};
  bool _isDisposed = false;
  bool _isStarting = false;

  // NEW: generous timeouts to avoid indefinite hangs while still tolerating heavy load.
  final Duration _singleWriteTimeout = const Duration(minutes: 4);
  final Duration _batchWriteTimeout = const Duration(minutes: 10);
  final Duration _readTimeout = const Duration(minutes: 1);

  /// Find ExifTool in PATH, near the binary/script, or in common locations.
  static Future<ExifToolService?> find({
    final bool showDiscoveryMessage = true,
  }) async {
    final isWindows = Platform.isWindows;
    final exiftoolNames = isWindows
        ? ['exiftool.exe', 'exiftool']
        : ['exiftool'];

    // 1) PATH
    for (final name in exiftoolNames) {
      try {
        final result = await Process.run(name, ['-ver']);
        if (result.exitCode == 0) {
          if (showDiscoveryMessage) {
            final version = result.stdout.toString().trim();
            logPrint('ExifTool found in PATH: $name (version $version)');
          }
          return ExifToolService(name);
        }
      } catch (_) {}
    }

    // 2) Binary / script dirs and relatives (like 4.2.1)
    String? binDir;
    try {
      binDir = File(Platform.resolvedExecutable).parent.path;
      if (showDiscoveryMessage) {
        logPrint('Binary directory: $binDir');
      }
    } catch (_) {}

    final scriptPath = Platform.script.toFilePath();
    final scriptDir = scriptPath.isNotEmpty
        ? File(scriptPath).parent.path
        : null;
    if (scriptDir != null && showDiscoveryMessage) {
      logPrint('Script directory: $scriptDir');
    }

    final List<String?> candidateDirs = [
      binDir,
      scriptDir,
      if (binDir != null) path.join(binDir, 'exif_tool'),
      if (scriptDir != null) path.join(scriptDir, 'exif_tool'),
      Directory.current.path,
      path.join(Directory.current.path, 'exif_tool'),
      if (scriptDir != null) path.dirname(scriptDir),
      if (binDir != null) path.dirname(binDir),
      if (binDir != null) path.join(path.dirname(binDir), 'exif_tool'),
    ];

    for (final dir in candidateDirs) {
      if (dir == null || dir.isEmpty) continue;
      for (final exeName in exiftoolNames) {
        final exiftoolFile = File(path.join(dir, exeName));
        if (await exiftoolFile.exists()) {
          try {
            final result = await Process.run(exiftoolFile.path, ['-ver']);
            if (result.exitCode == 0) {
              if (showDiscoveryMessage) {
                final version = result.stdout.toString().trim();
                logPrint(
                  '[ExifToolService] ExifTool found: ${exiftoolFile.path} (version $version)',
                );
              }
              return ExifToolService(exiftoolFile.path);
            }
          } catch (_) {}
        }
      }
    }

    // 3) Common install paths
    final commonPaths = isWindows
        ? [
            r'C:\Program Files\exiftool\exiftool.exe',
            r'C:\Program Files (x86)\exiftool\exiftool.exe',
            r'C:\exiftool\exiftool.exe',
            r'C:\ProgramData\chocolatey\bin\exiftool.exe',
          ]
        : [
            '/usr/bin/exiftool',
            '/usr/local/bin/exiftool',
            '/opt/homebrew/bin/exiftool',
          ];

    for (final p in commonPaths) {
      if (await File(p).exists()) {
        try {
          final result = await Process.run(p, ['-ver']);
          if (result.exitCode == 0) {
            if (showDiscoveryMessage) {
              final version = result.stdout.toString().trim();
              logPrint(
                '[ExifToolService] ExifTool found: $p (version $version)',
              );
            }
            return ExifToolService(p);
          }
        } catch (_) {}
      }
    }

    return null;
  }

  /// Start persistent ExifTool process (not used by batching, but kept available).
  Future<void> startPersistentProcess() async {
    if (_persistentProcess != null || _isDisposed || _isStarting) return;
    _isStarting = true;
    try {
      _persistentProcess = await Process.start(exiftoolPath, [
        '-stay_open',
        'True',
        '-@',
        '-',
      ]);

      _outputSubscription = _persistentProcess!.stdout
          .transform(const Utf8Decoder(allowMalformed: true))
          .transform(const LineSplitter())
          .listen(_handleOutput);

      _errorSubscription = _persistentProcess!.stderr
          .transform(const Utf8Decoder(allowMalformed: true))
          .transform(const LineSplitter())
          .listen(_handleError);
    } catch (e) {
      logWarning(
        '[ExifToolService] Failed to start ExifTool persistent process: $e',
      );
      _persistentProcess = null;
    } finally {
      _isStarting = false;
    }
  }

  void _handleOutput(final String line) {
    if (line.startsWith('{ready}')) {
      if (_pendingCommands.isNotEmpty) {
        final commandId = _pendingCommands.keys.last;
        final output = _commandOutputs[commandId] ?? '';
        _pendingCommands[commandId]!.complete(output);
        _pendingCommands.remove(commandId);
        _commandOutputs.remove(commandId);
      }
    } else {
      if (_pendingCommands.isNotEmpty) {
        final currentCommandId = _pendingCommands.keys.last;
        _commandOutputs[currentCommandId] =
            '${_commandOutputs[currentCommandId] ?? ''}$line\n';
      }
    }
  }

  void _handleError(final String line) {
    logPrint('[ExifToolService] ExifTool error: $line');
  }

  // /// One-shot execution. Batch minimizes launches, but we still use one-shot here.
  // Future<String> old_executeExifToolCommand(final List<String> args) async => executeExifToolCommand(args);  // Keep in the API for compatibility with tests

  /// NEW: ExifTool runner with timeout support and proper kill on expiration.
  Future<String> executeExifToolCommand(
    final List<String> args, {
    final Duration? timeout,
  }) async {
    final sw = Stopwatch()..start();
    Process? proc;
    try {
      logDebug(
        '[ExifToolService] Running command: $exiftoolPath ${args.join(' ')}',
      );

      // NOTE #1: Don't' use detachedWithStdio. We need live pipes to read stdout/stderr.
      proc = await Process.start(exiftoolPath, args);

      // NOTE #2: Drain stdout/stderr from the beginning to no block by back-pressure.
      // final stdoutFuture = proc.stdout.transform(utf8.decoder).join();
      final stdoutFuture = proc.stdout
          .transform(const Utf8Decoder(allowMalformed: true))
          .join();
      // final stderrFuture = proc.stderr.transform(utf8.decoder).join();
      final stderrFuture = proc.stderr
          .transform(const Utf8Decoder(allowMalformed: true))
          .join();

      // Wait for exit (with optional timeout)
      final exitCode = await proc.exitCode.timeout(
        timeout ??
            const Duration(
              days: 365,
            ), // effectively "no timeout" if not provided
        onTimeout: () {
          try {
            if (Platform.isWindows) {
              // Windows: no POSIX signals, kill() ends process.
              proc?.kill();
            } else {
              // POSIX: try to finish process with SIGTERM, if not use SIGKILL as fallback.
              proc?.kill();
              // Second try "best effort" later on
              Future<void>.delayed(const Duration(milliseconds: 300), () {
                try {
                  proc?.kill(ProcessSignal.sigkill);
                } catch (_) {}
              });
            }
          } catch (_) {}
          throw TimeoutException(
            'ExifTool command execution timed out after ${timeout!.inSeconds}s',
          );
        },
      );

      final out = await stdoutFuture;
      final err = await stderrFuture;

      if (exitCode != 0) {
        final errTrimmed = err.trim();
        // Always log full command + stderr at DEBUG so diagnostics are available.
        logDebug(
          '[ExifToolService] ExifTool failed (exit $exitCode). '
          'Command: $exiftoolPath ${args.join(' ')}. Stderr: $errTrimmed',
        );
        // InteropIFD errors (Truncated / Bad / Suspicious offset) are common in
        // Google Photos edited images and WhatsApp files. They are fully handled
        // by the retry logic in the calling code, so skip the user-visible WARNING
        // to avoid noise. A per-file message and step summary are emitted instead.
        if (!errTrimmed.contains('InteropIFD')) {
          logWarning(
            '[ExifToolService] ExifTool command failed (exit $exitCode): $errTrimmed',
          );
        }
        throw Exception('ExifTool failed: $err');
      }

      if (err.trim().isNotEmpty) {
        // ExifTool often writes warnings to stderr even on success; keep as warning.
        logDebug(
          '[ExifToolService] ExifTool command stderr (non-fatal): ${err.trim()}',
        );
      }

      return out.toString();
    } on TimeoutException catch (e) {
      logWarning('[ExifToolService] ExifTool command Timeout: $e');
      rethrow;
    } catch (e) {
      // logWarning('[ExifToolService] ExifTool command execution failed: $e');
      rethrow;
    } finally {
      sw.stop();
      logDebug(
        '[ExifToolService] ExifTool command Elapsed: ${(sw.elapsedMilliseconds / 1000.0).toStringAsFixed(3)}s',
      );
    }
  }

  /// Read EXIF (fast path).
  Future<Map<String, dynamic>> readExifData(final File file) async {
    // Build base exiftool args WITHOUT the file path (we will pass it via UTF-8 argfile to avoid Windows mojibake issues).
    final List<String> baseArgs = [
      '-q',
      '-q',
      '-fast',
      '-j',
      '-n',
      '-charset',
      'filename=UTF8',
      '-charset',
      'exiftool=UTF8',
      '-charset',
      'iptc=UTF8',
      '-charset',
      'id3=UTF8',
      '-charset',
      'quicktime=UTF8',
    ];

    String? argfilePath;
    try {
      // Create a UTF-8 (with BOM) argfile so exiftool receives the path correctly on Windows with Latin characters.
      argfilePath = await _createUtf8Argfile(baseArgs, [file.path]);

      // Call exiftool using the argfile. Keep your timeout behavior.
      final output = await executeExifToolCommand([
        '-@',
        argfilePath,
      ], timeout: _readTimeout);

      if (output.trim().isEmpty) return {};
      try {
        final List<dynamic> jsonList = jsonDecode(output);
        if (jsonList.isNotEmpty && jsonList[0] is Map<String, dynamic>) {
          final Map<String, dynamic> data = Map<String, dynamic>.from(
            jsonList[0] as Map,
          );
          return data;
        }
        return {};
      } catch (e) {
        logWarning(
          '[Step 4/8] JSON decode failed in readExifData: $e',
          forcePrint: true,
        );
        return {};
      }
    } finally {
      // Best-effort cleanup of the temporary argfile
      if (argfilePath != null) {
        try {
          File(argfilePath).deleteSync();
        } catch (_) {}
      }
    }
  }

  // ───────────────────────────────────────────────────────────────────────────
  // Common write flags for stability/consistency
  // NOTE:
  //  - -P preserves file times (mtime/atime) → prevents OS timestamp drift while writing tags.
  //  - -charset filename=UTF8 ensures UTF-8 filename handling consistently across platforms.
  //  - -overwrite_original keeps the "replace" semantics across filesystems (safer than _in_place_).
  //  - -api QuickTimeUTC=1 normalizes QuickTime time handling to UTC (no measurable slowdown).
  //  - NEW: -m to allow minor warnings (avoid aborting on recoverable EXIF issues).
  //  - NEW: -F to fix broken IFD/offsets (A: often converts “Truncated InteropIFD” into success).
  List<String> commonWriteArgs() => <String>[
    '-P',
    '-charset',
    'filename=UTF8',
    '-overwrite_original',
    '-api',
    'QuickTimeUTC=1',
    '-m',
    '-F', // NEW (A): ask exiftool to fix bad IFD offsets and continue
  ];

  /// Write EXIF data to a single file (classic argv).
  Future<void> writeExifDataSingle(
    final File file,
    final Map<String, dynamic> exifData,
  ) async {
    if (exifData.isEmpty) return;

    final args = <String>[];
    args.addAll(commonWriteArgs());
    for (final entry in exifData.entries) {
      args.add('-${entry.key}=${entry.value}');
    }
    args.add(file.path);

    final output = await executeExifToolCommand(
      args,
      timeout: _singleWriteTimeout,
    );
    if (output.contains('error') ||
        output.contains('Error') ||
        output.contains("weren't updated due to errors")) {
      throw Exception(
        '[ExifToolService] ExifTool single-mode failed to write metadata to ${file.path}: $output',
      );
    }
  }

  /// Batch write: multiple files in a single exiftool invocation (classic argv).
  Future<void> writeExifDataBatch(
    final List<MapEntry<File, Map<String, dynamic>>> batch,
  ) async {
    if (batch.isEmpty) return;
    final args = <String>[];
    args.addAll(commonWriteArgs());

    for (final fileAndTags in batch) {
      final file = fileAndTags.key;
      final tags = fileAndTags.value;
      if (tags.isEmpty) continue;

      for (final e in tags.entries) {
        args.add('-${e.key}=${e.value}');
      }
      args.add(file.path);
    }

    final output = await executeExifToolCommand(
      args,
      timeout: _batchWriteTimeout,
    );
    if (output.contains('error') ||
        output.contains('Error') ||
        output.contains("weren't updated due to errors")) {
      throw Exception(
        '[ExifToolService] ExifTool batch-mode failed to write metadata to some file in the batch: $output',
      );
    }
  }

  /// Batch write using an argfile (-@ file) to avoid command-line limits.
  Future<void> writeExifDataBatchViaArgFile(
    final List<MapEntry<File, Map<String, dynamic>>> batch,
  ) async {
    if (batch.isEmpty) return;

    // Build argfile with common args at the top (NO -common_args inside argfile).
    final StringBuffer buf = StringBuffer();

    // Common args (applies to the whole single invocation)
    for (final a in commonWriteArgs()) {
      if (a.contains(' ')) {
        final parts = a.split(' ');
        for (final p in parts) {
          if (p.isNotEmpty) buf.writeln(p);
        }
      } else {
        buf.writeln(a);
      }
    }

    // Then file-specific tags and files
    for (final fileAndTags in batch) {
      final file = fileAndTags.key;
      final tags = fileAndTags.value;
      if (tags.isEmpty) continue;

      for (final e in tags.entries) {
        buf.writeln('-${e.key}=${e.value}');
      }
      buf.writeln(file.path);
    }

    final tmp = await File(
      '${Directory.systemTemp.path}${Platform.pathSeparator}exif_args_${DateTime.now().microsecondsSinceEpoch}.txt',
    ).create();
    await tmp.writeAsString(buf.toString());

    try {
      final output = await executeExifToolCommand([
        '-@',
        tmp.path,
      ], timeout: _batchWriteTimeout);
      if (output.contains('error') ||
          output.contains('Error') ||
          output.contains("weren't updated due to errors")) {
        throw Exception(
          '[ExifToolService] ExifTool batch-mode failed to write metadata (using argfile): $output',
        );
      }
    } finally {
      try {
        await tmp.delete();
      } catch (_) {
        /* ignore */
      }
    }
  }

  Future<void> dispose() async {
    if (_isDisposed) return;
    _isDisposed = true;

    for (final completer in _pendingCommands.values) {
      completer.completeError('ExifTool service disposed');
    }
    _pendingCommands.clear();
    _commandOutputs.clear();

    try {
      await _outputSubscription?.cancel();
    } catch (_) {}
    _outputSubscription = null;

    try {
      await _errorSubscription?.cancel();
    } catch (_) {}
    _errorSubscription = null;

    if (_persistentProcess != null) {
      try {
        _persistentProcess!.stdin.write('-stay_open\nFalse\n');
        await _persistentProcess!.stdin.flush();
        await _persistentProcess!.stdin.close();
      } catch (_) {}

      try {
        await _persistentProcess!.exitCode.timeout(
          const Duration(seconds: 5),
          onTimeout: () {
            _persistentProcess!.kill();
            return -1;
          },
        );
      } catch (_) {
        try {
          _persistentProcess!.kill();
        } catch (_) {}
      } finally {
        _persistentProcess = null;
      }
    }
  }

  /// Create a temporary exiftool argfile encoded as UTF-8 WITH BOM to ensure non-ASCII paths are read correctly on all platforms.
  /// - Each argument is written on its own line.
  /// - IMPORTANT: Do NOT quote file paths; exiftool treats each line as a full token and quotes would become part of the filename.
  /// Returns the path to the argfile (caller must delete it).
  Future<String> _createUtf8Argfile(
    final List<String> baseArgs,
    final List<String> filePaths,
  ) async {
    final Directory tmpDir = await Directory.systemTemp.createTemp(
      'exif_args_',
    );
    final String argfilePath = path.join(tmpDir.path, 'args.txt');
    final IOSink sink = File(argfilePath).openWrite();

    try {
      // Write UTF-8 BOM explicitly so exiftool reads the argfile as UTF-8 on Windows; it is safe on macOS/Linux too.
      sink.add(<int>[0xEF, 0xBB, 0xBF]);

      // Write base args (one per line)
      baseArgs.forEach(sink.writeln);

      // Write file paths unquoted, normalized per-OS.
      for (final original in filePaths) {
        final String abs = path.normalize(File(original).absolute.path);
        final String norm = _normalizePathForExifTool(abs);
        sink.writeln(norm);
      }
    } finally {
      await sink.flush();
      await sink.close();
    }

    return argfilePath;
  }

  /// Normalize a filesystem path for ExifTool in a cross-platform way.
  /// - Windows: use backslashes and add \\?\ prefix for very long paths to bypass MAX_PATH legacy limits.
  /// - macOS/Linux: keep forward slashes; do not add Windows-specific prefixes.
  String _normalizePathForExifTool(final String absolutePath) {
    if (Platform.isWindows) {
      // Convert to backslashes for consistency on Windows
      String pWin = absolutePath.replaceAll('/', '\\');

      // Add \\?\ long-path prefix if needed and not already present
      //  - 248 is a conservative threshold for directories; MAX_PATH is 260 including filename.
      if (!pWin.startsWith(r'\\?\') && pWin.length >= 248) {
        pWin = r'\\?\' + pWin;
      }

      // Do NOT quote; each argfile line is a single token for ExifTool
      return pWin;
    }

    // On Unix-like systems leave the normalized absolute path as-is (forward slashes).
    return absolutePath;
  }
}
