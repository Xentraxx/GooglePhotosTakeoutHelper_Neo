import 'dart:io';
import 'package:gpth_neo/gpth_lib_exports.dart';

/// Enum representing different extension fixing modes
enum ExtensionFixingMode {
  /// No extension fixing
  none('none'),

  /// Fix extensions but skip TIFF-based files (default)
  standard('standard'),

  /// Fix extensions but skip both TIFF and JPEG files (conservative)
  conservative('conservative'),

  /// Fix extensions then exit immediately (solo mode)
  solo('solo');

  const ExtensionFixingMode(this.value);
  final String value;

  static ExtensionFixingMode fromString(final String value) =>
      ExtensionFixingMode.values.firstWhere(
        (final mode) => mode.value == value,
        orElse: () =>
            throw ArgumentError('Invalid extension fixing mode: $value'),
      );
}

/// Output format for Pixel motion photo transformation.
enum PixelMpTransformFormat {
  mp4('mp4'),
  jpg('jpg'),
  still('still');

  const PixelMpTransformFormat(this.value);
  final String value;

  static PixelMpTransformFormat fromString(final String value) =>
      PixelMpTransformFormat.values.firstWhere(
        (final format) => format.value == value.trim().toLowerCase(),
        orElse: () =>
            throw ArgumentError('Invalid Pixel MP transform format: $value'),
      );
}

/// Domain model representing all configuration options for GPTH processing
///
/// This replaces the `Map<String, dynamic> args` with a type-safe configuration object
/// that validates inputs and provides clear access to all processing options.
class ProcessingConfig {
  const ProcessingConfig({
    required this.inputPath,
    required this.outputPath,
    this.albumBehavior = AlbumBehavior.shortcut,
    this.dateDivision = DateDivisionLevel.none,
    this.writeExif = true,
    this.skipExtras = false,
    this.guessFromName = true,
    this.extensionFixing = ExtensionFixingMode.standard,
    this.transformPixelMp = false,
    this.pixelMpTransformFormat = PixelMpTransformFormat.mp4,
    this.updateCreationTime = false,
    this.limitFileSize = false,
    this.saveLog = true,
    this.verbose = false,
    this.isInteractiveMode = false,
    this.dividePartnerShared = false,
    this.keepInput =
        false, // keep the original input untouched by working on a temporary copy
    this.keepDuplicates =
        false, // keep duplicates files in `_Duplicates` subfolder within output folder
    this.inputExtractedFromZip =
        false, // If the input have been extracted from ZIP it will be set to true
    final String?
    userInputRoot, // Original root folder selected/provided by the user
    this.disableResumeCheck = false,
    this.allPhotosDirectoryName = kAllPhotosDirectoryName,
    this.hardlink = false,
  }) : userInputRoot = userInputRoot ?? inputPath;

  /// Creates a builder for configuring ProcessingConfig
  static ProcessingConfigBuilder builder({
    required final String inputPath,
    required final String outputPath,
  }) => ProcessingConfigBuilder._(inputPath, outputPath);

  final String inputPath;
  final String outputPath;
  final AlbumBehavior albumBehavior;
  final DateDivisionLevel dateDivision;
  final bool writeExif;
  final bool skipExtras;
  final bool guessFromName;
  final ExtensionFixingMode extensionFixing;
  final bool transformPixelMp;
  final PixelMpTransformFormat pixelMpTransformFormat;
  final bool updateCreationTime;
  final bool limitFileSize;
  final bool saveLog;
  final bool verbose;
  final bool isInteractiveMode;
  final bool dividePartnerShared;
  final bool keepInput;
  final bool keepDuplicates;
  final bool inputExtractedFromZip;
  final String userInputRoot;
  final bool disableResumeCheck;

  /// Prefer hard links over symlinks for shortcut/reverse-shortcut strategies (Windows only).
  final bool hardlink;

  /// Custom name for the non-album output directory (default: [kAllPhotosDirectoryName]).
  final String allPhotosDirectoryName;

