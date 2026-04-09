import 'dart:ffi' as ffi;
import 'dart:io';
import 'dart:isolate';

import 'package:ffi/ffi.dart';
import 'package:gpth_neo/gpth_lib_exports.dart';
import 'package:path/path.dart' as p;
import 'package:win32/win32.dart';

/// Service for creating Windows symbolic links using Win32 API
///
/// This service creates symbolic links on Windows using the native Win32 API,
/// providing better compatibility with cloud services and file type detection
/// compared to .lnk shortcut files.
class WindowsSymlinkService with LoggerMixin {
  /// Creates a new instance of WindowsSymlinkService
  WindowsSymlinkService();

  // Remember strategy: null = unknown, true = go straight to .lnk fallback, false = try native first
  static bool? _preferShortcutFallback;

  /// Creates a Windows symbolic link using native Win32 API
  ///
  /// [symlinkPath] Path where the symbolic link will be created
  /// [targetPath] Path to the target file/folder
  /// Throws Exception if symlink creation fails
  Future<void> createSymlink(
    final String symlinkPath,
    final String targetPath,
  ) async {
    if (!Platform.isWindows) {
      throw UnsupportedError('This service is only supported on Windows');
    }

    // NOTE: Do not throw for unsupported volumes; prefer automatic fallback to .lnk.
    final bool volumeSupportsSymlinks = supportsSymlinksAt(symlinkPath);
    if (!volumeSupportsSymlinks) _preferShortcutFallback = true;

    // Ensure target path is absolute
    final String absoluteTargetPath = p.isAbsolute(targetPath)
        ? targetPath
        : p.absolute(targetPath);

    // Thread-safe directory creation with retry logic for race conditions
    final Directory parentDir = Directory(p.dirname(symlinkPath));
    await _ensureDirectoryExistsSafe(parentDir);

    // Thread-safe target existence verification with retry
    await _verifyTargetExistsSafe(absoluteTargetPath);

    // If we already know native symlink is not viable, go straight to Windows Shortcut (.lnk)
    if (_preferShortcutFallback == true) {
      await _createWindowsShortcut(symlinkPath, absoluteTargetPath);
      return;
    }

    // Try native symlink first
    try {
      await _createSymlinkNative(symlinkPath, absoluteTargetPath);
      _preferShortcutFallback = false; // native path works in this environment
      return;
    } catch (e) {
      logDebug('Win32 symlink creation failed: $e');
      // Classify common causes to remember and switch to .lnk without failing the test flow.
      final String msg = e.toString();
      final bool privilegeError =
          msg.contains('0x522') ||
          msg.contains('1314') ||
          msg.contains('PRIVILEGE_NOT_HELD');
      final bool invalidFunction =
          msg.contains('0x1') || msg.contains('Incorrect function');
      final bool notSupported =
          msg.contains('0x32') || msg.contains('ERROR_NOT_SUPPORTED');

      if (privilegeError ||
          invalidFunction ||
          notSupported ||
          !volumeSupportsSymlinks) {
        _preferShortcutFallback = true;
        try {
          await _createWindowsShortcut(symlinkPath, absoluteTargetPath);
          return;
        } catch (e2) {
          throw Exception(
            'Failed to create Windows Shortcut after native symlink failed: $e2',
          );
        }
      }

      logDebug(
        'Unexpected Win32 error, attempting Dart Link then .lnk fallback: $e',
      );
    }

    // Fallback to Dart Link (thin wrapper). If it also fails, drop to .lnk and remember.
    try {
      await _createSymlinkDart(symlinkPath, absoluteTargetPath);
      _preferShortcutFallback = false;
    } catch (e) {
      logDebug(
        'Dart Link symlink creation failed, falling back to Windows Shortcut: $e',
      );
      _preferShortcutFallback = true;
      await _createWindowsShortcut(symlinkPath, absoluteTargetPath);
    }
  }

