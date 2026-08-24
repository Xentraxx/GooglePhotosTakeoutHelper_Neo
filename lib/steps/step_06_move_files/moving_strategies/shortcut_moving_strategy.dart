// ignore_for_file: unintended_html_in_doc_comment
import 'dart:io';

import 'package:gpth_neo/gpth_lib_exports.dart';
import 'package:path/path.dart' as path;

/// Shortcut strategy:
/// - Choose the file to move to ALL_PHOTOS:
///   - If there is any CANONICAL among primary+secondaries, choose the best-ranked CANONICAL.
///   - Otherwise, use the current primary.
/// - Move the chosen file to ALL_PHOTOS.
/// - For each album:
///   - If primary (originally NON-CANONICAL) belonged to it → create shortcut named with original primary basename.
///   - For each NON-CANONICAL secondary that belonged to it → create shortcut named with its original basename.
///   - After creating a shortcut that represents a NON-CANONICAL source file, delete the original source
///     (the representation in Output is the link), and mark that FileEntity or its synthetic clone accordingly.
/// - Flags:
///   - Moved file: isMoved=true, isShortcut=false.
///   - For represented NON-CANONICAL files by a shortcut: original deleted → isDeleted=true; shortcut entries use isShortcut=true.
class ShortcutMovingStrategy extends MoveMediaEntityStrategy {
  const ShortcutMovingStrategy(
    this._fileService,
    this._pathService,
    this._symlinkService,
  );

  final FileOperationService _fileService;
  final PathGeneratorService _pathService;
  final SymlinkService _symlinkService;

  @override
  String get name => 'Shortcut';

  @override
  bool get createsShortcuts => true;

  @override
  bool get createsDuplicates => false;

