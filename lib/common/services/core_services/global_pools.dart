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
      _dirPools.putIfAbsent(directory, () => Pool(1));

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
  }
}
