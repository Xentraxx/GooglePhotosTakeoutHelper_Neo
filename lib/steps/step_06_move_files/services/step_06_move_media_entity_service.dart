// Service module (updated) - MoveMediaEntityService
import 'dart:async';
import 'dart:io';
import 'package:console_bars/console_bars.dart';
import 'package:gpth_neo/gpth_lib_exports.dart';
import 'package:motion_photos/motion_photos.dart';
import 'package:path/path.dart' as path;

/// Modern media moving service using immutable MediaEntity
///
/// This service coordinates all the moving logic components and provides
/// a clean interface for moving media files according to configuration.
///— Uses MediaEntity exclusively for better performance and immutability.
///
/// ⚠️ Model note:
/// MediaEntity now exposes:
///   - `primaryFile` (the only physical source to move/copy/link),
///   - `secondaryFiles` (kept as metadata; duplicates already removed/moved in Step 3),
///   - album associations via `albumsMap` / `albumNames`.
/// There is NO `files` map anymore. This service therefore expects only one
/// physical "move" per entity (the primary).
class MoveMediaEntityService with LoggerMixin {
  MoveMediaEntityService()
    : _strategyFactory = MoveMediaEntityStrategyFactory(
        FileOperationService(),
        PathGeneratorService(),
        SymlinkService(),
      );

  /// Custom constructor for dependency injection (useful for testing)
  MoveMediaEntityService.withDependencies({
    required final FileOperationService fileService,
    required final PathGeneratorService pathService,
    required final SymlinkService symlinkService,
  }) : _strategyFactory = MoveMediaEntityStrategyFactory(
         fileService,
         pathService,
         symlinkService,
       );

  /// Suppress redundant .MP4 files when a sibling .jpg is a motion photo
  Future<int> _suppressRedundantMp4Companions(
    final ProcessingContext context,
  ) async {
    final collection = context.mediaCollection;
    final entities = collection.asList();
    final toRemove = <MediaEntity>[];
    for (final entity in entities) {
      final primary = entity.primaryFile;
      final lower = primary.path.toLowerCase();
      if (!lower.endsWith('.mp4')) continue; // Only suppress .mp4, never .mov

      final dir = path.dirname(primary.path);
      final base = path.basenameWithoutExtension(primary.path);
      // Look for sibling .jpg/.jpeg
      final candidates = [
        path.join(dir, '$base.jpg'),
        path.join(dir, '$base.JPG'),
        path.join(dir, '$base.jpeg'),
        path.join(dir, '$base.JPEG'),
      ];
      String? foundJpg;
      for (final candidate in candidates) {
        if (File(candidate).existsSync()) {
          foundJpg = candidate;
          break;
        }
      }
      if (foundJpg != null) {
        try {
          final isMotion = await MotionPhotos(foundJpg).isMotionPhoto();
          if (isMotion) {
            toRemove.add(entity);
          }
        } catch (_) {
          // Ignore errors, do not suppress if uncertain
        }
      }
    }
    for (final entity in toRemove) {
      if (context.config.verbose) {
        logDebug(
          '[Step 6/8] [left-behind] Redundant .mp4 excluded from output (sibling .jpg is already a motion photo): ${entity.primaryFile.path}',
          forcePrint: true,
        );
      }
    }
    collection.removeAll(toRemove);
    return toRemove.length;
  }

  /// In `still` mode: exclude .mp4 entities whose stem matches a sibling
  /// .heic/.heif entity in the same directory. The .heic still image is moved
  /// to output; the .mp4 video is left behind in the input folder.
  Future<int> _suppressMp4CompanionsOfHeic(
    final ProcessingContext context,
  ) async {
    final collection = context.mediaCollection;
    final entities = collection.asList();

    // Build a (dir|stem) set for all HEIC/HEIF entities.
    final heicKeys = <String>{};
    for (final entity in entities) {
      final lower = entity.primaryFile.path.toLowerCase();
      if (lower.endsWith('.heic') || lower.endsWith('.heif')) {
        final dir = path.dirname(entity.primaryFile.path).toLowerCase();
        final stem = path
            .basenameWithoutExtension(entity.primaryFile.path)
            .toLowerCase();
        heicKeys.add('$dir|$stem');
      }
    }

    final toRemove = <MediaEntity>[];
    for (final entity in entities) {
      final lower = entity.primaryFile.path.toLowerCase();
      if (!lower.endsWith('.mp4')) continue;
      final dir = path.dirname(entity.primaryFile.path).toLowerCase();
      final stem = path
          .basenameWithoutExtension(entity.primaryFile.path)
          .toLowerCase();
      if (heicKeys.contains('$dir|$stem')) {
        toRemove.add(entity);
      }
    }

    for (final entity in toRemove) {
      if (context.config.verbose) {
        logDebug(
          '[Step 6/8] [left-behind] .mp4 companion of HEIC excluded from output in still mode: ${entity.primaryFile.path}',
          forcePrint: true,
        );
      }
    }
    collection.removeAll(toRemove);
    return toRemove.length;
  }

  final MoveMediaEntityStrategyFactory _strategyFactory;

  // Keeps the last full set of results for verification/reporting purposes
  final List<MoveMediaEntityResult> _lastResults = [];

  /// Expose an immutable view of the last results after a run
  List<MoveMediaEntityResult> get lastResults =>
      List.unmodifiable(_lastResults);

