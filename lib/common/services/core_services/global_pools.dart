import 'dart:io';

import 'package:gpth_neo/gpth_lib_exports.dart';
import 'package:pool/pool.dart';

/// Central registry of shared Pool instances.
///
/// Creates one lazily-initialized [Pool] per [ConcurrencyOperation] so that
/// unrelated parts of the application coordinate throughput instead of spawning
/// many short‑lived pools whose limits compete unpredictably.
///
/// Rationale:
/// * Avoids repeated allocation of Pool objects for large batch operations.
/// * Provides a single choke point should future adaptive logic wish to resize.
/// * Keeps per-operation intent explicit via [ConcurrencyOperation].
class GlobalPools {
  GlobalPools._();

  static final Map<ConcurrencyOperation, Pool> _pools = {};

  /// Per-directory exclusive slots: at most one (findUniqueFileName + IO)
  /// in flight per output directory, eliminating the TOCTOU race where two
  /// concurrent fibers pick the same unique name before either renames/copies.
  static final Map<String, Pool> _dirPools = {};

  static final Map<String, Set<String>> _reservedPaths = {};
  static final Map<String, _DirectoryPoolMetrics> _dirMetrics = {};

  /// Obtain (and lazily create) the pool for the given operation.
  static Pool poolFor(final ConcurrencyOperation op) =>
      _pools.putIfAbsent(op, () {
        final size = ConcurrencyManager().concurrencyFor(op).clamp(1, 512);
        return Pool(size);
      });

  /// A [Pool] of size 1 keyed by [directory] path.
  ///
  /// Callers must hold this pool around the entire (pick-name → write) sequence
  /// so that no two concurrent operations can receive the same candidate path.
  static Pool dirPoolFor(final String directory) =>
      _dirPools.putIfAbsent(_normalizeKey(directory), () => Pool(1));

  /// Executes [action] under the per-directory exclusive slot while collecting
  /// basic contention telemetry.
  static Future<T> withDirectoryLock<T>(
    final String directory,
    final Future<T> Function() action,
  ) async {
    final String key = _normalizeKey(directory);
    final wait = Stopwatch()..start();
    return dirPoolFor(key).withResource(() async {
      wait.stop();
      final metrics = _dirMetrics.putIfAbsent(key, _DirectoryPoolMetrics.new);
      metrics.waitCount += 1;
      metrics.totalWait += wait.elapsed;

      final hold = Stopwatch()..start();
      try {
        return await action();
      } finally {
        hold.stop();
        metrics.holdCount += 1;
        metrics.totalHold += hold.elapsed;
      }
    });
  }

  static bool tryReservePath(final String directory, final String path) {
    final String dirKey = _normalizeKey(directory);
    final String pathKey = _normalizeKey(path);
    final reserved = _reservedPaths.putIfAbsent(dirKey, () => <String>{});
    if (reserved.contains(pathKey)) return false;
    reserved.add(pathKey);
    return true;
  }

  static void releaseReservedPath(final String directory, final String path) {
    final String dirKey = _normalizeKey(directory);
    final String pathKey = _normalizeKey(path);
    final reserved = _reservedPaths[dirKey];
    if (reserved == null) return;
    reserved.remove(pathKey);
    if (reserved.isEmpty) {
      _reservedPaths.remove(dirKey);
    }
  }

  static bool isPathReserved(final String directory, final String path) {
    final String dirKey = _normalizeKey(directory);
    final String pathKey = _normalizeKey(path);
    return _reservedPaths[dirKey]?.contains(pathKey) ?? false;
  }

  static int reservedPathCount([final String? directory]) {
    if (directory != null) {
      return _reservedPaths[_normalizeKey(directory)]?.length ?? 0;
    }
    return _reservedPaths.values.fold(
      0,
      (final sum, final set) => sum + set.length,
    );
  }

  static Map<String, DirectoryPoolMetrics> dirPoolMetricsSnapshot() => {
    for (final entry in _dirMetrics.entries)
      entry.key: DirectoryPoolMetrics(
        waitCount: entry.value.waitCount,
        holdCount: entry.value.holdCount,
        totalWait: entry.value.totalWait,
        totalHold: entry.value.totalHold,
      ),
  };

  /// Dispose and recreate a specific pool (e.g. after external config change).
  static Future<void> refresh(final ConcurrencyOperation op) async {
    final existing = _pools.remove(op);
    if (existing != null) {
      await existing.close();
    }
    poolFor(op); // recreate
  }

  /// Dispose all pools (primarily for tests).
  static Future<void> disposeAll() async {
    for (final pool in _pools.values) {
      await pool.close();
    }
    _pools.clear();
    for (final pool in _dirPools.values) {
      await pool.close();
    }
    _dirPools.clear();
    _reservedPaths.clear();
    _dirMetrics.clear();
  }

  static String _normalizeKey(final String value) =>
      Platform.isWindows ? value.toLowerCase() : value;
}

class DirectoryPoolMetrics {
  const DirectoryPoolMetrics({
    required this.waitCount,
    required this.holdCount,
    required this.totalWait,
    required this.totalHold,
  });

  final int waitCount;
  final int holdCount;
  final Duration totalWait;
  final Duration totalHold;
}

class _DirectoryPoolMetrics {
  int waitCount = 0;
  int holdCount = 0;
  Duration totalWait = Duration.zero;
  Duration totalHold = Duration.zero;
}
