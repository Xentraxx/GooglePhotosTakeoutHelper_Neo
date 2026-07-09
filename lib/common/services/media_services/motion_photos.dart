import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

/// A pure-Dart replacement for the `motion_photos` package.

/// Stores the start/end byte offsets of the embedded video within a motion
/// photo file.
class VideoIndex {
  const VideoIndex({required this.start, required this.end});

  /// Starting index of the video content in the motion photo buffer.
  final int start;

  /// Ending index of the video content in the motion photo buffer.
  final int end;

  int get videoLength => end - start;

  @override
  String toString() =>
      'VideoIndex{start: $start, end: $end, videoLength: $videoLength}';

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is VideoIndex &&
          runtimeType == other.runtimeType &&
          start == other.start &&
          end == other.end &&
          videoLength == other.videoLength;

  @override
  int get hashCode => start.hashCode ^ end.hashCode ^ videoLength.hashCode;
}

/// Classifies a file as a motion photo and, if so, extracts its [VideoIndex].
class MotionPhotos {
  MotionPhotos(this.filePath);
  final String filePath;
  bool bufferLoaded = false;
  late Uint8List _buffer;

  Future<void> loadBuffer() async {
    if (!bufferLoaded) {
      final File file = File(filePath);
      _buffer = await file.readAsBytes();
      bufferLoaded = true;
    }
  }

  /// Returns true if the file is a motion photo (i.e. an embedded video
  /// offset can be located).
  Future<bool> isMotionPhoto() async {
    try {
      await loadBuffer();
      return (await getMotionVideoIndex()) != null;
    } catch (e) {
      return false;
    }
  }

  /// Returns the [VideoIndex] of the embedded video, or null if the file is
  /// not a motion photo.
  ///
  /// The order matters: first look for the MP4 `ftyp mp42` header, then fall
  /// back to XMP-based offset extraction.
  Future<VideoIndex?> getMotionVideoIndex() async {
    await loadBuffer();
    final int mp4Index = _boyerMooreSearch(_buffer, _mp4HeaderPattern);
    if (mp4Index != -1) {
      return VideoIndex(start: mp4Index, end: _buffer.lengthInBytes);
    }
    return _extractVideoIndexFromXmp(_buffer);
  }

  // ───────────────────────────────────────────────────────────────────────
  // XMP extraction (regex-based, no `xml` dependency)
  // ───────────────────────────────────────────────────────────────────────

  static final RegExp _xmpBlock = RegExp(
    r'<x:xmpmeta.*?</x:xmpmeta>',
    dotAll: true,
  );

  /// Keys whose value is the byte count from the END of the file to the start
  /// of the embedded video. Mirrors `MotionPhotoConstants.fileOffsetKeys`.
  static const List<String> _offsetKeys = [
    'Item:Length',
    'GCamera:MicroVideoOffset',
  ];

  /// Tags that confirm a file is a motion photo even when the offset looks
  /// suspicious. Mirrors `MotionPhotoHelpers.hasMotionPhotoTags`.
  static bool _hasMotionPhotoTags(String xmp) {
    if (xmp.contains('GCamera:MotionPhoto')) return true;
    final mimeMatch = RegExp(r'Item:Mime\s*=\s*"([^"]*)"').firstMatch(xmp);
    if (mimeMatch != null && mimeMatch.group(1)!.startsWith('video')) {
      return true;
    }
    return false;
  }

  static VideoIndex? _extractVideoIndexFromXmp(Uint8List bytes) {
    try {
      final String buffer = latin1.decode(bytes, allowInvalid: false);
      final match = _xmpBlock.firstMatch(buffer);
      if (match == null) return null;
      final xmp = match.group(0)!;

      final int size = bytes.lengthInBytes;
      for (final key in _offsetKeys) {
        final valueMatch = RegExp('$key\\s*=\\s*"?([0-9]+)').firstMatch(xmp);
        if (valueMatch == null) continue;
        final offsetFromEnd = int.tryParse(valueMatch.group(1) ?? '');
        if (offsetFromEnd == null) continue;

        if (key == 'Item:Length') {
          // Sanity check: the offset must point inside the file, and if it
          // looks invalid we require explicit motion-photo tags before
          // trusting it.
          if (offsetFromEnd < 0 ||
              offsetFromEnd > size ||
              (size - offsetFromEnd < 0) ||
              !_hasMotionPhotoTags(xmp)) {
            continue;
          }
        }
        final start = size - offsetFromEnd;
        if (start < 0 || start > size) continue;
        return VideoIndex(start: start, end: size);
      }
    } catch (e) {
      // Swallow — matches the package's behaviour of returning null on failure.
    }
    return null;
  }

  // ───────────────────────────────────────────────────────────────────────
  // Boyer-Moore search (ported verbatim from the package)
  // ───────────────────────────────────────────────────────────────────────

  static int _boyerMooreSearch(List<int> arr, List<int> pattern) {
    final int arrLen = arr.length;
    final int patternLen = pattern.length;

    if (patternLen == 0) {
      return 0;
    }

    final Map<int, int> badChar = {};
    for (int i = 0; i < patternLen; i++) {
      badChar[pattern[i]] = i;
    }

    int shift = 0;
    while (shift <= arrLen - patternLen) {
      int j = patternLen - 1;

      while (j >= 0 && pattern[j] == arr[shift + j]) {
        j--;
      }

      if (j < 0) {
        return shift;
      } else {
        final int charIndex = arr[shift + j];
        final int badCharShift = badChar.containsKey(charIndex)
            ? badChar[charIndex]!
            : -1;
        shift += max(1, j - badCharShift);
      }
    }

    return -1;
  }

  // MP4 file header pattern with 'mp42' as the major brand.
  static final Uint8List _mp4HeaderPattern = Uint8List.fromList([
    0x00,
    0x00,
    0x00,
    0x18,
    0x66,
    0x74,
    0x79,
    0x70,
    0x6D,
    0x70,
    0x34,
    0x32,
    0x00,
    0x00,
    0x00,
    0x00,
  ]);
}
