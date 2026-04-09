// ignore_for_file: unintended_html_in_doc_comment
import 'dart:io';

import 'package:gpth_neo/gpth_lib_exports.dart';

/// Ignore-Albums strategy:
/// - Move only CANONICAL files (primary + secondaries that are canonical) to ALL_PHOTOS (date-structured if needed).
/// - Delete all NON-CANONICAL files from source (they will not appear in Output in any form).
/// - After each operation: update fe.targetPath (for moved), fe.isShortcut=false, fe.isMoved=true on moves,
///   and fe.isDeleted=true on deletions.
/// - Uses a snapshot of primary and secondaries to avoid in-loop modifications side effects.
class IgnoreAlbumsMovingStrategy extends MoveMediaEntityStrategy {
  const IgnoreAlbumsMovingStrategy(this._fileService, this._pathService);

  final FileOperationService _fileService;
  final PathGeneratorService _pathService;

  @override
  String get name => 'Ignore Albums';

  @override
  bool get createsShortcuts => false;

  @override
  bool get createsDuplicates => false;

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

    // Snapshot of the files to respect the "immutable getters" idea
    final List<FileEntity> files = <FileEntity>[
      entity.primaryFile,
      ...entity.secondaryFiles,
    ];

    // Common special folders handling (moved to utils): move to output/Special Folders and exclude from further logic
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

    for (final fe in files) {
      if (specialHandled.contains(fe)) {
        continue; // skip already handled as Special Folder
      }
      if (fe.isCanonical == true) {
        final sw = Stopwatch()..start();
        final File src = fe.asFile();
        try {
          final moved = await _fileService.moveFile(
            src,
            allPhotosDir,
            dateTaken: entity.dateTaken,
          );
          sw.stop();

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
            errorMessage: 'Failed to move canonical file: $e',
            duration: elapsed,
          );
        }
      } else {
        // Non-canonical → delete from source
        final dsw = Stopwatch()..start();
        final File src = fe.asFile();
        try {
          // If you have a delete method on _fileService, replace with that.
          await src.delete();
          dsw.stop();

          fe.isDeleted = true;
          fe.isShortcut = false;
          fe.targetPath = null;

          yield MoveMediaEntityResult.success(
            operation: MoveMediaEntityOperation(
              sourceFile: src,
              targetDirectory: Directory(MovingStrategyUtils.dirOf(src.path)),
              operationType: MediaEntityOperationType.delete,
              mediaEntity: entity,
            ),
            resultFile: src,
            duration: dsw.elapsed,
          );
        } catch (e) {
          final elapsed = dsw.elapsed;
          yield MoveMediaEntityResult.failure(
            operation: MoveMediaEntityOperation(
              sourceFile: src,
              targetDirectory: Directory(MovingStrategyUtils.dirOf(src.path)),
              operationType: MediaEntityOperationType.delete,
              mediaEntity: entity,
            ),
            errorMessage: 'Failed to delete non-canonical file: $e',
            duration: elapsed,
          );
        }
      }
    }
  }

  @override
  void validateContext(final MovingContext context) {}
}
