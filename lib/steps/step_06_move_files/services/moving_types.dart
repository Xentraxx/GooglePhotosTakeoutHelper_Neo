import 'dart:io';

import 'package:gpth_neo/gpth_lib_exports.dart';
import 'package:path/path.dart' as path;

/// Domain model representing the context for moving operations
///
/// This model encapsulates all the necessary information needed to perform
/// file moving operations, including configuration, paths, and operational metadata.
class MovingContext {
  const MovingContext({
    required this.outputDirectory,
    required this.dateDivision,
    required this.albumBehavior,
    this.verbose = false,
    this.dividePartnerShared = false,
  });

  /// Creates a MovingContext from ProcessingConfig
  factory MovingContext.fromConfig(
    final ProcessingConfig config,
    final Directory outputDirectory,
  ) => MovingContext(
    outputDirectory: outputDirectory,
    dateDivision: config.dateDivision,
    albumBehavior: config.albumBehavior,
    verbose: config.verbose,
    dividePartnerShared: config.dividePartnerShared,
  );
  final Directory outputDirectory;
  final DateDivisionLevel dateDivision;
  final AlbumBehavior albumBehavior;
  final bool verbose;
  final bool dividePartnerShared;
}

/// Represents a single file moving operation
class MovingOperation {
  const MovingOperation({
    required this.sourceFile,
    required this.targetDirectory,
    required this.operationType,
    this.albumKey,
    this.dateTaken,
  });
  final File sourceFile;
  final String? albumKey;
  final DateTime? dateTaken;
  final Directory targetDirectory;
  final MovingOperationType operationType;

  /// Gets the target file path for this operation
  String get targetPath =>
      path.join(targetDirectory.path, path.basename(sourceFile.path));

  /// Whether this operation is for an album file
  bool get isAlbumFile => albumKey != null;

  /// Whether this operation is for a main/year folder file
  bool get isMainFile => albumKey == null;
}

/// Types of moving operations
enum MovingOperationType { move, createSymlink, createReverseSymlink }

/// Result of a moving operation
class MovingResult {
  const MovingResult({
    required this.operation,
    required this.success,
    required this.duration,
    this.resultFile,
    this.errorMessage,
  });

  factory MovingResult.success({
    required final MovingOperation operation,
    required final File resultFile,
    required final Duration duration,
  }) => MovingResult(
    operation: operation,
    resultFile: resultFile,
    success: true,
    duration: duration,
  );

  factory MovingResult.failure({
    required final MovingOperation operation,
    required final String errorMessage,
    required final Duration duration,
  }) => MovingResult(
    operation: operation,
    success: false,
    errorMessage: errorMessage,
    duration: duration,
  );
  final MovingOperation operation;
  final File? resultFile;
  final bool success;
  final String? errorMessage;
  final Duration duration;
}
