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

  /// Parses motion photo bytes and extracts image and video components.
  ///
  /// Supports three motion photo formats, tried in order:
  /// 1. Google Pixel Micro Video (.MP/.MV): MP4 container with embedded JPEG.
  /// 2. Google Motion Photo V2 (.MP.jpg / .jpg): JPEG with appended MP4,
  ///    split point stored as [GCamera:MicroVideoOffset] in XMP metadata.
  ///    Pure-Dart implementation — no platform channel required.
  /// 3. Platform-channel fallback: uses [MotionPhotos.getMotionVideoIndex()]
  ///    which requires native iOS/Android implementation. Returns null on
  ///    desktop/CLI; throws [FormatException] in that case.
  ///
  /// [bytes] The file bytes
  /// [filePath] Path for error reporting
  Future<MotionPhoto> _parseMotionPhotoBytes(
    final Uint8List bytes,
    final String filePath,
  ) async {
    // 1. Google Pixel Micro Video format: MP4 container with embedded JPEG.
    final googlePixelFormat = _parseGooglePixelMicroVideo(bytes);
    if (googlePixelFormat != null) {
      return googlePixelFormat;
    }

    // 2. Google Motion Photo V2: JPEG + appended MP4, offset in XMP.
    //    Pure-Dart fallback that works on all platforms including desktop/CLI.
    final motionPhotoV2 = _parseGoogleMotionPhotoV2(bytes, filePath);
    if (motionPhotoV2 != null) {
      return motionPhotoV2;
    }

    // 3. Platform-channel fallback (iOS/Android only).
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

  /// Parses Google Motion Photo V2 format: a JPEG with an MP4 appended.
  ///
  /// In this format [GCamera:MicroVideoOffset] in the JPEG's XMP metadata
  /// stores the number of bytes from the END of the file to the start of the
  /// embedded MP4. The JPEG portion occupies bytes 0 .. (fileLength - offset)
  /// and the MP4 occupies the remaining bytes.
  ///
  /// This is a pure-Dart implementation that does not require platform channels,
  /// unlike [MotionPhotos.getMotionVideoIndex()] which only works on
  /// iOS/Android. Returns null if the bytes are not in this format.
  MotionPhoto? _parseGoogleMotionPhotoV2(
    final Uint8List bytes,
    final String filePath,
  ) {
    if (!_isValidJpeg(bytes)) return null;

    // Limit the XMP scan to the JPEG header area (first 128 KB).
    // APP1/XMP segments always appear in the header, before the SOS marker.
    final headerLen = bytes.length < 131072 ? bytes.length : 131072;
    final xmp = extractXmpMetadata(bytes.sublist(0, headerLen));
    if (xmp == null) return null;

    // GCamera:MicroVideoOffset is the byte count from the END of the file to
    // the start of the embedded MP4.
    final match = RegExp(r'MicroVideoOffset\s*=\s*"?(\d+)').firstMatch(xmp);
    if (match == null) return null;

    final offset = int.tryParse(match.group(1) ?? '');
    if (offset == null || offset <= 0 || offset >= bytes.length) return null;

    final videoStart = bytes.length - offset;
    if (videoStart <= 0 || videoStart >= bytes.length) return null;

    final imageData = bytes.sublist(0, videoStart);
    final videoData = bytes.sublist(videoStart);

    if (!_isValidJpeg(imageData)) return null;

    return MotionPhoto(
      filePath: filePath,
      imageData: imageData,
      videoData: videoData,
      videoOffset: videoStart,
      videoSize: offset,
    );
  }

  // _isValidJpeg retained for sanity check only
  bool _isValidJpeg(final Uint8List data) {
    if (data.length < 2) {
      return false;
    }
    return data[0] == 0xFF && data[1] == 0xD8;
  }

  /// Returns a copy of [jpegBytes] with the XMP APP1 segment removed.
  ///
  /// Extracted still images retain the original motion-photo XMP (which
  /// contains [GCamera:MicroVideo="1"] and a stale [GCamera:MicroVideoOffset])
  /// even after the video bytes are discarded. The [motion_photos] package's
  /// [isMotionPhoto()] returns true for any file whose XMP declares it as a
  /// motion photo, regardless of whether the video offset is valid. Removing
  /// the XMP APP1 segment ensures the extracted still is not mis-identified as
  /// a motion photo by downstream code or by the [motion_photos] package.
  ///
  /// Only the XMP APP1 segment (identified by the
  /// `http://ns.adobe.com/xap/1.0/` namespace URI) is removed. All other JPEG
  /// segments (EXIF, ICC profile, image data, etc.) are preserved. If the
  /// input is not a valid JPEG or contains no XMP, it is returned unchanged.
  Uint8List stripMotionPhotoXmp(final List<int> input) {
    final bytes = input is Uint8List ? input : Uint8List.fromList(input);
    if (!_isValidJpeg(bytes)) return bytes;

    final result = <int>[0xFF, 0xD8]; // SOI
    var i = 2;

    while (i < bytes.length - 1) {
      if (bytes[i] != 0xFF) {
        // Unexpected non-marker byte — copy remainder as-is.
        result.addAll(bytes.sublist(i));
        break;
      }

      final marker = bytes[i + 1];

      // EOI — end of image.
      if (marker == 0xD9) {
        result.addAll([0xFF, 0xD9]);
        break;
      }

      // Standalone markers (SOI, RST0-RST7) — 2 bytes, no length.
      if (marker == 0xD8 || (marker >= 0xD0 && marker <= 0xD7)) {
        result.addAll([0xFF, marker]);
        i += 2;
        continue;
      }

      // SOS — image data follows; can't parse further; copy to end.
      if (marker == 0xDA) {
        result.addAll(bytes.sublist(i));
        break;
      }

      // All other markers carry a 2-byte big-endian length that includes itself.
      if (i + 3 >= bytes.length) {
        result.addAll(bytes.sublist(i));
        break;
      }
      final segLen = (bytes[i + 2] << 8) | bytes[i + 3];
      final segEnd = i + 2 + segLen;
      if (segEnd > bytes.length) {
        result.addAll(bytes.sublist(i));
        break;
      }

      // APP1 — skip the segment if it is the XMP APP1.
      if (marker == 0xE1) {
        const xmpNs = 'http://ns.adobe.com/xap/1.0/';
        final payloadStart = i + 4;
        final payloadLen = segLen - 2;
        if (payloadLen >= xmpNs.length + 1 &&
            payloadStart + xmpNs.length <= bytes.length) {
          final ns = String.fromCharCodes(
            bytes.sublist(payloadStart, payloadStart + xmpNs.length),
          );
          if (ns == xmpNs) {
            i = segEnd; // Skip this XMP APP1 segment.
            continue;
          }
        }
      }

      // Copy segment as-is.
      result.addAll(bytes.sublist(i, segEnd));
      i = segEnd;
    }

    return Uint8List.fromList(result);
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
