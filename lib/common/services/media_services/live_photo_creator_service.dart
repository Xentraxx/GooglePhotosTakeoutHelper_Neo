import 'dart:io';
import 'package:meta/meta.dart';
import 'live_photo_models.dart';
import 'motion_photo_extractor_service.dart';

/// Service for creating Google Motion Photo V2 containers (JPEG + appended MP4).
///
/// Produces files in the same format Google Photos exports: a JPEG whose XMP
/// APP1 segment carries a `GCamera:MicroVideoOffset` pointing at the MP4 bytes
/// appended after the JPEG. This is the inverse of
/// [MotionPhotoExtractorService._parseGoogleMotionPhotoV2] (the reader) and
/// [MotionPhotoExtractorService.stripMotionPhotoXmp] (the XMP remover).
class LivePhotoCreatorService {
  /// Creates a new instance of LivePhotoCreatorService
  const LivePhotoCreatorService();

  /// Creates a live photo from image and video data
  ///
  /// [outputPath] Where to save the live photo file
  /// [imageData] The image file bytes (can be JPEG, etc.)
  /// [videoData] The embedded video bytes
  /// [metadata] Metadata to include in the live photo
  /// [config] Conversion configuration options
  ///
  /// Returns the created LivePhoto object
  Future<LivePhoto> createLivePhoto({
    required final String outputPath,
    required final List<int> imageData,
    required final List<int> videoData,
    required final LivePhotoMetadata metadata,
    final LivePhotoConversionConfig config = const LivePhotoConversionConfig(),
  }) async {
    // Ensure output directory exists
    final outputFile = File(outputPath);
    await outputFile.parent.create(recursive: true);

    // Build a valid Google Motion Photo V2 container: a JPEG whose XMP APP1
    // segment carries GCamera:MicroVideoOffset pointing at the MP4 appended
    // after the JPEG. This is what Google Photos natively exports and what
    // MotionPhotoExtractorService._parseGoogleMotionPhotoV2() consumes.
    final livePhotoData = createLivePhotoContainer(
      imageData,
      videoData,
      metadata,
      config,
    );

    await outputFile.writeAsBytes(livePhotoData);

    return LivePhoto(
      outputPath: outputPath,
      imageData: imageData,
      videoData: videoData,
      videoFormat: _detectVideoFormat(videoData),
      metadata: metadata,
    );
  }

  /// Builds a Google Motion Photo V2 container (JPEG + XMP offset + MP4).
  ///
  /// Layout: `[SOI][XMP APP1][rest of JPEG][MP4 bytes]`.
  ///
  /// - Any stale motion-photo XMP already present in [imageData] is stripped
  ///   first (via [MotionPhotoExtractorService.stripMotionPhotoXmp]) so a
  ///   sidecar-derived still cannot carry a wrong/old offset.
  /// - A fresh XMP APP1 segment is inserted immediately after the JPEG SOI
  ///   (`0xFF 0xD8`). It declares the file as a motion photo and records
  ///   `GCamera:MicroVideoOffset` = [videoData] length — the byte count from
  ///   the END of the file to the start of the appended MP4 (the exact
  ///   semantics the reader expects).
  /// - The MP4 is appended verbatim after the (modified) JPEG.
  @visibleForTesting
  List<int> createLivePhotoContainer(
    final List<int> imageData,
    final List<int> videoData,
    final LivePhotoMetadata metadata,
    final LivePhotoConversionConfig config,
  ) {
    // 1. Strip any pre-existing motion-photo XMP so the only offset in the
    //    output is the one we write below.
    final cleanedJpeg = const MotionPhotoExtractorService().stripMotionPhotoXmp(
      imageData,
    );

    // 2. Build the XMP APP1 segment and insert it right after the SOI marker.
    //    APP segments may appear in any order; placing it first is simplest and
    //    universally accepted by decoders.
    final xmpApp1 = buildMotionPhotoXmpApp1(videoData.length);
    final result = <int>[];
    if (cleanedJpeg.length >= 2 &&
        cleanedJpeg[0] == 0xFF &&
        cleanedJpeg[1] == 0xD8) {
      result
        ..addAll(cleanedJpeg.sublist(0, 2)) // SOI
        ..addAll(xmpApp1) // XMP APP1
        ..addAll(cleanedJpeg.sublist(2)); // rest of JPEG (APP0/EXIF/SOS/EOI…)
    } else {
      // Not a valid JPEG header — fall back to plain concat so the image at
      // least remains viewable (the caller logs a conversion warning path).
      result.addAll(cleanedJpeg);
    }

    // 3. Append the MP4. MicroVideoOffset == videoData.length, so the reader
    //    computes videoStart = fileLength - offset = result.length (before
    //    append) and lands exactly here.
    result.addAll(videoData);

    return result;
  }

