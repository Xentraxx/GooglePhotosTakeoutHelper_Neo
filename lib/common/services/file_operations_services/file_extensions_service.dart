/// File-related extensions for common operations
///
/// Extracted from utils.dart to provide a clean, reusable set of extensions
/// for file operations throughout the application.
library;

import 'dart:io';

import 'package:gpth_neo/gpth_lib_exports.dart';
import 'package:mime/mime.dart';
import 'package:path/path.dart' as p;

/// Extension methods for `Iterable<FileSystemEntity>`
extension FileSystemEntityIterableExtension on Iterable<FileSystemEntity> {
  /// Filters for files that are photos or videos
  Iterable<File> wherePhotoVideo() => whereType<File>().where((final File e) {
    // Fast path: check extension first (cheap set lookup) before falling back
    // to the more expensive lookupMimeType call.
    final String fileExtension = p.extension(e.path).toLowerCase();
    if (MediaExtensions.additional.contains(fileExtension) ||
        MediaExtensions.isMotionPhotoExtension(e.path)) {
      return true;
    }

    // Slow path: MIME type lookup for standard image/video extensions.
    final String mime = lookupMimeType(e.path) ?? '';
    return mime.startsWith('image/') ||
        mime.startsWith('video/') ||
        // https://github.com/TheLastGimbus/GooglePhotosTakeoutHelper/issues/223
        // https://github.com/dart-lang/mime/issues/102
        // 🙃🙃
        mime == 'model/vnd.mts';
  });
}

/// Extension methods for `Stream<FileSystemEntity>`
extension FileSystemEntityStreamExtension on Stream<FileSystemEntity> {
  /// Filters for files that are photos or videos
  Stream<File> wherePhotoVideo() => whereType<File>().where((final File e) {
    // Fast path: check extension first (cheap set lookup) before falling back
    // to the more expensive lookupMimeType call.
    final String fileExtension = p.extension(e.path).toLowerCase();
    if (MediaExtensions.additional.contains(fileExtension) ||
        MediaExtensions.isMotionPhotoExtension(e.path)) {
      return true;
    }

    // Slow path: MIME type lookup for standard image/video extensions.
    final String mime = lookupMimeType(e.path) ?? '';
    return mime.startsWith('image/') ||
        mime.startsWith('video/') ||
        // https://github.com/TheLastGimbus/GooglePhotosTakeoutHelper/issues/223
        // https://github.com/dart-lang/mime/issues/102
        // 🙃🙃
        mime == 'model/vnd.mts';
  });
}

/// Extension methods for Stream
extension StreamExtension on Stream {
  /// Filters stream elements by type
  Stream<T> whereType<T>() => where((final e) => e is T).cast<T>();
}

/// Extension methods for String
extension StringExtension on String {
  /// Replaces the last occurrence of a pattern in a string
  String replaceLast(final String from, final String to) {
    final int lastIndex = lastIndexOf(from);
    if (lastIndex == -1) return this;
    return replaceRange(lastIndex, lastIndex + from.length, to);
  }
}