  /// Moves media entities according to the provided context
  ///
  /// Emits progress as "entities processed" (not operations).
  Stream<int> moveMediaEntities(
    final MediaEntityCollection entityCollection,
    final MovingContext context,
  ) async* {
    // Reset previous results
    _lastResults.clear();

    // Create the appropriate strategy for the album behavior
    final strategy = _strategyFactory.createStrategy(context.albumBehavior);

    // Validate the context for this strategy
    strategy.validateContext(context);

    int processedEntities = 0;
    final allResults = <MoveMediaEntityResult>[];

    // Process each media entity
    for (final entity in entityCollection.entities) {
      // We require the primary to be "accounted for": either MOVED or DELETED.
      final String primarySourcePath = entity.primaryFile.sourcePath;
      var primaryAccounted = false;

      await for (final result in strategy.processMediaEntity(entity, context)) {
        allResults.add(result);

        final op = result.operation;
        final String opSrc =
            op.operationType == MediaEntityOperationType.delete ||
                op.operationType == MediaEntityOperationType.move
            ? op.sourceFile.path
            : op.sourceFile.path; // same, kept explicit for clarity

        // Primary is considered handled if strategy MOVED or DELETED it
        if (_samePath(opSrc, primarySourcePath) &&
            (op.operationType == MediaEntityOperationType.move ||
                op.operationType == MediaEntityOperationType.delete)) {
          primaryAccounted = true;
        }

        if (!result.success && context.verbose) {
          _logError(result);
        } else if (context.verbose) {
          _logResult(result);
        }
      }

      // Inject a synthetic failure only if the primary was neither moved nor deleted
      if (!primaryAccounted) {
        final syntheticOp = MoveMediaEntityOperation(
          sourceFile: File(primarySourcePath),
          targetDirectory: Directory(context.outputDirectory.path),
          operationType: MediaEntityOperationType.move, // nominal intent
          mediaEntity: entity,
        );
        final synthetic = MoveMediaEntityResult.failure(
          operation: syntheticOp,
          errorMessage: 'Primary file was not moved or deleted by strategy',
          duration: Duration.zero,
        );
        allResults.add(synthetic);
        if (context.verbose) {
          _logError(synthetic);
        }
      }

      processedEntities++;
      yield processedEntities;
    }

    // Finalization hook for the active strategy
    try {
      final finalizationResults = await strategy.finalize(
        context,
        entityCollection.entities.toList(),
      );
      allResults.addAll(finalizationResults);

      for (final result in finalizationResults) {
        if (!result.success && context.verbose) {
          _logError(result);
        } else if (context.verbose) {
          _logResult(result);
        }
      }
    } catch (e) {
      if (context.verbose) {
        logError('[Step 6/8] [Error] Strategy finalization failed: $e');
      }
    }

    // Store results for external verification (MoveFilesStep)
    _lastResults
      ..clear()
      ..addAll(allResults);

    // Print summary
    _printSummary(allResults);
  }

  /// High-performance parallel media moving.
  ///
  /// Concurrency is capped by [GlobalPools.poolFor(ConcurrencyOperation.moveCopy)].
  /// All entities are submitted to the pool at once — no artificial batch
  /// boundaries that would stall progress while the slowest entity in a batch
  /// catches up. Yields the running count of completed entities.
  Stream<int> moveMediaEntitiesParallel(
    final MediaEntityCollection entityCollection,
    final MovingContext context,
  ) async* {
    // Reset previous results
    _lastResults.clear();

    final strategy = _strategyFactory.createStrategy(context.albumBehavior);
    strategy.validateContext(context);

    final entities = entityCollection.entities.toList();
    final allResults = <MoveMediaEntityResult>[];

    // Submit every entity to the shared pool immediately; pool.withResource
    // enforces the concurrency cap without a manual semaphore or batch loop.
    final pool = GlobalPools.poolFor(ConcurrencyOperation.moveCopy);
    final futures = entities
        .map(
          (final entity) => pool.withResource(
            () => _processOneEntity(entity, strategy, context),
          ),
        )
        .toList();

    // Await futures in submission order and yield progress as each completes.
    // Pool concurrency means in-flight moves keep running while we await
    // each handle in turn — earlier completions are instant awaits.
    int processedEntities = 0;
    for (final future in futures) {
      final results = await future;
      allResults.addAll(results);
      processedEntities++;
      yield processedEntities;
    }

    // Finalize
    try {
      final finalizationResults = await strategy.finalize(context, entities);
      allResults.addAll(finalizationResults);
    } catch (e) {
      if (context.verbose) {
        logError('[Step 6/8] [Error] Strategy finalization failed: $e');
      }
    }

    _appendPostFinalizeIntegrityFailures(allResults, entities, context);

    // Store results for external verification (MoveFilesStep)
    _lastResults
      ..clear()
      ..addAll(allResults);

    // Print summary
    _printSummary(allResults);
  }

  void _appendPostFinalizeIntegrityFailures(
    final List<MoveMediaEntityResult> allResults,
    final List<MediaEntity> entities,
    final MovingContext context,
  ) {
    for (final entity in entities) {
      final primary = entity.primaryFile;
      final bool accountedFor = primary.isDeleted || primary.targetPath != null;
      if (accountedFor) continue;

      final synthetic = MoveMediaEntityResult.failure(
        operation: MoveMediaEntityOperation(
          sourceFile: File(primary.sourcePath),
          targetDirectory: Directory(context.outputDirectory.path),
          operationType: MediaEntityOperationType.move,
          mediaEntity: entity,
        ),
        errorMessage:
            'Primary file is still unaccounted for after strategy finalization',
        duration: Duration.zero,
      );
      allResults.add(synthetic);
      if (context.verbose) {
        _logError(synthetic);
      }
    }

    final int leakedReservations = GlobalPools.reservedPathCount();
    if (leakedReservations > 0) {
      logError(
        '[Step 6/8] [Integrity] Detected $leakedReservations leaked reserved output path(s) after moving.',
      );
    }
  }

  /// Processes a single [MediaEntity] through [strategy] and returns all
  /// operation results. Called from within a [Pool.withResource] slot.
  Future<List<MoveMediaEntityResult>> _processOneEntity(
    final MediaEntity entity,
    final MoveMediaEntityStrategy strategy,
    final MovingContext context,
  ) async {
    final results = <MoveMediaEntityResult>[];
    final String primarySourcePath = entity.primaryFile.sourcePath;
    var primaryAccounted = false;

    await for (final r in strategy.processMediaEntity(entity, context)) {
      results.add(r);

      if (_samePath(r.operation.sourceFile.path, primarySourcePath) &&
          (r.operation.operationType == MediaEntityOperationType.move ||
              r.operation.operationType == MediaEntityOperationType.delete)) {
        primaryAccounted = true;
      }

      if (context.verbose) {
        if (!r.success) {
          _logError(r);
        } else {
          _logResult(r);
        }
      }
    }

    if (!primaryAccounted) {
      final synthetic = MoveMediaEntityResult.failure(
        operation: MoveMediaEntityOperation(
          sourceFile: File(primarySourcePath),
          targetDirectory: Directory(context.outputDirectory.path),
          operationType: MediaEntityOperationType.move,
          mediaEntity: entity,
        ),
        errorMessage: 'Primary file was not moved or deleted by strategy',
        duration: Duration.zero,
      );
      results.add(synthetic);
      if (context.verbose) _logError(synthetic);
    }

    return results;
  }

