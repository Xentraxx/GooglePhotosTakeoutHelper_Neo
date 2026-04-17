import 'dart:async';
import 'dart:io';

import 'package:gpth_neo/gpth_lib_exports.dart';
import 'package:path/path.dart' as p;

/// High-performance file operation service with optimized I/O and concurrency control
///
/// This service provides efficient file operations with streaming for large files,
/// proper concurrency control, and cross-platform optimizations.
class FileOperationService with LoggerMixin {
  FileOperationService();

  /// Safely moves a file to the target location
  ///
  /// [sourceFile] The source file to move
  /// [targetDirectory] The target directory
  /// [dateTaken] Optional date to set as file modification time
  /// Returns the result file
  Future<File> moveFile(
    final File sourceFile,
    final Directory targetDirectory, {
    final DateTime? dateTaken,
  }) async =>
      _moveIntoDirectory(sourceFile, targetDirectory, dateTaken: dateTaken);

  /// High-performance file move using optimized streaming and concurrency control
  ///
  /// Uses platform-specific optimizations and streaming for large files
  /// [dateTaken] Optional date to set as file modification time
  Future<File> moveFileOptimized(
    final File sourceFile,
    final Directory targetDirectory, {
    final DateTime? dateTaken,
  }) async => GlobalPools.poolFor(ConcurrencyOperation.fileIO).withResource(
    () => _moveIntoDirectory(sourceFile, targetDirectory, dateTaken: dateTaken),
  );

  Future<File> _moveIntoDirectory(
    final File sourceFile,
    final Directory targetDirectory, {
    final DateTime? dateTaken,
  }) async {
    final Directory normalizedTargetDir = Directory(
      _normalizePathForWrite(targetDirectory.path),
    );
    await normalizedTargetDir.create(recursive: true);

    final _ReservedTarget reserved = await _reserveUniqueTarget(
      normalizedTargetDir,
      p.basename(sourceFile.path),
    );

    try {
      final resultFile = await _moveFileOptimized(sourceFile, reserved.file);
      if (dateTaken != null) {
        await setFileTimestamp(resultFile, dateTaken);
      }
      return resultFile;
    } on FileSystemException catch (e) {
      if (e.osError?.errorCode == 18 || e.message.contains('cross-device')) {
        throw FileOperationException(
          'Cannot move files across different drives. Please select an output location on the same drive as the input.',
          originalException: e,
        );
      }
      rethrow;
    } finally {
      GlobalPools.releaseReservedPath(
        reserved.directoryPath,
        reserved.file.path,
      );
    }
  }

  /// Internal optimized file move implementation
  Future<File> _moveFileOptimized(
    final File source,
    final File destination,
  ) async {
    // Normalize destination path to avoid trailing-space/dot segments
    final File normalizedDest = File(_normalizePathForWrite(destination.path));

    // Check if it's a same-drive operation for optimization
    if (_isSameDrive(source.path, normalizedDest.path)) {
      try {
        return await source.rename(normalizedDest.path);
      } on FileSystemException catch (e) {
        if (e.osError?.errorCode == 18 || e.message.contains('cross-device')) {
          // Fall through to copy+delete for EXDEV
        } else {
          rethrow;
        }
      }
    }

    // Cross-drive move requires copy + delete
    final copied = await _copyFileStreaming(source, normalizedDest);
    await _verifyCopiedFileIntegrity(source, copied);
    await source.delete();
    return copied;
  }

  Future<void> _verifyCopiedFileIntegrity(
    final File source,
    final File destination,
  ) async {
    if (!await destination.exists()) {
      throw FileOperationException(
        'Copied file missing at destination: ${destination.path}',
      );
    }

    final sourceStat = await source.stat();
    // size == -1 means the source file no longer exists (it was already deleted
    // by an earlier mover that processed the same underlying file). The
    // destination exists so the copy completed successfully — treat as success.
    if (sourceStat.size == -1) return;
    final destinationStat = await destination.stat();
    if (sourceStat.size != destinationStat.size) {
      throw FileOperationException(
        'Copied file size mismatch for ${destination.path} '
        '(source=${sourceStat.size}, destination=${destinationStat.size})',
      );
    }
  }

  /// Streaming file copy for better memory efficiency
  Future<File> _copyFileStreaming(
    final File source,
    final File destination,
  ) async {
    // Normalize destination before writing
    final File normalizedDest = File(_normalizePathForWrite(destination.path));
    final Directory parent = Directory(p.dirname(normalizedDest.path));
    await parent.create(recursive: true);

    final sourceStream = source.openRead();
    final destinationSink = normalizedDest.openWrite();

    try {
      await sourceStream.pipe(destinationSink);
      return normalizedDest;
    } finally {
      await destinationSink.close();
    }
  }

