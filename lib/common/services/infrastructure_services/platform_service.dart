import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';
import 'package:gpth_neo/gpth_lib_exports.dart';
import 'package:win32/win32.dart';

/// Service for platform-specific operations and disk space detection
///
/// Extracted from utils.dart to isolate platform-specific code
/// and provide better testability through interface abstraction.
class PlatformService {
  /// Creates a new instance of PlatformService
  const PlatformService();

  /// Returns disk free space in bytes for the given path
  ///  /// Returns disk free space in bytes for the given path
  ///
  /// [path] Directory path to check (defaults to current directory)
  /// Returns null if unable to determine free space
  Future<int?> getDiskFreeSpace([final String? path]) async {
    final targetPath = path ?? Directory.current.path;

    // Handle empty string as current directory
    final finalPath = targetPath.isEmpty ? Directory.current.path : targetPath;

    if (Platform.isLinux) {
      return _getDiskFreeLinux(finalPath);
    } else if (Platform.isWindows) {
      return _getDiskFreeWindows(finalPath);
    } else if (Platform.isMacOS) {
      return _getDiskFreeMacOS(finalPath);
    }

    return null; // Unsupported platform
  }

  /// Gets disk free space on Linux using statvfs
  Future<int?> _getDiskFreeLinux(final String path) async {
    try {
      final result = await Process.run('df', ['-B1', path]);
      if (result.exitCode == 0) {
        final lines = result.stdout.toString().split('\n');
        if (lines.length >= 2) {
          final parts = lines[1].split(RegExp(r'\s+'));
          if (parts.length >= 4) {
            return int.tryParse(parts[3]);
          }
        }
      }
    } catch (e) {
      // Ignore errors and return null
    }
    return null;
  }

  /// Gets disk free space on macOS using statvfs
  Future<int?> _getDiskFreeMacOS(final String path) async {
    try {
      final result = await Process.run('df', ['-k', path]);
      if (result.exitCode == 0) {
        final lines = result.stdout.toString().split('\n');
        if (lines.length >= 2) {
          final parts = lines[1].split(RegExp(r'\s+'));
          if (parts.length >= 4) {
            final freeKB = int.tryParse(parts[3]);
            return freeKB != null ? freeKB * 1024 : null; // Convert KB to bytes
          }
        }
      }
    } catch (e) {
      // Ignore errors and return null
    }
    return null;
  }

  /// Gets disk free space on Windows using GetDiskFreeSpaceEx
  int? _getDiskFreeWindows(final String path) {
    try {
      final pathPtr = path.toNativeUtf16();
      final freeBytes = calloc<Uint64>();
      final totalBytes = calloc<Uint64>();

      final result = GetDiskFreeSpaceEx(
        pathPtr,
        freeBytes,
        totalBytes,
        nullptr,
      );

      if (result != 0) {
        final free = freeBytes.value;
        calloc.free(pathPtr);
        calloc.free(freeBytes);
        calloc.free(totalBytes);
        return free;
      }

      calloc.free(pathPtr);
      calloc.free(freeBytes);
      calloc.free(totalBytes);
    } catch (e) {
      // Ignore errors and return null
    }
    return null;
  }

  /// Gets the number of logical processors available
  int getProcessorCount() => Platform.numberOfProcessors;

  /// Checks if the current platform supports symbolic links
  bool get supportsSymlinks => Platform.isLinux || Platform.isMacOS;

  /// Checks if the current platform supports Windows shortcuts
  bool get supportsWindowsShortcuts => Platform.isWindows;

  /// Check if running on Windows platform
  bool get isWindows => Platform.isWindows;

  /// Check if running on macOS platform
  bool get isMacOS => Platform.isMacOS;

  /// Check if running on Linux platform
  bool get isLinux => Platform.isLinux;

  /// Gets the optimal number of concurrent operations for this platform
  int getOptimalConcurrency() => ConcurrencyManager().platformOptimized;
}