  void _logResult(final MoveMediaEntityResult result) {
    final operation = result.operation;
    final status = result.success ? 'SUCCESS' : 'FAILED';
    logPrint(
      '[Step 6/8] [${operation.operationType.name.toUpperCase()}] $status: ${operation.sourceFile.path}',
    );
    if (result.resultFile != null) {
      logPrint('[Step 6/8]   → ${result.resultFile!.path}');
    }
  }

  void _logError(final MoveMediaEntityResult result) {
    logPrint(
      '[Step 6/8] [Error] Failed to process ${result.operation.sourceFile.path}: ${result.errorMessage}',
    );
  }

  // Print Summary
  void _printSummary(final List<MoveMediaEntityResult> results) {
    final allPhotosFolderName = FileEntity.allPhotosDirectoryName.trim().isEmpty
        ? '[output-root]'
        : FileEntity.allPhotosDirectoryName;

    // Totals per operation kind
    int primaryMoves = 0;
    int nonPrimaryMoves = 0;
    int copiesAllPhotos = 0;
    int copiesAlbums = 0;
    int symlinksCreated = 0;
    int jsonRefs = 0;
    int deletes = 0;

    // NEW: per-destination breakdown (configured non-album dir vs Albums)
    int primaryMovesAllPhotos = 0;
    int primaryMovesAlbums = 0;

    int nonPrimaryMovesAllPhotos = 0;
    int nonPrimaryMovesAlbums = 0;

    int symlinksAllPhotos = 0;
    int symlinksAlbums = 0;

    int jsonRefsAllPhotos = 0;
    int jsonRefsAlbums = 0;

    int deletesAllPhotos = 0;
    int deletesAlbums = 0;

    int failures = 0;

    // NEW: total operations breakdown (independent of success)
    int totalOpsAllPhotos = 0;
    int totalOpsAlbums = 0;

    for (final r in results) {
      final op = r.operation;

      // Accumulate TOTAL operations split by target kind (album vs main)
      if (op.isAlbumFile) {
        totalOpsAlbums++;
      } else {
        totalOpsAllPhotos++;
      }

      if (!r.success) {
        failures++;
        continue;
      }

      switch (op.operationType) {
        case MediaEntityOperationType.move:
          final src = op.sourceFile.path;
          final prim = op.mediaEntity.primaryFile.sourcePath; // usar sourcePath
          final isPrimary = _samePath(src, prim);
          if (isPrimary) {
            primaryMoves++;
            if (op.isAlbumFile) {
              primaryMovesAlbums++;
            } else {
              primaryMovesAllPhotos++;
            }
          } else {
            nonPrimaryMoves++;
            if (op.isAlbumFile) {
              nonPrimaryMovesAlbums++;
            } else {
              nonPrimaryMovesAllPhotos++;
            }
          }
          break;

        case MediaEntityOperationType.copy:
          if (op.isAlbumFile) {
            copiesAlbums++;
          } else {
            copiesAllPhotos++;
          }
          break;

        case MediaEntityOperationType.createSymlink:
        case MediaEntityOperationType.createReverseSymlink:
          symlinksCreated++;
          if (op.isAlbumFile) {
            symlinksAlbums++;
          } else {
            symlinksAllPhotos++;
          }
          break;

        case MediaEntityOperationType.createJsonReference:
          jsonRefs++;
          if (op.isAlbumFile) {
            jsonRefsAlbums++;
          } else {
            jsonRefsAllPhotos++;
          }
          break;

        case MediaEntityOperationType.delete:
          deletes++;
          if (op.isAlbumFile) {
            deletesAlbums++;
          } else {
            deletesAllPhotos++;
          }
          break;
      }
    }

    final totalOps = results.length;
    final computedOps =
        primaryMoves +
        nonPrimaryMoves +
        copiesAllPhotos +
        copiesAlbums +
        symlinksCreated +
        jsonRefs +
        deletes +
        failures;

    print(''); // print to force new line after progress bar
    const int detailsCol = 50; // starting column for the parenthesis block
    logPrint('[Step 6/8] === Moving Files Summary ===');
    logPrint(
      '${'[Step 6/8]     Primary files moved: $primaryMoves'.padRight(detailsCol)}($allPhotosFolderName: $primaryMovesAllPhotos, Albums: $primaryMovesAlbums)',
    );
    logPrint(
      '${'[Step 6/8]     Non-primary moves: $nonPrimaryMoves'.padRight(detailsCol)}($allPhotosFolderName: $nonPrimaryMovesAllPhotos, Albums: $nonPrimaryMovesAlbums)',
    );
    logPrint(
      '${'[Step 6/8]     Duplicated copies created: ${copiesAllPhotos + copiesAlbums}'.padRight(detailsCol)}($allPhotosFolderName: $copiesAllPhotos, Albums: $copiesAlbums)',
    );
    logPrint(
      '${'[Step 6/8]     Symlinks created: $symlinksCreated'.padRight(detailsCol)}($allPhotosFolderName: $symlinksAllPhotos, Albums: $symlinksAlbums)',
    );
    logPrint(
      '${'[Step 6/8]     JSON refs created: $jsonRefs'.padRight(detailsCol)}($allPhotosFolderName: $jsonRefsAllPhotos, Albums: $jsonRefsAlbums)',
    );
    logPrint(
      '${'[Step 6/8]     Deleted from source: $deletes'.padRight(detailsCol)}($allPhotosFolderName: $deletesAllPhotos, Albums: $deletesAlbums)',
    );
    logPrint(
      '${'[Step 6/8]     Failures: $failures'.padRight(detailsCol)}($allPhotosFolderName: ${results.where((final r) => !r.success && !r.operation.isAlbumFile).length}, Albums: ${results.where((final r) => !r.success && r.operation.isAlbumFile).length})',
    );
    logPrint(
      '${'[Step 6/8]     Total operations: $totalOps${computedOps != totalOps ? ' (computed: $computedOps)' : ''}'.padRight(detailsCol)}($allPhotosFolderName: $totalOpsAllPhotos, Albums: $totalOpsAlbums)',
    );

    if (failures > 0) {
      logError('[Step 6/8] Errors encountered:');
      results.where((final r) => !r.success).take(5).forEach((final result) {
        logError(
          '[Step 6/8]   • ${result.operation.sourceFile.path}: ${result.errorMessage}',
          forcePrint: true,
        );
      });
      final extra = failures - 5;
      if (extra > 0) {
        logError('[Step 6/8]   ... and $extra more errors', forcePrint: true);
      }
    }
  }

