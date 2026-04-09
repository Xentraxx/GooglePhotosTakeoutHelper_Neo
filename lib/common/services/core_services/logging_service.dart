import 'dart:convert';
import 'dart:io';
import 'package:gpth_neo/gpth_lib_exports.dart';

/// Service for application logging with colored output and level filtering
///
/// Extracted from utils.dart to provide a clean, testable logging interface
/// that can be easily mocked and configured for different environments.
class LoggingService {
  /// Creates a new instance of LoggingService
  LoggingService({
    this.isVerbose = false,
    this.enableColors = true,
    this.saveLog = false,
    final String? preferredLogDir,
  }) : _preferredLogDir = preferredLogDir {
    if (saveLog) _initFileSink();
  }

  /// Creates a logging service from processing configuration
  factory LoggingService.fromConfig(final ProcessingConfig config) =>
      LoggingService(
        isVerbose: config.verbose,
        enableColors:
            !Platform.isWindows || Platform.environment['TERM'] != null,
        preferredLogDir: config.outputPath,
        saveLog: config.saveLog,
      );

  /// Test override for quit/exit to prevent actual process termination in tests
  static void Function(int code)? testExitOverride;

  /// Whether verbose logging is enabled
  final bool isVerbose;

  /// Whether to use colored output (disable for file logging)
  final bool enableColors;

  /// Whether to also save logs to a file
  final bool saveLog;

  /// Creation timestamp used for per-instance information (file uses global timestamp)
  final DateTime _createdAt = DateTime.now();

  /// Global shared timestamp for the log filename (ensures a single file per process)
  static String? _globalTimestamp;

  /// Global shared sink and path so all instances write to the same file
  static IOSink? _globalSink;
  static String? _globalLogFilePath;

  /// Session header guard (avoid duplicating the header across instances)
  static bool _sessionHeaderWritten = false;

  /// Invocation details captured by the entrypoint.
  ///
  /// We can't reliably recover the original shell command string in Dart, but we can
  /// record the executable + argv array (and a best-effort reconstructed command).
  static String? _invocationExecutable;
  static String? _invocationCwd;
  static List<String>? _invocationArgs;

  /// Capture the current process invocation so it can be written into the log header.
  ///
  /// Call this as early as possible from the entrypoint (before the log file is created).
  static void setInvocation({
    required final List<String> args,
    final String? executable,
    final String? cwd,
  }) {
    _invocationArgs = List<String>.from(args);
    _invocationExecutable = executable;
    _invocationCwd = cwd;
  }

  static String _reconstructCommand(final String exe, final List<String> args) {
    String quote(final String s) {
      // Best-effort quoting for readability in logs.
      if (s.isEmpty) return '""';
      final needsQuotes = RegExp(r'[\s"\\]').hasMatch(s);
      if (!needsQuotes) return s;
      return '"${s.replaceAll('\\', '\\\\').replaceAll('"', '\\"')}"';
    }

    final parts = <String>[quote(exe), ...args.map(quote)];
    return parts.join(' ');
  }

  /// Collected warning messages during processing
  final List<String> _warnings = [];

  /// Collected error messages during processing
  final List<String> _errors = [];

  /// Path of the log file if file logging is enabled (mirrors global path)
  String? _logFilePath;

  /// Sink used to persist logs to disk (points to global sink)
  IOSink? _fileSink;

  /// Preferred Log Dir to save the log
  final String? _preferredLogDir;

  /// Log levels with associated colors
  static const Map<String, String> _levelColors = {
    'error': '\x1B[31m', // Red
    'warning': '\x1B[33m', // Yellow
    'info': '\x1B[32m', // Green
    'debug': '\x1B[36m', // Cyan
  };

  /// Fixed width for level text inside brackets to align like [WARNING]
  static const int _levelTextWidth = 7; // "WARNING" length

