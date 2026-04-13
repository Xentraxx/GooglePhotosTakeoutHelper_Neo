import 'dart:io';

import 'package:gpth_neo/gpth_lib_exports.dart';
import 'package:path/path.dart' as path;

/// Service responsible for creating symlinks across platforms
///
/// This service creates symbolic links on all platforms (Windows, macOS, Linux),
/// providing a unified interface for the moving logic. Previously created Windows
/// shortcuts (.lnk files), but now creates real symlinks for better compatibility.
///
/// Windows strategy (performance-aware):
/// - Try the fast native symlink (WindowsSymlinkService) once. If it succeeds, cache success
///   and keep using it for all subsequent files.
/// - If the first attempt fails (likely missing SeCreateSymbolicLinkPrivilege),
///   cache the failure and immediately use the slower fallbacks for all files:
///     * Files  -> hard link (mklink /H) if same NTFS volume
///     * Dirs   -> junction (mklink /J)
class SymlinkService {
  // Process-wide cache: null=unknown, true=fast path usable, false=fast path not usable
  static bool? _winFastSymlinkUsable;

  /// Creates a symbolic link to target file
  ///
  /// [targetDirectory] Directory where the symlink will be created
  /// [sourceFile] File to link to
  /// Returns the created symlink file
  /// Uses relative paths to avoid breaking when folders are moved
  Future<File> createSymlink(
    final Directory targetDirectory,
    final File sourceFile, {
    final bool preferHardlink = false,
  }) async {
    // Ensure the parent directory for the symlink exists
    if (!await targetDirectory.exists()) {
      await targetDirectory.create(recursive: true);
    }

    // Use relative path to prevent breaking when folders are moved (Unix usage)
    final String targetRelativePath = path.relative(
      sourceFile.path,
      from: targetDirectory.path,
    );

    // Windows-safe link name: strip trailing spaces/dots only on the *link* leaf.
    // (We do NOT touch the source file on disk.)
    final String rawBasename = path.basename(sourceFile.path);
    final String linkBasename = _sanitizeLeafForWindows(rawBasename);
    final File desiredLink = File(
      path.join(targetDirectory.path, linkBasename),
    );

    // Hold a per-directory exclusive slot so that findUniqueFileName + link
    // creation are one atomic unit — prevents TOCTOU silent overwrites when
    // concurrent entities target the same output directory.
    return GlobalPools.dirPoolFor(targetDirectory.path).withResource(() async {
      final File linkFile = ServiceContainer.instance.utilityService
          .findUniqueFileName(desiredLink);

      if (!Platform.isWindows) {
        // Unix: create a symlink (relative target)
        final Link link = await Link(linkFile.path).create(targetRelativePath);
        return File(link.path);
      }

      // ───────────────────────────────────────────────────────────────────────────
      // Windows path (with fast/slow caching)
      // ───────────────────────────────────────────────────────────────────────────

      // Explicit hardlink mode: for file targets, skip symlink attempts and create
      // a hard link directly. This is Windows-only and only valid on same-volume paths.
      if (preferHardlink) {
        final FileStat st = await sourceFile.stat();
        if (st.type == FileSystemEntityType.directory) {
          throw FileSystemException(
            'Hardlink mode only supports files on Windows (for now. If you need it on linux create an issue).',
            linkFile.path,
          );
        }
        if (!_sameDrive(sourceFile.path, linkFile.path)) {
          throw FileSystemException(
            'Cannot create hard link across different drives.',
            linkFile.path,
          );
        }
        await _createWindowsHardLink(linkFile.path, sourceFile.absolute.path);
        return linkFile;
      }

      // If not explicitly disabled yet, try the fast native symlink once.
      if (_winFastSymlinkUsable != false) {
        try {
          final service = WindowsSymlinkService();
          await service.createSymlink(linkFile.path, sourceFile.absolute.path);
          _winFastSymlinkUsable = true; // cache success
          return linkFile;
        } catch (e) {
          // Cache failure to avoid retrying the fast path on every file (likely privilege issue)
          _winFastSymlinkUsable = false;
          // Fall through to slow fallbacks for this and subsequent calls
        }
      }

      // Slow fallbacks (no privilege required):
      // 1) Directory -> junction (/J)
      // 2) File      -> hard link (/H) only if same drive
      try {
        final FileStat st = await sourceFile.stat();
        if (st.type == FileSystemEntityType.directory) {
          await _createWindowsJunction(linkFile.path, sourceFile.absolute.path);
          return linkFile;
        } else {
          if (_sameDrive(sourceFile.path, linkFile.path)) {
            await _createWindowsHardLink(
              linkFile.path,
              sourceFile.absolute.path,
            );
            return linkFile;
          } else {
            // Different drive: hard link impossible. Keep the error explicit.
            throw FileSystemException(
              'Cannot create hard link across different drives. '
              'Enable Developer Mode (Windows) or run as Administrator to allow symlinks.',
              linkFile.path,
            );
          }
        }
      } catch (fallbackErr) {
        throw FileSystemException(
          'Failed to create link for "${sourceFile.path}". '
          'Tried: ${_winFastSymlinkUsable == false ? "fallback only" : "symlink → fallback"}. '
          'Fallback error: $fallbackErr',
          linkFile.path,
        );
      }
    });
  }

  // ───────────────────────────────────────────────────────────────────────────
  // Windows helpers
  // ───────────────────────────────────────────────────────────────────────────

  /// Create a Windows hard link for files using `mklink /H`.
  Future<void> _createWindowsHardLink(
    final String linkPath,
    final String targetAbs,
  ) async {
    // mklink /H "link" "target"
    final result = await Process.run('cmd', [
      '/c',
      'mklink',
      '/H',
      linkPath,
      targetAbs,
    ], runInShell: true);
    if (result.exitCode != 0) {
      throw FileSystemException(
        'mklink /H failed (${result.exitCode}): ${(result.stderr ?? '').toString().trim()}',
        linkPath,
      );
    }
  }

  /// Create a Windows junction for directories using `mklink /J`.
  Future<void> _createWindowsJunction(
    final String linkPath,
    final String targetAbs,
  ) async {
    // mklink /J "link" "target"
    final result = await Process.run('cmd', [
      '/c',
      'mklink',
      '/J',
      linkPath,
      targetAbs,
    ], runInShell: true);
    if (result.exitCode != 0) {
      throw FileSystemException(
        'mklink /J failed (${result.exitCode}): ${(result.stderr ?? '').toString().trim()}',
        linkPath,
      );
    }
  }

  /// On Windows, hard links require both paths to live on the same drive.
  bool _sameDrive(final String a, final String b) {
    if (!Platform.isWindows) return true;
    String driveOf(final String p) =>
        p.length >= 2 ? p.substring(0, 2).toUpperCase() : '';
    return driveOf(a) == driveOf(b);
  }

  /// Windows does not allow trailing spaces or dots in *file names* (leaf).
  /// We only sanitize the link *basename* we are creating, never the source.
  String _sanitizeLeafForWindows(final String leaf) {
    if (!Platform.isWindows) return leaf;
    // Remove trailing spaces/dots only (keep Unicode intact).
    final String sanitized = leaf.replaceAll(RegExp(r'[. ]+$'), '');
    return sanitized.isEmpty ? leaf : sanitized;
  }
}
