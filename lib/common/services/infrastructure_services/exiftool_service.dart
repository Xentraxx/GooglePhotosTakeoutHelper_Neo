import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:gpth_neo/gpth_lib_exports.dart';
import 'package:path/path.dart' as path;

/// Infrastructure service for ExifTool external process management.
/// Keeps 4.2.2 performance behavior while restoring robust path discovery
/// (binary/script dir, parent dirs, PATH, common install paths) and
/// adds safe batch write via classic argv and via argfile (-@ file).
class ExifToolService with LoggerMixin {
  ExifToolService(this.exiftoolPath);

  final String exiftoolPath;

  // ─── Stay-open IPC state ────────────────────────────────────────────────────
  // A single long-running ExifTool Perl process receives all write commands via
  // stdin (the -stay_open / -execute protocol), eliminating the ~1-2 s Perl
  // startup cost that occurs on every one-shot invocation on Linux / WSL.
  Process? _stayOpenProc;
  late Stream<String>? _stayOpenStdout; // broadcast stream from proc.stdout
  late Stream<String>? _stayOpenStderr; // broadcast stream from proc.stderr
  // Serialise commands so stdout/stderr attribution is unambiguous.
  Future<void> _stayOpenChain = Future<void>.value();
  int _stayOpenCounter = 0;
  bool _isDisposed = false;
  bool _isStarting = false;
  // ───────────────────────────────────────────────────────────────────────────

  static const int _maxCommandPreviewChars = 320;

  // Generous timeouts to avoid indefinite hangs while still tolerating heavy load.
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

  /// Start the persistent ExifTool process in stay-open IPC mode.
  ///
  /// All subsequent write operations (single-file and batch) are routed through
  /// this single permanently-running Perl process via stdin/stdout, eliminating
  /// the ~1-2 s Perl startup overhead that occurs on every one-shot invocation
  /// on Linux / WSL.  Falls back gracefully to one-shot if the process cannot
  /// be started.
  Future<void> startPersistentProcess() async {
    if (_stayOpenProc != null || _isDisposed || _isStarting) return;
    _isStarting = true;
    try {
      _stayOpenProc = await Process.start(exiftoolPath, [
        '-stay_open',
        'True',
        '-@',
        '-',
      ]);

      _stayOpenStdout = _stayOpenProc!.stdout
          .transform(const Utf8Decoder(allowMalformed: true))
          .transform(const LineSplitter())
          .asBroadcastStream();

      _stayOpenStderr = _stayOpenProc!.stderr
          .transform(const Utf8Decoder(allowMalformed: true))
          .transform(const LineSplitter())
          .asBroadcastStream();

      logDebug('[ExifToolService] Stay-open IPC process started.');
    } catch (e) {
      _stayOpenProc = null;
      logWarning(
        '[ExifToolService] Failed to start stay-open process '
        '(will fall back to one-shot): $e',
      );
    } finally {
      _isStarting = false;
    }
  }

  /// Serialise [fn] so that at most one stay-open command runs at a time.
  /// This ensures stdout/stderr attribution is unambiguous across concurrent callers.
  Future<T> _withStayOpenLock<T>(final Future<T> Function() fn) {
    final completer = Completer<T>();
    _stayOpenChain = _stayOpenChain.then((_) async {
      try {
        completer.complete(await fn());
      } catch (e, st) {
        completer.completeError(e, st);
      }
    });
    return completer.future;
  }

  /// Send [args] to the stay-open process and return stdout.
  /// Falls back to [executeExifToolCommand] if stay-open is not running.
  Future<String> _executeViaStayOpen(
    final List<String> args, {
    final Duration? timeout,
  }) async {
    if (_stayOpenProc == null || _isDisposed) {
      return executeExifToolCommand(args, timeout: timeout);
    }
    return _withStayOpenLock(
      () => _runOneStayOpenCommand(args, timeout: timeout),
    );
  }