  /// Validates the configuration and throws descriptive errors if invalid
  void validate() {
    if (inputPath.isEmpty) {
      throw const ConfigurationException('Input path cannot be empty');
    }
    if (outputPath.isEmpty) {
      throw const ConfigurationException('Output path cannot be empty');
    }
    // Solo mode validation - solo mode implies extension fixing is enabled
    if (extensionFixing == ExtensionFixingMode.solo) {
      // Solo mode is valid - it's a mode of extension fixing
    }
  }

  /// Returns whether the processing should continue after extension fixing
  bool get shouldContinueAfterExtensionFix =>
      extensionFixing != ExtensionFixingMode.solo;

  /// Returns the list of date extractors based on configuration
  List<DateTimeExtractor> get dateExtractors {
    final extractors = <DateTimeExtractor>[jsonDateTimeExtractor];

    // Always add EXIF extractor - it can work without ExifTool for many formats using native extraction
    // ExifTool can be null, but ExifDateExtractor handles this gracefully by using native extraction
    final exifTool = ServiceContainer.instance.exifTool;
    extractors.add(
      (final File f) => ExifDateExtractor(exifTool).exifDateTimeExtractor(
        f,
        globalConfig: ServiceContainer.instance.globalConfig,
        datesDict: ServiceContainer.instance.globalConfig.jsonDatesDictionary,
      ),
    );

    // final exifTool = ServiceContainer.instance.exifTool;
    // extractors.add(
    //   (final File f) => ExifDateExtractor(exifTool).exifDateTimeExtractor(
    //     f,
    //     globalConfig: ServiceContainer.instance.globalConfig,
    //   ),
    // );

    if (guessFromName) {
      extractors.add(guessExtractor);
    }

    extractors.add((final File f) => jsonDateTimeExtractor(f, tryhard: true));

    // Add folder year extractor as final fallback
    extractors.add(folderYearExtractor);

    return extractors;
  }

  ProcessingConfig copyWith({
    final String? inputPath,
    final String? outputPath,
    final AlbumBehavior? albumBehavior,
    final DateDivisionLevel? dateDivision,
    final bool? writeExif,
    final bool? skipExtras,
    final bool? guessFromName,
    final ExtensionFixingMode? extensionFixing,
    final bool? transformPixelMp,
    final PixelMpTransformFormat? pixelMpTransformFormat,
    final bool? updateCreationTime,
    final bool? limitFileSize,
    final bool? saveLog,
    final bool? verbose,
    final bool? isInteractiveMode,
    final bool? dividePartnerShared,
    final bool? keepInput,
    final bool? keepDuplicates,
    final bool? inputExtractedFromZip,
    final String? userInputRoot,
    final bool? disableResumeCheck,
    final String? allPhotosDirectoryName,
    final bool? hardlink,
  }) => ProcessingConfig(
    inputPath: inputPath ?? this.inputPath,
    outputPath: outputPath ?? this.outputPath,
    albumBehavior: albumBehavior ?? this.albumBehavior,
    dateDivision: dateDivision ?? this.dateDivision,
    writeExif: writeExif ?? this.writeExif,
    skipExtras: skipExtras ?? this.skipExtras,
    guessFromName: guessFromName ?? this.guessFromName,
    extensionFixing: extensionFixing ?? this.extensionFixing,
    transformPixelMp: transformPixelMp ?? this.transformPixelMp,
    pixelMpTransformFormat:
        pixelMpTransformFormat ?? this.pixelMpTransformFormat,
    updateCreationTime: updateCreationTime ?? this.updateCreationTime,
    limitFileSize: limitFileSize ?? this.limitFileSize,
    saveLog: saveLog ?? this.saveLog,
    verbose: verbose ?? this.verbose,
    isInteractiveMode: isInteractiveMode ?? this.isInteractiveMode,
    dividePartnerShared: dividePartnerShared ?? this.dividePartnerShared,
    keepInput: keepInput ?? this.keepInput,
    keepDuplicates: keepDuplicates ?? this.keepDuplicates,
    inputExtractedFromZip: inputExtractedFromZip ?? this.inputExtractedFromZip,
    userInputRoot: userInputRoot ?? this.userInputRoot,
    disableResumeCheck: disableResumeCheck ?? this.disableResumeCheck,
    allPhotosDirectoryName:
        allPhotosDirectoryName ?? this.allPhotosDirectoryName,
    hardlink: hardlink ?? this.hardlink,
  );
}

