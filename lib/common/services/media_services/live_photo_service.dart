import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import '../core_services/container_service.dart';
import 'live_photo_creator_service.dart';
import 'live_photo_models.dart';
import 'motion_photo_extractor_service.dart';

/// Comprehensive service for live photo conversion operations
///
/// Provides high-level API for:
/// - Converting motion photos (.mv) to live photos (.heic)
/// - Extracting components from motion photos
/// - Creating live photos from separate image and video files
/// - Repairing and validating live photos
class LivePhotoService {
  /// Creates a new instance of LivePhotoService
  LivePhotoService({
    MotionPhotoExtractorService? extractor,
    LivePhotoCreatorService? creator,
  }) : _extractor = extractor ?? const MotionPhotoExtractorService(),
       _creator = creator ?? const LivePhotoCreatorService();

  final MotionPhotoExtractorService _extractor;
  final LivePhotoCreatorService _creator;

  /// Converts a motion photo file to modern live photo format
  ///
  /// [inputPath] Path to the motion photo file (e.g., .mv file)
  /// [outputPath] Path where the live photo will be saved (usually .heic)
  /// [config] Configuration for the conversion process
  /// [onProgress] Optional callback for progress updates (0.0-1.0)
  ///
  /// Returns a [LivePhotoConversionResult] with details about the operation
  Future<LivePhotoConversionResult> convertMotionPhotoToLivePhoto({
    required final String inputPath,
    required final String outputPath,
    final LivePhotoConversionConfig config = const LivePhotoConversionConfig(),
    final Function(double)? onProgress,
  }) async {
    final stopwatch = Stopwatch()..start();

    try {
      onProgress?.call(0.0);

      // Extract motion photo components
      final motionPhoto = await _extractor.extractMotionPhoto(inputPath);
      onProgress?.call(0.3);

      // Prepare metadata
      final metadata = LivePhotoMetadata(
        imageWidth: motionPhoto.imageData.extractJpegDimensions()?.$1,
        imageHeight: motionPhoto.imageData.extractJpegDimensions()?.$2,
        videoWidth: motionPhoto.videoData.extractVideoMp4Dimensions()?.$1,
        videoHeight: motionPhoto.videoData.extractVideoMp4Dimensions()?.$2,
        customXmpData: _buildLivePhotoXmpData(),
      );

      onProgress?.call(0.6);

      // Create live photo
      await _creator.createLivePhoto(
        outputPath: outputPath,
        imageData: motionPhoto.imageData,
        videoData: motionPhoto.videoData,
        metadata: metadata,
        config: config,
      );

      onProgress?.call(1.0);

      stopwatch.stop();

      return LivePhotoConversionResult(
        success: true,
        outputFilePath: outputPath,
        bytesProcessed:
            motionPhoto.imageData.length + motionPhoto.videoData.length,
        processingTime: stopwatch.elapsed,
      );
    } catch (e) {
      stopwatch.stop();

      return LivePhotoConversionResult(
        success: false,
        errorMessage: 'Conversion failed: ${e.toString()}',
        processingTime: stopwatch.elapsed,
      );
    }
  }

  /// Converts a motion photo to live photo while forcing a specific still image.
  ///
  /// This is used for Pixel `.MP/.MV` cases where a high-quality sidecar
  /// still image (for example `.MP.jpg`) should be preferred over embedded
  /// preview JPEG content inside the motion container.
  Future<LivePhotoConversionResult>
  convertMotionPhotoToLivePhotoWithStillImage({
    required final String inputPath,
    required final String stillImagePath,
    required final String outputPath,
    final LivePhotoConversionConfig config = const LivePhotoConversionConfig(),
    final Function(double)? onProgress,
  }) async {
    final stopwatch = Stopwatch()..start();

    try {
      onProgress?.call(0.0);

      final stillFile = File(stillImagePath);
      if (!stillFile.existsSync()) {
        throw FileSystemException('Still image file not found', stillImagePath);
      }

      final stillImageData = await stillFile.readAsBytes();
      onProgress?.call(0.2);

      final motionPhoto = await _extractor.extractMotionPhoto(inputPath);
      onProgress?.call(0.5);

      final metadata = LivePhotoMetadata(
        imageWidth: stillImageData.extractJpegDimensions()?.$1,
        imageHeight: stillImageData.extractJpegDimensions()?.$2,
        videoWidth: motionPhoto.videoData.extractVideoMp4Dimensions()?.$1,
        videoHeight: motionPhoto.videoData.extractVideoMp4Dimensions()?.$2,
        customXmpData: _buildLivePhotoXmpData(),
      );

      await _creator.createLivePhoto(
        outputPath: outputPath,
        imageData: stillImageData,
        videoData: motionPhoto.videoData,
        metadata: metadata,
        config: config,
      );

      // Best-effort transfer of source still-image metadata into output HEIC.
      // This keeps original EXIF/XMP information when ExifTool is available.
      final exifTool = ServiceContainer.instance.exifTool;
      if (exifTool != null) {
        try {
          await exifTool.copyMetadataFromFile(
            source: stillFile,
            target: File(outputPath),
          );
        } catch (_) {
          // Non-fatal: conversion output remains usable even if metadata copy fails.
        }
      }

      onProgress?.call(1.0);
      stopwatch.stop();

      return LivePhotoConversionResult(
        success: true,
        outputFilePath: outputPath,
        bytesProcessed: stillImageData.length + motionPhoto.videoData.length,
        processingTime: stopwatch.elapsed,
      );
    } catch (e) {
      stopwatch.stop();
      return LivePhotoConversionResult(
        success: false,
        errorMessage: 'Conversion failed: ${e.toString()}',
        processingTime: stopwatch.elapsed,
      );
    }
  }