  /// NEW: Pure, side-effect-free path preview that also *primes* the global timestamp.
  /// This DOES NOT create any file or directory and MUST be called *before* the
  /// final logger with `preferredLogDir` is constructed if you want a stable name.
  static String previewLogFilePath(final String preferredLogDir) {
    // Reuse the existing global timestamp or set it just once.
    final String ts = _globalTimestamp ??= _tsForFilenameStatic(DateTime.now());
    final String base = Directory(preferredLogDir).path;
    final String sep = Platform.pathSeparator;
    // Keep the exact naming scheme the sink will use later.
    return '$base${sep}gpth_v${version}_$ts.log';
  }

  /// Logs a message with the specified level
  ///
  /// [message] The message to log
  /// [level] Log level: 'info', 'warning', 'error', 'debug'
  /// [forcePrint] If true, prints even when verbose mode is disabled
  void log(
    final String message, {
    final String level = 'info',
    final bool forcePrint = false,
  }) {
    // Persist to file if enabled. For 'debug', only write when verbose is true.
    final String lvl = level.toLowerCase();
    final bool canWriteFile =
        _fileSink != null && (lvl != 'debug' || isVerbose);
    if (canWriteFile) {
      final String plain = _formatPlainMessage(message, level);
      _writeToFile(plain);
    }

    // Print to console respecting verbosity / forcePrint
    if (isVerbose || forcePrint) {
      final String output = _formatMessage(message, level);
      print(output);
    }
  }

  /// Prints an info message without ANSI colors, always to console and file.
  ///
  /// This behaves like a standard print but prefixes the line with an aligned [INFO]
  /// and also persists it to the log file when enabled, regardless of verbosity.
  void printPlain(final String message, {final bool forcePrint = true}) {
    final String line = _formatPlainMessage(message, 'info');
    if (_fileSink != null) _writeToFile(line);
    if (forcePrint) {
      print(line);
    }
  }

  /// Logs an info message
  void info(final String message, {final bool forcePrint = false}) {
    log(message, forcePrint: forcePrint);
  }

  /// Logs a warning message
  void warning(final String message, {final bool forcePrint = false}) {
    _warnings.add(message);
    log(message, level: 'warning', forcePrint: forcePrint);
  }

  /// Logs an error message
  void error(final String message, {final bool forcePrint = false}) {
    _errors.add(message);
    log(message, level: 'error', forcePrint: forcePrint);
  }

  /// Logs a debug message (only in verbose mode)
  void debug(final String message, {final bool forcePrint = false}) {
    log(message, level: 'debug', forcePrint: forcePrint);
  }

  /// Formats a message with level and color coding (for console)
  String _formatMessage(final String message, final String level) {
    final String label = _formatAlignedLabel(level);
    if (!enableColors) {
      return '$label $message';
    }
    final String color = _levelColors[level.toLowerCase()] ?? '';
    const String reset = '\x1B[0m';
    return '\r$color$label $message$reset';
  }

  /// Formats a message without ANSI (for file or plain prints)
  String _formatPlainMessage(final String message, final String level) {
    final String label = _formatAlignedLabel(level);
    return '$label $message';
  }

  /// Returns an aligned bracketed label like [INFO   ], [ERROR  ], [WARNING]
  /// Centered within the fixed width to keep visual harmony across levels.
  String _formatAlignedLabel(final String level) {
    final String levelUpper = level.toUpperCase();
    final int padTotal = _levelTextWidth - levelUpper.length;
    if (padTotal <= 0) return '[$levelUpper]';
    final int leftPad = padTotal ~/ 2;
    final int rightPad = padTotal - leftPad;
    final String lp = ' ' * leftPad;
    final String rp = ' ' * rightPad;
    return '[$lp$levelUpper$rp]';
  }

  /// Creates a child logger with the same configuration
  LoggingService copyWith({
    final bool? isVerbose,
    final bool? enableColors,
    final bool? saveLog,
  }) => LoggingService(
    isVerbose: isVerbose ?? this.isVerbose,
    enableColors: enableColors ?? this.enableColors,
    saveLog: saveLog ?? this.saveLog,
    preferredLogDir: _preferredLogDir,
  );

  /// Gets all collected warning messages
  List<String> get warnings => List.unmodifiable(_warnings);

  /// Gets all collected error messages
  List<String> get errors => List.unmodifiable(_errors);

  /// Gets the absolute path of the log file if enabled
  String? get logFilePath => _logFilePath;