/// Builder pattern for creating ProcessingConfig instances with fluent API
///
/// This makes configuration creation more readable and maintainable:
/// ```dart
/// final config = ProcessingConfig.builder(
///   inputPath: '/path/to/input',
///   outputPath: '/path/to/output',
/// )
/// .withVerboseOutput()
/// .withAlbumBehavior(AlbumBehavior.duplicateCopy)
/// .withDateDivision(DateDivisionLevel.month)
/// .withExtensionFixing(nonJpeg: true)
/// .build();
/// ```
class ProcessingConfigBuilder {
  ProcessingConfigBuilder._(this._inputPath, this._outputPath);
  final String _inputPath;
  final String _outputPath;

  AlbumBehavior _albumBehavior = AlbumBehavior.shortcut;
  DateDivisionLevel _dateDivision = DateDivisionLevel.none;
  bool _writeExif = true;
  bool _skipExtras = false;
  bool _guessFromName = true;
  ExtensionFixingMode _extensionFixing = ExtensionFixingMode.standard;
  bool _transformPixelMp = false;
  PixelMpTransformFormat _pixelMpTransformFormat = PixelMpTransformFormat.mp4;
  bool _updateCreationTime = false;
  bool _limitFileSize = false;
  bool _saveLog = true;
  bool _verbose = false;
  bool _isInteractiveMode = false;
  bool _dividePartnerShared = false;
  bool _keepInput = false;
  bool _keepDuplicates = false;
  bool _inputExtractedFromZip = false;
  String? _userInputRoot; // NEW
  String _allPhotosDirectoryName = kAllPhotosDirectoryName;
  bool _hardlink = false;

  /// Set album behavior (shortcut, reverse-shortcut, duplicate-copy, json, nothing, ignore)
  set albumBehavior(final AlbumBehavior behavior) {
    _albumBehavior = behavior;
  }

  /// Set date division level (none, year, month, day)
  set dateDivision(final DateDivisionLevel level) {
    _dateDivision = level;
  }

  /// Configure EXIF writing
  set exifWriting(final bool enable) {
    _writeExif = enable;
  }

  /// Skip extra files (Live Photo videos, etc.)
  set skipExtras(final bool enable) {
    _skipExtras = enable;
  }

  /// Enable/disable guessing dates from filenames
  set guessFromName(final bool enable) {
    _guessFromName = enable;
  }

  /// Configure extension fixing options
  void setExtensionFixing({
    final bool jpeg = false,
    final bool nonJpeg = false,
    final bool soloMode = false,
  }) {
    if (soloMode) {
      _extensionFixing = ExtensionFixingMode.solo;
    } else if (nonJpeg) {
      _extensionFixing = ExtensionFixingMode.conservative;
    } else if (jpeg) {
      _extensionFixing = ExtensionFixingMode.standard;
    } else {
      _extensionFixing = ExtensionFixingMode.none;
    }
  }

  /// Set extension fixing mode directly
  set extensionFixing(final ExtensionFixingMode mode) {
    _extensionFixing = mode;
  }

  /// Enable Google Pixel motion photo transformation
  set pixelTransformation(final bool enable) {
    _transformPixelMp = enable;
  }

  /// Set output format for Pixel motion photo transformation.
  set pixelTransformationFormat(final PixelMpTransformFormat format) {
    _pixelMpTransformFormat = format;
  }

  /// Update file creation time (Windows only)
  set creationTimeUpdate(final bool enable) {
    _updateCreationTime = enable;
  }

  /// Limit file size during processing
  set fileSizeLimit(final bool enable) {
    _limitFileSize = enable;
  }

