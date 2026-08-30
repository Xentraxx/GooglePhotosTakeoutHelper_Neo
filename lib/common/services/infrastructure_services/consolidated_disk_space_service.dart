import 'dart:io';
import 'package:gpth_neo/gpth_lib_exports.dart';

/// Consolidated service for all disk space operations across different platforms
///
/// This service merges functionality from:
/// - PlatformService.getDiskFreeSpace()
/// - DiskSpaceService.getAvailableSpace()
/// - Platform-specific disk operations scattered across the codebase
///
/// Provides a unified interface for disk space checking while handling
/// platform-specific implementations internally.
class ConsolidatedDiskSpaceService with LoggerMixin {
  /// Creates a new consolidated disk space service
  ConsolidatedDiskSpaceService();

  // ============================================================================
  // PLATFORM DETECTION (consolidated from PlatformService)
  // ============================================================================

  /// Whether the current platform is Windows
  bool get isWindows => Platform.isWindows;

  /// Whether the current platform is macOS
  bool get isMacOS => Platform.isMacOS;

  /// Whether the current platform is Linux
  bool get isLinux => Platform.isLinux;

  // ============================================================================
  // DISK SPACE OPERATIONS
  // ============================================================================

  /// Gets available disk space for the given path
  ///
  /// [path] Directory path to check (defaults to current directory)
  /// Returns available space in bytes, or null if unable to determine
  Future<int?> getAvailableSpace([final String? path]) =>
      const PlatformService().getDiskFreeSpace(path);

  /// Checks if there's enough space for a given operation
  ///
  /// [path] Directory path to check
  /// [requiredBytes] Number of bytes needed
  /// [safetyMarginBytes] Additional safety margin (default: 100MB)
  ///
  /// Returns true if there's enough space, false otherwise
  Future<bool> hasEnoughSpace(
    final String path,
    final int requiredBytes, {
    final int safetyMarginBytes = 100 * 1024 * 1024, // 100MB default
  }) async {
    final availableBytes = await getAvailableSpace(path);

    if (availableBytes == null) {
      logWarning('Cannot determine available space, assuming insufficient');
      return false;
    }

    final totalNeeded = requiredBytes + safetyMarginBytes;
    return availableBytes >= totalNeeded;
  }

  /// Calculates required space for a file operation
  ///
  /// [sourceFiles] Files that will be processed
  /// [operationType] Type of operation (copy, move, etc.)
  /// [albumBehavior] How albums will be handled
  ///
  /// Returns estimated bytes needed for the operation
  Future<int> calculateRequiredSpace(
    final List<File> sourceFiles,
    final String operationType,
    final String albumBehavior,
  ) async {
    int totalSize = 0;

    // Calculate total size of source files
    for (final file in sourceFiles) {
      try {
        if (file.existsSync()) {
          totalSize += file.lengthSync();
        }
      } catch (e) {
        logWarning('Could not get size for ${file.path}: $e');
      }
    }

    // Apply multiplier based on operation type and album behavior
    double multiplier = 1.0;

    if (operationType.toLowerCase() == 'copy') {
      multiplier = 2.0; // Need space for both original and copy
    }

    if (albumBehavior == 'duplicate-copy') {
      multiplier *= 1.5; // Additional space for album duplicates
    } else if (albumBehavior == 'shortcut') {
      multiplier *= 1.1; // Small overhead for shortcuts
    }

    return safeRoundToInt((totalSize * multiplier).toDouble());
  }
}
