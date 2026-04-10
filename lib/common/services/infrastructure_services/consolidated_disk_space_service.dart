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

  /// Gets the optimal concurrency level for the current platform
  int getOptimalConcurrency() => ConcurrencyManager().diskOptimized;

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

  /// Gets disk usage statistics for multiple paths
  ///
  /// Useful for checking both input and output directories
  /// [paths] List of paths to check
  /// Returns map of path to available bytes (null if failed)
  Future<Map<String, int?>> getMultipleSpaceInfo(
    final List<String> paths,
  ) async {
    final Map<String, int?> results = {};

    // Simple sequential processing - disk space checks are lightweight
    await Future.wait(
      paths.map((final path) async {
        results[path] = await getAvailableSpace(path);
      }),
    );

    return results;
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

  // ============================================================================
  // SYSTEM RESOURCE CHECKING
  // ============================================================================

  /// Checks overall system resources (memory, disk, CPU)
  ///
  /// [requiredDiskSpace] Minimum required disk space in bytes
  /// [targetPath] Path where disk space will be used
  ///
  /// Returns resource adequacy information
  Future<SystemResourceInfo> checkSystemResources({
    required final int requiredDiskSpace,
    required final String targetPath,
  }) async {
    // Check disk space
    final availableSpace = await getAvailableSpace(targetPath);
    final hasEnoughDisk =
        availableSpace != null && availableSpace >= requiredDiskSpace;

    // Check memory (simplified - assume 4GB+ is sufficient)
    bool hasEnoughMemory = true;
    try {
      if (isLinux || isMacOS) {
        final result = await Process.run('free', ['-m']);
        if (result.exitCode == 0) {
          final output = result.stdout.toString();
          final match = RegExp(r'Mem:\s+(\d+)').firstMatch(output);
          if (match != null) {
            final memoryMB = int.tryParse(match.group(1)!) ?? 0;
            hasEnoughMemory = memoryMB >= 4096; // 4GB minimum
          }
        }
      }
    } catch (e) {
      logWarning('Could not check memory: $e');
    }

    return SystemResourceInfo(
      hasEnoughMemory: hasEnoughMemory,
      hasEnoughDiskSpace: hasEnoughDisk,
      availableDiskSpaceMB: availableSpace != null
          ? safeRoundToInt(availableSpace / (1024 * 1024))
          : null,
      processorCount: Platform.numberOfProcessors,
    );
  }
}

/// System resource information
class SystemResourceInfo {
  const SystemResourceInfo({
    required this.hasEnoughMemory,
    required this.hasEnoughDiskSpace,
    required this.availableDiskSpaceMB,
    required this.processorCount,
  });

  /// Whether sufficient memory is available
  final bool hasEnoughMemory;

  /// Whether sufficient disk space is available
  final bool hasEnoughDiskSpace;

  /// Available disk space in MB (null if unknown)
  final int? availableDiskSpaceMB;

  /// Number of processor cores
  final int processorCount;

  /// Whether all resource requirements are met
  bool get isResourcesAdequate => hasEnoughMemory && hasEnoughDiskSpace;
}
