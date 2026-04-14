import 'dart:io';
import 'dart:typed_data';
import 'package:motion_photos/motion_photos.dart';
import 'live_photo_models.dart';

/// Service for extracting motion photo data from files like Google Pixel .mv format
///
/// Motion photos (used by Google Pixel phones) embed video data alongside
/// an image file. The video offset is typically marked in XMP metadata.
class MotionPhotoExtractorService {
  /// Creates a new instance of MotionPhotoExtractorService
  const MotionPhotoExtractorService();

  /// Extracts motion photo data from a file
  ///
  /// [filePath] Path to the motion photo file (e.g., .mv file)
  /// Returns a MotionPhoto object containing the extracted image and video data
  /// Throws [FileSystemException] if file doesn't exist or can't be read
  /// Throws [FormatException] if file format is invalid
  Future<MotionPhoto> extractMotionPhoto(final String filePath) async {
    final file = File(filePath);

    if (!file.existsSync()) {
      throw FileSystemException('Motion photo file not found', filePath);
    }

    final fileBytes = await file.readAsBytes();
    return _parseMotionPhotoBytes(fileBytes, filePath);
  }

  /// Parses motion photo bytes and extracts image and video components
  ///
  /// Supports two motion photo formats:
  /// 1. Google Pixel format: [MP4 video container with embedded JPEG]
  /// 2. Standard format: [Image JPEG data][Video data (MP4/MOV)]
  ///
  /// [bytes] The file bytes
  /// [filePath] Path for error reporting
  Future<MotionPhoto> _parseMotionPhotoBytes(
    final Uint8List bytes,
    final String filePath,
  ) async {
    // First, check if this is a Google Pixel Micro Video format
    // (MP4 video with embedded JPEG image)
    final googlePixelFormat = _parseGooglePixelMicroVideo(bytes);
    if (googlePixelFormat != null) {
      return googlePixelFormat;
    }

    // Otherwise, use motion_photos plugin to find video offset
    final motionPhotos = MotionPhotos(filePath);
    final videoIndex = await motionPhotos.getMotionVideoIndex();
    if (videoIndex == null) {
      throw FormatException(
        'Unable to locate video data in motion photo file (plugin did not find offset)',
        filePath,
      );
    }

    final imageData = bytes.sublist(0, videoIndex.start);
    final videoData = bytes.sublist(videoIndex.start, videoIndex.end);

    // Validate that image starts with JPEG signature
    if (!_isValidJpeg(imageData)) {
      throw FormatException(
        'Image data does not appear to be a valid JPEG',
        filePath,
      );
    }

    return MotionPhoto(
      filePath: filePath,
      imageData: imageData,
      videoData: videoData,
      videoOffset: videoIndex.start,
      videoSize: videoIndex.videoLength,
    );
  }

  /// Attempts to parse Google Pixel Micro Video format
  ///
  /// Google Pixel motion photos (.mp files) have the structure:
  /// [MP4 video data with embedded JPEG image inside]
  ///
  /// Returns a MotionPhoto if this format is detected, null otherwise
  MotionPhoto? _parseGooglePixelMicroVideo(final Uint8List bytes) {
    // Check if file starts with MP4 ftyp box
    if (bytes.length < 12) {
      return null;
    }

    // Check for MP4 'ftyp' box at the start
    if (!(bytes[4] == 0x66 &&
        bytes[5] == 0x74 &&
        bytes[6] == 0x79 &&
        bytes[7] == 0x70)) {
      return null; // Not MP4 format
    }

    // Look for JPEG image embedded in the MP4 data
    int jpegStartOffset = -1;
    for (int i = 0; i < bytes.length - 1; i++) {
      if (bytes[i] == 0xFF && bytes[i + 1] == 0xD8) {
        jpegStartOffset = i;
        break;
      }
    }

    if (jpegStartOffset <= 0) {
      return null; // No JPEG found
    }

    // Find the end of the JPEG
    int jpegEndOffset = -1;
    for (int i = jpegStartOffset + 2; i < bytes.length - 1; i++) {
      if (bytes[i] == 0xFF && bytes[i + 1] == 0xD9) {
        jpegEndOffset = i + 2;
        break;
      }
    }

    if (jpegEndOffset <= jpegStartOffset) {
      return null; // No valid JPEG end marker
    }

    // Extract JPEG image data
    final imageData = bytes.sublist(jpegStartOffset, jpegEndOffset);

    // Create a combined video container that includes the entire MP4 structure
    // For Google Pixel, the video is the MP4 container itself
    final videoData = bytes;

    return MotionPhoto(
      filePath: '',
      imageData: imageData,
      videoData: videoData,
      videoOffset: jpegStartOffset,
      videoSize: jpegEndOffset - jpegStartOffset,
    );
  }

  // _isValidJpeg retained for sanity check only
  bool _isValidJpeg(final Uint8List data) {
    if (data.length < 2) {
      return false;
    }
    return data[0] == 0xFF && data[1] == 0xD8;
  }

  /// Extracts XMP metadata from image data
  ///
  /// Looks for XMP data structure in JPEG file
  /// Format: 0xFF 0xE1 followed by size and "http://ns.adobe.com/xap/1.0/"
  String? extractXmpMetadata(final Uint8List imageData) {
    const xmpMarker = 0xFF;
    const xmpApp1 = 0xE1;

    for (int i = 0; i < imageData.length - 10; i++) {
      if (imageData[i] == xmpMarker && imageData[i + 1] == xmpApp1) {
        // Found APP1 marker, could contain XMP
        final sizeHigh = imageData[i + 2];
        final sizeLow = imageData[i + 3];
        final markerSize = (sizeHigh << 8) | sizeLow;

        if (i + 4 + markerSize <= imageData.length) {
          try {
            // Extract XMP data (skip marker bytes and size)
            final xmpData = imageData.sublist(i + 4, i + 4 + markerSize);
            final xmpString = String.fromCharCodes(xmpData);

            if (xmpString.contains('http://ns.adobe.com/xap/1.0/') ||
                xmpString.contains('<x:xmpmeta')) {
              return xmpString;
            }
          } catch (e) {
            // Continue searching if decode fails
          }
        }
      }
    }

    return null;
  }
}