  bool _samePath(final String a, final String b) =>
      a.replaceAll('\\', '/').toLowerCase() ==
      b.replaceAll('\\', '/').toLowerCase();

  // ───────────────────────────────────────────────────────────────────────────
  // Orchestrator moved from the Step: runs the whole Step 6 workflow inside the service
  // ───────────────────────────────────────────────────────────────────────────

  /// Runs the full Step 6 workflow and returns a summary with the same data/message the step used to produce.
  Future<MoveFilesSummary> moveAll(final ProcessingContext context) async {
    logPrint(
      '[Step 6/8] Moving files to Output folder (this may take a while)...',
    );

    // Optional pre-pass: transform Pixel .MP/.MV on primary files (in-place, still in input).
    int transformedCount = 0;
    final targetFormat = context.config.pixelMpTransformFormat;
    if (context.config.transformPixelMp) {
      transformedCount = await _transformPixelPrimaries(context);
      // In jpg mode, also merge Apple Live Photo pairs (HEIC+MP4 → motion JPEG).
      if (context.config.pixelMpTransformFormat == PixelMpTransformFormat.jpg) {
        transformedCount += await _transformAppleLivePhotosToMotionJpg(context);
      }
      if (context.config.verbose) {
        logDebug(
          '[Step 6/8] Transformed $transformedCount Pixel .MP/.MV primary files to ${_describePixelTransformTarget(targetFormat)}',
          forcePrint: true,
        );
      }
      // Suppress redundant .mp4 companions if --transform-pixel-mp is set
      final suppressedMp4 = await _suppressRedundantMp4Companions(context);
      if (context.config.verbose && suppressedMp4 > 0) {
        logDebug(
          '[Step 6/8] Suppressed $suppressedMp4 redundant .mp4 files next to motion-photo .jpg',
          forcePrint: true,
        );
      }
      // In still mode, also exclude .mp4 companions of HEIC/HEIF files.
      if (context.config.pixelMpTransformFormat ==
          PixelMpTransformFormat.still) {
        final suppressedHeicMp4 = await _suppressMp4CompanionsOfHeic(context);
        if (context.config.verbose && suppressedHeicMp4 > 0) {
          logDebug(
            '[Step 6/8] Excluded $suppressedHeicMp4 .mp4 companions of HEIC files in still mode',
            forcePrint: true,
          );
        }
      }
    }

    final progressBar = FillingBar(
      desc: '[ INFO  ] [Step 6/8] Moving entities',
      total: context.mediaCollection.length,
      width: 50,
      percentage: true,
    );

    final movingContext = MovingContext(
      outputDirectory: context.outputDirectory,
      dateDivision: context.config.dateDivision,
      albumBehavior: context.config.albumBehavior,
      allPhotosDirectoryName: context.config.allPhotosDirectoryName,
      dividePartnerShared: context.config.dividePartnerShared,
      hardlink: context.config.hardlink,
    );

    int entitiesProcessed = 0;
    await for (final _ in moveMediaEntitiesParallel(
      context.mediaCollection,
      movingContext,
    )) {
      entitiesProcessed++;
      progressBar.update(entitiesProcessed);
    }

    // Summary based on lastResults from service
    int primaryMovedCount = 0;
    int nonPrimaryMoves = 0;
    int symlinksCreated = 0;
    int deletesCount = 0; // <-- defined

    bool samePath(final String a, final String b) =>
        a.replaceAll('\\', '/').toLowerCase() ==
        b.replaceAll('\\', '/').toLowerCase();

    for (final r in lastResults) {
      if (!r.success) continue;

      switch (r.operation.operationType) {
        case MediaEntityOperationType.move:
          final src = r.operation.sourceFile.path;
          final prim = r.operation.mediaEntity.primaryFile.sourcePath;
          if (samePath(src, prim)) {
            primaryMovedCount++;
          } else {
            nonPrimaryMoves++;
          }
          break;

        case MediaEntityOperationType.createSymlink:
        case MediaEntityOperationType.createReverseSymlink:
          symlinksCreated++;
          break;

        case MediaEntityOperationType.copy:
        case MediaEntityOperationType.createJsonReference:
          // not headline
          break;

        case MediaEntityOperationType.delete:
          deletesCount++;
          break;
      }
    }

    // Build final message exactly as before
    final String message =
        'Moved $primaryMovedCount primary files, created $symlinksCreated symlinks'
        '${nonPrimaryMoves > 0 ? ', non-primary moves: $nonPrimaryMoves' : ''}'
        '${transformedCount > 0 ? ', transformed $transformedCount Pixel files to ${_describePixelTransformTarget(targetFormat)}' : ''}'
        '${deletesCount > 0 ? ', deletes: $deletesCount' : ''}';

    return MoveFilesSummary(
      entitiesProcessed: entitiesProcessed,
      transformedCount: transformedCount,
      albumBehaviorValue: context.config.albumBehavior.value,
      primaryMovedCount: primaryMovedCount,
      nonPrimaryMoves: nonPrimaryMoves,
      symlinksCreated: symlinksCreated,
      deletesCount: deletesCount,
      message: message,
    );
  }

