import 'dart:async';
import 'dart:collection';
import 'dart:io';
import 'dart:typed_data';
import 'package:gpth_neo/gpth_lib_exports.dart';
import 'package:xxh3/xxh3.dart';

/// Optimized service for calculating media file hashes and sizes with intelligent caching
///
/// Uses streaming for large files to reduce memory usage and provides
/// improved concurrency control for better performance. Now includes
/// hash caching to avoid recalculating hashes for previously processed files.
class MediaHashService with LoggerMixin {
  // 50MB
  /// Creates a new instance of MediaHashService
  MediaHashService({this.maxCacheSize = 10000});

  /// Maximum number of entries to keep in cache
  final int maxCacheSize;

  /// Cache for file hashes - uses LRU eviction policy
  static final LinkedHashMap<String, _CacheEntry> _hashCache = LinkedHashMap();

  /// Cache for file sizes - lightweight since sizes are quick to calculate
  static final Map<String, ({int size, DateTime modified})> _sizeCache = {};

  /// Mutex for thread-safe cache operations
  static final _cacheMutex = _Mutex();

  static const int _largeFileThreshold = 50 * 1024 * 1024;

  /// Calculates the XXH3 hash of a file using streaming for large files with caching
  ///
  /// [file] File to calculate hash for
  /// Returns the XXH3 hash as an unsigned hex string
  /// Throws [FileSystemException] if file doesn't exist or can't be read
  Future<String> calculateFileHash(final File file) async {
    // Generate cache key from file metadata
    final fileStat = await file.stat();
    final cacheKey = _generateCacheKey(
      file.path,
      fileStat,
    ); // Check cache first (with synchronization)
    final cached = await _cacheMutex.protect(() async {
      if (_hashCache.containsKey(cacheKey)) {
        final cached = _hashCache[cacheKey]!;
        // Move to end (LRU)
        _hashCache.remove(cacheKey);
        _hashCache[cacheKey] = cached;
        return cached.hash;
      }
      return null;
    });

    if (cached != null) {
      return cached;
    }

    // Add retry logic for file system operations that might be delayed
    const maxRetries = 3;
    const baseDelay = Duration(milliseconds: 10);

    for (int attempt = 0; attempt < maxRetries; attempt++) {
      if (await file.exists()) {
        try {
          final fileSize = await file.length();
          String hash;

          // For small files, load all bytes at once; for large files stream in chunks.
          if (fileSize < _largeFileThreshold) {
            final bytes = await file.readAsBytes();
            hash = xxh3String(bytes);
          } else {
            // Stream large files to avoid high memory usage
            final state = xxh3Stream();
            await for (final chunk in file.openRead()) {
              state.update(Uint8List.fromList(chunk));
            }
            hash = state.digestString();
          } // Store in cache (with synchronization)
          await _cacheMutex.protect(() async {
            _addToCache(cacheKey, hash, fileSize);
          });
          return hash;
        } catch (e) {
          if (attempt == maxRetries - 1) {
            throw FileSystemException(
              'Failed to calculate hash: $e',
              file.path,
            );
          }
          // Wait before retrying
          await Future.delayed(baseDelay * (attempt + 1));
        }
      } else {
        if (attempt == maxRetries - 1) {
          throw FileSystemException('File does not exist', file.path);
        }
        // Wait before checking again - file might be in process of being written
        await Future.delayed(baseDelay * (attempt + 1));
      }
    }

    throw FileSystemException('File does not exist after retries', file.path);
  }

  /// Calculates the size of a file in bytes with caching
  ///
  /// [file] File to get size of
  /// Returns file size in bytes
  /// Throws [FileSystemException] if file doesn't exist
  Future<int> calculateFileSize(final File file) async {
    final filePath = file.path;

    // Check if we have a recent size calculation
    if (_sizeCache.containsKey(filePath)) {
      final cached = _sizeCache[filePath]!;
      final fileModified = await file.lastModified();

      // Use cached size if file hasn't been modified
      if (cached.modified.isAtSameMomentAs(fileModified)) {
        return cached.size;
      }
    }

    // Add retry logic for file system operations that might be delayed
    const maxRetries = 3;
    const baseDelay = Duration(milliseconds: 10);

    for (int attempt = 0; attempt < maxRetries; attempt++) {
      if (await file.exists()) {
        try {
          final stat = await file.stat();
          _sizeCache[file.path] = (size: stat.size, modified: stat.modified);
          return stat.size;
        } catch (e) {
          if (attempt == maxRetries - 1) {
            throw FileSystemException('Failed to get file size: $e', file.path);
          }
          // Wait before retrying
          await Future.delayed(baseDelay * (attempt + 1));
        }
      } else {
        if (attempt == maxRetries - 1) {
          throw FileSystemException('File does not exist', file.path);
        }
        // Wait before checking again - file might be in process of being written
        await Future.delayed(baseDelay * (attempt + 1));
      }
    }

    throw FileSystemException('File does not exist after retries', file.path);
  }

  /// Calculates both hash and size for a file in a single streaming pass
  ///
  /// More efficient than calling both methods separately as it reads the file only once.
  ///
  /// [file] File to analyze
  /// Returns a record with (hash, size)
  /// Throws [FileSystemException] if file doesn't exist or can't be read
  Future<({String hash, int size})> calculateHashAndSize(
    final File file,
  ) async {
    if (!await file.exists()) {
      throw FileSystemException('File does not exist', file.path);
    }

    final state = xxh3Stream();
    int totalSize = 0;

    await for (final chunk in file.openRead()) {
      state.update(Uint8List.fromList(chunk));
      totalSize += chunk.length;
    }
    final hash = state.digestString();
    final cacheKey = _generateCacheKey(file.path, await file.stat());
    await _cacheMutex.protect(() async {
      _addToCache(cacheKey, hash, totalSize);
    });
    _sizeCache[file.path] = (size: totalSize, modified: DateTime.now());

    return (hash: hash, size: totalSize);
  }