  /// Check if two paths are on the same drive (for optimization)
  bool _isSameDrive(final String path1, final String path2) {
    if (!Platform.isWindows) {
      // Unix-like systems do not use drive letters; still attempt rename first.
      // If paths span different mount points, rename will throw EXDEV and we fall back to copy+delete.
      return true;
    }

    final drive1 = path1.length >= 2 ? path1.substring(0, 2).toUpperCase() : '';
    final drive2 = path2.length >= 2 ? path2.substring(0, 2).toUpperCase() : '';

    return drive1 == drive2 && drive1.contains(':');
  }

  /// Sets the last modified time for a file with proper error handling
  ///
  /// [file] The file to modify
  /// [timestamp] The timestamp to set
  Future<void> setFileTimestamp(
    final File file,
    final DateTime timestamp,
  ) async {
    // Handle Windows date limitations
    DateTime adjustedTime = timestamp;
    if (Platform.isWindows && timestamp.isBefore(DateTime(1970))) {
      print(
        '[Info]: ${file.path} has date $timestamp, which is before 1970 (not supported on Windows) - will be set to 1970-01-01',
      );
      adjustedTime = DateTime(1970);
    }

    try {
      await file.setLastModified(adjustedTime);
    } on OSError catch (e) {
      // Sometimes Windows throws error but succeeds anyway
      // Only throw if it's not error code 0
      if (e.errorCode != 0) {
        throw FileOperationException(
          "Can't set modification time on $file: $e",
          originalException: e,
        );
      }
      // Error code 0 means success, so we ignore it
    } catch (e) {
      // For other exceptions, check if it's the Windows "success" quirk
      final errorMessage = e.toString();
      if (errorMessage.contains('The operation completed successfully')) {
        // This is a Windows quirk where it reports success as an error - ignore it
        return;
      }

      // For genuine errors, we can log and continue
      logError("Can't set modification time on $file: $e.");
    }
  }

  /// Ensures a directory exists, creating it if necessary
  Future<void> ensureDirectoryExists(final Directory directory) async {
    final Directory normalized = Directory(
      _normalizePathForWrite(directory.path),
    );
    if (!await normalized.exists()) {
      await normalized.create(recursive: true);
    }
  }

  /// Batch create multiple directories with concurrency control
  Future<void> ensureDirectoriesExist(final List<Directory> directories) async {
    final pool = GlobalPools.poolFor(ConcurrencyOperation.fileIO);
    final concurrency = ConcurrencyManager().concurrencyFor(
      ConcurrencyOperation.fileIO,
    );
    logDebug(
      'Starting $concurrency threads (fileIO directory ensure concurrency)',
    );
    await Future.wait(
      directories.map(
        (final dir) => pool.withResource(() => ensureDirectoryExists(dir)),
      ),
    );
  }

  /// Batch file move operations with progress reporting
  Future<List<FileOperationResult>> batchMove(
    final List<({File source, Directory target})> operations, {
    final void Function(int completed, int total)? onProgress,
  }) async {
    final results = <FileOperationResult>[];
    final pool = GlobalPools.poolFor(ConcurrencyOperation.fileIO);
    final concurrency = ConcurrencyManager().concurrencyFor(
      ConcurrencyOperation.fileIO,
    );
    logDebug('Starting $concurrency threads (fileIO move concurrency)');
    int completed = 0;

    final futures = operations.map(
      (final op) async => pool.withResource(() async {
        try {
          final result = await moveFileOptimized(op.source, op.target);
          completed++;
          onProgress?.call(completed, operations.length);
          return FileOperationResult(
            success: true,
            sourceFile: op.source,
            resultFile: result,
          );
        } catch (e) {
          completed++;
          onProgress?.call(completed, operations.length);
          return FileOperationResult(
            success: false,
            sourceFile: op.source,
            error: e.toString(),
          );
        }
      }),
    );

    results.addAll(await Future.wait(futures));
    return results;
  }

  /// Copies a file to the target location (for duplicate copy strategy)
  ///
  /// [sourceFile] The source file to copy
  /// [targetDirectory] The target directory
  /// [dateTaken] Optional date to set as file modification time
  /// Returns the copied file
  Future<File> copyFile(
    final File sourceFile,
    final Directory targetDirectory, {
    final DateTime? dateTaken,
  }) async {
    final Directory normalizedTargetDir = Directory(
      _normalizePathForWrite(targetDirectory.path),
    );
    await normalizedTargetDir.create(recursive: true);

    final _ReservedTarget reserved = await _reserveUniqueTarget(
      normalizedTargetDir,
      p.basename(sourceFile.path),
    );

    try {
      final resultFile = await _copyFileStreaming(sourceFile, reserved.file);
      await _verifyCopiedFileIntegrity(sourceFile, resultFile);
      if (dateTaken != null) {
        await setFileTimestamp(resultFile, dateTaken);
      }
      return resultFile;
    } finally {
      GlobalPools.releaseReservedPath(
        reserved.directoryPath,
        reserved.file.path,
      );
    }
  }