  Future<String> _runOneStayOpenCommand(
    final List<String> args, {
    final Duration? timeout,
  }) async {
    final int id = ++_stayOpenCounter;
    final String tag = id.toString().padLeft(8, '0');
    final String readySignal = '{ready$tag}';

    logDebug(
      '[ExifToolService] Stay-open command #$id '
      '(${args.length} args): ${_formatArgsForDebug(args)}',
    );

    final outLines = <String>[];
    final errLines = <String>[];
    final readyCompleter = Completer<void>();

    // Subscribe before writing so we cannot miss any output lines.
    final outSub = _stayOpenStdout!.listen((final line) {
      if (line == readySignal) {
        if (!readyCompleter.isCompleted) readyCompleter.complete();
      } else {
        outLines.add(line);
      }
    });
    final errSub = _stayOpenStderr!.listen(errLines.add);

    // Write args and the tagged execute sentinel.
    final sb = StringBuffer();
    args.forEach(sb.writeln);
    sb.writeln('-execute$tag');
    _stayOpenProc!.stdin.write(sb.toString());
    await _stayOpenProc!.stdin.flush();

    try {
      if (timeout != null) {
        await readyCompleter.future.timeout(
          timeout,
          onTimeout: () => throw TimeoutException(
            'ExifTool stay-open command timed out after ${timeout.inSeconds}s',
          ),
        );
      } else {
        await readyCompleter.future;
      }
    } finally {
      await outSub.cancel();
      await errSub.cancel();
    }

    final stderrStr = errLines.join('\n');

    // Fatal errors from ExifTool appear as "Error:" on stderr.
    // Warnings ("Warning:") are non-fatal — match one-shot behaviour.
    final hasError = errLines.any((final l) {
      final t = l.trimLeft();
      return t.startsWith('Error:') || t.startsWith('error:');
    });

    if (hasError) {
      final errTrimmed = stderrStr.trim();
      // 'Not a valid XYZ (looks more like a JPEG)' means the file has a wrong
      // extension (e.g. .CR2 or .DNG with JPEG bytes); Step 7 retries via the
      // native JPEG path and emits its own message, so suppress noise here.
      if (!errTrimmed.contains('InteropIFD') &&
          !errTrimmed.contains('atom is too large for rewriting') &&
          !errTrimmed.contains('looks more like')) {
        logDebug(
          '[ExifToolService] ExifTool failed (stay-open). Stderr: $errTrimmed',
        );
        logWarning('[ExifToolService] ExifTool command failed: $errTrimmed');
      }
      throw Exception('ExifTool failed: $stderrStr');
    }

    if (stderrStr.trim().isNotEmpty) {
      logDebug(
        '[ExifToolService] ExifTool command stderr (non-fatal): ${stderrStr.trim()}',
      );
    }

    return outLines.join('\n');
  }

  String _formatArgsForDebug(final List<String> args) {
    final quoted = args
        .map((final a) {
          if (a.isEmpty) return "''";
          if (a.contains(' ') || a.contains('"') || a.contains("'")) {
            return '"${a.replaceAll('"', r'\"')}"';
          }
          return a;
        })
        .join(' ');

    if (quoted.length <= _maxCommandPreviewChars) {
      return quoted;
    }

    return '${quoted.substring(0, _maxCommandPreviewChars)} ...';
  }

  String _formatFullCommandForDebug(final List<String> args) =>
      _formatArgsForDebug(<String>[exiftoolPath, ...args]);

