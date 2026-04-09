// ignore_for_file: unintended_html_in_doc_comment
import 'dart:convert';
import 'dart:io';

import 'package:gpth_neo/gpth_lib_exports.dart';
import 'package:path/path.dart' as path;

/// JSON strategy:
/// - Move **primary** to ALL_PHOTOS.
/// - For each album:
///   - If the primary was originally NON-CANONICAL and belonged to that album, add a JSON entry for it.
///   - For each NON-CANONICAL secondary that belonged to that album, add a JSON entry.
/// - After JSON recording:
///   - Delete **all secondaries** from source (CANONICAL secondaries are deleted without JSON entry).
/// - JSON fields (all relative paths use forward slashes):
///   {
///     "albums": {
///       "<albumName>": [
///         {
///           "albumName": "<album>",
///           "albumPath": "Albums/<Album>",                 // relative to output
///           "fileName": "<originalBaseName>",
///           "filePath": "Albums/<Album>/<originalBase>",   // relative to output (intended album path for original name)
///           "targetPath": "All Photos/.../<movedPrimary>"  // relative to output, final target of moved primary
///         },
///         ...
///       ]
///     },
///     "metadata": { ... }
///   }
class JsonMovingStrategy extends MoveMediaEntityStrategy {
  JsonMovingStrategy(this._fileService, this._pathService);

  final FileOperationService _fileService;
  final PathGeneratorService _pathService;

  // albumName -> list of entries
  final Map<String, List<Map<String, String>>> _albumInfo = {};

  @override
  String get name => 'JSON';

  @override
  bool get createsShortcuts => false;

  @override
  bool get createsDuplicates => false;

  @override
  Stream<MoveMediaEntityResult> processMediaEntity(
    final MediaEntity entity,
    final MovingContext context,
  ) async* {
    final Directory outDir = context.outputDirectory;
    final Directory allPhotosDir = MovingStrategyUtils.allPhotosDir(
      _pathService,
      entity,
      context,
    );

    // Snapshot
    final FileEntity primary = entity.primaryFile;
    final List<FileEntity> secondaries = <FileEntity>[...entity.secondaryFiles];

    final bool primaryWasCanonical = primary.isCanonical == true;

    // Common special folders handling: move to Special Folders and exclude from JSON logic
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

    // Move primary to ALL_PHOTOS
    if (!specialHandled.contains(primary)) {
      final sw = Stopwatch()..start();
      final File src = primary.asFile();
      File movedPrimary;
      try {
        movedPrimary = await _fileService.moveFile(
          src,
          allPhotosDir,
          dateTaken: entity.dateTaken,
        );
        sw.stop();

        primary.targetPath = movedPrimary.path;
        primary.isShortcut = false;
        primary.isMoved = true;

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
          errorMessage: 'Failed to move primary: $e',
          duration: elapsed,
        );
        return;
      }

      final String primaryRel = path
          .relative(movedPrimary.path, from: outDir.path)
          .replaceAll('\\', '/');

      // Build JSON entries per album
      for (final albumName in entity.albumNames) {
        final Directory albumDir =
            MovingStrategyUtils.albumDirConsideringUntitled(
              _pathService,
              albumName,
              entity,
              context,
            );
        final String albumRel = path
            .relative(albumDir.path, from: outDir.path)
            .replaceAll('\\', '/');

        // Primary entry if it was originally non-canonical and belonged to this album
        if (!primaryWasCanonical &&
            MovingStrategyUtils.fileBelongsToAlbum(
              entity,
              primary,
              albumName,
            )) {
          final String originalBase = path.basename(primary.sourcePath);
          final String albumPathWithFile = '$albumRel/$originalBase';
          (_albumInfo[albumName] ??= <Map<String, String>>[]).add({
            'albumName': albumName,
            'albumPath': albumRel,
            'fileName': originalBase,
            'filePath': albumPathWithFile,
            'targetPath': primaryRel,
          });
        }

        // Secondary entries: only NON-CANONICAL that belonged to this album
        for (final sec in secondaries) {
          if (specialHandled.contains(sec)) {
            continue; // do not include Special Folder files
          }
          if (sec.isCanonical == true) continue;
          if (!MovingStrategyUtils.fileBelongsToAlbum(entity, sec, albumName)) {
            continue;
          }
          final String secBase = path.basename(sec.sourcePath);
          final String albumPathWithFile = '$albumRel/$secBase';
          (_albumInfo[albumName] ??= <Map<String, String>>[]).add({
            'albumName': albumName,
            'albumPath': albumRel,
            'fileName': secBase,
            'filePath': albumPathWithFile,
            'targetPath': primaryRel,
          });
        }
      }
    }