  /// Returns true if the underlying volume for [path] supports reparse points
  /// (i.e., Windows symbolic links / junctions). Uses GetVolumeInformationW
  /// and checks FILE_SUPPORTS_REPARSE_POINTS.
  static bool supportsSymlinksAt(final String path) {
    if (!Platform.isWindows) return false;

    // Resolve to a volume root like "C:\" or "D:\"
    final String abs = p.isAbsolute(path) ? path : p.absolute(path);
    String root = p.rootPrefix(abs);
    if (root.isEmpty) {
      final m = RegExp(r'^[A-Za-z]:[\\/]').firstMatch(abs);
      if (m != null) root = m.group(0)!;
    }
    if (root.isEmpty) return false;
    if (!root.endsWith('\\') && !root.endsWith('/')) root = '$root\\';

    return using((final Arena arena) {
      final rootPtr = root.toNativeUtf16(allocator: arena);

      // Allocate a DWORD (Uint32) for the file system flags
      final flagsPtr = arena.allocate<ffi.Uint32>(ffi.sizeOf<ffi.Uint32>());

      final ok = GetVolumeInformation(
        rootPtr,
        ffi.nullptr, // lpVolumeNameBuffer
        0, // nVolumeNameSize
        ffi.nullptr, // lpVolumeSerialNumber
        ffi.nullptr, // lpMaximumComponentLength
        flagsPtr, // lpFileSystemFlags
        ffi.nullptr, // lpFileSystemNameBuffer
        0, // nFileSystemNameSize
      );

      if (ok == 0) return false;

      // Use lowerCamelCase to avoid lint warnings.
      const int fileSupportsReparsePoints = 0x00000080;
      return (flagsPtr.value & fileSupportsReparsePoints) != 0;
    });
  }

  /// Safely ensures a directory exists, handling race conditions
  ///
  /// [directory] The directory to create
  /// Retries up to 3 times with delays to handle concurrent creation
  Future<void> _ensureDirectoryExistsSafe(final Directory directory) async {
    const int maxRetries = 3;
    const Duration retryDelay = Duration(milliseconds: 50);

    for (int attempt = 1; attempt <= maxRetries; attempt++) {
      try {
        if (!await directory.exists()) {
          await directory.create(recursive: true);
        }
        return; // Success
      } catch (e) {
        if (attempt == maxRetries) {
          throw Exception(
            'Failed to create directory after $maxRetries attempts: $e',
          );
        }
        await Future.delayed(retryDelay);
      }
    }
  }

  /// Safely verifies target existence with retry logic
  ///
  /// [targetPath] Path to verify
  /// Retries up to 3 times to handle file system delays
  Future<void> _verifyTargetExistsSafe(final String targetPath) async {
    const int maxRetries = 3;
    const Duration retryDelay = Duration(milliseconds: 50);

    for (int attempt = 1; attempt <= maxRetries; attempt++) {
      if (File(targetPath).existsSync() || Directory(targetPath).existsSync()) {
        return; // Target exists
      }

      if (attempt == maxRetries) {
        throw Exception('Target path does not exist: $targetPath');
      }

      // Small delay to handle file system propagation delays
      await Future.delayed(retryDelay);
    }
  }

  /// Creates a Windows symbolic link using native Win32 API
  ///
  /// [symlinkPath] Path where the symbolic link will be created
  /// [targetPath] Path to the target file/folder
  /// Throws Exception if Win32 API calls fail
  Future<void> _createSymlinkNative(
    final String symlinkPath,
    final String targetPath,
  ) async {
    // Run the synchronous symlink operations in a separate isolate to avoid blocking
    await Isolate.run(() => _createSymlinkSync(symlinkPath, targetPath));
  }

