// ignore_for_file: unintended_html_in_doc_comment
import 'dart:io';

import 'package:gpth_neo/gpth_lib_exports.dart';
import 'package:path/path.dart' as path;

/// Duplicate-Copy strategy:
/// - If there is ANY CANONICAL file in the entity:
///   - Move CANONICAL files to ALL_PHOTOS (no album copies for canonicals).
///   - Move NON-CANONICAL files to one album they belonged to; copy to other albums they belonged to.
///   - Do NOT create copies in ALL_PHOTOS for NON-CANONICAL files.
/// - If there are NO CANONICAL files in the entity:
///   - Choose the best-ranked NON-CANONICAL and create ONE duplicate copy in ALL_PHOTOS
///     as a new synthetic secondary with `isDuplicateCopy=true` and `isMoved=false`.
///   - Move originals to their primary album and copy to other albums they belonged to.
/// - Always update targetPath and flags accordingly.
class DuplicateCopyMovingStrategy extends MoveMediaEntityStrategy {
  const DuplicateCopyMovingStrategy(this._fileService, this._pathService);

  final FileOperationService _fileService;
  final PathGeneratorService _pathService;

  @override
  String get name => 'Duplicate Copy';

  @override
  bool get createsShortcuts => false;

  @override
  bool get createsDuplicates => true;

