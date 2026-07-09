// ignore_for_file: unintended_html_in_doc_comment
import 'dart:io';

import 'package:gpth_neo/gpth_lib_exports.dart';
import 'package:path/path.dart' as path;

/// Reverse-Shortcut strategy:
/// - Move all NON-CANONICAL files (primary and secondaries) physically into Albums/<Album>.
/// - Choose the best-ranked NON-CANONICAL (among the moved ones) as the "anchor".
/// - For each CANONICAL file (including canonical primary if any), create a shortcut in ALL_PHOTOS pointing to the anchor,
///   then delete the original canonical source (its representation in Output becomes the shortcut).
/// - If there are NO NON-CANONICAL files at all, move the canonical primary to ALL_PHOTOS (fallback).
/// - Flags are updated as: moved.isMoved=true; represented-by-shortcut.isShortcut=true and originals deleted (isDeleted=true).
class ReverseShortcutMovingStrategy extends MoveMediaEntityStrategy {
  const ReverseShortcutMovingStrategy(
    this._fileService,
    this._pathService,
    this._symlinkService,
  );

  final FileOperationService _fileService;
  final PathGeneratorService _pathService;
  final SymlinkService _symlinkService;

  @override
  String get name => 'Reverse Shortcut';

  @override
  bool get createsShortcuts => true;

  @override
  bool get createsDuplicates => false;