  /// Transform Pixel .MP/.MV to configured format (in input).
  /// Since they still live in input, update the FileEntity **sourcePath**.
  Future<int> _transformPixelPrimaries(final ProcessingContext context) async {
    switch (context.config.pixelMpTransformFormat) {
      case PixelMpTransformFormat.jpg:
        return _transformPixelPrimariesToMotionJpg(context);
      case PixelMpTransformFormat.still:
        return _transformPixelPrimariesToStill(context);
      case PixelMpTransformFormat.mp4:
        return _transformPixelPrimariesToMp4(context);
    }
  }

  String _describePixelTransformTarget(final PixelMpTransformFormat format) {
    switch (format) {
      case PixelMpTransformFormat.mp4:
        return '.mp4';
      case PixelMpTransformFormat.jpg:
        return '.jpg';
      case PixelMpTransformFormat.still:
        return 'still image';
    }
  }

  Future<int> _transformPixelPrimariesToMp4(
    final ProcessingContext context,
  ) async {
    int transformed = 0;

    final collection = context.mediaCollection;
    final entities = collection.asList(); // snapshot
    final transformedPathMap = <String, String>{};

    for (final entity in entities) {
      final files = <FileEntity>[entity.primaryFile, ...entity.secondaryFiles];

      for (final fileEntity in files) {
        final oldPath = fileEntity.sourcePath;
        final oldPathKey = oldPath.toLowerCase();

        // Reuse already-transformed path when multiple FileEntity instances
        // reference the same underlying file.
        final mappedPath = transformedPathMap[oldPathKey];
        if (mappedPath != null) {
          fileEntity.sourcePath = mappedPath;
          continue;
        }

        final lower = oldPath.toLowerCase();
        if (!(lower.endsWith('.mp') || lower.endsWith('.mv'))) {
          continue;
        }

        final dot = oldPath.lastIndexOf('.');
        final newPath = dot > 0
            ? '${oldPath.substring(0, dot)}.mp4'
            : '$oldPath.mp4';

        try {
          final sourceFile = File(oldPath);
          if (!await sourceFile.exists()) {
            final transformedFile = File(newPath);
            if (await transformedFile.exists()) {
              fileEntity.sourcePath = transformedFile.path;
              transformedPathMap[oldPathKey] = transformedFile.path;
            }
            continue;
          }

          final renamed = await sourceFile.rename(newPath);
          // IMPORTANT: still input -> update sourcePath, not targetPath
          fileEntity.sourcePath = renamed.path;
          transformedPathMap[oldPathKey] = renamed.path;
          transformed++;
        } catch (e) {
          logPrint('[Step 6/8] Warning: Failed to transform $oldPath: $e');
        }
      }
    }

    return transformed;
  }

  Future<int> _transformPixelPrimariesToMotionJpg(
    final ProcessingContext context,
  ) async {
    int transformed = 0;
    final collection = context.mediaCollection;
    final entities = collection.asList();
    final livePhotoService = LivePhotoService();

    for (final entity in entities) {
      final primary = entity.primaryFile;
      final lower = primary.path.toLowerCase();

      if (lower.endsWith('.mp') || lower.endsWith('.mv')) {
        final oldPath = primary.path;
        final dot = oldPath.lastIndexOf('.');
        final newPath = dot > 0
            ? '${oldPath.substring(0, dot)}.jpg'
            : '$oldPath.jpg';

        try {
          LivePhotoConversionResult result;
          final preferredStillPath = await _findPreferredStillImagePath(
            oldPath,
          );

          if (preferredStillPath != null) {
            result = await livePhotoService
                .convertMotionPhotoToLivePhotoWithStillImage(
                  inputPath: oldPath,
                  stillImagePath: preferredStillPath,
                  outputPath: newPath,
                );

            if (!result.success) {
              logPrint(
                '[Step 6/8] Warning: Sidecar-still motion .jpg conversion failed for ${primary.path}. Falling back to embedded JPEG conversion.',
              );
              final fallbackTarget = File(newPath);
              if (context.config.verbose && await fallbackTarget.exists()) {
                logDebug(
                  '[Step 6/8] [left-behind] Incomplete .jpg from failed sidecar conversion left in input; retry with embedded JPEG will overwrite it: ${fallbackTarget.path}',
                  forcePrint: true,
                );
              }
              result = await livePhotoService.convertMotionPhotoToLivePhoto(
                inputPath: oldPath,
                outputPath: newPath,
              );
            }
          } else {
            result = await livePhotoService.convertMotionPhotoToLivePhoto(
              inputPath: oldPath,
              outputPath: newPath,
            );
          }

          if (result.success) {
            if (context.config.verbose) {
              logDebug(
                '[Step 6/8] [left-behind] Source .MP left in input after motion .jpg conversion: $oldPath',
                forcePrint: true,
              );
            }

            primary.sourcePath = newPath;
            // Update secondaries (album-folder copies) so that the shortcut
            // created in the album output folder gets the correct .jpg name
            // rather than the stale .MP/.MV name. The physical .mp/.mv file in
            // the album input subfolder is left behind (the strategy's
            // try-catch delete will silently no-op on the now-non-existent old
            // path).
            final newExt = path.extension(newPath); // '.jpg'
            for (final sec in entity.secondaryFiles) {
              final secLower = sec.sourcePath.toLowerCase();
              if (secLower.endsWith('.mp') || secLower.endsWith('.mv')) {
                final secOldPath = sec.sourcePath;
                final secDot = secOldPath.lastIndexOf('.');
                final secNewPath = secDot > 0
                    ? '${secOldPath.substring(0, secDot)}$newExt'
                    : '$secOldPath$newExt';
                if (context.config.verbose) {
                  logDebug(
                    '[Step 6/8] [left-behind] Album-copy .MP left in input; updating secondary path for correct shortcut name: $secOldPath → $secNewPath',
                    forcePrint: true,
                  );
                }
                sec.sourcePath = secNewPath;
              }
            }
            // The sidecar .jpg was consumed to produce the motion .jpg output.
            // Remove any other entity tracking the same sidecar path to avoid
            // a double-move.
            if (preferredStillPath != null) {
              final normalizedStill = preferredStillPath
                  .replaceAll('\\', '/')
                  .toLowerCase();
              final duplicates = collection.asList().where((final e) {
                if (e == entity) return false;
                return e.primaryFile.sourcePath
                        .replaceAll('\\', '/')
                        .toLowerCase() ==
                    normalizedStill;
              }).toList();
              collection.removeAll(duplicates);
            }
            transformed++;
          } else {
            // .jpg conversion failed (e.g. no valid JPEG embedded in the .MP
            // file). Fall back to renaming to .mp4 so the video is preserved.
            final mp4Path = dot > 0
                ? '${oldPath.substring(0, dot)}.mp4'
                : '$oldPath.mp4';
            try {
              final renamed = await File(oldPath).rename(mp4Path);
              primary.sourcePath = renamed.path;
              logPrint(
                '[Step 6/8] Info: ${path.basename(oldPath)} has no embeddable JPEG; renamed to .mp4 as fallback (${result.errorMessage ?? 'unknown error'}).',
              );
            } catch (renameErr) {
              logPrint(
                '[Step 6/8] Warning: Failed to transform ${primary.path} to motion .jpg: ${result.errorMessage ?? 'unknown error'}',
              );
            }
          }
        } catch (e) {
          // .jpg conversion threw. Fall back to .mp4 rename so the video is preserved.
          final mp4Path = dot > 0
              ? '${oldPath.substring(0, dot)}.mp4'
              : '$oldPath.mp4';
          try {
            final renamed = await File(oldPath).rename(mp4Path);
            primary.sourcePath = renamed.path;
            logPrint(
              '[Step 6/8] Info: ${path.basename(oldPath)} has no embeddable JPEG; renamed to .mp4 as fallback ($e).',
            );
          } catch (renameErr) {
            logPrint(
              '[Step 6/8] Warning: Failed to transform ${primary.path} to motion .jpg: $e',
            );
          }
        }
      }
    }

    return transformed;
  }

