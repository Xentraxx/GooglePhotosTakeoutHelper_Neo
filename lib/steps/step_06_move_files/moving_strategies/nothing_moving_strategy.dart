// ignore_for_file: unintended_html_in_doc_comment
import 'dart:io';

import 'package:gpth_neo/gpth_lib_exports.dart';

/// Nothing strategy:
/// - Move **primary** to ALL_PHOTOS (date-structured if needed).
/// - Delete **all secondaries** from source (they will not appear in Output).
/// - After each operation: update fe.targetPath and flags (isShortcut=false; isMoved=true for moved; isDeleted=true for deleted).
class NothingMovingStrategy extends MoveMediaEntityStrategy {
  const NothingMovingStrategy(this._fileService, this._pathService);

  final FileOperationService _fileService;
  final PathGeneratorService _pathService;

  @override
  String get name => 'Nothing';

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

    // Snapshot to avoid in-loop mutations
    final FileEntity primary = entity.primaryFile;
    final List<FileEntity> secondaries = <FileEntity>[...entity.secondaryFiles];

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

    // Move primary
    if (!specialHandled.contains(primary)) {
      {
        final sw = Stopwatch()..start();
        final File src = primary.asFile();
        try {
          final moved = await _fileService.moveFile(
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
            errorMessage: 'Failed to move primary: $e',
            duration: elapsed,
          );
        }
      }
    }

    // Delete all secondaries
    for (final sec in secondaries) {
      if (specialHandled.contains(sec)) {
        continue; // skip already moved to Special Folders
      }
      final dsw = Stopwatch()..start();
      final File src = sec.asFile();
      try {
        await src.delete();
        dsw.stop();

        sec.isDeleted = true;
        sec.isShortcut = false;
        sec.targetPath = null;

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
          errorMessage: 'Failed to delete secondary: $e',
          duration: elapsed,
        );
      }
    }
  }

  @override
  void validateContext(final MovingContext context) {}
}