  /// Calculates hashes for multiple files with optimized concurrency control and memory management
  ///
  /// [files] List of files to process
  /// Returns a map of file path to hash
  Future<Map<String, String>> calculateMultipleHashes(
    final List<File> files,
  ) async {
    final results = <String, String>{};
    final pool = GlobalPools.poolFor(ConcurrencyOperation.hash);

    // Process in chunks to manage memory for large collections
    const chunkSize = 1000;
    for (
      int chunkStart = 0;
      chunkStart < files.length;
      chunkStart += chunkSize
    ) {
      final chunk = files.skip(chunkStart).take(chunkSize);

      final futures = chunk.map(
        (final file) async => pool
            .withResource(() async {
              final hash = await calculateFileHash(file);
              return MapEntry(file.path, hash);
            })
            .catchError((final e) {
              print('Warning: Failed to calculate hash for ${file.path}: $e');
              // Provide empty hash marker so map insert logic is uniform
              return MapEntry(file.path, '');
            }),
      );

      final chunkResults = await Future.wait(futures);
      for (final result in chunkResults) {
        // Only include successful (non-empty) hashes. Empty string signals a failure.
        if (result.value.isNotEmpty) {
          results[result.key] = result.value;
        }
      }

      // Report progress for large operations
      if (files.length > 1000) {
        final processed = chunkStart + chunkSize;
        final progress = (processed / files.length * 100).clamp(0, 100);
        print('Hash calculation progress: ${progress.toStringAsFixed(1)}%');
      }
    }

    return results;
  }

  /// Compares two files by hash to determine if they are identical
  ///
  /// [file1] First file to compare
  /// [file2] Second file to compare
  /// Returns true if files have identical content
  Future<bool> areFilesIdentical(final File file1, final File file2) async {
    // Quick size check first
    final size1 = await calculateFileSize(file1);
    final size2 = await calculateFileSize(file2);

    if (size1 != size2) {
      return false;
    }

    // If sizes match, compare hashes
    final hash1 = await calculateFileHash(file1);
    final hash2 = await calculateFileHash(file2);

    return hash1 == hash2;
  }

  /// Batch calculate hash and size for multiple files efficiently
  ///
  /// [files] List of files to process
  /// Returns list of results with success status
  Future<List<({String path, String hash, int size, bool success})>>
  calculateHashAndSizeBatch(final List<File> files) async {
    final pool = GlobalPools.poolFor(ConcurrencyOperation.hash);

    final futures = files.map(
      (final file) async => pool
          .withResource(() async {
            final result = await calculateHashAndSize(file);
            return (
              path: file.path,
              hash: result.hash,
              size: result.size,
              success: true,
            );
          })
          .catchError((final e) {
            print('Warning: Failed to process ${file.path}: $e');
            return (path: file.path, hash: '', size: 0, success: false);
          }),
    );

    return Future.wait(futures);
  }

  /// Generate cache key from file metadata
  // ignore: prefer_expression_function_bodies
  String _generateCacheKey(final String path, final FileStat stat) {
    // Use path, size, and modification time as cache key
    // This ensures cache invalidation when files change
    return '$path:${stat.size}:${stat.modified.millisecondsSinceEpoch}';
  }

  /// Add entry to hash cache with LRU eviction
  void _addToCache(final String cacheKey, final String hash, final int size) {
    // Remove oldest entries if cache is full
    while (_hashCache.length >= maxCacheSize) {
      final oldestKey = _hashCache.keys.first;
      _hashCache.remove(oldestKey);
      // logDebug('Evicting cache entry for key: $oldestKey');
    }

    _hashCache[cacheKey] = _CacheEntry(hash: hash, size: size);
  }

  /// Get cache statistics for monitoring performance
  Map<String, dynamic> getCacheStats() => {
    'hashCacheSize': _hashCache.length,
    'sizeCacheSize': _sizeCache.length,
    'maxCacheSize': maxCacheSize,
    'cacheUtilization':
        '${(_hashCache.length / maxCacheSize * 100).toStringAsFixed(1)}%',
  };

  /// Clear all caches
  void clearCache() {
    _hashCache.clear();
    _sizeCache.clear();
  }
}

// Concurrency now managed via package:pool.

class _CacheEntry {
  const _CacheEntry({required this.hash, required this.size});

  final String hash;
  final int size;
}

/// Simple mutex for synchronizing cache operations
class _Mutex {
  bool _locked = false;
  final Queue<Completer<void>> _waitQueue = Queue<Completer<void>>();

  Future<T> protect<T>(final Future<T> Function() operation) async {
    await _acquire();
    try {
      return await operation();
    } finally {
      _release();
    }
  }

  Future<void> _acquire() async {
    if (!_locked) {
      _locked = true;
      return;
    }

    final completer = Completer<void>();
    _waitQueue.add(completer);
    return completer.future;
  }

  void _release() {
    if (_waitQueue.isNotEmpty) {
      final next = _waitQueue.removeFirst();
      next.complete();
    } else {
      _locked = false;
    }
  }
}
