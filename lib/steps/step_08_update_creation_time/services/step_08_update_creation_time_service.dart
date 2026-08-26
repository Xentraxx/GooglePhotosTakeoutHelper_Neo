// Service module: UpdateCreationTimeService
import 'dart:async';
import 'dart:ffi';
import 'dart:io';

import 'package:console_bars/console_bars.dart';
import 'package:ffi/ffi.dart';
import 'package:gpth_neo/gpth_lib_exports.dart';
import 'package:win32/win32.dart';

/// Service that updates filesystem timestamps according to MediaEntity.dateTaken
///
/// English note:
/// - Orchestrates the whole Step 8 logic formerly in the step's `execute`.
/// - Keeps behavior identical: same logs, counters, progress bar, and result message.
/// - Cross-platform handling remains the same (Windows vs POSIX).
class UpdateCreationTimeService with LoggerMixin {
  /// Run the full update process and return a summary compatible with the former step output.
  Future<UpdateCreationTimeSummary> updateCreationTimes(
    final ProcessingContext context,
  ) async {
    if (!context.config.updateCreationTime) {
      const reason = 'disabled in configuration';
      logWarning(
        '[Step 8/8] Skipping creation time update ($reason).',
        forcePrint: true,
      );
      return const UpdateCreationTimeSummary(
        updatedCount: 0,
        failedCount: 0,
        updatedPhysical: 0,
        updatedShortcuts: 0,
        failedPhysical: 0,
        failedShortcuts: 0,
        skipped: true,
        message: 'Creation time update skipped: $reason',
      );
    }

    logPrint('[Step 8/8] Updating creation times...');

    // Build the list of output items from the collection
    // (primary + secondaries with targetPath != null; include shortcuts too).
    final filesToTouch = <_ToTouch>[];
    for (final entity in context.mediaCollection.entities) {
      final dt = entity.dateTaken;
      if (dt == null) continue;

      final fes = <FileEntity>[entity.primaryFile, ...entity.secondaryFiles];
      for (final fe in fes) {
        final tp = fe.targetPath;
        if (tp == null) continue;
        filesToTouch.add(_ToTouch(File(tp), dt, isShortcut: fe.isShortcut));
      }
    }

    if (filesToTouch.isEmpty) {
      logPrint('[Step 8/8] No files found to update creation times.');
      return const UpdateCreationTimeSummary(
        updatedCount: 0,
        failedCount: 0,
        updatedPhysical: 0,
        updatedShortcuts: 0,
        failedPhysical: 0,
        failedShortcuts: 0,
        skipped: false,
        message: 'Updated creation times for 0 files',
      );
    }

    // Initialize progress bar - always visible
    final progressBar = FillingBar(
      desc: '[ INFO  ] [Step 8/8] Updating creation times',
      total: filesToTouch.length,
      width: 50,
      percentage: true,
    );

    int updated = 0;
    int failed = 0;
    // Per-type counters (physical vs shortcuts)
    int updatedPhysical = 0;
    int updatedShortcuts = 0;
    int failedPhysical = 0;
    int failedShortcuts = 0;

    for (int i = 0; i < filesToTouch.length; i++) {
      final f = filesToTouch[i];
      try {
        final ok = _setFileTimesToDateTakenCrossPlatform(
          f.file.path,
          f.dateTaken,
          isShortcut: f.isShortcut,
        );
        if (ok) {
          updated++;
          if (f.isShortcut) {
            updatedShortcuts++;
          } else {
            updatedPhysical++;
          }
        } else {
          failed++;
          if (f.isShortcut) {
            failedShortcuts++;
          } else {
            failedPhysical++;
          }
        }
      } catch (e) {
        failed++;
        if (f.isShortcut) {
          failedShortcuts++;
        } else {
          failedPhysical++;
        }
        logWarning(
          '[Step 8/8] Timestamp update failed for ${f.file.path}: $e',
          forcePrint: true,
        );
      }
      progressBar.update(i + 1);
    }

    print(''); // print to force new line after progress bar

    // Explicit summary line (with per-type breakdown)
    logPrint(
      '[Step 8/8] Update Creation Time Summary → updated: $updated (physical=$updatedPhysical, shortcuts=$updatedShortcuts), failed: $failed (physical=$failedPhysical, shortcuts=$failedShortcuts)',
    );

    return UpdateCreationTimeSummary(
      updatedCount: updated,
      failedCount: failed,
      updatedPhysical: updatedPhysical,
      updatedShortcuts: updatedShortcuts,
      failedPhysical: failedPhysical,
      failedShortcuts: failedShortcuts,
      skipped: false,
      message: 'Updated creation times for $updated files',
    );
  }