  /// Builds the XMP APP1 segment bytes for a Google Motion Photo V2 file.
  ///
  /// Segment layout: `0xFF 0xE1` + 2-byte big-endian length (includes itself)
  /// + `http://ns.adobe.com/xap/1.0/\0` (namespace URI + null terminator) +
  /// XMP payload. The payload declares `GCamera:MotionPhoto="1"` (so
  /// [MotionPhotos._hasMotionPhotoTags] matches) and
  /// `GCamera:MicroVideoOffset` = [videoLength] (bytes from end of file to the
  /// appended MP4 — the exact semantics the reader expects).
  @visibleForTesting
  static List<int> buildMotionPhotoXmpApp1(final int videoLength) {
    final xmpPayload = _buildMotionPhotoXmpPayload(videoLength);
    final payloadBytes = xmpPayload.codeUnits; // XMP is ASCII-safe.

    const ns = 'http://ns.adobe.com/xap/1.0/';
    final nsBytes = ns.codeUnits; // 28 bytes, no null yet.

    // Segment length = 2 (length field) + ns (28) + 1 (null) + payload.
    final segLen = 2 + nsBytes.length + 1 + payloadBytes.length;
    if (segLen > 0xFFFF) {
      // An APP1 segment cannot exceed 64KB. In practice the payload is tiny
      // (~300 bytes), but guard against pathological inputs by truncating the
      // payload rather than emitting a malformed segment.
      final maxPayload = 0xFFFF - 2 - nsBytes.length - 1;
      payloadBytes.removeRange(maxPayload, payloadBytes.length);
    }
    final finalLen = 2 + nsBytes.length + 1 + payloadBytes.length;

    final segment = <int>[];
    segment
      ..add(0xFF)
      ..add(0xE1) // APP1 marker
      ..add((finalLen >> 8) & 0xFF) // big-endian length (high byte)
      ..add(finalLen & 0xFF) // big-endian length (low byte)
      ..addAll(nsBytes)
      ..add(0x00) // null terminator after namespace URI
      ..addAll(payloadBytes);
    return segment;
  }

  /// Builds the XMP payload string declaring a Google Motion Photo V2.
  ///
  /// Uses the `rdf:Description` **attribute** form (e.g.
  /// `GCamera:MicroVideoOffset="16"`) rather than child elements, because the
  /// reader's regex ([MotionPhotos._offsetKeys] /
  /// [MotionPhotoExtractorService._parseGoogleMotionPhotoV2]) matches
  /// `MicroVideoOffset\s*=\s*"?(\d+)` — i.e. it requires an `=` sign, which
  /// only the attribute form provides.
  static String _buildMotionPhotoXmpPayload(final int videoLength) =>
      '<?xpacket begin="\uFEFF" id="W5M0MpCehiHzreSzNTczkc9d"?>'
      '<x:xmpmeta xmlns:x="adobe:ns:meta/" x:xmptk="GooglePhotosTakeoutHelper">'
      '<rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#">'
      '<rdf:Description rdf:about="" '
      'xmlns:GCamera="http://ns.google.com/photos/1.0/camera/" '
      'GCamera:MotionPhoto="1" '
      'GCamera:MicroVideoOffset="$videoLength"/>'
      '</rdf:RDF>'
      '</x:xmpmeta>'
      '<?xpacket end="w"?>';

