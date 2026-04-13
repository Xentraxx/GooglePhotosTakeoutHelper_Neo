import 'dart:convert';
import 'dart:io';

import 'package:gpth_neo/gpth_lib_exports.dart';
import 'package:logging/logging.dart' as pkg;

// _LogContext – carries per-call configuration through the package:logging pipeline.
class _LogContext {
  const _LogContext({
    required this.forcePrint,
    required this.isVerbose,
    required this.enableColors,
  });
  final bool forcePrint;
  final bool isVerbose;
  final bool enableColors;
}

// _GpthHandler – process-wide I/O singleton registered on Logger.root.
//
// Derives per-record config (verbosity, colours) from the _LogContext object
// attached to each LogRecord rather than from shared mutable state.
class _GpthHandler {
  _GpthHandler._();
  static final _GpthHandler instance = _GpthHandler._();

  static String? _globalTimestamp;
  static IOSink? _globalSink;
  static String? _globalLogFilePath;
  static bool _sessionHeaderWritten = false;

  static String? _invocationExecutable;
  static String? _invocationCwd;
  static List<String>? _invocationArgs;

  static const Map<String, String> _levelColors = {
    'error': '\x1B[31m',
    'warning': '\x1B[33m',
    'info': '\x1B[32m',
    'debug': '\x1B[36m',
  };
  static const int _levelTextWidth = 7;

  static String _labelFor(final pkg.Level level) {
    if (level == pkg.Level.SEVERE) return 'error';
    if (level == pkg.Level.WARNING) return 'warning';
    if (level == pkg.Level.FINE) return 'debug';
    return 'info';
  }

  void handle(final pkg.LogRecord record) {
    // The _LogContext is passed as the third argument to _pkgLogger.log(), which
    // maps to LogRecord.error in package:logging — not LogRecord.object.
    // (LogRecord.object is only set when message is non-String; our messages are
    // always Strings, so record.object is null.)
    final _LogContext? ctx = record.error is _LogContext
        ? record.error as _LogContext
        : null;
    final bool isForcePrint = ctx?.forcePrint ?? false;
    final bool isVerbose = ctx?.isVerbose ?? false;
    final bool enableColors = ctx?.enableColors ?? true;
    final bool isDebugLevel = record.level == pkg.Level.FINE;
    final bool isPlainLevel = record.level >= pkg.Level.SHOUT;
    final String label = _labelFor(record.level);

    if (_globalLogFilePath != null && (!isDebugLevel || isVerbose)) {
      _writeToFile(_formatPlain(record.message, label));
    }
    if (isPlainLevel || isVerbose || isForcePrint) {
      print(
        _formatForConsole(record.message, label, enableColors: enableColors),
      );
    }
  }

  String _formatForConsole(
    final String message,
    final String level, {
    required final bool enableColors,
  }) {
    final String lbl = _alignedLabel(level);
    if (!enableColors) return '$lbl $message';
    final String color = _levelColors[level] ?? '';
    const String reset = '\x1B[0m';
    return '$color$lbl $message$reset';
  }

  String _formatPlain(final String message, final String level) =>
      '${_alignedLabel(level)} $message';

  String _alignedLabel(final String level) {
    final String upper = level.toUpperCase();
    final int pad = _levelTextWidth - upper.length;
    if (pad <= 0) return '[$upper]';
    final int left = pad ~/ 2;
    final int right = pad - left;
    return '[${' ' * left}$upper${' ' * right}]';
  }

  void _writeToFile(final String line) {
    try {
      final String? p = _globalLogFilePath;
      if (p == null) return;
      File(p).writeAsStringSync('$line\n', mode: FileMode.append, flush: true);
    } catch (_) {}
  }