  @override
  Stream<MoveMediaEntityResult> processMediaEntity(
    final MediaEntity entity,
    final MovingContext context,
  ) async* {
    // Snapshot
    final FileEntity primary = entity.primaryFile;
    final List<FileEntity> secondaries = <FileEntity>[...entity.secondaryFiles];
    final List<FileEntity> allFiles = <FileEntity>[primary, ...secondaries];

    // Snapshot flag: primary canonicity BEFORE any move
    final bool primaryWasCanonical = primary.isCanonical == true;

    // Common special folders handling: move to Special Folders and exclude from shortcut logic
    final (
      Set<FileEntity> specialHandled,
      List<MoveMediaEntityResult> sfResults,
    ) = await MovingStrategyUtils.handleSpecialFoldersForEntity(
      _fileService,
      context,
      entity,
    );
    for (final r in sfResults) {
      yield r;
    }

    // Decide which file to move to ALL_PHOTOS (prefer best canonical if exists)
    final List<FileEntity> canonicals = allFiles
        .where(
          (final f) => f.isCanonical == true && !specialHandled.contains(f),
        )
        .toList();
    final FileEntity chosen = canonicals.isNotEmpty
        ? _chooseBestRanked(canonicals)
        : primary;

    // Move chosen file to ALL_PHOTOS
    if (!specialHandled.contains(chosen)) {
      final Directory allPhotosDir = MovingStrategyUtils.allPhotosDir(
        _pathService,
        entity,
        context,
      );

      final sw = Stopwatch()..start();
      final File src = chosen.asFile();
      File movedPrimary;
      try {
        movedPrimary = await _fileService.moveFile(
          src,
          allPhotosDir,
          dateTaken: entity.dateTaken,
        );
        sw.stop();

        chosen.targetPath = movedPrimary.path;
        chosen.isShortcut = false;
        chosen.isMoved = true;

        yield MoveMediaEntityResult.success(
          operation: MoveMediaEntityOperation(
            sourceFile: src,
            targetDirectory: allPhotosDir,
            operationType: MediaEntityOperationType.move,
            mediaEntity: entity,
          ),
          resultFile: movedPrimary,
          duration: sw.elapsed,
        );
      } catch (e) {
        final elapsed = sw.elapsed;
        yield MoveMediaEntityResult.failure(
          operation: MoveMediaEntityOperation(
            sourceFile: src,
            targetDirectory: allPhotosDir,
            operationType: MediaEntityOperationType.move,
            mediaEntity: entity,
          ),
          errorMessage: 'Failed to move primary file: $e',
          duration: elapsed,
        );
        return;
      }

      // Collect synthetic shortcut secondaries after loops
      final List<FileEntity> pendingShortcutSecondaries = <FileEntity>[];
      final MediaHashService mediaHashService = MediaHashService();

      // Per-entity, per-album registry of basenames already materialized as shortcuts
      // This avoids creating "(1)" when multiple originals share the same name.
      final Map<String, Set<String>> usedBasenamesPerAlbum =
          <String, Set<String>>{};

      // Iterate unique album names to avoid duplicate passes on the same album
      for (final albumName in {...entity.albumNames}) {
        final Directory albumDir =
            MovingStrategyUtils.albumDirConsideringUntitled(
              _pathService,
              albumName,
              entity,
              context,
            );
        final Set<String> usedHere = usedBasenamesPerAlbum.putIfAbsent(
          albumName,
          () => <String>{},
        );

        // Reuse actual links only. A regular file at this location must not be
        // reported as a shortcut: that was the cause of video entries being
        // silently retained as physical album files on a rerun.
        Future<File?> reuseIfExistingShortcut(final String desiredName) async {
          final String candidate = path.join(albumDir.path, desiredName);
          if (usedHere.contains(desiredName) || await Link(candidate).exists()) {
            return File(candidate);
          }
          return null;
        }

        // A previous interrupted run can leave a regular file in the intended
        // shortcut location. Shortcut mode must never leave physical media in
        // Albums: identical duplicates are removed and distinct files are
        // preserved outside Albums before the shortcut is created.
        Future<void> clearRegularCandidateForShortcut(
          final String desiredName,
        ) async {
          final String candidatePath = path.join(albumDir.path, desiredName);
          if (await Link(candidatePath).exists()) return;

          final File candidate = File(candidatePath);
          if (!await candidate.exists()) return;

          try {
            final String candidateHash = await mediaHashService.calculateFileHash(
              candidate,
            );
            final String canonicalHash = await mediaHashService.calculateFileHash(
              movedPrimary,
            );
            if (candidateHash == canonicalHash) {
              await candidate.delete();
              logDebug(
                '[Step 6/8] Removed stale physical album duplicate before '
                "recreating shortcut: '$candidatePath'.",
              );
            } else {
              final Directory conflictsDir = Directory(
                path.join(
                  context.outputDirectory.path,
                  'Shortcut Conflicts',
                  path.basename(albumDir.path),
                ),
              );
              final File preserved = await _fileService.moveFile(
                candidate,
                conflictsDir,
              );
              logWarning(
                '[Step 6/8] Moved conflicting physical album entry outside '
                "Albums before recreating shortcut: '$candidatePath' -> '${preserved.path}'.",
                forcePrint: true,
              );
            }
          } catch (error) {
            logWarning(
              '[Step 6/8] Could not verify existing album entry before '
              "creating shortcut '$candidatePath': $error",
              forcePrint: true,
            );
          }
        }

        // Primary shortcut if originally non-canonical and belonged to this album
        if (!primaryWasCanonical &&
            !specialHandled.contains(primary) &&
            MovingStrategyUtils.fileBelongsToAlbum(
              entity,
              primary,
              albumName,
            )) {
          final String desiredName = path.basename(primary.sourcePath);
          final ssw = Stopwatch()..start();
          try {
            // 1) Try reuse if the same basename already exists in album
            await clearRegularCandidateForShortcut(desiredName);
            final File? existing = await reuseIfExistingShortcut(desiredName);
            if (existing != null) {
              ssw.stop();

              // Represent primary's original using the already-present shortcut
              pendingShortcutSecondaries.add(
                _buildShortcutClone(primary, existing.path),
              );

              // Delete the original NON-CANONICAL primary source
              try {
                await File(primary.sourcePath).delete();
                primary.isDeleted = true;
              } catch (_) {}

              // Mark basename as used for this entity/album
              usedHere.add(desiredName);

              yield MoveMediaEntityResult.success(
                operation: MoveMediaEntityOperation(
                  sourceFile: movedPrimary,
                  targetDirectory: albumDir,
                  operationType: MediaEntityOperationType.createSymlink,
                  mediaEntity: entity,
                  albumKey: albumName,
                ),
                resultFile: existing,
                duration: ssw.elapsed,
              );
            } else {
              // 2) Create the symlink and try to rename to desiredName (will ensure uniqueness on disk)
              final File shortcut =
                  await MovingStrategyUtils.createSymlinkWithPreferredName(
                    _symlinkService,
                    albumDir,
                    movedPrimary,
                    desiredName,
                    context.hardlink,
                  );
              ssw.stop();

              pendingShortcutSecondaries.add(
                _buildShortcutClone(primary, shortcut.path),
              );

              // Delete the original NON-CANONICAL primary source
              try {
                await File(primary.sourcePath).delete();
                primary.isDeleted = true;
              } catch (_) {}

              // Record the basename actually used (after rename)
              usedHere.add(path.basename(shortcut.path));

              yield MoveMediaEntityResult.success(
                operation: MoveMediaEntityOperation(
                  sourceFile: movedPrimary,
                  targetDirectory: albumDir,
                  operationType: MediaEntityOperationType.createSymlink,
                  mediaEntity: entity,
                  albumKey: albumName,
                ),
                resultFile: shortcut,
                duration: ssw.elapsed,
              );
            }
          } catch (e) {
            final elapsed = ssw.elapsed;
            yield MoveMediaEntityResult.failure(
              operation: MoveMediaEntityOperation(
                sourceFile: movedPrimary,
                targetDirectory: albumDir,
                operationType: MediaEntityOperationType.createSymlink,
                mediaEntity: entity,
                albumKey: albumName,
              ),
              errorMessage:
                  'Failed to create album shortcut for non-canonical primary: $e',
              duration: elapsed,
            );
          }
        }

        // Shortcuts for NON-CANONICAL secondaries that belonged to this album
        for (final sec in secondaries) {
          if (specialHandled.contains(sec)) continue; // skip Special Folders
          if (sec.isCanonical == true) continue;
          if (!MovingStrategyUtils.fileBelongsToAlbum(entity, sec, albumName)) {
            continue;
          }
          final String desiredName = path.basename(sec.sourcePath);
          final ssw = Stopwatch()..start();
          try {
            // First, reuse if an identical basename already exists here
            await clearRegularCandidateForShortcut(desiredName);
            final File? existing = await reuseIfExistingShortcut(desiredName);
            if (existing != null) {
              ssw.stop();

              if (sec.targetPath == null) {
                sec.targetPath = existing.path;
                sec.isShortcut = true;
              } else {
                pendingShortcutSecondaries.add(
                  _buildShortcutClone(sec, existing.path),
                );
              }

              // Delete the original NON-CANONICAL secondary source
              try {
                await File(sec.sourcePath).delete();
                sec.isDeleted = true;
              } catch (_) {}

              usedHere.add(desiredName);

              yield MoveMediaEntityResult.success(
                operation: MoveMediaEntityOperation(
                  sourceFile: movedPrimary,
                  targetDirectory: albumDir,
                  operationType: MediaEntityOperationType.createSymlink,
                  mediaEntity: entity,
                  albumKey: albumName,
                ),
                resultFile: existing,
                duration: ssw.elapsed,
              );
            } else {
              // Otherwise, create a new symlink with the preferred name
              final File shortcut =
                  await MovingStrategyUtils.createSymlinkWithPreferredName(
                    _symlinkService,
                    albumDir,
                    movedPrimary,
                    desiredName,
                    context.hardlink,
                  );
              ssw.stop();

              if (sec.targetPath == null) {
                sec.targetPath = shortcut.path;
                sec.isShortcut = true;
              } else {
                pendingShortcutSecondaries.add(
                  _buildShortcutClone(sec, shortcut.path),
                );
              }

              // Delete the original NON-CANONICAL secondary source
              try {
                await File(sec.sourcePath).delete();
                sec.isDeleted = true;
              } catch (_) {}

              usedHere.add(path.basename(shortcut.path));

              yield MoveMediaEntityResult.success(
                operation: MoveMediaEntityOperation(
                  sourceFile: movedPrimary,
                  targetDirectory: albumDir,
                  operationType: MediaEntityOperationType.createSymlink,
                  mediaEntity: entity,
                  albumKey: albumName,
                ),
                resultFile: shortcut,
                duration: ssw.elapsed,
              );
            }
          } catch (e) {
            final elapsed = ssw.elapsed;
            yield MoveMediaEntityResult.failure(
              operation: MoveMediaEntityOperation(
                sourceFile: movedPrimary,
                targetDirectory: albumDir,
                operationType: MediaEntityOperationType.createSymlink,
                mediaEntity: entity,
                albumKey: albumName,
              ),
              errorMessage: 'Failed to create secondary shortcut: $e',
              duration: elapsed,
            );
          }
        }

        // Issue #133 fallback: album memberships recovered from orphaned JSON
        // sidecars have no physical file inside the album folder, so neither
        // of the blocks above created a shortcut. Represent the membership
        // with a shortcut to the moved primary. Memberships that had a
        // physical file (canonical or not) in the album folder keep their
        // original handling.
        final bool albumHasPhysicalFile = allFiles.any(
          (final f) =>
              MovingStrategyUtils.fileBelongsToAlbum(entity, f, albumName),
        );
        if (!albumHasPhysicalFile) {
          final String desiredName = path.basename(movedPrimary.path);
          final ssw = Stopwatch()..start();
          try {
            await clearRegularCandidateForShortcut(desiredName);
            final File? existing = await reuseIfExistingShortcut(desiredName);
            final File shortcut =
                existing ??
                await MovingStrategyUtils.createSymlinkWithPreferredName(
                  _symlinkService,
                  albumDir,
                  movedPrimary,
                  desiredName,
                  context.hardlink,
                );
            ssw.stop();

            pendingShortcutSecondaries.add(
              _buildShortcutClone(chosen, shortcut.path),
            );
            usedHere.add(path.basename(shortcut.path));

            yield MoveMediaEntityResult.success(
              operation: MoveMediaEntityOperation(
                sourceFile: movedPrimary,
                targetDirectory: albumDir,
                operationType: MediaEntityOperationType.createSymlink,
                mediaEntity: entity,
                albumKey: albumName,
              ),
              resultFile: shortcut,
              duration: ssw.elapsed,
            );
          } catch (e) {
            final elapsed = ssw.elapsed;
            yield MoveMediaEntityResult.failure(
              operation: MoveMediaEntityOperation(
                sourceFile: movedPrimary,
                targetDirectory: albumDir,
                operationType: MediaEntityOperationType.createSymlink,
                mediaEntity: entity,
                albumKey: albumName,
              ),
              errorMessage:
                  'Failed to create album shortcut for recovered album membership: $e',
              duration: elapsed,
            );
          }
        }
      }

      if (pendingShortcutSecondaries.isNotEmpty) {
        entity.secondaryFiles.addAll(pendingShortcutSecondaries);
      }
    }
  }

  @override
  void validateContext(final MovingContext context) {}

  FileEntity _buildShortcutClone(
    final FileEntity src,
    final String shortcutPath,
  ) => FileEntity(
    sourcePath: src.sourcePath,
    targetPath: shortcutPath,
    isShortcut: true,
    dateAccuracy: src.dateAccuracy,
    ranking: src.ranking,
  );

  FileEntity _chooseBestRanked(final List<FileEntity> files) {
    files.sort((final a, final b) {
      final ra = a.ranking;
      final rb = b.ranking;
      final cmp = ra.compareTo(rb); // lower is better
      if (cmp != 0) return cmp;

      final ba = path.basename(a.path).length;
      final bb = path.basename(b.path).length;
      if (ba != bb) return ba.compareTo(bb);

      return a.path.length.compareTo(b.path.length);
    });
    return files.first;
  }
}
