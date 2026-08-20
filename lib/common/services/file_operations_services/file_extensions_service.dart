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
    final String mime = lookupMimeType(e.path) ?? '';
    final String fileExtension = p.extension(e.path).toLowerCase();
    return mime.startsWith('image/') ||
        mime.startsWith('video/') ||
        // https://github.com/TheLastGimbus/GooglePhotosTakeoutHelper/issues/223
        // https://github.com/dart-lang/mime/issues/102
        // 🙃🙃
        mime == 'model/vnd.mts' ||
        MediaExtensions.additional.contains(fileExtension) ||
        // Pixel motion-photo extensions not covered by dart:mime, including
        // the `.mp~<digits>` edited-alternate family (issue #138).
        MediaExtensions.isMotionPhotoExtension(e.path);
  });
}

/// Extension methods for `Stream<FileSystemEntity>`
extension FileSystemEntityStreamExtension on Stream<FileSystemEntity> {
  /// Filters for files that are photos or videos
  Stream<File> wherePhotoVideo() => whereType<File>().where((final File e) {
    final String mime = lookupMimeType(e.path) ?? '';
    final String fileExtension = p.extension(e.path).toLowerCase();
    return mime.startsWith('image/') ||
        mime.startsWith('video/') ||
        // https://github.com/TheLastGimbus/GooglePhotosTakeoutHelper/issues/223
        // https://github.com/dart-lang/mime/issues/102
        // 🙃🙃
        mime == 'model/vnd.mts' ||
        MediaExtensions.additional.contains(fileExtension) ||
        // Pixel motion-photo extensions not covered by dart:mime, including
        // the `.mp~<digits>` edited-alternate family (issue #138).
        MediaExtensions.isMotionPhotoExtension(e.path);
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
