import 'dart:io';

import 'package:emoji_regex/emoji_regex.dart' as regex;
import 'package:gpth_neo/gpth_lib_exports.dart';
import 'package:path/path.dart' as path;

/// Service for sanitizing filenames and handling emoji characters
class FilenameSanitizerService with LoggerMixin {
  FilenameSanitizerService();

  /// Encodes emoji characters in album directory names to hex representation and renames the folder.
  ///
  /// This function handles filesystem compatibility issues with emoji characters
  /// by converting them to hexadecimal representations. It processes both
  /// standard Unicode emojis and invisible modifier characters.
  ///
  /// [albumDir] The Directory whose name may contain emoji characters.
  /// Returns the new (possibly hex-encoded) directory after renaming on disk.
  Directory encodeAndRenameAlbumIfEmoji(final Directory albumDir) {
    final String originalName = path.basename(albumDir.path);
    if (!regex.emojiRegex().hasMatch(originalName) &&
        !RegExp(r'\u{FE0F}|\u{FE0E}', unicode: true).hasMatch(originalName)) {
      // Check for emojis or invisible modifier characters (variation selectors)
      return albumDir;
    }

    logInfo('Found an emoji in \\${albumDir.path}. Encoding it to hex.');
    final String parentPath = albumDir.parent.path;
    final StringBuffer cleanName = StringBuffer();

    for (int i = 0; i < originalName.length; i++) {
      final int codeUnit = originalName.codeUnitAt(i);
      final String char = String.fromCharCode(
        codeUnit,
      ); // Handle high surrogates (first part of surrogate pairs for emojis > U+FFFF)
      if (codeUnit >= 0xD800 &&
          codeUnit <= 0xDBFF &&
          i + 1 < originalName.length) {
        final int nextCodeUnit = originalName.codeUnitAt(i + 1);
        if (nextCodeUnit >= 0xDC00 && nextCodeUnit <= 0xDFFF) {
          // Combine surrogate pair to get actual Unicode code point
          final int emoji =
              ((codeUnit - 0xD800) << 10) + (nextCodeUnit - 0xDC00) + 0x10000;
          cleanName.write('_0x${emoji.toRadixString(16)}_');
          i++; // Skip the next code unit as it's part of this surrogate pair
          continue;
        }
      } // Handle Basic Multilingual Plane (BMP) emojis and invisible modifier characters
      if (regex.emojiRegex().hasMatch(char) ||
          RegExp(r'\u{FE0F}|\u{FE0E}', unicode: true).hasMatch(char)) {
        cleanName.write('_0x${codeUnit.toRadixString(16)}_');
      } else {
        cleanName.write(char);
      }
    }
    final String newPath = path.join(parentPath, cleanName.toString());
    if (albumDir.path != newPath) {
      // Check if directory exists before attempting rename
      if (!albumDir.existsSync()) {
        logWarning('Directory does not exist: ${albumDir.path}');
        return albumDir; // Return original directory if it doesn't exist
      }

      // On Windows a previous interrupted pipeline run may have renamed the
      // emoji dir to hex but crashed before restoring it.  If the hex-encoded
      // destination already exists, treat it as "already renamed" and return it
      // so the pipeline can proceed without throwing.
      if (Directory(newPath).existsSync()) {
        logWarning(
          'Hex-encoded destination already exists at $newPath – '
          'skipping rename of "${albumDir.path}" (may be from a previous interrupted run).',
        );
        return Directory(newPath);
      }

      try {
        albumDir.renameSync(newPath);
      } catch (e) {
        throw Exception(
          'Error while trying to rename directory with emoji "${albumDir.path}": $e',
        );
      }
    }
    return Directory(newPath);
  }

  /// Decodes hex-encoded emoji sequences back to emoji characters.
  ///
  /// This function reverses the encoding process, converting hex-encoded
  /// emoji sequences back to their original Unicode characters. It only
  /// processes the final path segment (filename/directory name).
  ///
  /// [encodedPath] The path with hex-encoded emojis in the last segment.
  /// Returns the path with emojis restored, or the original path if no encoding is present.
  String decodeAndRestoreAlbumEmoji(final String encodedPath) {
    final List<String> parts = encodedPath.split(path.separator);
    if (parts.isEmpty) return encodedPath;

    // Only decode if hex-encoded emoji is present in the last segment
    if (RegExp(r'_0x[0-9a-fA-F]+_').hasMatch(parts.last)) {
      logInfo(
        'Found a hex encoded emoji in $encodedPath. Decoding it back to emoji.',
      );
      parts[parts.length - 1] = _decodeEmojiComponent(parts.last);
      return parts.join(path.separator);
    }
    return encodedPath;
  }

  /// Decodes hex-encoded emoji characters in a string back to original emoji
  ///
  /// This is useful for decoding album names that contain hex-encoded emoji
  /// instead of full paths. Used for album-info.json generation.
  ///
  /// [text] String that may contain hex-encoded emoji sequences
  /// Returns the string with emoji restored
  String decodeEmojiInText(final String text) => _decodeEmojiComponent(text);

  /// Internal helper function to decode hex-encoded emoji characters back to Unicode.
  ///
  /// Processes strings containing patterns like "_0x1f600_" and converts them
  /// back to their corresponding Unicode characters. Handles both BMP characters
  /// and characters requiring surrogate pairs.
  ///
  /// [component] A string potentially containing hex-encoded emojis
  /// Returns the string with all hex-encoded emojis converted back to Unicode
  String _decodeEmojiComponent(final String component) {
    final RegExp emojiPattern = RegExp(r'_0x([0-9a-fA-F]+)_');
    return component.replaceAllMapped(emojiPattern, (final Match match) {
      final int codePoint = int.parse(match.group(1)!, radix: 16);
      return String.fromCharCode(codePoint);
    });
  }
}
