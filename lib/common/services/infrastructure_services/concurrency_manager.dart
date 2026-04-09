import 'dart:io';
import 'package:gpth_neo/gpth_lib_exports.dart';

/// Canonical operation types for concurrency decisions (Phase 1 enum introduction)
enum ConcurrencyOperation {
  hash,
  exif,
  duplicate,
  fileIO,
  moveCopy,
  other, // fallback
}

/// Centralized concurrency management for the entire application
///
/// This class provides consistent concurrency calculations across all services
/// and eliminates the need for hardcoded multipliers scattered throughout the codebase.
class ConcurrencyManager {
  factory ConcurrencyManager() => _instance;
  const ConcurrencyManager._internal();

  /// Logger used by ConcurrencyManager. Can be injected at startup to respect
  /// the application's ProcessingConfig (verbosity/colors). Defaults to a
  /// non-verbose logger to preserve previous behavior when not initialized.
  static LoggingService logger = LoggingService(
    saveLog: ServiceContainer.instance.globalConfig.saveLog,
  );
  static const ConcurrencyManager _instance = ConcurrencyManager._internal();

  // ============================================================================
  // CORE CONCURRENCY CALCULATIONS
  // ============================================================================

  /// Base CPU core count (cached for performance)
  static int? _cachedCpuCount;

  /// Gets the number of CPU cores, with caching for performance
  int get cpuCoreCount {
    _cachedCpuCount ??= Platform.numberOfProcessors;
    return _cachedCpuCount!;
  }

  /// Concurrency multipliers (modifiable via [setMultipliers] for tests or CLI overrides)
  static int _standardMultiplier = 2;
  static int _conservativeMultiplier = 2;
  // Disk optimized (I/O heavy) default multiplier.
  static int _diskOptimizedMultiplier = 8;

  /// Update one or more concurrency multipliers atomically.
  /// Passing null leaves the existing value unchanged.
  static void setMultipliers({
    final int? standard,
    final int? conservative,
    final int? diskOptimized,
  }) {
    if (standard != null) _standardMultiplier = standard;
    if (conservative != null) _conservativeMultiplier = conservative;
    if (diskOptimized != null) _diskOptimizedMultiplier = diskOptimized;
  }

  // ============================================================================
  // CONCURRENCY LEVELS
  // ============================================================================

  /// Standard concurrency level for most operations
  int get standard {
    final val = cpuCoreCount * _standardMultiplier;
    return val;
  }

  /// Conservative concurrency for resource-intensive operations
  int get conservative {
    final val = cpuCoreCount * _conservativeMultiplier;
    return val;
  }

  /// Platform-optimized concurrency (platform-specific logic)
  int get platformOptimized {
    int val;
    if (Platform.isWindows) {
      val =
          cpuCoreCount *
          _standardMultiplier; // Windows handles concurrent I/O well
    } else if (Platform.isMacOS) {
      val =
          cpuCoreCount *
          _conservativeMultiplier; // macOS handles concurrency well, slightly more conservative
    } else if (Platform.isLinux) {
      val =
          cpuCoreCount *
          _standardMultiplier; // Modern Linux handles concurrent I/O excellently
    } else {
      val =
          cpuCoreCount *
          _conservativeMultiplier; // Conservative default for other Unix-like systems
    }
    return val;
  }

  /// Disk I/O optimized concurrency
  int get diskOptimized {
    // Apply multiplier then clamp to prevent oversubscription on large core counts.
    // Historic behaviour (v4.0.9) effectively: cores * 2 capped at 8.
    int val = cpuCoreCount * _diskOptimizedMultiplier;
    const int maxIoConcurrency = 32;
    if (val > maxIoConcurrency) val = maxIoConcurrency;
    return val;
  }

  // ============================================================================
  // ADAPTIVE CONCURRENCY
  // ============================================================================

  /// Calculates adaptive concurrency based on performance metrics
  ///
  /// [recentPerformanceMetrics] List of recent performance measurements
  /// [baseLevel] Base concurrency level to scale from
  ///
  /// Returns scaled concurrency based on performance
  int getAdaptiveConcurrency(
    final List<double> recentPerformanceMetrics, {
    int? baseLevel,
  }) {
    baseLevel ??= standard;

    if (recentPerformanceMetrics.isEmpty) {
      return baseLevel;
    }

    final avgPerformance =
        recentPerformanceMetrics.reduce((final a, final b) => a + b) /
        recentPerformanceMetrics.length;

    // Scale concurrency based on performance
    if (avgPerformance > 10.0) {
      return baseLevel * 3; // High performance - scale up
    } else if (avgPerformance > 5.0) {
      return baseLevel; // Normal performance - use base
    } else {
      return (baseLevel * 0.5).round(); // Poor performance - scale down
    }
  }

  // ============================================================================
  // CUSTOM CONCURRENCY CALCULATIONS
  // ============================================================================

  /// Gets concurrency with custom multiplier
  ///
  /// [multiplier] Custom multiplier to apply to CPU core count
  /// [minValue] Minimum concurrency value (default: 1)
  /// [maxValue] Maximum concurrency value (null = no limit)
  ///
  /// Returns calculated concurrency with optional bounds
  int getCustomConcurrency(
    final double multiplier, {
    final int minValue = 1,
    final int? maxValue,
  }) {
    int result = (cpuCoreCount * multiplier).round();

    if (result < minValue) result = minValue;
    if (maxValue != null && result > maxValue) result = maxValue;

    try {
      LoggingService(
        saveLog: ServiceContainer.instance.globalConfig.saveLog,
      ).info('Starting $result threads (custom multiplier $multiplier)');
    } catch (_) {}
    return result;
  }

  /// New enum-based API (preferred)
  int concurrencyFor(final ConcurrencyOperation op) {
    switch (op) {
      case ConcurrencyOperation.hash:
        final val = cpuCoreCount * 4; // CPU heavy + I/O overlap
        _logOnce('hash', val);
        return val;
      case ConcurrencyOperation.exif:
        final val = diskOptimized; // Mostly I/O bound
        _logOnce('exif', val);
        return val;
      case ConcurrencyOperation.duplicate:
        final val = conservative; // Memory intensive comparisons
        _logOnce('duplicate', val);
        return val;
      case ConcurrencyOperation.fileIO:
      case ConcurrencyOperation.moveCopy:
        final val = diskOptimized; // Disk/file operations
        _logOnce('fileIO', val);
        return val;
      case ConcurrencyOperation.other:
        final val = standard;
        _logOnce('default', val);
        return val;
    }
  }

  // Basic once-per-key logging cache to cut noise
  static final Set<String> _loggedKeys = <String>{};
  void _logOnce(final String key, final int val) {
    if (_loggedKeys.add(key)) {
      try {
        logger.debug('Starting $val threads ($key concurrency)');
      } catch (_) {}
    }
  }

  // ============================================================================
  // UTILITY METHODS
  // ============================================================================

  /// Invalidates the cached CPU count (useful for testing)
  void invalidateCache() {
    _cachedCpuCount = null;
  }
}