  Future<int> _transformPixelPrimariesToStill(
    final ProcessingContext context,
  ) async {
    int transformed = 0;
    final collection = context.mediaCollection;
    final entities = collection.asList();
    const extractor = MotionPhotoExtractorService();

    for (final entity in entities) {
      final primary = entity.primaryFile;
      final lower = primary.path.toLowerCase();

      if (!(lower.endsWith('.mp') || lower.endsWith('.mv'))) {
        continue;
      }

      final oldPath = primary.path;

      try {
        final preferredStillPath = await _findPreferredStillImagePath(oldPath);

        if (preferredStillPath != null) {
          primary.sourcePath = preferredStillPath;
          if (context.config.verbose) {
            logDebug(
              '[Step 6/8] [left-behind] Source .MP left in input after redirecting to sidecar still: $oldPath',
              forcePrint: true,
            );
          }
          // Update secondaries so album shortcut names reflect the new .jpg
          // extension instead of the stale .mp/.mv name.
          final newExt = path.extension(preferredStillPath); // likely '.jpg'
          for (final sec in entity.secondaryFiles) {
            final secLower = sec.sourcePath.toLowerCase();
            if (secLower.endsWith('.mp') || secLower.endsWith('.mv')) {
              final secOldPath = sec.sourcePath;
              final secDot = secOldPath.lastIndexOf('.');
              final secNewPath = secDot > 0
                  ? '${secOldPath.substring(0, secDot)}$newExt'
                  : '$secOldPath$newExt';
              if (context.config.verbose) {
                logDebug(
                  '[Step 6/8] [left-behind] Album-copy .MP left in input; updating secondary path for correct shortcut name: $secOldPath → $secNewPath',
                  forcePrint: true,
                );
              }
              sec.sourcePath = secNewPath;
            }
          }
          // The sidecar .jpg is now owned by this entity. Remove any other
          // entity in the collection whose primary points to the same path
          // to avoid a double-move failure.
          final normalizedStill = preferredStillPath
              .replaceAll('\\', '/')
              .toLowerCase();
          final duplicates = collection.asList().where((final e) {
            if (e == entity) return false;
            return e.primaryFile.sourcePath
                    .replaceAll('\\', '/')
                    .toLowerCase() ==
                normalizedStill;
          }).toList();
          collection.removeAll(duplicates);
          transformed++;
          continue;
        }

        // Fallback: extract embedded JPEG if no sidecar still image exists.
        final motionPhoto = await extractor.extractMotionPhoto(oldPath);
        final dot = oldPath.lastIndexOf('.');
        final stillPath = dot > 0
            ? '${oldPath.substring(0, dot)}.jpg'
            : '$oldPath.jpg';

        final stillFile = File(stillPath);
        await stillFile.writeAsBytes(motionPhoto.imageData);

        if (context.config.verbose) {
          logDebug(
            '[Step 6/8] [left-behind] Source .MP left in input after extracting embedded still: $oldPath',
            forcePrint: true,
          );
        }

        primary.sourcePath = stillPath;
        // Update secondaries so album shortcut names reflect the new .jpg
        // extension instead of the stale .mp/.mv name.
        for (final sec in entity.secondaryFiles) {
          final secLower = sec.sourcePath.toLowerCase();
          if (secLower.endsWith('.mp') || secLower.endsWith('.mv')) {
            final secOldPath = sec.sourcePath;
            final secDot = secOldPath.lastIndexOf('.');
            final secNewPath = secDot > 0
                ? '${secOldPath.substring(0, secDot)}.jpg'
                : '$secOldPath.jpg';
            if (context.config.verbose) {
              logDebug(
                '[Step 6/8] [left-behind] Album-copy .MP left in input; updating secondary path for correct shortcut name: $secOldPath → $secNewPath',
                forcePrint: true,
              );
            }
            sec.sourcePath = secNewPath;
          }
        }
        transformed++;
      } catch (e) {
        logPrint(
          '[Step 6/8] Warning: Failed to transform ${primary.path} to still image: $e',
        );
      }
    }

    return transformed;
  }

