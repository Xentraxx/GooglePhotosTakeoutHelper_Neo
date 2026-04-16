// Service module (updated) - MoveMediaEntityService
import 'dart:async';
import 'dart:io';
import 'package:console_bars/console_bars.dart';
import 'package:gpth_neo/gpth_lib_exports.dart';
import 'package:path/path.dart' as path;
import 'pixel_mp_transform_service.dart';

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
      transformedCount = await const PixelMpTransformService().transformAll(
        context,
      );
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
        '${transformedCount > 0 ? ', transformed $transformedCount Pixel files to ${const PixelMpTransformService().describeFormat(targetFormat)}' : ''}'
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