    // Delete all secondaries from source (CANONICAL: no JSON entry; NON-CANONICAL: entry already recorded above)
    for (final sec in secondaries) {
      if (specialHandled.contains(sec)) {
        continue; // already moved to Special Folders
      }
      final dsw = Stopwatch()..start();
      final File srcSec = sec.asFile();
      try {
        await srcSec.delete();
        dsw.stop();

        sec.isDeleted = true;
        sec.isShortcut = false;
        sec.targetPath = null;

        yield MoveMediaEntityResult.success(
          operation: MoveMediaEntityOperation(
            sourceFile: srcSec,
            targetDirectory: Directory(MovingStrategyUtils.dirOf(srcSec.path)),
            operationType: MediaEntityOperationType.delete,
            mediaEntity: entity,
          ),
          resultFile: srcSec,
          duration: dsw.elapsed,
        );
      } catch (e) {
        final elapsed = dsw.elapsed;
        yield MoveMediaEntityResult.failure(
          operation: MoveMediaEntityOperation(
            sourceFile: srcSec,
            targetDirectory: Directory(MovingStrategyUtils.dirOf(srcSec.path)),
            operationType: MediaEntityOperationType.delete,
            mediaEntity: entity,
          ),
          errorMessage: 'Failed to delete secondary after JSON: $e',
          duration: elapsed,
        );
      }
    }
  }

  @override
  Future<List<MoveMediaEntityResult>> finalize(
    final MovingContext context,
    final List<MediaEntity> processedEntities,
  ) async {
    final String jsonPath = _pathService.generateAlbumsInfoJsonPath(
      context.outputDirectory,
    );
    final File jsonFile = File(jsonPath);

    final sw = Stopwatch()..start();
    try {
      final payload = {
        'albums': _albumInfo,
        'metadata': {
          'generated': DateTime.now().toIso8601String(),
          'total_albums': _albumInfo.length,
          'total_entities': processedEntities.length,
          'strategy': 'json',
        },
      };
      await jsonFile.writeAsString(
        const JsonEncoder.withIndent('  ').convert(payload),
      );
      sw.stop();

      if (processedEntities.isEmpty) return const <MoveMediaEntityResult>[];

      return [
        MoveMediaEntityResult.success(
          operation: MoveMediaEntityOperation(
            sourceFile: jsonFile,
            targetDirectory: context.outputDirectory,
            operationType: MediaEntityOperationType.createJsonReference,
            mediaEntity: processedEntities.first,
          ),
          resultFile: jsonFile,
          duration: sw.elapsed,
        ),
      ];
    } catch (e) {
      sw.stop();
      if (processedEntities.isEmpty) return const <MoveMediaEntityResult>[];
      return [
        MoveMediaEntityResult.failure(
          operation: MoveMediaEntityOperation(
            sourceFile: jsonFile,
            targetDirectory: context.outputDirectory,
            operationType: MediaEntityOperationType.createJsonReference,
            mediaEntity: processedEntities.first,
          ),
          errorMessage: 'Failed to create albums-info.json: $e',
          duration: sw.elapsed,
        ),
      ];
    }
  }

  @override
  void validateContext(final MovingContext context) {}
}
