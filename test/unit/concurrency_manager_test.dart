/// Tests for ConcurrencyManager.concurrencyFor() dispatch table.
///
/// Covers:
/// - Every ConcurrencyOperation value maps to the correct concurrency level
/// - setMultipliers() changes the underlying levels
/// - getAdaptiveConcurrency() scales correctly based on performance metrics
/// - cpuCoreCount returns a positive value matching Platform.numberOfProcessors
library;

import 'dart:io';

import 'package:gpth_neo/gpth_lib_exports.dart';
import 'package:test/test.dart';

void main() {
  group('ConcurrencyManager', () {
    final manager = ConcurrencyManager();

    setUp(() {
      // Reset multipliers to known defaults before each test
      ConcurrencyManager.setMultipliers(
        standard: 2,
        conservative: 2,
        diskOptimized: 8,
      );
      manager.invalidateCache();
    });

    group('cpuCoreCount', () {
      test('returns a positive integer', () {
        expect(manager.cpuCoreCount, greaterThan(0));
      });

      test('matches Platform.numberOfProcessors', () {
        expect(manager.cpuCoreCount, equals(Platform.numberOfProcessors));
      });
    });

    group('concurrencyFor – dispatch table', () {
      test('hash maps to cpu * 4', () {
        final expected = manager.cpuCoreCount * 4;
        expect(
          manager.concurrencyFor(ConcurrencyOperation.hash),
          equals(expected),
        );
      });

      test('exif maps to diskOptimized', () {
        expect(
          manager.concurrencyFor(ConcurrencyOperation.exif),
          equals(manager.diskOptimized),
        );
      });

      test('duplicate maps to conservative', () {
        expect(
          manager.concurrencyFor(ConcurrencyOperation.duplicate),
          equals(manager.conservative),
        );
      });

      test('fileIO maps to diskOptimized', () {
        expect(
          manager.concurrencyFor(ConcurrencyOperation.fileIO),
          equals(manager.diskOptimized),
        );
      });

      test('moveCopy maps to diskOptimized', () {
        expect(
          manager.concurrencyFor(ConcurrencyOperation.moveCopy),
          equals(manager.diskOptimized),
        );
      });

      test('other maps to standard', () {
        expect(
          manager.concurrencyFor(ConcurrencyOperation.other),
          equals(manager.standard),
        );
      });

      test(
        'all ConcurrencyOperation enum values are handled without throwing',
        () {
          for (final op in ConcurrencyOperation.values) {
            expect(
              () => manager.concurrencyFor(op),
              returnsNormally,
              reason: 'concurrencyFor($op) should not throw',
            );
          }
        },
      );

      test('all operations return positive values', () {
        for (final op in ConcurrencyOperation.values) {
          expect(
            manager.concurrencyFor(op),
            greaterThan(0),
            reason: '$op should return a positive concurrency level',
          );
        }
      });
    });

    group('concurrency levels', () {
      test('standard = cpuCoreCount * standardMultiplier (default 2)', () {
        expect(manager.standard, equals(manager.cpuCoreCount * 2));
      });

      test(
        'conservative = cpuCoreCount * conservativeMultiplier (default 2)',
        () {
          expect(manager.conservative, equals(manager.cpuCoreCount * 2));
        },
      );

      test('diskOptimized is capped at 32', () {
        ConcurrencyManager.setMultipliers(diskOptimized: 100);
        expect(manager.diskOptimized, lessThanOrEqualTo(32));
      });

      test('diskOptimized with low multiplier is not capped', () {
        ConcurrencyManager.setMultipliers(diskOptimized: 1);
        expect(
          manager.diskOptimized,
          equals((manager.cpuCoreCount * 1).clamp(0, 32)),
        );
      });
    });

    group('setMultipliers', () {
      tearDown(() {
        // Restore defaults after each inner test
        ConcurrencyManager.setMultipliers(
          standard: 2,
          conservative: 2,
          diskOptimized: 8,
        );
      });

      test('changing standard multiplier updates standard level', () {
        ConcurrencyManager.setMultipliers(standard: 4);
        expect(manager.standard, equals(manager.cpuCoreCount * 4));
      });

      test('changing conservative multiplier updates conservative level', () {
        ConcurrencyManager.setMultipliers(conservative: 3);
        expect(manager.conservative, equals(manager.cpuCoreCount * 3));
      });

      test('changing diskOptimized multiplier updates diskOptimized level', () {
        ConcurrencyManager.setMultipliers(diskOptimized: 2);
        final expected = (manager.cpuCoreCount * 2).clamp(0, 32);
        expect(manager.diskOptimized, equals(expected));
      });

      test('null parameter leaves existing value unchanged', () {
        ConcurrencyManager.setMultipliers(standard: 5);
        final standardBefore = manager.standard;
        // Only change conservative; standard should stay
        ConcurrencyManager.setMultipliers(conservative: 6);
        expect(manager.standard, equals(standardBefore));
      });
    });

    group('getAdaptiveConcurrency', () {
      test('returns baseLevel when metrics list is empty', () {
        expect(manager.getAdaptiveConcurrency([], baseLevel: 8), equals(8));
      });

      test('returns standard when no baseLevel provided and metrics empty', () {
        expect(manager.getAdaptiveConcurrency([]), equals(manager.standard));
      });

      test('scales up (×3) for high performance (avg > 10 files/sec)', () {
        const baseLevel = 4;
        final result = manager.getAdaptiveConcurrency([
          15.0,
          12.0,
          11.5,
        ], baseLevel: baseLevel);
        expect(result, equals(baseLevel * 3));
      });

      test('uses base for normal performance (5 < avg ≤ 10 files/sec)', () {
        const baseLevel = 4;
        final result = manager.getAdaptiveConcurrency([
          7.0,
          6.0,
          8.5,
        ], baseLevel: baseLevel);
        expect(result, equals(baseLevel));
      });

      test('scales down (×0.5) for poor performance (avg ≤ 5 files/sec)', () {
        const baseLevel = 4;
        final result = manager.getAdaptiveConcurrency([
          1.0,
          2.0,
          3.0,
        ], baseLevel: baseLevel);
        expect(result, equals((baseLevel * 0.5).round()));
      });

      test('handles exactly 10.0 avg as normal performance tier', () {
        final result = manager.getAdaptiveConcurrency([10.0], baseLevel: 6);
        // avg == 10.0 is NOT > 10.0, so it falls into the normal bucket
        expect(result, equals(6));
      });
    });
  });
}
