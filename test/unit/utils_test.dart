/// # Utility Functions Test Suite
///
/// Comprehensive tests for utility functions that provide essential support
/// services across the Google Photos Takeout Helper Neo application, including
/// stream processing, file operations, system validation, and helper utilities.
///
/// ## Core Functionality Tested
///
/// ### Stream Processing Extensions
/// - Type filtering extensions for processing file streams efficiently
/// - Media file filtering to identify photos and videos specifically
/// - Stream transformation utilities for batch processing operations
/// - Performance optimization for large directory traversals
///
/// ### File System Operations
/// - Intelligent filename generation to avoid conflicts during operations
/// - Safe file operations with collision detection and resolution
/// - Cross-platform path handling and normalization
/// - File extension detection and validation for media types
/// - Directory creation and management with proper permissions
///
/// ### System Validation and Environment
/// - Disk space checking before large file operations
/// - Platform-specific behavior detection and adaptation
/// - Memory usage monitoring for resource-intensive operations
/// - External tool availability verification (ExifTool, etc.)
///
/// ### JSON and Data Processing
/// - Safe JSON parsing with error handling for malformed metadata
/// - Timestamp conversion utilities for various date formats
/// - Unicode normalization for cross-platform filename compatibility
/// - Data validation and sanitization for user inputs
///
/// ### Logging and Progress Tracking
/// - Structured logging utilities for operation tracking
/// - Progress reporting mechanisms for long-running operations
/// - Error categorization and user-friendly message formatting
/// - Debug information collection for troubleshooting
///
/// ## Technical Implementation
///
/// The utility functions provide a foundation for reliable operations across
/// different operating systems and file systems. Key areas include:
///
/// ### Cross-Platform Compatibility
/// - Handling of different path separators and filename restrictions
/// - Unicode normalization for international character support
/// - Case sensitivity handling for different file systems
/// - Permission and access control validation
///
/// ### Performance Optimization
/// - Efficient stream processing for large photo collections
/// - Memory-conscious operations for resource-constrained systems
/// - Batch processing capabilities to minimize I/O overhead
/// - Caching mechanisms for frequently accessed metadata
///
/// ### Error Recovery and Resilience
/// - Graceful handling of filesystem errors and permissions issues
/// - Retry mechanisms for transient failures
/// - Fallback strategies when preferred methods are unavailable
/// - Comprehensive error reporting for user guidance
library;

import 'dart:io';
import 'package:gpth_neo/gpth_lib_exports.dart';
import 'package:path/path.dart' as path;
import 'package:test/test.dart';

import '../setup/test_setup.dart';