  /// Enable save-log output
  set saveLog(final bool enable) {
    _saveLog = enable;
  }

  /// Enable verbose output
  set verboseOutput(final bool enable) {
    _verbose = enable;
  }

  /// Enable interactive mode
  set interactiveMode(final bool enable) {
    _isInteractiveMode = enable;
  }

  /// Enable partner shared media separation
  set dividePartnerShared(final bool enable) {
    _dividePartnerShared = enable;
  }

  /// Keep original input untouched by cloning it to a sibling temporary directory and using the clone.
  set keepInput(final bool enable) {
    _keepInput = enable;
  }

  /// Keep duplicates files in `_Duplicates` subfolder within output folder.
  set keepDuplicates(final bool enable) {
    _keepDuplicates = enable;
  }

  /// Indicate that input comes from an internal ZIP extraction
  set inputExtractedFromZip(final bool value) {
    _inputExtractedFromZip = value;
  }

  /// Original root folder selected/provided by the user (before resolving to Google Photos subfolder)
  set userInputRoot(final String value) {
    _userInputRoot = value;
  }

  /// Prefer hard links over symlinks for shortcut/reverse-shortcut strategies (Windows only).
  set hardlink(final bool enable) {
    _hardlink = enable;
  }

  /// Custom name for the non-album output directory (default: [kAllPhotosDirectoryName]).
  set allPhotosDirectoryName(final String value) {
    _allPhotosDirectoryName = value;
  }

  /// Build the final ProcessingConfig instance
  ProcessingConfig build() {
    final config = ProcessingConfig(
      inputPath: _inputPath,
      outputPath: _outputPath,
      albumBehavior: _albumBehavior,
      dateDivision: _dateDivision,
      writeExif: _writeExif,
      skipExtras: _skipExtras,
      guessFromName: _guessFromName,
      extensionFixing: _extensionFixing,
      transformPixelMp: _transformPixelMp,
      pixelMpTransformFormat: _pixelMpTransformFormat,
      updateCreationTime: _updateCreationTime,
      limitFileSize: _limitFileSize,
      saveLog: _saveLog,
      verbose: _verbose,
      isInteractiveMode: _isInteractiveMode,
      dividePartnerShared: _dividePartnerShared,
      keepInput: _keepInput,
      keepDuplicates: _keepDuplicates,
      inputExtractedFromZip: _inputExtractedFromZip,
      userInputRoot:
          _userInputRoot ??
          _inputPath, // fallback to _inputPath if not explicitly provided
      allPhotosDirectoryName: _allPhotosDirectoryName,
      hardlink: _hardlink,
    );

    // Validate the configuration before returning
    config.validate();
    return config;
  }
}

/// Enum representing how albums should be handled
enum AlbumBehavior {
  shortcut('shortcut'),
  reverseShortcut('reverse-shortcut'),
  duplicateCopy('duplicate-copy'),
  json('json'),
  nothing('nothing'),
  ignoreAlbums(
    'ignore',
  ); // NEW: strategy that ignores albums (move canonicals to ALL_PHOTOS, delete non-canonicals)

  const AlbumBehavior(this.value);
  final String value;

  static AlbumBehavior fromString(final String value) =>
      AlbumBehavior.values.firstWhere(
        (final behavior) => behavior.value == value,
        orElse: () => throw ArgumentError('Invalid album behavior: $value'),
      );
}

/// Enum representing how files should be divided by date
enum DateDivisionLevel {
  none(0),
  year(1),
  month(2),
  day(3);

  const DateDivisionLevel(this.value);
  final int value;

  static DateDivisionLevel fromInt(final int value) =>
      DateDivisionLevel.values.firstWhere(
        (final level) => level.value == value,
        orElse: () =>
            throw ArgumentError('Invalid date division level: $value'),
      );
}

class ConfigurationException implements Exception {
  const ConfigurationException(this.message);
  final String message;

  @override
  String toString() => 'ConfigurationException: $message';
}