  /// Converts multiple motion photos to live photos
  ///
  /// [inputPaths] List of motion photo file paths
  /// [outputDirectory] Directory where live photos will be saved
  /// [config] Configuration for the conversion process
  /// [onProgress] Optional callback for progress updates per file
  ///
  /// Returns list of conversion results
  Future<List<LivePhotoConversionResult>> convertMultipleMotionPhotos({
    required final List<String> inputPaths,
    required final String outputDirectory,
    final LivePhotoConversionConfig config = const LivePhotoConversionConfig(),
    final Function(int, int)? onProgress,
  }) async {
    final results = <LivePhotoConversionResult>[];

    for (int i = 0; i < inputPaths.length; i++) {
      onProgress?.call(i, inputPaths.length);

      final inputPath = inputPaths[i];
      final fileName = _generateOutputFileName(
        inputPath,
        outputDirectory,
        config.outputFormat,
      );

      try {
        final result = await convertMotionPhotoToLivePhoto(
          inputPath: inputPath,
          outputPath: fileName,
          config: config,
        );
        results.add(result);
      } catch (e) {
        results.add(
          LivePhotoConversionResult(
            success: false,
            errorMessage: 'Failed to convert $inputPath: $e',
            processingTime: Duration.zero,
          ),
        );
      }
    }

    return results;
  }

  /// Extracts image and video from a motion photo
  ///
  /// [inputPath] Path to the motion photo file
  /// [outputImagePath] Where to save the extracted image
  /// [outputVideoPath] Where to save the extracted video
  ///
  /// Returns a MotionPhoto object with extracted data
  Future<MotionPhoto> extractMotionPhotoComponents({
    required final String inputPath,
    final String? outputImagePath,
    final String? outputVideoPath,
  }) async {
    final motionPhoto = await _extractor.extractMotionPhoto(inputPath);

    if (outputImagePath != null) {
      final imageFile = File(outputImagePath);
      await imageFile.parent.create(recursive: true);
      await imageFile.writeAsBytes(motionPhoto.imageData);
    }

    if (outputVideoPath != null) {
      final videoFile = File(outputVideoPath);
      await videoFile.parent.create(recursive: true);
      await videoFile.writeAsBytes(motionPhoto.videoData);
    }

    return motionPhoto;
  }

