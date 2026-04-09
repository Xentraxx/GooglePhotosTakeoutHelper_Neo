// ignore_for_file: unintended_html_in_doc_comment
import 'dart:io';

import 'package:gpth_neo/gpth_lib_exports.dart';
import 'package:path/path.dart' as path;

/// ─────────────────────────────────────────────────────────────────────────
/// Shared utilities for all moving strategies
/// (centralized in this service module so strategies can import and reuse them)
/// ─────────────────────────────────────────────────────────────────────────
class MovingStrategyUtils {
  const MovingStrategyUtils._();

  /// Generate ALL_PHOTOS target directory (date-structured if needed).
  static Directory allPhotosDir(
    final PathGeneratorService pathService,
    final MediaEntity entity,
    final MovingContext context,
  ) => pathService.generateTargetDirectory(
    null,
    entity.dateTaken,
    context,
    isPartnerShared: entity.partnerShared,
  );

  /// Generate Albums/<albumName> target directory (date-structured if needed).
  static Directory albumDir(
    final PathGeneratorService pathService,
    final String albumName,
    final MediaEntity entity,
    final MovingContext context,
  ) => pathService.generateTargetDirectory(
    albumName,
    entity.dateTaken,
    context,
    isPartnerShared: entity.partnerShared,
  );

  /// Generate album directory but reroute to "Untitled Albums" if albumName starts with any entry in untitledAlbums (case-insensitive).
  /// Note: keeps date-structured path produced by pathService; only swaps the top-level 'Albums' with 'Untitled Albums' when present.
  static Directory albumDirConsideringUntitled(
    final PathGeneratorService pathService,
    final String albumName,
    final MediaEntity entity,
    final MovingContext context,
  ) {
    final Directory base = albumDir(pathService, albumName, entity, context);

    // Fast check against untitled list (case-insensitive "startsWith")
    final String nameLower = albumName.toLowerCase();
    bool isUntitled = false;
    for (final u in untitledAlbums) {
      if (nameLower.startsWith(u.toLowerCase())) {
        isUntitled = true;
        break;
      }
    }
    if (!isUntitled) return base;

    // Build a sibling path under "<output>/Untitled Albums/..." preserving the relative structure after "Albums"
    final String outPath = context.outputDirectory.path;
    final String basePath = base.path;

    // Compute relative path to output and swap the first segment if it is "Albums"
    final String rel = path.relative(basePath, from: outPath);
    final List<String> parts = rel.replaceAll('\\', '/').split('/');
    if (parts.isNotEmpty && parts.first.toLowerCase() == 'albums') {
      parts[0] = 'Untitled Albums';
      final String newRel = parts.join('/');
      return Directory(path.join(outPath, newRel));
    }

    // Fallback: if we cannot detect the 'Albums' segment, place under "Untitled Albums/<albumName>"
    return Directory(path.join(outPath, 'Untitled Albums', albumName));
  }

  /// Returns true if 'child' path equals or is a subpath of 'parent'.
  static bool isSubPath(final String child, final String parent) {
    final String c = child.replaceAll('\\', '/');
    final String p = parent.replaceAll('\\', '/');
    return c == p || c.startsWith('$p/');
  }

  /// Returns the directory (without trailing slash) of a path, handling both separators.
  static String dirOf(final String p) {
    final normalized = p.replaceAll('\\', '/');
    final idx = normalized.lastIndexOf('/');
    return idx < 0 ? '' : normalized.substring(0, idx);
  }

  /// Infer album name for a given file source directory using albumsMap metadata.
  /// Returns null if no album matches.
  static String? inferAlbumForSourceDir(
    final MediaEntity entity,
    final String fileSourceDir,
  ) {
    for (final entry in entity.albumsMap.entries) {
      for (final src in entry.value.sourceDirectories) {
        if (isSubPath(fileSourceDir, src)) return entry.key;
      }
    }
    return entity.albumNames.isNotEmpty ? entity.albumNames.first : null;
  }

  /// Compute the list of album names a given file (by its source directory) belonged to.
  static List<String> albumsForFile(
    final MediaEntity entity,
    final FileEntity file,
  ) {
    final fileDir = dirOf(file.sourcePath);
    final List<String> result = <String>[];
    for (final entry in entity.albumsMap.entries) {
      for (final src in entry.value.sourceDirectories) {
        if (isSubPath(fileDir, src)) {
          result.add(entry.key);
          break;
        }
      }
    }
    return result;
  }

  /// Predicate: whether [file] belonged to the given [albumName] according to sourceDirectories.
  static bool fileBelongsToAlbum(
    final MediaEntity entity,
    final FileEntity file,
    final String albumName,
  ) {
    final albumInfo = entity.albumsMap[albumName];
    if (albumInfo == null || albumInfo.sourceDirectories.isEmpty) return false;
    final fileDir = dirOf(file.sourcePath);
    for (final src in albumInfo.sourceDirectories) {
      if (isSubPath(fileDir, src)) return true;
    }
    return false;
  }