  @override
  Stream<MoveMediaEntityResult> processMediaEntity(
    final MediaEntity entity,
    final MovingContext context,
  ) async* {
    final FileEntity primary = entity.primaryFile;
    final List<FileEntity> secondaries = <FileEntity>[...entity.secondaryFiles];
    final List<FileEntity> allFiles = <FileEntity>[primary, ...secondaries];

    // Snapshot canonicity BEFORE any move
    final Map<FileEntity, bool> wasCanonical = {
      for (final f in allFiles) f: f.isCanonical == true,
    };

    final List<FileEntity> nonCanonicals = allFiles
        .where((final f) => f.isCanonical != true)
        .toList();

    // Common special folders handling: move to Special Folders and exclude from further logic
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

    final List<FileEntity> nonCanonicalsUsable = nonCanonicals
        .where((final f) => !specialHandled.contains(f))
        .toList();

    if (nonCanonicalsUsable.isNotEmpty) {
      // Move every NON-CANONICAL to its album (deterministic choice per file)
      final Map<FileEntity, File> movedMap = <FileEntity, File>{};

      for (final fe in nonCanonicalsUsable) {
        final List<String> albumsForThisFile =
            MovingStrategyUtils.albumsForFile(entity, fe);
        final String primaryAlbum = albumsForThisFile.isNotEmpty
            ? albumsForThisFile.first
            : (entity.albumNames.isNotEmpty
                  ? entity.albumNames.first
                  : 'Unknown Album');

        final Directory albumDir =
            MovingStrategyUtils.albumDirConsideringUntitled(
              _pathService,
              primaryAlbum,
              entity,
              context,
            );

        final sw = Stopwatch()..start();
        final File src = fe.asFile();
        try {
          final File m = await _fileService.moveFile(
            src,
            albumDir,
            dateTaken: entity.dateTaken,
          );
          sw.stop();

          fe.targetPath = m.path;
          fe.isShortcut = false;
          fe.isMoved = true;

          movedMap[fe] = m;

          yield MoveMediaEntityResult.success(
            operation: MoveMediaEntityOperation(
              sourceFile: src,
              targetDirectory: albumDir,
              operationType: MediaEntityOperationType.move,
              mediaEntity: entity,
              albumKey: primaryAlbum,
            ),
            resultFile: m,
            duration: sw.elapsed,
          );
        } catch (e) {
          final elapsed = sw.elapsed;
          yield MoveMediaEntityResult.failure(
            operation: MoveMediaEntityOperation(
              sourceFile: src,
              targetDirectory: albumDir,
              operationType: MediaEntityOperationType.move,
              mediaEntity: entity,
              albumKey: primaryAlbum,
            ),
            errorMessage: 'Failed to move non-canonical file: $e',
            duration: elapsed,
          );
        }
      }

      // Choose anchor: best-ranked among NON-CANONICAL moved
      final FileEntity anchor = _chooseBestRanked(nonCanonicalsUsable);
      final File? anchorMoved = movedMap[anchor];
      if (anchorMoved == null) {
        // Fallback: if nothing moved, do nothing more
        return;
      }

      // For each CANONICAL (pre-move), create shortcut in ALL_PHOTOS pointing to anchor and delete original
      final Directory allPhotosDir = MovingStrategyUtils.allPhotosDir(
        _pathService,
        entity,
        context,
      );

      // Per-entity registry of basenames already materialized in ALL_PHOTOS
      // This prevents producing "(1)" when multiple canonical files map to the same desired name.
      final Set<String> usedBasenamesAllPhotos = <String>{};

      for (final fe in allFiles) {
        if (specialHandled.contains(fe)) continue; // skip Special Folders
        if (wasCanonical[fe] != true) continue;

        final String desiredName = path.basename(fe.sourcePath);
        final String desiredPath = path.join(allPhotosDir.path, desiredName);

        final ssw = Stopwatch()..start();
        try {
          // Try reuse if a link/file with the desired basename already exists in ALL_PHOTOS
          if (usedBasenamesAllPhotos.contains(desiredName) ||
              MovingStrategyUtils.existsAny(desiredPath)) {
            ssw.stop();

            // Represent this canonical via the existing shortcut (synthetic entry)
            entity.secondaryFiles.add(
              FileEntity(
                sourcePath: fe.sourcePath,
                targetPath: desiredPath,
                isShortcut: true,
                dateAccuracy: fe.dateAccuracy,
                ranking: fe.ranking,
              ),
            );

            // Delete original canonical source
            try {
              await File(fe.sourcePath).delete();
              fe.isDeleted = true;
            } catch (_) {}

            usedBasenamesAllPhotos.add(desiredName);

            yield MoveMediaEntityResult.success(
              operation: MoveMediaEntityOperation(
                sourceFile: anchorMoved,
                targetDirectory: allPhotosDir,
                operationType: MediaEntityOperationType.createReverseSymlink,
                mediaEntity: entity,
              ),
              resultFile: File(desiredPath),
              duration: ssw.elapsed,
            );
          } else {
            // Otherwise create a symlink and try to rename it to the preferred basename
            final File shortcut =
                await MovingStrategyUtils.createSymlinkWithPreferredName(
                  _symlinkService,
                  allPhotosDir,
                  anchorMoved,
                  desiredName,
                  context.hardlink,
                );
            ssw.stop();

            entity.secondaryFiles.add(
              FileEntity(
                sourcePath: fe.sourcePath,
                targetPath: shortcut.path,
                isShortcut: true,
                dateAccuracy: fe.dateAccuracy,
                ranking: fe.ranking,
              ),
            );

            // Delete original canonical source
            try {
              await File(fe.sourcePath).delete();
              fe.isDeleted = true;
            } catch (_) {}

            usedBasenamesAllPhotos.add(path.basename(shortcut.path));

            yield MoveMediaEntityResult.success(
              operation: MoveMediaEntityOperation(
                sourceFile: anchorMoved,
                targetDirectory: allPhotosDir,
                operationType: MediaEntityOperationType.createReverseSymlink,
                mediaEntity: entity,
              ),
              resultFile: shortcut,
              duration: ssw.elapsed,
            );
          }
        } catch (e) {
          final elapsed = ssw.elapsed;
          yield MoveMediaEntityResult.failure(
            operation: MoveMediaEntityOperation(
              sourceFile: anchorMoved,
              targetDirectory: allPhotosDir,
              operationType: MediaEntityOperationType.createReverseSymlink,
              mediaEntity: entity,
            ),
            errorMessage: 'Failed to create reverse shortcut: $e',
            duration: elapsed,
          );
        }
      }

      // Issue #133 fallback: album memberships without any physical file in
      // the album folder (recovered from orphaned JSON sidecars) — represent
      // them with a shortcut in the album pointing to the anchor.
      for (final albumName in entity.albumNames) {
        final bool albumHasPhysicalFile = allFiles.any(
          (final f) =>
              MovingStrategyUtils.fileBelongsToAlbum(entity, f, albumName),
        );
        if (albumHasPhysicalFile) continue;

        yield* _createAlbumShortcutToMovedFile(
          entity,
          context,
          albumName,
          anchorMoved,
          anchor,
        );
      }
    } else {
      // No NON-CANONICALS → move canonical primary to ALL_PHOTOS
      if (!MovingStrategyUtils.isInSpecialFolder(primary.sourcePath)) {
        final Directory allPhotosDir = MovingStrategyUtils.allPhotosDir(
          _pathService,
          entity,
          context,
        );

        final sw = Stopwatch()..start();
        final File src = primary.asFile();
        File? moved;
        try {
          moved = await _fileService.moveFile(
            src,
            allPhotosDir,
            dateTaken: entity.dateTaken,
          );
          sw.stop();

          primary.targetPath = moved.path;
          primary.isShortcut = false;
          primary.isMoved = true;

          yield MoveMediaEntityResult.success(
            operation: MoveMediaEntityOperation(
              sourceFile: src,
              targetDirectory: allPhotosDir,
              operationType: MediaEntityOperationType.move,
              mediaEntity: entity,
            ),
            resultFile: moved,
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
            errorMessage: 'Failed to move canonical primary: $e',
            duration: elapsed,
          );
        }

        // Issue #133 fallback: album memberships recovered from orphaned JSON
        // sidecars (no physical file in the album folder) — represent them
        // with a shortcut in the album pointing to the moved primary.
        if (moved != null) {
          for (final albumName in entity.albumNames) {
            final bool albumHasPhysicalFile = allFiles.any(
              (final f) =>
                  MovingStrategyUtils.fileBelongsToAlbum(entity, f, albumName),
            );
            if (albumHasPhysicalFile) continue;

            yield* _createAlbumShortcutToMovedFile(
              entity,
              context,
              albumName,
              moved,
              primary,
            );
          }
        }
      }
      // else: primary was already handled as Special Folder
    }
  }