  /// NEW: ExifTool runner with timeout support and proper kill on expiration.
  Future<String> executeExifToolCommand(
    final List<String> args, {
    final Duration? timeout,
  }) async {
    final sw = Stopwatch()..start();
    Process? proc;
    try {
      logDebug(
        '[ExifToolService] Running command: ${_formatFullCommandForDebug(args)}',
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
        // InteropIFD errors (Truncated / Bad / Suspicious offset) are common in
        // Google Photos edited images and WhatsApp files. They are fully handled
        // by the retry logic in the calling code and surfaced via a [WARNING] by
        // the caller, so skip both the DEBUG dump and the user-visible WARNING here
        // to avoid printing the same file list twice.
        //
        // 'atom is too large for rewriting' is a hard ExifTool limit on large
        // QuickTime/MOV files; retrying is pointless and the caller emits its
        // own user-friendly warning, so suppress here too.
        // 'Not a valid XYZ (looks more like a JPEG)' means the file has a wrong
        // extension (e.g. .CR2 or .DNG with JPEG bytes); Step 7 retries via the
        // native JPEG path and emits its own message, so suppress noise here.
        if (!errTrimmed.contains('InteropIFD') &&
            !errTrimmed.contains('atom is too large for rewriting') &&
            !errTrimmed.contains('looks more like')) {
          logDebug(
            '[ExifToolService] ExifTool failed (exit $exitCode). '
            'Command: ${_formatFullCommandForDebug(args)}. Stderr: $errTrimmed',
          );
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
    }
  }

  /// Read EXIF (fast path).
  Future<Map<String, dynamic>> readExifData(final File file) async {
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

    String output;

    if (_stayOpenProc != null && !_isDisposed) {
      // Stay-open path: send args + file path inline through stdin.
      // No temp argfile needed — stdin accepts UTF-8 on all platforms.
      output = await _executeViaStayOpen([
        ...baseArgs,
        file.path,
      ], timeout: _readTimeout);
    } else {
      // One-shot fallback: use a BOM argfile for correct non-ASCII path
      // handling on Windows.
      String? argfilePath;
      try {
        argfilePath = await _createUtf8Argfile(baseArgs, [file.path]);
        output = await executeExifToolCommand([
          '-@',
          argfilePath,
        ], timeout: _readTimeout);
      } finally {
        if (argfilePath != null) {
          try {
            File(argfilePath).deleteSync();
          } catch (_) {}
        }
      }
    }

    if (output.trim().isEmpty) return {};
    try {
      final List<dynamic> jsonList = jsonDecode(output);
      if (jsonList.isNotEmpty && jsonList[0] is Map<String, dynamic>) {
        return Map<String, dynamic>.from(jsonList[0] as Map);
      }
      return {};
    } catch (e) {
      logWarning(
        '[Step 4/8] JSON decode failed in readExifData: $e',
        forcePrint: true,
      );
      return {};
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
    // Normalize the path for ExifTool (adds \\?\ prefix for long Windows paths).
    args.add(_normalizePathForExifTool(file.absolute.path));

    final output = await _executeViaStayOpen(
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
    // ExifTool tag assignments are global to one command; they are not
    // scoped to the filename that follows them. Isolate each file so one
    // file's metadata cannot overwrite another file in the batch.
    for (final fileAndTags in batch) {
      if (fileAndTags.value.isEmpty) continue;
      await writeExifDataSingle(fileAndTags.key, fileAndTags.value);
    }
  }

  /// Batch write using an argfile (-@ file) to avoid command-line limits.
  ///
  /// When the stay-open IPC process is active the args are sent directly
  /// over stdin — no temp file is needed and there are no command-line length
  /// limits.  The argfile path falls back to a temp file only for one-shot
  /// invocations (e.g. when [startPersistentProcess] was not called).
  Future<void> writeExifDataBatchViaArgFile(
    final List<MapEntry<File, Map<String, dynamic>>> batch,
  ) async {
    if (batch.isEmpty) return;
    // An arg file containing several files has the same global-assignment
    // problem, so use the isolated per-file path here as well.
    return writeExifDataBatch(batch);
  }

  /// Copy metadata from [source] to [target] using ExifTool's `-TagsFromFile`.
  ///
  /// This performs a broad metadata transfer (`EXIF`, `XMP`, and related tags)
  /// and preserves file timestamps via [commonWriteArgs].
  Future<void> copyMetadataFromFile({
    required final File source,
    required final File target,
  }) async {
    final args = <String>[];
    args.addAll(commonWriteArgs());
    args.add('-TagsFromFile');
    args.add(_normalizePathForExifTool(source.absolute.path));
    args.add('-all:all');
    args.add('-xmp:all');
    args.add(_normalizePathForExifTool(target.absolute.path));

    final output = await _executeViaStayOpen(
      args,
      timeout: _singleWriteTimeout,
    );
    if (output.contains('error') ||
        output.contains('Error') ||
        output.contains("weren't updated due to errors")) {
      throw Exception(
        '[ExifToolService] ExifTool copy-metadata failed from ${source.path} to ${target.path}: $output',
      );
    }
  }

  Future<void> dispose() async {
    if (_isDisposed) return;
    _isDisposed = true;

    if (_stayOpenProc != null) {
      try {
        _stayOpenProc!.stdin.write('-stay_open\nFalse\n-execute\n');
        await _stayOpenProc!.stdin.flush();
        await _stayOpenProc!.stdin.close();
      } catch (_) {}

      try {
        await _stayOpenProc!.exitCode.timeout(
          const Duration(seconds: 5),
          onTimeout: () {
            _stayOpenProc!.kill();
            return -1;
          },
        );
      } catch (_) {
        try {
          _stayOpenProc!.kill();
        } catch (_) {}
      } finally {
        _stayOpenProc = null;
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