  /// Cross-platform timestamp update.
  /// Windows: sets CreationTime and LastWriteTime = dateTaken (preserving LastAccessTime).
  /// POSIX   : sets mtime (and atime) = dateTaken. If [isShortcut] is true and the path is a symlink,
  ///           we update the symlink's own timestamps using utimensat(AT_SYMLINK_NOFOLLOW).
  bool _setFileTimesToDateTakenCrossPlatform(
    final String filePath,
    final DateTime dateTaken, {
    required final bool isShortcut,
  }) {
    if (Platform.isWindows) {
      return _setFileTimesToDateTakenWindows(
        filePath,
        dateTaken,
        isShortcut: isShortcut,
      );
    } else {
      return _setFileTimesToDateTakenPosix(
        filePath,
        dateTaken,
        isShortcut: isShortcut,
      );
    }
  }

  /// Synchronous Win32 creation/write time update to a specific DateTime (entity.dateTaken).
  /// If [isShortcut] is true, the handle is opened with FILE_FLAG_OPEN_REPARSE_POINT
  /// so we touch the link itself (not its target). LastAccessTime is preserved as-is.
  bool _setFileTimesToDateTakenWindows(
    final String filePath,
    final DateTime dateTaken, {
    required final bool isShortcut,
  }) {
    try {
      return using((final Arena arena) {
        // Convert to extended-length path to avoid MAX_PATH issues on Windows.
        // IMPORTANT: make path absolute first; \\?\ only makes sense for absolute paths.
        final String extended = _toExtendedLengthPath(filePath);
        final pathPtr = extended.toNativeUtf16(allocator: arena);

        // Always allow directory handles; don't follow symlinks when touching shortcuts.
        final int flags =
            FILE_ATTRIBUTE_NORMAL |
            FILE_FLAG_BACKUP_SEMANTICS |
            (isShortcut ? FILE_FLAG_OPEN_REPARSE_POINT : 0);

        // Open file handle with write attributes access
        final fileHandle = CreateFile(
          pathPtr,
          FILE_WRITE_ATTRIBUTES,
          FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE,
          nullptr, // leave security attributes null
          OPEN_EXISTING,
          flags,
          0,
        );

        if (fileHandle == INVALID_HANDLE_VALUE) {
          // Log error code captured atomically with the result.
          final int err = GetLastError();
          logWarning(
            '[Step 8/8] CreateFile failed for "$extended" (error=$err)',
            forcePrint: true,
          );
          return false;
        }

        try {
          // Target FILETIME from dateTaken (UTC)
          final Pointer<FILETIME> pCreation = arena<FILETIME>();
          final Pointer<FILETIME> pWrite = arena<FILETIME>();
          _writeDateTimeToFileTimePtr(pCreation, dateTaken.toUtc());
          _writeDateTimeToFileTimePtr(pWrite, dateTaken.toUtc());

          // Set CreationTime and LastWriteTime = dateTaken; keep LastAccessTime unchanged (nullptr)
          final bool setOk =
              SetFileTime(fileHandle, pCreation, nullptr, pWrite) != 0;
          return setOk;
        } finally {
          CloseHandle(fileHandle);
        }
      });
    } catch (e) {
      logWarning(
        '[Step 8/8] Windows timestamp update failed for "$filePath": $e',
        forcePrint: true,
      );
      return false;
    }
  }

  /// POSIX implementation using utimensat.
  /// NOTE: On POSIX there is no creation time; we set both mtime and atime to `dateTaken`.
  ///       If the path is a shortcut/symlink, we attempt to touch the link itself using
  ///       AT_SYMLINK_NOFOLLOW. Fallbacks apply if utimensat is not available.
  bool _setFileTimesToDateTakenPosix(
    final String filePath,
    final DateTime dateTaken, {
    required final bool isShortcut,
  }) {
    try {
      final DynamicLibrary? libc = _loadLibC();
      if (libc == null) {
        // Fallback: only mtime on the target (cannot touch the symlink itself here).
        try {
          File(filePath).setLastModifiedSync(dateTaken);
          return !isShortcut; // we only updated the target; for shortcuts say false
        } catch (_) {
          return false;
        }
      }

      // typedef int utimensat(int dirfd, const char *pathname, const struct timespec times[2], int flags);
      _Utimensat? utimensat;
      try {
        utimensat = libc
            .lookup<NativeFunction<_UtimensatNative>>('utimensat')
            .asFunction<_Utimensat>();
      } catch (_) {
        utimensat = null;
      }

      if (utimensat == null) {
        // Fallback if symbol not found.
        try {
          File(filePath).setLastModifiedSync(dateTaken);
          return !isShortcut;
        } catch (_) {
          return false;
        }
      }

      return using((final Arena arena) {
        final Pointer<Utf8> p = filePath.toNativeUtf8(allocator: arena);

        // Build timespec array [atime, mtime]
        final Pointer<_Timespec> times = arena<_Timespec>(2);

        // NOTE: We set BOTH atime and mtime to dateTaken for simplicity/cross-tool consistency.
        final int sec = dateTaken.toUtc().millisecondsSinceEpoch ~/ 1000;
        final int nsec =
            (dateTaken.toUtc().microsecondsSinceEpoch % 1000000) * 1000;

        times[0]
          ..tvSec = sec
          ..tvNsec = nsec;
        times[1]
          ..tvSec = sec
          ..tvNsec = nsec;

        const int atFdcwd = -100;
        const int atSymlinkNofollow = 0x100;

        final int flags = isShortcut ? atSymlinkNofollow : 0;
        final int r = utimensat!(atFdcwd, p, times, flags);
        if (r == 0) return true;

        // Fallback: if touching symlink itself is unsupported, try touching target when isShortcut=false or as last resort.
        try {
          File(filePath).setLastModifiedSync(dateTaken);
          return !isShortcut; // if it was a symlink we likely only touched the target
        } catch (_) {
          return false;
        }
      });
    } catch (e) {
      logWarning(
        '[Step 8/8] POSIX timestamp update failed for "$filePath": $e',
        forcePrint: true,
      );
      return false;
    }
  }