  /// Merges Apple Live Photo pairs (HEIC/HEIF + same-stem MP4) into a single
  /// Google-style motion JPEG (JPEG bytes with MP4 appended).
  ///
  /// In Google Photos Takeout, Apple Live Photos are exported as a HEIC still
  /// image alongside an MP4 video that bears the same stem name.  The actual
  /// bytes inside the .HEIC are typically JPEG so the resulting .jpg produced
  /// here is a valid Google Motion Photo V2 container.
  ///
  /// **Limitation — original-quality (true) HEIC files are not merged.**
  /// When the user stored photos at original quality, Google Takeout exports
  /// the full-resolution HEIC (an ISO-BMFF container, `ftyp heic` box, first
  /// byte `0x00`). Producing a Google Motion Photo requires the still image to
  /// be JPEG bytes — concatenating ISO-BMFF bytes with an MP4 produces a file
  /// whose header looks like a MOV container, which ExifTool correctly rejects
  /// with "Not a valid JPG (looks more like a MOV)". Decoding a true HEIC to
  /// JPEG requires a native libheif decoder; no such decoder is available in a
  /// Dart CLI context (Flutter native plugins and libheif-wasm are not usable).
  /// True HEIC files and their MP4 companions are therefore moved as-is.
  ///
  /// Only called in [PixelMpTransformFormat.jpg] mode.
  /// `.MOV` companions are intentionally left untouched — in a Google Takeout
  /// a `.MOV` alongside a `.HEIC` is generally unrelated to the still image.
  Future<int> _transformAppleLivePhotosToMotionJpg(
    final ProcessingContext context,
  ) async {
    int transformed = 0;
    final collection = context.mediaCollection;
    final livePhotoService = LivePhotoService();

    // Snapshot first so mutations during the loop don't affect iteration.
    final entities = collection.asList();

    // Build a (dir, stem) → MP4-entity lookup (both case-insensitive).
    // Keying by directory prevents cross-folder false matches where
    // unrelated files happen to share the same basename.
    final mp4ByDirAndStem = <String, MediaEntity>{};
    for (final entity in entities) {
      final lower = entity.primaryFile.path.toLowerCase();
      if (lower.endsWith('.mp4')) {
        final dir = path.dirname(entity.primaryFile.path).toLowerCase();
        final stem = path
            .basenameWithoutExtension(entity.primaryFile.path)
            .toLowerCase();
        mp4ByDirAndStem['$dir|$stem'] = entity;
      }
    }

    final toRemoveMp4 = <MediaEntity>[];

    for (final entity in entities) {
      final primary = entity.primaryFile;
      final lower = primary.path.toLowerCase();

      // Accept both .heic/.heif (when Step 1 was skipped or conservative) and
      // .jpg/.jpeg (when Step 1 has already renamed the JPEG-encoded HEIC).
      final isHeic = lower.endsWith('.heic') || lower.endsWith('.heif');
      final isJpeg = lower.endsWith('.jpg') || lower.endsWith('.jpeg');
      if (!isHeic && !isJpeg) continue;

      final dir = path.dirname(primary.path).toLowerCase();
      final stem = path.basenameWithoutExtension(primary.path).toLowerCase();
      final mp4Entity = mp4ByDirAndStem['$dir|$stem'];
      if (mp4Entity == null) continue;

      final imagePath = primary.path;

      if (isHeic) {
        // Only storage-saver HEICs can be merged: Google re-encodes the still
        // to JPEG bytes but keeps the .HEIC extension, so the first two bytes
        // are FF D8 and createLivePhotoFromComponents produces valid output.
        //
        // Original-quality (true) HEIC files are ISO-BMFF containers (first
        // byte 0x00). Concatenating them with an MP4 produces a file whose
        // header is an ISO-BMFF ftyp box — identical to a MOV container.
        // ExifTool correctly identifies the result as "MOV" and refuses to
        // write EXIF to it. Decoding a true HEIC to JPEG would require a
        // native libheif decoder which is not available in a Dart CLI context.
        // True HEIC files and their MP4 companions are therefore moved as-is;
        // only the embedded Apple Live Photo relationship is lost.
        try {
          final raf = await File(imagePath).open();
          final header = await raf.read(2);
          await raf.close();
          if (header.length < 2 || header[0] != 0xFF || header[1] != 0xD8) {
            if (context.config.verbose) {
              logDebug(
                '[Step 6/8] Skipping true HEIC (original-quality, not JPEG-encoded) — '
                'cannot merge without a native libheif decoder. '
                'Moving .heic and .mp4 as separate files: $imagePath',
                forcePrint: true,
              );
            }
            continue;
          }
        } catch (_) {
          continue;
        }
      } else {
        // isJpeg: Step 1 may have already renamed the JPEG-encoded HEIC to .jpg.
        // Guard: if the .jpg already contains embedded video it IS a motion
        // photo and must not be merged again with the companion .mp4
        // (_suppressRedundantMp4Companions will handle the mp4 removal instead).
        try {
          final alreadyMotion = await MotionPhotos(imagePath).isMotionPhoto();
          if (alreadyMotion) continue;
        } catch (_) {
          continue;
        }
      }

      final mp4Path = mp4Entity.primaryFile.path;
      final baseName = path.basenameWithoutExtension(imagePath);
      final outPath = path.join(path.dirname(imagePath), '$baseName.jpg');

      try {
        final result = await livePhotoService.createLivePhotoFromComponents(
          imagePath: imagePath,
          videoPath: mp4Path,
          outputPath: outPath,
        );

        if (result.success) {
          // Only delete the source image when the merge produced a differently-
          // named output file (e.g. .heic → .jpg).  When the source was already
          // .jpg the output path is identical and the file was overwritten in
          // place — deleting it here would remove the merged result.
          if (imagePath.toLowerCase() != outPath.toLowerCase()) {
            if (context.config.verbose) {
              logDebug(
                '[Step 6/8] [left-behind] Source HEIC left in input after Apple Live Photo merge: $imagePath',
                forcePrint: true,
              );
            }
          }
          primary.sourcePath = outPath;
          toRemoveMp4.add(mp4Entity);
          transformed++;
        } else {
          logPrint(
            '[Step 6/8] Warning: Failed to convert Apple Live Photo pair '
            '$imagePath to motion .jpg: ${result.errorMessage ?? 'unknown error'}',
          );
        }
      } catch (e) {
        logPrint(
          '[Step 6/8] Warning: Failed to convert Apple Live Photo pair '
          '$imagePath to motion .jpg: $e',
        );
      }
    }

    for (final entity in toRemoveMp4) {
      if (context.config.verbose) {
        logDebug(
          '[Step 6/8] [left-behind] .mp4 companion excluded from output after Apple Live Photo merge: ${entity.primaryFile.path}',
          forcePrint: true,
        );
      }
    }
    collection.removeAll(toRemoveMp4);
    return transformed;
  }

