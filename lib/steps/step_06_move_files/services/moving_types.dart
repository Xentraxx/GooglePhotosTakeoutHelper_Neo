import 'dart:io';

import 'package:gpth_neo/gpth_lib_exports.dart';

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
    this.allPhotosDirectoryName = kAllPhotosDirectoryName,
    this.hardlink = false,
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
    allPhotosDirectoryName: config.allPhotosDirectoryName,
    hardlink: config.hardlink,
  );
  final Directory outputDirectory;
  final DateDivisionLevel dateDivision;
  final AlbumBehavior albumBehavior;
  final bool verbose;
  final bool dividePartnerShared;
  final bool hardlink;

  /// Name of the non-album output directory (default: [kAllPhotosDirectoryName]).
  final String allPhotosDirectoryName;
}