  /// Creates a live photo from separate image and video files
  ///
  /// [imagePath] Path to the image file
  /// [videoPath] Path to the video file
  /// [outputPath] Where to save the live photo
  /// [config] Configuration for the conversion process
  ///
  /// Returns a conversion result
  Future<LivePhotoConversionResult> createLivePhotoFromComponents({
    required final String imagePath,
    required final String videoPath,
    required final String outputPath,
    final LivePhotoConversionConfig config = const LivePhotoConversionConfig(),
  }) async {
    final stopwatch = Stopwatch()..start();

    try {
      final imageFile = File(imagePath);
      final videoFile = File(videoPath);

      if (!imageFile.existsSync()) {
        throw FileSystemException('Image file not found', imagePath);
      }

      if (!videoFile.existsSync()) {
        throw FileSystemException('Video file not found', videoPath);
      }

      final imageData = await imageFile.readAsBytes();
      final videoData = await videoFile.readAsBytes();

      final metadata = LivePhotoMetadata(
        imageWidth: imageData.extractJpegDimensions()?.$1,
        imageHeight: imageData.extractJpegDimensions()?.$2,
        videoWidth: videoData.extractVideoMp4Dimensions()?.$1,
        videoHeight: videoData.extractVideoMp4Dimensions()?.$2,
        customXmpData: _buildLivePhotoXmpData(),
      );

      await _creator.createLivePhoto(
        outputPath: outputPath,
        imageData: imageData,
        videoData: videoData,
        metadata: metadata,
        config: config,
      );

      stopwatch.stop();

      return LivePhotoConversionResult(
        success: true,
        outputFilePath: outputPath,
        bytesProcessed: imageData.length + videoData.length,
        processingTime: stopwatch.elapsed,
      );
    } catch (e) {
      stopwatch.stop();

      return LivePhotoConversionResult(
        success: false,
        errorMessage: 'Failed to create live photo: ${e.toString()}',
        processingTime: stopwatch.elapsed,
      );
    }
  }

  /// Validates if a file appears to be a valid motion photo
  ///
  /// [filePath] Path to the file to validate
  /// Returns true if file appears to be a motion photo
  Future<bool> validateMotionPhoto(final String filePath) async {
    try {
      final file = File(filePath);
      if (!file.existsSync()) {
        return false;
      }

      final bytes = await file.readAsBytes();
      return _isValidMotionPhoto(bytes);
    } catch (e) {
      return false;
    }
  }

  /// Validates if bytes appear to be a valid motion photo
  ///
  /// Motion photos should have JPEG image followed by video data
  bool _isValidMotionPhoto(final Uint8List bytes) {
    if (bytes.length < 100) {
      return false;
    }

    // Check for JPEG start marker
    if (bytes[0] != 0xFF || bytes[1] != 0xD8) {
      return false;
    }

    // Check for JPEG end marker
    bool hasJpegEnd = false;
    for (int i = bytes.length - 10; i < bytes.length - 2; i++) {
      if (i >= 0 && bytes[i] == 0xFF && bytes[i + 1] == 0xD9) {
        hasJpegEnd = true;
        break;
      }
    }

    if (!hasJpegEnd) {
      return false;
    }

    // Check if there's video data after JPEG
    // Look for MP4 or MOV signature
    for (int i = bytes.length ~/ 2; i < bytes.length - 8; i++) {
      // Check for 'ftyp' (MP4)
      if (bytes[i] == 0x66 &&
          bytes[i + 1] == 0x74 &&
          bytes[i + 2] == 0x79 &&
          bytes[i + 3] == 0x70) {
        return true;
      }
    }

    return false;
  }

  /// Generates an appropriate output filename based on input and configuration
  String _generateOutputFileName(
    final String inputPath,
    final String outputDirectory,
    final String outputFormat,
  ) {
    final inputFile = File(inputPath);
    final baseName = inputFile.path.split(Platform.pathSeparator).last;
    final nameWithoutExt = baseName.replaceFirst(RegExp(r'\.[^.]*$'), '');

    return '$outputDirectory${Platform.pathSeparator}$nameWithoutExt.$outputFormat';
  }

  /// Builds standard XMP data for iPhone live photos
  Map<String, String> _buildLivePhotoXmpData() => {
    'GContainer:Container': 'MotionPhoto',
    'GContainer:Directory': 'MotionPhoto',
    'GContainer:Item': 'motionvideofile',
    'MicroVideo': '1',
  };

  /// Gets detailed information about a motion photo file
  ///
  /// [filePath] Path to the motion photo file
  /// Returns metadata about the file or null if invalid
  Future<Map<String, dynamic>?> getMotionPhotoInfo(
    final String filePath,
  ) async {
    try {
      final motionPhoto = await _extractor.extractMotionPhoto(filePath);
      final file = File(filePath);

      return {
        'filePath': filePath,
        'fileSize': file.lengthSync(),
        'imageSize': motionPhoto.imageData.length,
        'videoSize': motionPhoto.videoData.length,
        'videoOffset': motionPhoto.videoOffset,
        'imageDimensions': motionPhoto.imageData.extractJpegDimensions(),
        'videoDimensions': motionPhoto.videoData.extractVideoMp4Dimensions(),
      };
    } catch (e) {
      return null;
    }
  }
}