  Future<String?> _findPreferredStillImagePath(final String mpPath) async {
    final dot = mpPath.lastIndexOf('.');
    final basePath = dot > 0 ? mpPath.substring(0, dot) : mpPath;

    final candidates = <String>[
      '$mpPath.jpg',
      '$mpPath.JPG',
      '$mpPath.jpeg',
      '$mpPath.JPEG',
      '$basePath.jpg',
      '$basePath.JPG',
      '$basePath.jpeg',
      '$basePath.JPEG',
    ];

    String? preferredPath;
    int preferredSize = -1;

    for (final candidate in candidates) {
      final file = File(candidate);
      if (await file.exists()) {
        final size = await file.length();
        if (size > preferredSize) {
          preferredSize = size;
          preferredPath = candidate;
        }
      }
    }

    return preferredPath;
  }
}

/// Operation result
class MoveMediaEntityResult {
  const MoveMediaEntityResult({
    required this.operation,
    required this.success,
    required this.duration,
    this.resultFile,
    this.errorMessage,
  });

  factory MoveMediaEntityResult.success({
    required final MoveMediaEntityOperation operation,
    required final File resultFile,
    required final Duration duration,
  }) => MoveMediaEntityResult(
    operation: operation,
    success: true,
    resultFile: resultFile,
    duration: duration,
  );

  factory MoveMediaEntityResult.failure({
    required final MoveMediaEntityOperation operation,
    required final String errorMessage,
    required final Duration duration,
  }) => MoveMediaEntityResult(
    operation: operation,
    success: false,
    errorMessage: errorMessage,
    duration: duration,
  );

  final MoveMediaEntityOperation operation;
  final bool success;
  final File? resultFile;
  final Duration duration;
  final String? errorMessage;

  bool get isSuccess => success;
  bool get isFailure => !success;
}

/// Base class for MediaEntity moving strategies (unchanged public API)
abstract class MoveMediaEntityStrategy {
  const MoveMediaEntityStrategy();

  String get name;
  bool get createsShortcuts;
  bool get createsDuplicates;

  Stream<MoveMediaEntityResult> processMediaEntity(
    final MediaEntity entity,
    final MovingContext context,
  );

  Future<List<MoveMediaEntityResult>> finalize(
    final MovingContext context,
    final List<MediaEntity> processedEntities,
  ) async => [];

  void validateContext(final MovingContext context) {}
}

/// Factory to create strategy by AlbumBehavior
class MoveMediaEntityStrategyFactory {
  const MoveMediaEntityStrategyFactory(
    this._fileService,
    this._pathService,
    this._symlinkService,
  );

  final FileOperationService _fileService;
  final PathGeneratorService _pathService;
  final SymlinkService _symlinkService;

  MoveMediaEntityStrategy createStrategy(final AlbumBehavior albumBehavior) {
    switch (albumBehavior) {
      case AlbumBehavior.shortcut:
        return ShortcutMovingStrategy(
          _fileService,
          _pathService,
          _symlinkService,
        );
      case AlbumBehavior.duplicateCopy:
        return DuplicateCopyMovingStrategy(_fileService, _pathService);
      case AlbumBehavior.reverseShortcut:
        return ReverseShortcutMovingStrategy(
          _fileService,
          _pathService,
          _symlinkService,
        );
      case AlbumBehavior.json:
        return JsonMovingStrategy(_fileService, _pathService);
      case AlbumBehavior.nothing:
        return NothingMovingStrategy(_fileService, _pathService);
      case AlbumBehavior.ignoreAlbums: // NEW: wire the new strategy
        return IgnoreAlbumsMovingStrategy(_fileService, _pathService);
    }
  }
}

/// Represents a single file moving operation
class MoveMediaEntityOperation {
  const MoveMediaEntityOperation({
    required this.sourceFile,
    required this.targetDirectory,
    required this.operationType,
    required this.mediaEntity,
    this.albumKey,
  });

  final File sourceFile;
  final Directory targetDirectory;
  final MediaEntityOperationType operationType;
  final MediaEntity mediaEntity;
  final String? albumKey;

  File get targetFile =>
      File(path.join(targetDirectory.path, sourceFile.uri.pathSegments.last));

  bool get isAlbumFile => albumKey != null;
  bool get isMainFile => albumKey == null;
}

enum MediaEntityOperationType {
  move,
  copy,
  createSymlink,
  createReverseSymlink,
  createJsonReference,
  delete, // NEW: represents a deletion from source (no output artifact)
}

/// Summary DTO returned by the orchestrator to keep StepResult data identical to before.
class MoveFilesSummary {
  const MoveFilesSummary({
    required this.entitiesProcessed,
    required this.transformedCount,
    required this.albumBehaviorValue,
    required this.primaryMovedCount,
    required this.nonPrimaryMoves,
    required this.symlinksCreated,
    required this.deletesCount,
    required this.message,
  });

  final int entitiesProcessed;
  final int transformedCount;
  final String albumBehaviorValue;
  final int primaryMovedCount;
  final int nonPrimaryMoves;
  final int symlinksCreated;
  final int deletesCount;
  final String message;
}
