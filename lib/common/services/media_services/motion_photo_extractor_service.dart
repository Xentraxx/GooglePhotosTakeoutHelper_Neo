import 'dart:io';
import 'dart:typed_data';
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
  /// 1. Standard format: [Image JPEG data][Video data (MP4/MOV)]
  /// 2. Google Pixel format: [MP4 video container with embedded JPEG]
  ///
  /// The split point can be detected by:
  /// 1. Looking for JPEG start (0xFF 0xD8) and end (0xFF 0xD9) markers
  /// 2. Looking for MP4/MOV file signatures (ftyp box)
  /// 3. XMP metadata specifying the offset
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

    // Otherwise, try standard format (JPEG image + MP4 video)
    int videoOffset = _findVideoOffset(bytes);

    if (videoOffset <= 0 || videoOffset >= bytes.length) {
      // Fallback: assume a reasonable split point
      // For many motion photos, the video starts around 80% of the file
      videoOffset = (bytes.length * 0.8).toInt();

      // Further refine by looking backwards for JPEG end marker
      videoOffset = _findLastJpegEnd(bytes, videoOffset);
    }

    if (videoOffset <= 0 || videoOffset >= bytes.length) {
      throw FormatException(
        'Unable to locate video data in motion photo file',
        filePath,
      );
    }

    final imageData = bytes.sublist(0, videoOffset);
    final videoData = bytes.sublist(videoOffset);

    // Validate that image starts with JPEG signature
    if (!_isValidJpeg(imageData)) {
      throw FormatException(
        'Image data does not appear to be a valid JPEG',
        filePath,
      );
    }

    // Validate that video starts with MP4 signature or is valid video format
    if (!_isValidVideoFormat(videoData)) {
      // Log warning but continue - some motion photos may have different format
    }

    return MotionPhoto(
      filePath: filePath,
      imageData: imageData,
      videoData: videoData,
      videoOffset: videoOffset,
      videoSize: videoData.length,
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

  /// Attempts to find the video offset by looking for video file signatures
  ///
  /// Looks for:
  /// 1. MP4 'ftyp' box signature
  /// 2. MOV file signatures
  /// 3. Other common video format markers
  int _findVideoOffset(final Uint8List bytes) {
    // Search for MP4 'ftyp' box
    // ftyp box format: [size:4 bytes][type:'ftyp'] = 0x66747970
    const ftypSignature = [0x66, 0x74, 0x79, 0x70]; // 'ftyp' in hex

    for (int i = 4; i < bytes.length - 4; i++) {
      if (_bytesMatch(bytes, i, ftypSignature)) {
        // ftyp is preceded by 4-byte size, so video starts at i-4
        return i - 4;
      }
    }

    // Search for MOV vide tag (less reliable but fallback)
    const videSignature = [0x76, 0x69, 0x64, 0x65]; // 'vide'
    for (int i = 0; i < bytes.length - 4; i++) {
      if (_bytesMatch(bytes, i, videSignature) && i > 32) {
        // Try to find box start before this
        return _findBoxStart(bytes, i);
      }
    }

    return -1;
  }

  /// Finds the start of an MP4 box by looking backward for a valid box header
  int _findBoxStart(final Uint8List bytes, final int position) {
    // Boxes are typically preceded by a 4-byte size header
    for (int i = position; i >= 8; i--) {
      // Check if this could be a box size
      final size = _readUint32(bytes, i - 4);
      if (size > 8 && size < 0x10000000 && i - 4 + size <= bytes.length) {
        return i - 4;
      }
    }
    return -1;
  }

  /// Finds the last JPEG end marker in the data
  ///
  /// JPEG files end with the marker 0xFF 0xD9
  int _findLastJpegEnd(final Uint8List bytes, final int startSearch) {
    const jpegEnd = [0xFF, 0xD9];

    for (int i = startSearch; i > 0; i--) {
      if (i < bytes.length - 2) {
        if (_bytesMatch(bytes, i, jpegEnd)) {
          return i + 2;
        }
      }
    }

    // If no marker found, search from file size backwards
    for (int i = bytes.length - 2; i >= 0; i--) {
      if (i < bytes.length - 2) {
        if (_bytesMatch(bytes, i, jpegEnd)) {
          return i + 2;
        }
      }
    }

    return -1;
  }

  /// Checks if the given data appears to be a valid JPEG
  ///
  /// JPEG files start with the marker sequence 0xFF 0xD8
  bool _isValidJpeg(final Uint8List data) {
    if (data.length < 2) {
      return false;
    }
    return data[0] == 0xFF && data[1] == 0xD8;
  }

  /// Checks if the given data appears to be valid video format
  ///
  /// Checks for MP4 (ftyp box) or MOV format
  bool _isValidVideoFormat(final Uint8List data) {
    if (data.length < 8) {
      return false;
    }

    // Check for MP4 'ftyp' box
    if (data.length >= 12) {
      // Box size at [0-4], type at [4-8]
      if (data[4] == 0x66 &&
          data[5] == 0x74 &&
          data[6] == 0x79 &&
          data[7] == 0x70) {
        return true;
      }
    }

    // Check for QuickTime/MOV format (starts with specific box types)
    if (data.length >= 12) {
      if (data[4] >= 32 && data[4] < 127) {
        // Likely a valid box type ASCII
        return true;
      }
    }

    return false;
  }

  /// Helper to read a 32-bit unsigned integer in big-endian format
  int _readUint32(final Uint8List bytes, final int offset) {
    if (offset + 4 > bytes.length) {
      return 0;
    }
    return (bytes[offset] << 24) |
        (bytes[offset + 1] << 16) |
        (bytes[offset + 2] << 8) |
        bytes[offset + 3];
  }

  /// Helper to check if bytes match a pattern at a specific offset
  bool _bytesMatch(
    final Uint8List bytes,
    final int offset,
    final List<int> pattern,
  ) {
    if (offset + pattern.length > bytes.length) {
      return false;
    }

    for (int i = 0; i < pattern.length; i++) {
      if (bytes[offset + i] != pattern[i]) {
        return false;
      }
    }

    return true;
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