  // ------------------------------- Utilities --------------------------------

  /// Convert normal path to extended-length path (\\?\ prefix) for long-path safety on Windows.
  /// IMPORTANT: This function now ensures the path is absolute before applying the prefix.
  ///
  /// The \\?\ prefix disables Win32 path normalization, which means forward slashes ('/')
  /// are NOT translated to backslashes and cause CreateFile to fail with ERROR_INVALID_NAME
  /// (error 123). We must normalize all separators to '\\' before applying the prefix.
  String _toExtendedLengthPath(final String p) {
    if (!Platform.isWindows) return p;
    // Ensure absolute first, then normalize all separators to backslashes.
    final String abs = File(p).absolute.path.replaceAll('/', '\\');
    if (abs.startsWith('\\\\?\\')) return abs;
    if (abs.startsWith('\\\\')) return '\\\\?\\UNC${abs.substring(1)}';
    return '\\\\?\\$abs';
  }

  /// Write a DateTime (UTC) into a FILETIME pointer.
  /// FILETIME = 100-nanosecond intervals since January 1, 1601 (UTC).
  void _writeDateTimeToFileTimePtr(
    final Pointer<FILETIME> p,
    final DateTime utc,
  ) {
    const int epochDiff100ns =
        116444736000000000; // between 1601-01-01 and 1970-01-01
    final int ftTicks = utc.millisecondsSinceEpoch * 10000 + epochDiff100ns;
    p.ref
      ..dwHighDateTime = (ftTicks >> 32) & 0xFFFFFFFF
      ..dwLowDateTime = ftTicks & 0xFFFFFFFF;
  }

  DynamicLibrary? _loadLibC() {
    try {
      if (Platform.isLinux) return DynamicLibrary.open('libc.so.6');
      if (Platform.isMacOS) {
        return DynamicLibrary.process(); // libc is in the default namespace on macOS
      }
      if (Platform.isAndroid) return DynamicLibrary.open('libc.so');
      return null;
    } catch (_) {
      return null;
    }
  }
}

// FFI types for POSIX utimensat

// struct timespec { time_t tv_sec; long tv_nsec; }
// NOTE: We use Int64 for both fields, which matches 64-bit Linux/macOS ABIs.
final class _Timespec extends Struct {
  @Int64()
  external int tvSec;

  @Int64()
  external int tvNsec;
}

typedef _UtimensatNative =
    Int32 Function(
      Int32 dirfd,
      Pointer<Utf8> pathname,
      Pointer<_Timespec> times,
      Int32 flags,
    );
typedef _Utimensat =
    int Function(
      int dirfd,
      Pointer<Utf8> pathname,
      Pointer<_Timespec> times,
      int flags,
    );

class _ToTouch {
  _ToTouch(this.file, this.dateTaken, {required this.isShortcut});
  final File file;
  final DateTime dateTaken;
  final bool isShortcut;
}

/// Summary DTO returned by the service to keep StepResult data identical to before.
class UpdateCreationTimeSummary {
  const UpdateCreationTimeSummary({
    required this.updatedCount,
    required this.failedCount,
    required this.updatedPhysical,
    required this.updatedShortcuts,
    required this.failedPhysical,
    required this.failedShortcuts,
    required this.skipped,
    required this.message,
  });

  final int updatedCount;
  final int failedCount;
  final int updatedPhysical;
  final int updatedShortcuts;
  final int failedPhysical;
  final int failedShortcuts;
  final bool skipped;
  final String message;
}