  /// Detects the video format from video data
  ///
  /// Returns 'mp4', 'mov', or 'unknown'
  String _detectVideoFormat(final List<int> videoData) {
    if (videoData.length < 12) {
      return 'unknown';
    }

    // Check for MP4/ISOM 'ftyp' box
    if (videoData[4] == 0x66 &&
        videoData[5] == 0x74 &&
        videoData[6] == 0x79 &&
        videoData[7] == 0x70) {
      // Check for specific MP4 variant
      if (videoData.length >= 12) {
        final fourCcCode = String.fromCharCodes(videoData.sublist(8, 12));
        if (fourCcCode == 'isom' ||
            fourCcCode == 'mp42' ||
            fourCcCode == 'mp41') {
          return 'mp4';
        }
      }
      return 'mp4';
    }

    // Check for QuickTime/MOV 'wide' box or 'mdat'
    if (videoData[4] == 0x77 &&
        videoData[5] == 0x69 &&
        videoData[6] == 0x64 &&
        videoData[7] == 0x65) {
      return 'mov';
    }

    return 'unknown';
  }
}

/// Extension method for parsing image dimensions
extension ImageDataExtension on List<int> {
  /// Attempts to extract image dimensions from JPEG data
  ///
  /// Returns (width, height) or null if unable to determine
  (int, int)? extractJpegDimensions() {
    if (length < 20) {
      return null;
    }

    // Look for SOF (Start of Frame) marker
    // SOF markers: 0xFFC0-0xFFC9 (except 0xFFC4 and 0xFFC8)

    int i = 2; // Skip SOI marker
    while (i < length - 9) {
      if (this[i] == 0xFF) {
        final marker = this[i + 1];

        // Check if this is a SOF marker (but not DHT or DAC)
        if ((marker >= 0xC0 && marker <= 0xC3) ||
            (marker >= 0xC5 && marker <= 0xC7) ||
            (marker >= 0xC9 && marker <= 0xCB) ||
            (marker >= 0xCD && marker <= 0xCF)) {
          // Found SOF marker
          // Format: FF C0 [size:2] [precision:1] [height:2] [width:2] ...
          if (i + 9 < length) {
            final height = (this[i + 5] << 8) | this[i + 6];
            final width = (this[i + 7] << 8) | this[i + 8];
            return (width, height);
          }
        }

        // Skip to next marker
        final segmentSize = (this[i + 2] << 8) | this[i + 3];
        i += segmentSize + 2;
      } else {
        i++;
      }
    }

    return null;
  }

  /// Attempts to extract video dimensions from MP4/MOV data
  ///
  /// Returns (width, height) or null if unable to determine
  (int, int)? extractVideoMp4Dimensions() {
    if (length < 32) {
      return null;
    }

    // Look for 'tkhd' (track header) atom in 'moov' box
    // This contains width and height information
    // Format is complex, simplified version looks for common patterns

    // Search for 'tkhd' marker
    final tkhd = [0x74, 0x6B, 0x68, 0x64]; // 'tkhd'

    for (int i = 0; i < length - 36; i++) {
      if (this[i] == tkhd[0] &&
          this[i + 1] == tkhd[1] &&
          this[i + 2] == tkhd[2] &&
          this[i + 3] == tkhd[3]) {
        // Found tkhd box
        // Width/height are at fixed offsets in the box
        if (i + 36 < length) {
          // Extract width and height (fixed point 16.16 format)
          // They're 4 bytes each after some offset
          final widthRaw =
              (this[i + 28] << 8) | this[i + 29]; // Simplified extraction
          final heightRaw = (this[i + 30] << 8) | this[i + 31];

          if (widthRaw > 0 &&
              heightRaw > 0 &&
              widthRaw < 16000 &&
              heightRaw < 16000) {
            return (widthRaw, heightRaw);
          }
        }
      }
    }

    return null;
  }
}