  Future<_ReservedTarget> _reserveUniqueTarget(
    final Directory normalizedTargetDir,
    final String basename,
  ) async => GlobalPools.withDirectoryLock(normalizedTargetDir.path, () async {
    final File targetFile = _findAndReserveUniqueTarget(
      File(p.join(normalizedTargetDir.path, basename)),
    );
    return _ReservedTarget(
      directoryPath: normalizedTargetDir.path,
      file: targetFile,
    );
  });

  File _findAndReserveUniqueTarget(final File initialFile) {
    final String directory = initialFile.parent.path;
    final String nameWithoutExtension = initialFile.nameWithoutExtension;
    final String extension = initialFile.extension;

    File candidate = initialFile;
    int counter = 0;
    while (true) {
      final bool existsOnDisk = candidate.existsSync();
      final bool reserved = GlobalPools.isPathReserved(
        directory,
        candidate.path,
      );
      if (!existsOnDisk && !reserved) {
        final bool didReserve = GlobalPools.tryReservePath(
          directory,
          candidate.path,
        );
        if (didReserve) return candidate;
      }

      counter++;
      final String newName = '$nameWithoutExtension($counter)$extension';
      candidate = File('$directory${Platform.pathSeparator}$newName');
    }
  }

  /// NEW: normalize destination paths before touching the filesystem
  ///
  /// - Trims **trailing spaces and dots** from **each path segment** (ASCII-only).
  /// - Removes ASCII control chars only (0x00..0x1F).
  /// - **NEVER** transforms Unicode letters (accents, ñ, emojis, etc.).
  /// - Ensures no empty segments remain (replaces with "_").
  /// - **Preserves absolute root prefixes** ("/", "C:\\", and UNC "\\\\server\\share\\").
  /// - **Honors relative semantics** by skipping "." segments and preserving ".." segments.
  String _normalizePathForWrite(final String rawPath) {
    if (rawPath.isEmpty) return rawPath;

    // Preserve the root prefix (Unix "/", Windows drive roots like "C:\\" and UNC roots "\\\\server\\share\\")
    final String root = p.rootPrefix(rawPath);
    final String remainder = rawPath.substring(root.length);

    // Split by slash or backslash, allowing duplicates.
    final List<String> rawParts = remainder.split(RegExp(r'[\\/]+'));

    final List<String> norm = <String>[];
    for (int i = 0; i < rawParts.length; i++) {
      var seg = rawParts[i];
      if (seg.isEmpty) continue;

      // Keep relative semantics: skip "." and preserve ".." literally.
      if (seg == '.') continue;
      if (seg == '..') {
        norm.add('..');
        continue;
      }

      // Sanitize segment without altering any non-ASCII characters.
      seg = _sanitizeSegmentPreserveUnicode(seg);

      // Avoid empty component
      if (seg.isEmpty) seg = '_';

      norm.add(seg);
    }

    if (norm.isEmpty) return root.isNotEmpty ? root : '.';

    final String joined = norm.join(Platform.pathSeparator);
    if (root.isEmpty) return joined;

    final bool rootEndsWithSep = root.endsWith('\\') || root.endsWith('/');
    return rootEndsWithSep
        ? '$root$joined'
        : '$root${Platform.pathSeparator}$joined';
  }

  /// Sanitizes a single path segment while preserving all Unicode characters.
  ///
  /// - Removes ASCII control codes (0x00..0x1F).
  /// - Trims trailing ASCII '.' (0x2E) and ' ' (0x20) only.
  /// - Does not change case, normalize, or decompose any Unicode code points.
  String _sanitizeSegmentPreserveUnicode(final String segment) {
    if (segment.isEmpty) return segment;

    // 1) Remove ASCII control codes by filtering code units <= 0x1F.
    final List<int> units = <int>[];
    for (final cu in segment.codeUnits) {
      if (cu >= 0x20) units.add(cu);
    }
    if (units.isEmpty) return '';

    // 2) Trim trailing ASCII dot/space, preserving everything else verbatim.
    int end = units.length;
    while (end > 0) {
      final cu = units[end - 1];
      if (cu == 0x20 /* ' ' */ || cu == 0x2E /* '.' */ ) {
        end--;
        continue;
      }
      break;
    }

    if (end <= 0) return '';
    return String.fromCharCodes(units.sublist(0, end));
  }
}

/// Result of a file operation
class FileOperationResult {
  const FileOperationResult({
    required this.success,
    required this.sourceFile,
    this.resultFile,
    this.error,
  });

  final bool success;
  final File sourceFile;
  final File? resultFile;
  final String? error;
}

/// Exception thrown when file operations fail
class FileOperationException implements Exception {
  const FileOperationException(this.message, {this.originalException});
  final String message;
  final Object? originalException;

  @override
  String toString() => 'FileOperationException: $message';
}

class _ReservedTarget {
  const _ReservedTarget({required this.directoryPath, required this.file});

  final String directoryPath;
  final File file;
}