  /// Whether file logging is currently enabled and sink is open
  bool get isFileLoggingEnabled => _fileSink != null;

  /// Clears all collected warning and error messages
  void clearCollectedMessages() {
    _warnings.clear();
    _errors.clear();
  }

  /// Prints error message to stderr with newline
  void errorToStderr(final Object? object) {
    stderr.write('$object\n');
    if (_fileSink != null) {
      final String line = '${_formatAlignedLabel('stderr')} $object';
      _writeToFile(line);
    }
  }

  /// Exits the program with optional code, showing interactive message if needed
  ///
  /// [code] Exit code (default: 1)
  Never quit([final int code = 1]) {
    // Allow tests to intercept exit to avoid terminating the test process
    final override = testExitOverride;
    if (override != null) {
      override(code);
      throw _LoggingTestExitException(code);
    }

    if (Platform.environment['INTERACTIVE'] == 'true') {
      print(
        '[gpth ${code != 0 ? 'quitted :(' : 'finished :)'} (code $code) - press enter to close]',
      );
      stdin.readLineSync();
    }
    // Best-effort flush/close without awaiting (keep method signature sync)
    try {
      _globalSink?.flush();
    } catch (_) {}
    try {
      _globalSink?.close();
    } catch (_) {}
    _fileSink = null;
    _globalSink = null;
    exit(code);
  }

  /// Initializes the file sink and directory, using a global session timestamp.
  void _initFileSink() {
    try {
      // Reuse global sink if already initialized
      if (_globalSink != null && _globalLogFilePath != null) {
        _fileSink = _globalSink;
        _logFilePath = _globalLogFilePath;
        return;
      }

      final String baseDirPath = _preferredLogDir ?? 'Logs';
      final Directory dir = Directory(baseDirPath);
      if (!dir.existsSync()) dir.createSync(recursive: true);

      // Use (or set) a global timestamp so every instance writes to the same file
      final String ts = _globalTimestamp ??= _tsForFilenameStatic(
        DateTime.now(),
      );
      final String candidatePath =
          '${dir.path}${Platform.pathSeparator}gpth_v${version}_$ts.log';
      final File f = File(candidatePath);

      // Create file explicitly (Windows/Google Drive can fail with append-open on non-existing files)
      if (!f.existsSync()) f.createSync(recursive: true);

      String pathUsed;

      // Primary attempt: normal path + write
      try {
        pathUsed = f.absolute.path;
        _globalSink = f.openWrite();
      } on FileSystemException {
        // Windows fallback: try extended-length path (\\?\)
        if (Platform.isWindows) {
          final String ext = _toExtendedWindowsPath(f.absolute.path);
          final File f2 = File(ext);
          if (!f2.existsSync()) f2.createSync(recursive: true);
          pathUsed = f2.path;
          _globalSink = f2.openWrite();
        } else {
          rethrow;
        }
      }

      // Assign globals so every new instance will reuse the same sink/path
      _globalLogFilePath = pathUsed;
      _fileSink = _globalSink;
      _logFilePath = _globalLogFilePath;

      // Session header only once per process
      if (!_sessionHeaderWritten) {
        _globalSink!.writeln(
          '${_formatAlignedLabel('info')} ===== GPTH Logging started ${_createdAt.toIso8601String()} =====',
        );
        _globalSink!.writeln(
          '${_formatAlignedLabel('info')} Log file: $_globalLogFilePath',
        );
        _globalSink!.writeln(
          '${_formatAlignedLabel('info')} Platform: ${Platform.operatingSystem} ${Platform.version.split(' ').first}',
        );
        _globalSink!.writeln(
          '${_formatAlignedLabel('info')} GPTH Version: $version',
        );

        // Invocation info (captured by entrypoint).
        final exe = _invocationExecutable;
        final cwd = _invocationCwd;
        final argv = _invocationArgs;
        if (exe != null || cwd != null || argv != null) {
          _globalSink!.writeln('${_formatAlignedLabel('info')} Invocation:');
          if (exe != null) {
            _globalSink!.writeln(
              '${_formatAlignedLabel('info')}   Executable: $exe',
            );
          }
          if (cwd != null) {
            _globalSink!.writeln('${_formatAlignedLabel('info')}   CWD: $cwd');
          }
          if (argv != null) {
            // JSON array preserves exact argv tokens.
            _globalSink!.writeln(
              '${_formatAlignedLabel('info')}   Args (argv): ${jsonEncode(argv)}',
            );
            if (exe != null) {
              _globalSink!.writeln(
                '${_formatAlignedLabel('info')}   Command (approx): ${_reconstructCommand(exe, argv)}',
              );
            }
          }
        }

        _sessionHeaderWritten = true;
      }
    } catch (e) {
      // If file sink fails, keep console logging; do not crash the app.
      _fileSink = null;
      _logFilePath = null;
      _globalSink = null;
      _globalLogFilePath = null;
    }

    // Last-resort fallback to system temp if globals are still null
    if (_globalSink == null || _globalLogFilePath == null) {
      try {
        final Directory tmp = Directory.systemTemp;
        final String ts = _globalTimestamp ??= _tsForFilenameStatic(
          DateTime.now(),
        );
        final String altPath =
            '${tmp.path}${Platform.pathSeparator}gpth_v${version}_$ts.log';
        final File alt = File(altPath);
        if (!alt.existsSync()) alt.createSync(recursive: true);
        _globalLogFilePath = alt.absolute.path;
        _globalSink = alt.openWrite();
        _fileSink = _globalSink;
        _logFilePath = _globalLogFilePath;

        if (!_sessionHeaderWritten) {
          _globalSink!.writeln(
            '${_formatAlignedLabel('info')} ===== GPTH Logging started ${_createdAt.toIso8601String()} =====',
          );
          _globalSink!.writeln(
            '${_formatAlignedLabel('info')} Log file: $_globalLogFilePath',
          );
          _globalSink!.writeln(
            '${_formatAlignedLabel('info')} Platform: ${Platform.operatingSystem} ${Platform.version.split(' ').first}',
          );
          _sessionHeaderWritten = true;
        }
      } catch (_) {
        _fileSink = null;
        _logFilePath = null;
        _globalSink = null;
        _globalLogFilePath = null;
      }
    }
  }