  /// Create a symlink to [target] inside [dir] and try to rename it to [preferredBasename].
  /// On name collision, appends " (n)" before extension.
  static Future<File> createSymlinkWithPreferredName(
    final SymlinkService symlinkService,
    final Directory dir,
    final File target,
    final String preferredBasename,
  ) async {
    final File link = await symlinkService.createSymlink(dir, target);
    final String currentBase = link.uri.pathSegments.last;
    if (currentBase == preferredBasename) return link;

    final String finalBasename = _resolveUniqueBasename(dir, preferredBasename);
    final String desiredPath = path.join(dir.path, finalBasename);
    try {
      return await link.rename(desiredPath);
    } catch (_) {
      return link;
    }
  }

  static String _resolveUniqueBasename(final Directory dir, final String base) {
    final int dot = base.lastIndexOf('.');
    final String stem = dot > 0 ? base.substring(0, dot) : base;
    final String ext = dot > 0 ? base.substring(dot) : '';
    String candidate = base;
    int idx = 1;
    while (existsAny(path.join(dir.path, candidate))) {
      candidate = '$stem ($idx)$ext';
      idx++;
    }
    return candidate;
  }

  static bool existsAny(final String fullPath) {
    try {
      return File(fullPath).existsSync() ||
          Link(fullPath).existsSync() ||
          Directory(fullPath).existsSync();
    } catch (_) {
      return false;
    }
  }

  // ───────────────────────────────────────────────────────────────────────
  // Special Folders helpers (centralized):
  // - Case-insensitive match of any path segment against the predefined list.
  // - Capitalization rule: first letter uppercase, rest lowercase.
  // - Target directory: <output>/Special Folders/<CapitalizedName>
  // - One common entry point: handleSpecialFoldersForEntity(...) to keep strategies short.
  // ───────────────────────────────────────────────────────────────────────

  static bool isInSpecialFolder(final String sourcePath) =>
      matchSpecialFolderInPath(sourcePath) != null;

  static String? matchSpecialFolderInPath(final String sourcePath) {
    final String norm = sourcePath.replaceAll('\\', '/');
    final List<String> segments = norm.split('/');
    for (final seg in segments) {
      final String segLower = seg.toLowerCase();
      for (final name in specialFolders) {
        // specialFolders are defined in constant.dart module
        if (segLower == name) {
          return _capitalizeFirst(name);
        }
      }
    }
    return null;
  }

  static Directory specialFolderDir(
    final Directory outputDir,
    final String specialCapName,
  ) => Directory(path.join(outputDir.path, 'Special Folders', specialCapName));

  static String _capitalizeFirst(final String s) {
    if (s.isEmpty) return s;
    final String lower = s.toLowerCase();
    return lower[0].toUpperCase() + lower.substring(1);
  }

  /// Moves any file from the entity that lives under a Special Folder directly to output/Special Folders/<CapName>/...
  /// Returns the set of handled FileEntity and the list of MoveMediaEntityResult to be yielded by the caller.
  static Future<(Set<FileEntity>, List<MoveMediaEntityResult>)>
  handleSpecialFoldersForEntity(
    final FileOperationService fileService,
    final MovingContext context,
    final MediaEntity entity,
  ) async {
    final Set<FileEntity> handled = <FileEntity>{};
    final List<MoveMediaEntityResult> results = <MoveMediaEntityResult>[];

    // Snapshot to avoid in-loop mutations
    final List<FileEntity> files = <FileEntity>[
      entity.primaryFile,
      ...entity.secondaryFiles,
    ];

    for (final fe in files) {
      final String? specialCap = matchSpecialFolderInPath(fe.sourcePath);
      if (specialCap == null) continue;

      final Directory specialDir = specialFolderDir(
        context.outputDirectory,
        specialCap,
      );
      final sw = Stopwatch()..start();
      final File src = fe.asFile();
      try {
        final File moved = await fileService.moveFile(
          src,
          specialDir,
          dateTaken: entity.dateTaken,
        );
        sw.stop();

        fe.targetPath = moved.path;
        fe.isShortcut = false;
        fe.isMoved = true;

        handled.add(fe);

        results.add(
          MoveMediaEntityResult.success(
            operation: MoveMediaEntityOperation(
              sourceFile: src,
              targetDirectory: specialDir,
              operationType: MediaEntityOperationType.move,
              mediaEntity: entity,
            ),
            resultFile: moved,
            duration: sw.elapsed,
          ),
        );
      } catch (e) {
        final elapsed = sw.elapsed;
        results.add(
          MoveMediaEntityResult.failure(
            operation: MoveMediaEntityOperation(
              sourceFile: src,
              targetDirectory: specialDir,
              operationType: MediaEntityOperationType.move,
              mediaEntity: entity,
            ),
            errorMessage: 'Failed to move special-folder file: $e',
            duration: elapsed,
          ),
        );
      }
    }

    return (handled, results);
  }
}