  /// Synchronous symlink creation using Win32 API
  ///
  /// [symlinkPath] Path where the symbolic link will be created
  /// [targetPath] Path to the target file/folder
  void _createSymlinkSync(final String symlinkPath, final String targetPath) {
    using((final Arena arena) {
      // Convert paths to native UTF16
      final symlinkPathPtr = symlinkPath.toNativeUtf16(allocator: arena);
      final targetPathPtr = targetPath.toNativeUtf16(allocator: arena);

      // Delete existing symlink if it exists
      final existingAttributes = GetFileAttributes(symlinkPathPtr);
      if (existingAttributes != 0xFFFFFFFF) {
        // INVALID_FILE_ATTRIBUTES
        if ((existingAttributes & FILE_ATTRIBUTE_REPARSE_POINT) != 0) {
          // It's a reparse point (symlink), delete it
          DeleteFile(symlinkPathPtr);
        }
      }

      // Determine if target is a directory
      final targetAttributes = GetFileAttributes(targetPathPtr);
      final isDirectory =
          targetAttributes != 0xFFFFFFFF && // INVALID_FILE_ATTRIBUTES
          (targetAttributes & FILE_ATTRIBUTE_DIRECTORY) != 0;

      // Create symbolic link
      // SYMBOLIC_LINK_FLAG_DIRECTORY = 0x1 for directories, 0x0 for files
      // SYMBOLIC_LINK_FLAG_ALLOW_UNPRIVILEGED_CREATE = 0x2 (Windows 10 Creator Update+)
      final flags = (isDirectory ? 0x1 : 0x0) | 0x2;

      final result = CreateSymbolicLink(symlinkPathPtr, targetPathPtr, flags);

      if (result == 0) {
        final error = GetLastError();
        throw Exception(
          'Failed to create symbolic link: Win32 error 0x${error.toRadixString(16)}. '
          'Note: Creating symlinks may require Developer Mode to be enabled on Windows 10/11.',
        );
      }

      logDebug(
        'Successfully created symbolic link: $symlinkPath -> $targetPath',
      );
    });
  }

  /// Creates a symbolic link using Dart's Link class as fallback
  ///
  /// [symlinkPath] Path where the symbolic link will be created
  /// [targetPath] Path to the target file/folder
  Future<void> _createSymlinkDart(
    final String symlinkPath,
    final String targetPath,
  ) async {
    // Use relative path to prevent breaking when folders are moved
    final String targetRelativePath = p.relative(
      targetPath,
      from: p.dirname(symlinkPath),
    );

    // Delete existing link if it exists
    final existingLink = Link(symlinkPath);
    if (await existingLink.exists()) {
      await existingLink.delete();
    }

    final link = await Link(symlinkPath).create(targetRelativePath);

    logDebug(
      'Successfully created symbolic link using Dart Link: ${link.path} -> $targetRelativePath',
    );
  }

  /// Creates a Windows Shell Shortcut (.lnk) pointing to [targetPath].
  /// This method does not require admin privileges and works on volumes without reparse points.
  /// If [symlinkPath] does not end with .lnk or .url, a ".lnk" suffix will be appended automatically.
  Future<void> _createWindowsShortcut(
    final String symlinkPath,
    final String targetPath,
  ) async {
    final String workDir = p.dirname(targetPath);

    // Ensure a valid shortcut extension (.lnk or .url). Default to .lnk.
    String outPath = symlinkPath;
    final String lower = outPath.toLowerCase();
    final bool hasValidExt = lower.endsWith('.lnk') || lower.endsWith('.url');
    if (!hasValidExt) outPath = '$outPath.lnk';

    // Escape quotes for PowerShell string literals
    String esc(final String s) => s.replaceAll('"', '""');

    // Build PowerShell script using interpolation (avoid '+' concatenation).
    final String script =
        '\$WshShell = New-Object -ComObject WScript.Shell;'
        '\$s = \$WshShell.CreateShortcut("${esc(outPath)}");'
        '\$s.TargetPath = "${esc(targetPath)}";'
        '\$s.WorkingDirectory = "${esc(workDir)}";'
        '\$s.Save();';

    final proc = await Process.run('powershell.exe', [
      '-NoProfile',
      '-NonInteractive',
      '-ExecutionPolicy',
      'Bypass',
      '-Command',
      script,
    ]);

    if (proc.exitCode != 0) {
      throw Exception('Failed to create Windows Shortcut: ${proc.stderr}');
    }

    logDebug('Successfully created Windows Shortcut: $outPath -> $targetPath');
  }
}