  void initFileSink(final String baseDirPath, final DateTime createdAt) {
    try {
      if (_globalSink != null && _globalLogFilePath != null) return;

      final Directory dir = Directory(baseDirPath);
      if (!dir.existsSync()) dir.createSync(recursive: true);

      final String ts = _globalTimestamp ??= _tsForFilenameStatic(
        DateTime.now(),
      );
      final String candidatePath =
          '${dir.path}${Platform.pathSeparator}gpth_v${version}_$ts.log';
      final File f = File(candidatePath);
      if (!f.existsSync()) f.createSync(recursive: true);

      String pathUsed;
      try {
        pathUsed = f.absolute.path;
        _globalSink = f.openWrite();
      } on FileSystemException {
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

      _globalLogFilePath = pathUsed;
      if (!_sessionHeaderWritten) {
        _writeSessionHeader(createdAt);
        _sessionHeaderWritten = true;
      }
    } catch (_) {
      _globalSink = null;
      _globalLogFilePath = null;
    }

    if (_globalSink == null || _globalLogFilePath == null) {
      try {
        final String ts = _globalTimestamp ??= _tsForFilenameStatic(
          DateTime.now(),
        );
        final String altPath =
            '${Directory.systemTemp.path}${Platform.pathSeparator}gpth_v${version}_$ts.log';
        final File alt = File(altPath);
        if (!alt.existsSync()) alt.createSync(recursive: true);
        _globalLogFilePath = alt.absolute.path;
        _globalSink = alt.openWrite();
        if (!_sessionHeaderWritten) {
          _writeSessionHeader(createdAt);
          _sessionHeaderWritten = true;
        }
      } catch (_) {
        _globalSink = null;
        _globalLogFilePath = null;
      }
    }
  }

  void _writeSessionHeader(final DateTime createdAt) {
    void w(final String msg) => _writeToFile(_formatPlain(msg, 'info'));
    w('===== GPTH Logging started ${createdAt.toIso8601String()} =====');
    w('Log file: $_globalLogFilePath');
    w(
      'Platform: ${Platform.operatingSystem} (Dart SDK ${Platform.version.split(' ').first})',
    );
    w('GPTH Version: $version');
    final exe = _invocationExecutable;
    final cwd = _invocationCwd;
    final argv = _invocationArgs;
    if (exe != null || cwd != null || argv != null) {
      w('Invocation:');
      if (exe != null) w('  Executable: $exe');
      if (cwd != null) w('  CWD: $cwd');
      if (argv != null) {
        w('  Args (argv): ${jsonEncode(argv)}');
        if (exe != null) {
          w('  Command (approx): ${_reconstructCommand(exe, argv)}');
        }
      }
    }
  }

  void closeFileSink() {
    try {
      _globalSink?.flush();
    } catch (_) {}
    try {
      _globalSink?.close();
    } catch (_) {}
    _globalSink = null;
    _globalLogFilePath = null;
  }
}

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
    _ensureRootListener();
    if (saveLog) {
      _GpthHandler.instance.initFileSink(
        _preferredLogDir ?? 'Logs',
        _createdAt,
      );
    }
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

  // ── package:logging wiring ────────────────────────────────────────────────
  static final pkg.Logger _pkgLogger = pkg.Logger('gpth');
  static bool _rootListenerInstalled = false;

  static void _ensureRootListener() {
    if (_rootListenerInstalled) return;
    _rootListenerInstalled = true;
    pkg.Logger.root.level = pkg.Level.ALL;
    pkg.Logger.root.onRecord.listen(_GpthHandler.instance.handle);
  }

  static pkg.Level _toPkgLevel(final String level) {
    switch (level.toLowerCase()) {
      case 'error':
        return pkg.Level.SEVERE;
      case 'warning':
        return pkg.Level.WARNING;
      case 'debug':
        return pkg.Level.FINE;
      default:
        return pkg.Level.INFO;
    }
  }

  /// Whether verbose logging is enabled
  final bool isVerbose;

  /// Whether to use colored output (disable for file logging)
  final bool enableColors;

  /// Whether to also save logs to a file
  final bool saveLog;

  /// Creation timestamp used for per-instance information (file uses global timestamp)
  final DateTime _createdAt = DateTime.now();

  /// Collected warning messages during processing
  final List<String> _warnings = [];

  /// Collected error messages during processing
  final List<String> _errors = [];

  /// Preferred Log Dir to save the log
  final String? _preferredLogDir;

  /// Capture the current process invocation so it can be written into the log header.
  ///
  /// Call this as early as possible from the entrypoint (before the log file is created).
  static void setInvocation({
    required final List<String> args,
    final String? executable,
    final String? cwd,
  }) {
    _GpthHandler._invocationArgs = List<String>.from(args);
    _GpthHandler._invocationExecutable = executable;
    _GpthHandler._invocationCwd = cwd;
  }

  /// Pure, side-effect-free path preview that also primes the global timestamp.
  static String previewLogFilePath(final String preferredLogDir) {
    final String ts = _GpthHandler._globalTimestamp ??= _tsForFilenameStatic(
      DateTime.now(),
    );
    final String base = Directory(preferredLogDir).path;
    return '$base${Platform.pathSeparator}gpth_v${version}_$ts.log';
  }