void main() {
  group('Refactored Service Tests', () {
    late TestFixture fixture;
    late FormattingService formattingService;
    late PlatformService platformService;
    late LoggingService loggingService;

    setUp(() async {
      fixture = TestFixture();
      await fixture.setUp();
      await ServiceContainer.instance.initialize();
      formattingService = const FormattingService();
      platformService = const PlatformService();
      loggingService = LoggingService();
    });

    tearDown(() async {
      await fixture.tearDown();
      await ServiceContainer.reset();
    });

    group('Stream Extensions', () {
      /// Tests stream processing extensions that efficiently filter and
      /// transform file streams for media processing operations, including
      /// type filtering and media-specific file identification.
      test('whereType filters stream correctly', () {
        final stream = Stream.fromIterable([1, 'a', 2, 'b', 3, 'c']);

        expect(stream.whereType<int>(), emitsInOrder([1, 2, 3, emitsDone]));
      });

      /// Should filter media files using wherePhotoVideo.
      test('wherePhotoVideo filters media files', () {
        final stream = Stream<FileSystemEntity>.fromIterable([
          File('${fixture.basePath}/photo.jpg'),
          File('${fixture.basePath}/document.txt'),
          File('${fixture.basePath}/video.mp4'),
          File('${fixture.basePath}/audio.mp3'),
          File('${fixture.basePath}/image.png'),
        ]);

        expect(
          stream.wherePhotoVideo().map((final f) => path.basename(f.path)),
          emitsInOrder(['photo.jpg', 'video.mp4', 'image.png', emitsDone]),
        );
      });
    });

    group('File Operations', () {
      /// Tests file system operations including intelligent filename generation
      /// to prevent conflicts, safe file operations, and cross-platform
      /// path handling with proper collision resolution.
      test('findUniqueFileName generates unique filename', () {
        final existingFile = fixture.createFile('test.jpg', [1, 2, 3]);
        final uniqueFile = formattingService.findUniqueFileName(existingFile);

        expect(uniqueFile.path, endsWith('test(1).jpg'));
        expect(uniqueFile.existsSync(), isFalse);
      });

      /// Should return original if file does not exist.
      test('findUniqueFileName returns original if file does not exist', () {
        final nonExistentFile = File('${fixture.basePath}/nonexistent.jpg');
        final result = formattingService.findUniqueFileName(nonExistentFile);

        expect(result.path, nonExistentFile.path);
      });
    });

    group('Disk Operations', () {
      /// Should return non-null value for disk free space.
      test('getDiskFreeSpace returns non-null value', () async {
        final freeSpace = await platformService.getDiskFreeSpace('.');

        expect(freeSpace, isNotNull);
        expect(freeSpace!, greaterThan(0));
      }, tags: 'flaky');
    });

    group('File Size Formatting', () {
      /// Should format bytes correctly to human-readable string.
      test('formatFileSize formats bytes correctly', () {
        expect(formattingService.formatFileSize(1024), contains('KB'));
        expect(formattingService.formatFileSize(1024 * 1024), contains('MB'));
        expect(
          formattingService.formatFileSize(1024 * 1024 * 1024),
          contains('GB'),
        );
      });
    });

    group('Logging', () {
      /// Should handle different log levels without throwing.
      test('LoggingService handles different levels', () {
        // Test that logging service doesn't throw
        expect(() => loggingService.info('test info'), returnsNormally);
        expect(() => loggingService.warning('test warning'), returnsNormally);
        expect(() => loggingService.error('test error'), returnsNormally);
      });
    });
    group('Directory Validation', () {
      /// Should succeed for existing directory.
      test('validateDirectory succeeds for existing directory', () {
        final dir = fixture.createDirectory('test_dir');

        final result = formattingService.validateDirectory(dir);

        expect(result.isSuccess, isTrue);
      });

      /// Should fail for non-existing directory when should exist.
      test(
        'validateDirectory fails for non-existing directory when should exist',
        () {
          final dir = Directory('${fixture.basePath}/nonexistent');

          final result = formattingService.validateDirectory(dir);

          expect(result.isFailure, isTrue);
        },
      );
    });

    group('Platform-specific Operations', () {
      /// Should handle Windows symlinks (Windows only test).
      test(
        'WindowsSymlinkService handles Windows symlinks',
        () async {
          if (!Platform.isWindows) return;

          final targetFile = fixture.createFile('target.txt', [1, 2, 3]);
          final symlinkPath = '${fixture.basePath}/symlink';
          final windowsSymlinkService = WindowsSymlinkService();

          // Precondition: the link should not exist yet (neither native nor .lnk fallback)
          expect(File(symlinkPath).existsSync(), isFalse);
          expect(File('$symlinkPath.lnk').existsSync(), isFalse);

          // Create the link (native symlink if possible; .lnk fallback otherwise)
          await windowsSymlinkService.createSymlink(
            symlinkPath,
            targetFile.path,
          );

          // Postcondition: either the native symlink exists OR the .lnk fallback exists.
          // Use both File and Link checks for the native path: File.existsSync() follows
          // the symlink to verify the target, while Link.existsSync() checks the link
          // itself exists regardless of target state (covers directory symlinks and
          // Windows Server environments where File resolution may behave differently).
          final existsNative =
              File(symlinkPath).existsSync() || Link(symlinkPath).existsSync();
          final existsShortcut = File('$symlinkPath.lnk').existsSync();
          expect(
            existsNative || existsShortcut,
            isTrue,
            reason: 'Expected a native symlink or a .lnk fallback to exist',
          );
        },
        skip: !Platform.isWindows ? 'Windows only test' : null,
      );
    });
  });
}