  @override
  Stream<MoveMediaEntityResult> processMediaEntity(
    final MediaEntity entity,
    final MovingContext context,
  ) async* {
    final Directory allPhotosDir = MovingStrategyUtils.allPhotosDir(
      _pathService,
      entity,
      context,
    );
    final FileEntity primary = entity.primaryFile;
    final List<FileEntity> secondaries = <FileEntity>[...entity.secondaryFiles];
    final List<FileEntity> allFiles = <FileEntity>[primary, ...secondaries];

    final bool hasCanonical = allFiles.any((final f) => f.isCanonical == true);

    // Common special folders handling: move to Special Folders and exclude from copies/duplicates logic
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

    // Helper: move a file to a target dir
    Future<(File?, Duration)> moveWithTiming(
      final File src,
      final Directory dest,
    ) async {
      final sw = Stopwatch()..start();
      try {
        final moved = await _fileService.moveFile(
          src,
          dest,
          dateTaken: entity.dateTaken,
        );
        sw.stop();
        return (moved, sw.elapsed);
      } catch (_) {
        final elapsed = sw.elapsed;
        return (null, elapsed);
      }
    }

    // Helper: copy a file to a target dir
    Future<(File?, Duration)> copyWithTiming(
      final File src,
      final Directory dest,
    ) async {
      final sw = Stopwatch()..start();
      try {
        final copied = await _fileService.copyFile(
          src,
          dest,
          dateTaken: entity.dateTaken,
        );
        sw.stop();
        return (copied, sw.elapsed);
      } catch (_) {
        final elapsed = sw.elapsed;
        return (null, elapsed);
      }
    }

    // Case A: There is at least one canonical in the entity
    if (hasCanonical) {
      // Move canonicals to ALL_PHOTOS
      for (final fe in allFiles.where((final f) => f.isCanonical == true)) {
        if (specialHandled.contains(fe)) continue; // skip Special Folders
        final File src = fe.asFile();
        final (File? moved, Duration elapsed) = await moveWithTiming(
          src,
          allPhotosDir,
        );
        if (moved != null) {
          fe.targetPath = moved.path;
          fe.isShortcut = false;
          fe.isMoved = true;

          yield MoveMediaEntityResult.success(
            operation: MoveMediaEntityOperation(
              sourceFile: src,
              targetDirectory: allPhotosDir,
              operationType: MediaEntityOperationType.move,
              mediaEntity: entity,
            ),
            resultFile: moved,
            duration: elapsed,
          );
        } else {
          yield MoveMediaEntityResult.failure(
            operation: MoveMediaEntityOperation(
              sourceFile: src,
              targetDirectory: allPhotosDir,
              operationType: MediaEntityOperationType.move,
              mediaEntity: entity,
            ),
            errorMessage: 'Failed to move canonical file',
            duration: elapsed,
          );
        }
      }

      // For NON-CANONICALS: move to primary album and copy to the rest
      for (final fe in allFiles.where((final f) => f.isCanonical != true)) {
        if (specialHandled.contains(fe)) continue; // skip Special Folders
        final List<String> albumsForThisFile =
            MovingStrategyUtils.albumsForFile(entity, fe);
        final String primaryAlbum = albumsForThisFile.isNotEmpty
            ? albumsForThisFile.first
            : (entity.albumNames.isNotEmpty
                  ? entity.albumNames.first
                  : 'Unknown Album');

        // Move original to primary album
        final Directory primaryAlbumDir =
            MovingStrategyUtils.albumDirConsideringUntitled(
              _pathService,
              primaryAlbum,
              entity,
              context,
            );
        final File srcMove = fe.asFile();
        final (File? movedToAlbum, Duration moveElapsed) = await moveWithTiming(
          srcMove,
          primaryAlbumDir,
        );
        if (movedToAlbum != null) {
          fe.targetPath = movedToAlbum.path;
          fe.isShortcut = false;
          fe.isMoved = true;

          yield MoveMediaEntityResult.success(
            operation: MoveMediaEntityOperation(
              sourceFile: srcMove,
              targetDirectory: primaryAlbumDir,
              operationType: MediaEntityOperationType.move,
              mediaEntity: entity,
              albumKey: primaryAlbum,
            ),
            resultFile: movedToAlbum,
            duration: moveElapsed,
          );
        } else {
          yield MoveMediaEntityResult.failure(
            operation: MoveMediaEntityOperation(
              sourceFile: srcMove,
              targetDirectory: primaryAlbumDir,
              operationType: MediaEntityOperationType.move,
              mediaEntity: entity,
              albumKey: primaryAlbum,
            ),
            errorMessage: 'Failed to move non-canonical file to album',
            duration: moveElapsed,
          );
          continue;
        }

        // Copy to remaining albums
        for (final albumName in albumsForThisFile.skip(1)) {
          final Directory albumDir =
              MovingStrategyUtils.albumDirConsideringUntitled(
                _pathService,
                albumName,
                entity,
                context,
              );
          final (File? copied, Duration copyElapsed) = await copyWithTiming(
            movedToAlbum,
            albumDir,
          );
          if (copied != null) {
            yield MoveMediaEntityResult.success(
              operation: MoveMediaEntityOperation(
                sourceFile: movedToAlbum,
                targetDirectory: albumDir,
                operationType: MediaEntityOperationType.copy,
                mediaEntity: entity,
                albumKey: albumName,
              ),
              resultFile: copied,
              duration: copyElapsed,
            );
          } else {
            yield MoveMediaEntityResult.failure(
              operation: MoveMediaEntityOperation(
                sourceFile: movedToAlbum,
                targetDirectory: albumDir,
                operationType: MediaEntityOperationType.copy,
                mediaEntity: entity,
                albumKey: albumName,
              ),
              errorMessage: 'Failed to copy non-canonical file to album',
              duration: copyElapsed,
            );
          }
        }
      }

      return;
    }

    // Case B: No canonicals → create ONE duplicate copy in ALL_PHOTOS from the best-ranked NON-CANONICAL
    final List<FileEntity> nonCanonicals = allFiles
        .where(
          (final f) => f.isCanonical != true && !specialHandled.contains(f),
        )
        .toList();
    if (nonCanonicals.isEmpty) return;

    final FileEntity best = _chooseBestRanked(nonCanonicals);
    final File srcBest = best.asFile();
    final (File? copiedToAll, Duration copyElapsed) = await copyWithTiming(
      srcBest,
      allPhotosDir,
    );
    if (copiedToAll != null) {
      // Synthetic secondary representing the duplicate copy in ALL_PHOTOS
      entity.secondaryFiles.add(
        FileEntity(
          sourcePath: best.sourcePath,
          targetPath: copiedToAll.path,
          dateAccuracy: best.dateAccuracy,
          ranking: best.ranking,
        )..isDuplicateCopy = true, // mark duplicate copy
      );

      yield MoveMediaEntityResult.success(
        operation: MoveMediaEntityOperation(
          sourceFile: srcBest,
          targetDirectory: allPhotosDir,
          operationType: MediaEntityOperationType.copy,
          mediaEntity: entity,
        ),
        resultFile: copiedToAll,
        duration: copyElapsed,
      );
    } else {
      yield MoveMediaEntityResult.failure(
        operation: MoveMediaEntityOperation(
          sourceFile: srcBest,
          targetDirectory: allPhotosDir,
          operationType: MediaEntityOperationType.copy,
          mediaEntity: entity,
        ),
        errorMessage: 'Failed to create duplicate copy in ALL_PHOTOS',
        duration: copyElapsed,
      );
    }

    // Move each NON-CANONICAL original to its primary album and copy to other albums
    for (final fe in nonCanonicals) {
      final List<String> albumsForThisFile = MovingStrategyUtils.albumsForFile(
        entity,
        fe,
      );
      final String primaryAlbum = albumsForThisFile.isNotEmpty
          ? albumsForThisFile.first
          : (entity.albumNames.isNotEmpty
                ? entity.albumNames.first
                : 'Unknown Album');

      // Move original to primary album
      final Directory primaryAlbumDir =
          MovingStrategyUtils.albumDirConsideringUntitled(
            _pathService,
            primaryAlbum,
            entity,
            context,
          );
      final File srcMove = fe.asFile();
      final (File? movedToAlbum, Duration moveElapsed) = await moveWithTiming(
        srcMove,
        primaryAlbumDir,
      );
      if (movedToAlbum != null) {
        fe.targetPath = movedToAlbum.path;
        fe.isShortcut = false;
        fe.isMoved = true;

        yield MoveMediaEntityResult.success(
          operation: MoveMediaEntityOperation(
            sourceFile: srcMove,
            targetDirectory: primaryAlbumDir,
            operationType: MediaEntityOperationType.move,
            mediaEntity: entity,
            albumKey: primaryAlbum,
          ),
          resultFile: movedToAlbum,
          duration: moveElapsed,
        );
      } else {
        yield MoveMediaEntityResult.failure(
          operation: MoveMediaEntityOperation(
            sourceFile: srcMove,
            targetDirectory: primaryAlbumDir,
            operationType: MediaEntityOperationType.move,
            mediaEntity: entity,
            albumKey: primaryAlbum,
          ),
          errorMessage: 'Failed to move non-canonical file to album',
          duration: moveElapsed,
        );
        continue;
      }

      // Copy to remaining albums
      for (final albumName in albumsForThisFile.skip(1)) {
        final Directory albumDir =
            MovingStrategyUtils.albumDirConsideringUntitled(
              _pathService,
              albumName,
              entity,
              context,
            );
        final (File? copied, Duration copyElapsed2) = await copyWithTiming(
          movedToAlbum,
          albumDir,
        );
        if (copied != null) {
          yield MoveMediaEntityResult.success(
            operation: MoveMediaEntityOperation(
              sourceFile: movedToAlbum,
              targetDirectory: albumDir,
              operationType: MediaEntityOperationType.copy,
              mediaEntity: entity,
              albumKey: albumName,
            ),
            resultFile: copied,
            duration: copyElapsed2,
          );
        } else {
          yield MoveMediaEntityResult.failure(
            operation: MoveMediaEntityOperation(
              sourceFile: movedToAlbum,
              targetDirectory: albumDir,
              operationType: MediaEntityOperationType.copy,
              mediaEntity: entity,
              albumKey: albumName,
            ),
            errorMessage: 'Failed to copy non-canonical file to album',
            duration: copyElapsed2,
          );
        }
      }
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