  /// Logs a message with the specified level.
  void log(
    final String message, {
    final String level = 'info',
    final bool forcePrint = false,
  }) {
    _pkgLogger.log(
      _toPkgLevel(level),
      message,
      _LogContext(
        forcePrint: forcePrint,
        isVerbose: isVerbose,
        enableColors: enableColors,
      ),
    );
  }

  /// Prints a plain info line (no ANSI), always to console and log file.
  void printPlain(final String message, {final bool forcePrint = true}) {
    _pkgLogger.log(
      pkg.Level.SHOUT,
      message,
      _LogContext(
        forcePrint: true,
        isVerbose: isVerbose,
        enableColors: enableColors,
      ),
    );
  }

  /// Logs an info message.
  void info(final String message, {final bool forcePrint = false}) {
    _pkgLogger.log(
      pkg.Level.INFO,
      message,
      _LogContext(
        forcePrint: forcePrint,
        isVerbose: isVerbose,
        enableColors: enableColors,
      ),
    );
  }

  /// Logs a warning message (also accumulated in [warnings]).
  void warning(final String message, {final bool forcePrint = false}) {
    _warnings.add(message);
    _pkgLogger.log(
      pkg.Level.WARNING,
      message,
      _LogContext(
        forcePrint: forcePrint,
        isVerbose: isVerbose,
        enableColors: enableColors,
      ),
    );
  }

  /// Logs an error message (also accumulated in [errors]).
  void error(final String message, {final bool forcePrint = false}) {
    _errors.add(message);
    _pkgLogger.log(
      pkg.Level.SEVERE,
      message,
      _LogContext(
        forcePrint: forcePrint,
        isVerbose: isVerbose,
        enableColors: enableColors,
      ),
    );
  }

  /// Logs a debug message (only emitted when [isVerbose] is true).
  void debug(final String message, {final bool forcePrint = false}) {
    _pkgLogger.log(
      pkg.Level.FINE,
      message,
      _LogContext(
        forcePrint: forcePrint,
        isVerbose: isVerbose,
        enableColors: enableColors,
      ),
    );
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

  /// Gets the absolute path of the log file if enabled.
  String? get logFilePath => _GpthHandler._globalLogFilePath;

  /// Whether file logging is currently enabled and a log file path is set.
  bool get isFileLoggingEnabled => _GpthHandler._globalLogFilePath != null;

  /// Clears all collected warning and error messages
  void clearCollectedMessages() {
    _warnings.clear();
    _errors.clear();
  }

  /// Prints an error to stderr and appends it to the log file if enabled.
  void errorToStderr(final Object? object) {
    stderr.write('$object\n');
    if (_GpthHandler._globalLogFilePath != null) {
      _GpthHandler.instance._writeToFile('[STDERR ] $object');
    }
  }

  /// Exits the program with optional code, showing interactive message if needed.
  Never quit([final int code = 1]) {
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
    _GpthHandler.instance.closeFileSink();
    exit(code);
  }

  /// Flushes and closes the file sink (console logging unaffected).
  void close() => _GpthHandler.instance.closeFileSink();
}

// Library-level private helpers used by _GpthHandler and LoggingService.

String _tsForFilenameStatic(final DateTime dt) {
  String two(final int v) => v < 10 ? '0$v' : '$v';
  final String y = dt.year.toString().padLeft(4, '0');
  final String m = two(dt.month);
  final String d = two(dt.day);
  final String h = two(dt.hour);
  final String mi = two(dt.minute);
  final String s = two(dt.second);
  return '$y$m$d-$h$mi$s';
}

String _toExtendedWindowsPath(final String absPath) {
  if (absPath.startsWith(r'\\?\') || absPath.startsWith(r'\\.\')) {
    return absPath;
  }
  if (absPath.startsWith(r'\\')) return r'\\?\UNC\' + absPath.substring(2);
  return r'\\?\' + absPath;
}

String _reconstructCommand(final String exe, final List<String> args) {
  String quote(final String s) {
    if (s.isEmpty) return '""';
    if (RegExp(r'[\s"\\]').hasMatch(s)) {
      return '"${s.replaceAll('\\', '\\\\').replaceAll('"', '\\"')}"';
    }
    return s;
  }

  return [quote(exe), ...args.map(quote)].join(' ');
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