  /// Creates a shortcut inside Albums/<albumName> pointing to [movedFile]
  /// and records it as a synthetic secondary on the entity (issue #133).
  Stream<MoveMediaEntityResult> _createAlbumShortcutToMovedFile(
    final MediaEntity entity,
    final MovingContext context,
    final String albumName,
    final File movedFile,
    final FileEntity representedFile,
  ) async* {
    final Directory albumDir = MovingStrategyUtils.albumDirConsideringUntitled(
      _pathService,
      albumName,
      entity,
      context,
    );
    final String desiredName = path.basename(movedFile.path);

    final ssw = Stopwatch()..start();
    try {
      final String candidatePath = path.join(albumDir.path, desiredName);
      final File shortcut = MovingStrategyUtils.existsAny(candidatePath)
          ? File(candidatePath)
          : await MovingStrategyUtils.createSymlinkWithPreferredName(
              _symlinkService,
              albumDir,
              movedFile,
              desiredName,
              context.hardlink,
            );
      ssw.stop();

      entity.secondaryFiles.add(
        FileEntity(
          sourcePath: representedFile.sourcePath,
          targetPath: shortcut.path,
          isShortcut: true,
          dateAccuracy: representedFile.dateAccuracy,
          ranking: representedFile.ranking,
        ),
      );

      yield MoveMediaEntityResult.success(
        operation: MoveMediaEntityOperation(
          sourceFile: movedFile,
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
          sourceFile: movedFile,
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

  @override
  void validateContext(final MovingContext context) {}

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