  /// Writes a single line to the log file without ANSI control codes.
  void _writeToFile(final String line) {
    try {
      // Asynchronous write with flush to avoid lost last lines
      final String? p = _globalLogFilePath ?? _logFilePath;
      if (p == null) return;
      File(p).writeAsStringSync('$line\n', mode: FileMode.append, flush: true);
    } catch (_) {
      // Swallow file I/O errors to avoid breaking the application flow.
    }
  }

  /// Formats timestamp as yyyymmdd-hhmmss for filenames. (static helper for preview)
  static String _tsForFilenameStatic(final DateTime dt) {
    String two(final int v) => v < 10 ? '0$v' : '$v';
    final String y = dt.year.toString().padLeft(4, '0');
    final String m = two(dt.month);
    final String d = two(dt.day);
    final String h = two(dt.hour);
    final String mi = two(dt.minute);
    final String s = two(dt.second);
    return '$y$m$d-$h$mi$s';
  }

  /// Converts an absolute Windows path to extended-length form (\\?\ or \\?\UNC\)
  String _toExtendedWindowsPath(final String absPath) {
    // Already extended or device path
    if (absPath.startsWith(r'\\?\') || absPath.startsWith(r'\\.\')) {
      return absPath;
    }
    // UNC path
    if (absPath.startsWith(r'\\')) return r'\\?\UNC\' + absPath.substring(2);
    return r'\\?\' + absPath;
  }

  /// Closes the file sink gracefully (optional; console logging unaffected).
  void close() {
    try {
      _globalSink?.flush();
    } catch (_) {}
    try {
      _globalSink?.close();
    } catch (_) {}
    _fileSink = null;
    _globalSink = null;
  }
}

/// Extension to add logging capabilities to any class
mixin LoggerMixin {
  // Per-instance logger storage without adding instance fields.
  // Using Expando keeps objects const-constructible while still allowing
  // instance-specific loggers to be attached later.
  static final Expando<LoggingService> _perInstanceLogger =
      Expando<LoggingService>('LoggerMixin.logger');

  // Process-wide default logger used when an instance logger is not set.
  static LoggingService? _sharedDefaultLogger;

  /// Returns the logger for this instance if one was set via the setter.
  /// Otherwise returns the shared default logger, creating it lazily from
  /// global config the first time it is needed.
  LoggingService get logger =>
      _perInstanceLogger[this] ??
      (_sharedDefaultLogger ??= _createDefaultLoggerFromGlobalConfig());

  /// Assigns a logger to this specific instance (stored in the Expando).
  set logger(final LoggingService newLogger) {
    _perInstanceLogger[this] = newLogger;
  }

  /// Allows the application to set/replace the shared default logger used by
  /// instances that don't have a per-instance logger assigned.
  static set sharedDefaultLogger(final LoggingService logger) =>
      _sharedDefaultLogger = logger;

  // Convenience wrappers delegating to the resolved logger
  void logInfo(final String message, {final bool forcePrint = false}) =>
      logger.info(message, forcePrint: forcePrint);

  void logWarning(final String message, {final bool forcePrint = false}) =>
      logger.warning(message, forcePrint: forcePrint);

  void logError(final String message, {final bool forcePrint = false}) =>
      logger.error(message, forcePrint: forcePrint);

  void logDebug(final String message, {final bool forcePrint = false}) =>
      logger.debug(message, forcePrint: forcePrint);

  /// Prints a plain, aligned INFO line (no ANSI colors) and persists to file if enabled.
  void logPrint(final String message, {final bool forcePrint = true}) =>
      logger.printPlain(message, forcePrint: forcePrint);

  /// Builds a sensible default logger if none was injected yet.
  /// Prefers an already-initialized logger from the ServiceContainer to keep
  /// coloring and file sinks consistent across the process; otherwise falls back
  /// to a fresh LoggingService using platform/global defaults.
  static LoggingService _createDefaultLoggerFromGlobalConfig() {
    // Prefer the app-wide logger if the container is ready
    try {
      return ServiceContainer.instance.loggingService;
    } catch (_) {
      // ServiceContainer not ready yet — fall through to local defaults
    }

    bool save;
    try {
      save = ServiceContainer.instance.globalConfig.saveLog == true;
    } catch (_) {
      save = false; // Safe default when global config is not available
    }

    final bool colors =
        !Platform.isWindows || Platform.environment['TERM'] != null;
    return LoggingService(enableColors: colors, saveLog: save);
  }
}

/// Lightweight concrete class that applies [LoggerMixin] so that top-level
/// free functions in any file can delegate to it without needing `this`.
class TopLevelLogger with LoggerMixin {
  const TopLevelLogger();
}

// ─────────────────────────────────────────────────────────────────────────────
// Package-wide top-level log helpers.
// Files that need file-scoped logging can simply import gpth_lib_exports.dart
// and call these directly instead of redeclaring the boilerplate locally.
const _kTopLevelLogger = TopLevelLogger();
void logPrint(final String message, {final bool forcePrint = true}) =>
    _kTopLevelLogger.logPrint(message, forcePrint: forcePrint);
void logDebug(final String message, {final bool forcePrint = false}) =>
    _kTopLevelLogger.logDebug(message, forcePrint: forcePrint);
void logInfo(final String message, {final bool forcePrint = false}) =>
    _kTopLevelLogger.logInfo(message, forcePrint: forcePrint);
void logWarning(final String message, {final bool forcePrint = false}) =>
    _kTopLevelLogger.logWarning(message, forcePrint: forcePrint);
void logError(final String message, {final bool forcePrint = false}) =>
    _kTopLevelLogger.logError(message, forcePrint: forcePrint);
// ─────────────────────────────────────────────────────────────────────────────

/// Exception thrown by quit when test override is active
class _LoggingTestExitException implements Exception {
  const _LoggingTestExitException(this.code);
  final int code;

  @override
  String toString() =>
      'Application attempted to quit with exit code $code. '
      'This indicates a fatal error or completion condition was reached. '
      'In production, this would terminate the application immediately. '
      'Review the logs above for the specific reason for termination.';
}
