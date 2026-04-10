import 'dart:io';
import 'package:gpth_neo/gpth_lib_exports.dart';
import 'package:test/test.dart';

void main() {
  group('PlatformService', () {
    late PlatformService platformService;

    setUp(() {
      platformService = const PlatformService();
    });

    test('should create PlatformService instance', () {
      expect(platformService, isA<PlatformService>());
    });

    test('should return disk free space for current directory', () async {
      final freeSpace = await platformService.getDiskFreeSpace();

      // Should return a number (bytes) or null if unsupported
      expect(freeSpace, anyOf(isNull, isA<int>()));

      // If not null, should be a positive number
      if (freeSpace != null) {
        expect(freeSpace, greaterThan(0));
      }
    });

    test('should return disk free space for specific path', () async {
      final tempDir = await Directory.systemTemp.createTemp('disk_space_test');

      try {
        final freeSpace = await platformService.getDiskFreeSpace(tempDir.path);

        // Should return a number (bytes) or null if unsupported
        expect(freeSpace, anyOf(isNull, isA<int>()));

        // If not null, should be a positive number
        if (freeSpace != null) {
          expect(freeSpace, greaterThan(0));
        }
      } finally {
        await tempDir.delete(recursive: true);
      }
    });

    test('should handle non-existent path gracefully', () async {
      const nonExistentPath = '/this/path/does/not/exist/probably';

      final freeSpace = await platformService.getDiskFreeSpace(nonExistentPath);

      // Should return null for non-existent paths
      expect(freeSpace, isNull);
    });

    test('should use current directory when no path provided', () async {
      final currentDirSpace = await platformService.getDiskFreeSpace();
      final explicitCurrentDirSpace = await platformService.getDiskFreeSpace(
        Directory.current.path,
      );

      // Both should return the same result (allowing for slight timing differences)
      if (currentDirSpace != null && explicitCurrentDirSpace != null) {
        // Allow for small differences due to timing
        final difference = (currentDirSpace - explicitCurrentDirSpace).abs();
        final tolerance = currentDirSpace * 0.01; // 1% tolerance
        expect(difference, lessThan(tolerance));
      } else {
        // Both should be null if unsupported
        expect(currentDirSpace, equals(explicitCurrentDirSpace));
      }
    });

    group('Platform-specific behavior', () {
      test(
        'should handle Windows platform correctly',
        () async {
          // This test will only be meaningful on Windows
          if (Platform.isWindows) {
            final freeSpace = await platformService.getDiskFreeSpace('C:\\');
            expect(freeSpace, isA<int>());
            expect(freeSpace!, greaterThan(0));
          }
        },
        skip: !Platform.isWindows ? 'Windows-only test' : null,
      );

      test(
        'should handle Linux platform correctly',
        () async {
          // This test will only be meaningful on Linux
          if (Platform.isLinux) {
            final freeSpace = await platformService.getDiskFreeSpace('/');
            expect(freeSpace, anyOf(isNull, isA<int>()));
            if (freeSpace != null) {
              expect(freeSpace, greaterThan(0));
            }
          }
        },
        skip: !Platform.isLinux ? 'Linux-only test' : null,
      );

      test(
        'should handle macOS platform correctly',
        () async {
          // This test will only be meaningful on macOS
          if (Platform.isMacOS) {
            final freeSpace = await platformService.getDiskFreeSpace('/');
            expect(freeSpace, anyOf(isNull, isA<int>()));
            if (freeSpace != null) {
              expect(freeSpace, greaterThan(0));
            }
          }
        },
        skip: !Platform.isMacOS ? 'macOS-only test' : null,
      );

      test('should return null for unsupported platforms', () async {
        // For platforms other than Windows, Linux, macOS
        if (!Platform.isWindows && !Platform.isLinux && !Platform.isMacOS) {
          final freeSpace = await platformService.getDiskFreeSpace();
          expect(freeSpace, isNull);
        }
      });
    });

    test('should handle empty path string', () async {
      final freeSpace = await platformService.getDiskFreeSpace('');

      // Empty path should be treated as current directory
      final currentDirSpace = await platformService.getDiskFreeSpace(
        Directory.current.path,
      );
      if (freeSpace != null && currentDirSpace != null) {
        final difference = (freeSpace - currentDirSpace).abs();
        final tolerance = currentDirSpace * 0.01; // 1% tolerance
        expect(difference, lessThan(tolerance));
      } else {
        expect(freeSpace, equals(currentDirSpace));
      }
    });

    test('should handle whitespace-only path', () async {
      final freeSpace = await platformService.getDiskFreeSpace('   ');

      // Whitespace-only path should be treated as current directory
      final currentDirSpace = await platformService.getDiskFreeSpace(
        Directory.current.path,
      );
      if (freeSpace != null && currentDirSpace != null) {
        final difference = (freeSpace - currentDirSpace).abs();
        final tolerance = currentDirSpace * 0.01; // 1% tolerance
        expect(difference, lessThan(tolerance));
      } else {
        expect(freeSpace, equals(currentDirSpace));
      }
    });

    test('should be consistent across multiple calls', () async {
      final results = <int?>[];

      // Make multiple calls in quick succession
      for (int i = 0; i < 3; i++) {
        final result = await platformService.getDiskFreeSpace();
        results.add(result);
      }

      // All results should be of the same type (null or int)
      final types = results.map((final r) => r.runtimeType).toSet();
      expect(types.length, lessThanOrEqualTo(1));

      // If all are non-null, they should be reasonably close
      if (results.every((final r) => r != null)) {
        final values = results.cast<int>();
        final min = values.reduce((final a, final b) => a < b ? a : b);
        final max = values.reduce((final a, final b) => a > b ? a : b);
        final difference = max - min;

        // Allow for reasonable variation (disk usage can change between calls)
        expect(difference, lessThan(max * 0.1)); // 10% tolerance
      }
    });
  });
}
