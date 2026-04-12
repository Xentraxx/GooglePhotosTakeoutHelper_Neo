/// Model representing a motion photo (e.g., Google Pixel .mv files)
///
/// Motion photos contain both a static image and an embedded video.
/// The video offset is typically stored in XMP metadata.
class MotionPhoto {
  MotionPhoto({
    required this.filePath,
    required this.imageData,
    required this.videoData,
    required this.videoOffset,
    required this.videoSize,
    this.metadata,
  });

  /// Path to the motion photo file
  final String filePath;

  /// The static image data extracted from the file
  final List<int> imageData;

  /// The embedded video data
  final List<int> videoData;

  /// Optional metadata from the file
  final Map<String, String>? metadata;

  /// Offset where the video data starts within the file
  final int videoOffset;

  /// Size of the video data in bytes
  final int videoSize;

  /// Total file size
  int get totalSize => videoOffset + videoSize;
}

/// Model representing a live photo for iPhone/modern devices
///
/// iPhone live photos typically use HEIC format with embedded video.
/// The video is stored as auxiliary data with specific metadata markers.
class LivePhoto {
  LivePhoto({
    required this.outputPath,
    required this.imageData,
    required this.videoData,
    required this.videoFormat,
    required this.metadata,
  });

  /// Path where the live photo will be saved
  final String outputPath;

  /// The main image file (HEIC format)
  final List<int> imageData;

  /// The embedded video file
  final List<int> videoData;

  /// Video format (e.g., 'mp4', 'mov')
  final String videoFormat;

  /// Metadata to embed in the live photo
  final LivePhotoMetadata metadata;
}

/// Metadata for a live photo
class LivePhotoMetadata {
  LivePhotoMetadata({
    this.captureDateTime,
    this.cameraMake,
    this.cameraModel,
    this.latitude,
    this.longitude,
    this.altitude,
    this.customXmpData = const {},
    this.imageWidth,
    this.imageHeight,
    this.videoWidth,
    this.videoHeight,
    this.videoDuration,
  });

  /// Original capture date/time
  final DateTime? captureDateTime;

  /// Camera make (e.g., 'Apple', 'Google')
  final String? cameraMake;

  /// Camera model
  final String? cameraModel;

  /// GPS latitude
  final double? latitude;

  /// GPS longitude
  final double? longitude;

  /// Altitude in meters
  final double? altitude;

  /// Custom XMP metadata entries
  final Map<String, String> customXmpData;

  /// Image width in pixels
  final int? imageWidth;

  /// Image height in pixels
  final int? imageHeight;

  /// Video width in pixels
  final int? videoWidth;

  /// Video height in pixels
  final int? videoHeight;

  /// Video duration in seconds
  final double? videoDuration;

  /// Converts metadata to XMP format string
  String toXmpString() {
    final buffer = StringBuffer();
    buffer.writeln('<?xml version="1.0" encoding="UTF-8"?>');
    buffer.writeln(
      '<x:xmpmeta xmlns:x="adobe:ns:meta/" x:xmptk="Apple XMP Lib">',
    );

    // Add image dimensions
    if (imageWidth != null && imageHeight != null) {
      buffer.writeln(
        '  <rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#">',
      );
      buffer.writeln('    <rdf:Description rdf:about=""');
      buffer.writeln('      xmp:CreatorTool="GooglePhotosTakeoutHelper">');

      // GContainer for Apple live photo format
      buffer.writeln('      <GContainer:Container');
      buffer.writeln(
        '        xmlns:GContainer="http://ns.google.com/photos/1.0/container/">',
      );
      buffer.writeln(
        '        <GContainer:Directory GContainer:name="MotionPhoto"/>',
      );

      // Video reference
      if (videoWidth != null && videoHeight != null) {
        buffer.writeln(
          '        <GContainer:Item GContainer:type="Image" GContainer:name="motionvideofile" GContainer:length="0">',
        );
        buffer.writeln(
          '          <GContainer:Item GContainer:type="Metadata" GContainer:name="MicroVideo"/>',
        );
        buffer.writeln('        </GContainer:Item>');
      }

      buffer.writeln('      </GContainer:Container>');
      buffer.writeln('    </rdf:Description>');
    }

    // Add custom XMP data
    for (final entry in customXmpData.entries) {
      buffer.writeln('  <rdf:Description rdf:about="">');
      buffer.writeln('    <${entry.key}>${entry.value}</${entry.key}>');
      buffer.writeln('  </rdf:Description>');
    }

    buffer.writeln('  </rdf:RDF>');
    buffer.writeln('</x:xmpmeta>');

    return buffer.toString();
  }
}

/// Result of a live photo conversion operation
class LivePhotoConversionResult {
  LivePhotoConversionResult({
    required this.success,
    this.outputFilePath,
    this.errorMessage,
    this.bytesProcessed = 0,
    required this.processingTime,
    this.warnings = const [],
  });

  /// Whether the conversion was successful
  final bool success;

  /// Path to the created live photo file
  final String? outputFilePath;

  /// Error message if conversion failed
  final String? errorMessage;

  /// Number of bytes processed
  final int bytesProcessed;

  /// Duration of the conversion operation
  final Duration processingTime;

  /// Warnings that occurred during conversion
  final List<String> warnings;

  @override
  String toString() =>
      'LivePhotoConversionResult(success: $success, output: $outputFilePath, '
      'bytes: $bytesProcessed, time: ${processingTime.inMilliseconds}ms)';
}

/// Configuration for live photo conversion
class LivePhotoConversionConfig {
  const LivePhotoConversionConfig({
    this.preserveOrientation = true,
    this.compressImage = true,
    this.compressionQuality = 85,
    this.preserveMetadata = true,
    this.stripSensitiveMetadata = false,
    this.outputFormat = 'heic',
    this.maxOutputSize = 0,
    this.useHardwareAcceleration = true,
  });

  /// Whether to preserve orientation during conversion
  final bool preserveOrientation;

  /// Whether to compress the output image
  final bool compressImage;

  /// Compression quality (0-100), only used if compressImage is true
  final int compressionQuality;

  /// Whether to preserve metadata
  final bool preserveMetadata;

  /// Whether to strip sensitive metadata (GPS, etc.)
  final bool stripSensitiveMetadata;

  /// Output image format (heic, heif, jpg, etc.)
  final String outputFormat;

  /// Maximum output size in bytes (0 for unlimited)
  final int maxOutputSize;

  /// Whether to use hardware acceleration if available
  final bool useHardwareAcceleration;

  @override
  String toString() =>
      'LivePhotoConversionConfig(format: $outputFormat, quality: $compressionQuality, '
      'preserveMetadata: $preserveMetadata)';
}
