/// Tests for the ExifTool stderr path-extraction logic inside
/// WriteExifProcessingService, specifically the fix that prevents an infinite
/// error-loop when an album folder name contains a hyphen (" - ").
///
/// Regression for: paths like "/Photos/Birthday Party - 16.42022/img.jpg"
/// previously caused the last " - " to be mistaken for the ExifTool
/// message/path separator, so the extracted "path" was only the trailing
/// fragment and never matched any queue entry → writeBatchSafe re-queued
/// the same chunk endlessly.
library;

import 'package:gpth_neo/gpth_lib_exports.dart';
import 'package:test/test.dart';

/// Minimal stub that satisfies the WriteExifProcessingService constructor.
/// We never call any exiftool methods in these tests.
class _NullExifTool {}

WriteExifProcessingService _makeService() =>
    WriteExifProcessingService(exifTool: _NullExifTool());

void main() {
  group('WriteExifProcessingService._extractBadPathsFromExifError', () {
    late WriteExifProcessingService svc;

    setUp(() {
      svc = _makeService();
    });

    // -----------------------------------------------------------------------
    // Helper – thin wrapper around the @visibleForTesting accessor
    // -----------------------------------------------------------------------
    Set<String> extract(final String errorText) =>
        svc.extractBadPathsFromExifErrorForTest(errorText);

    // -----------------------------------------------------------------------
    // Baseline: paths WITHOUT a hyphen in the directory name
    // -----------------------------------------------------------------------

    test('extracts Unix absolute path without hyphen in directory', () {
      const stderr =
          'Error: File not writable - /home/user/Photos/photo.jpg\n'
          '    0 image files updated';
      final paths = extract(stderr);

      expect(paths, contains('/home/user/photos/photo.jpg'));
    });

    test('extracts Windows absolute path without hyphen in directory', () {
      const stderr =
          r'Error: File not writable - C:\Users\user\Photos\photo.jpg'
          '\n    0 image files updated';
      final paths = extract(stderr);

      expect(
        paths,
        anyOf(
          contains(r'c:\users\user\photos\photo.jpg'),
          contains('c:/users/user/photos/photo.jpg'),
        ),
      );
    });

    // -----------------------------------------------------------------------
    // The regression case: album directory contains " - "
    // -----------------------------------------------------------------------

    test(
      'extracts correct path when Unix album folder contains " - " (regression)',
      () {
        // Before the fix, lastIndexOf(" - ") would land on the " - " inside
        // the album name, producing only "16.42022/photo.jpg" which never
        // matched any queue entry → infinite loop.
        const stderr =
            'Error: File not writable - '
            '/home/user/Birthday Party - 16.42022/photo.jpg\n'
            '    0 image files updated';
        final paths = extract(stderr);

        // Must contain the FULL path (lowercased), not just the trailing fragment.
        expect(
          paths,
          contains('/home/user/birthday party - 16.42022/photo.jpg'),
        );
        // The fragment alone must NOT be returned as the sole result.
        expect(paths, isNot(equals({'16.42022/photo.jpg'})));
      },
    );

    test(
      'extracts correct path when Windows album folder contains " - " (regression)',
      () {
        const stderr =
            r'Error: File not writable - '
            r'C:\Users\user\Taufe anna - 16.42022\img.jpg'
            '\n    0 image files updated';
        final paths = extract(stderr);

        // At least one variant must contain the full album folder segment.
        expect(
          paths.any(
            (final p) =>
                p.contains('taufe anna - 16.42022') && p.endsWith('img.jpg'),
          ),
          isTrue,
          reason: 'Expected full path including album hyphen, got: $paths',
        );
      },
    );

    test('extracts correct path when album folder contains multiple " - "', () {
      const stderr =
          'Error: File not writable - '
          '/mnt/photos/A - B - C/snap.png\n'
          '    0 image files updated';
      final paths = extract(stderr);

      expect(
        paths.any(
          (final p) => p.contains('a - b - c') && p.endsWith('snap.png'),
        ),
        isTrue,
        reason: 'Expected full path including multiple hyphens, got: $paths',
      );
    });

    // -----------------------------------------------------------------------
    // Relative-path fallback (no absolute-path prefix)
    // -----------------------------------------------------------------------

    test('extracts relative path when no absolute prefix is present', () {
      const stderr =
          'Error: File not writable - relative/subdir/photo.jpg\n'
          '    0 image files updated';
      final paths = extract(stderr);

      expect(paths.any((final p) => p.endsWith('photo.jpg')), isTrue);
    });

    // -----------------------------------------------------------------------
    // Empty / unrecognised error → must return empty set (prevents infinite loop)
    // -----------------------------------------------------------------------

    test('returns empty set for error with no recognisable path', () {
      const stderr = 'Some internal ExifTool error without any file reference';
      final paths = extract(stderr);

      expect(paths, isEmpty);
    });

    test('returns empty set for blank error string', () {
      final paths = extract('');
      expect(paths, isEmpty);
    });

    // -----------------------------------------------------------------------
    // Multi-line stderr with mixed good/bad lines
    // -----------------------------------------------------------------------

    test('ignores non-diagnostic lines and collects only the bad path', () {
      const stderr =
          '    1 image files read\n'
          'Error: File not writable - /media/photos/Summer - 2023/img.jpg\n'
          '    0 image files updated\n';
      final paths = extract(stderr);

      expect(
        paths.any(
          (final p) => p.contains('summer - 2023') && p.endsWith('img.jpg'),
        ),
        isTrue,
      );
    });

    test('collects multiple bad paths from multi-line stderr', () {
      const stderr =
          'Error: File not writable - /photos/album1/a.jpg\n'
          'Error: File not writable - /photos/album2/b.jpg\n';
      final paths = extract(stderr);

      expect(paths, contains('/photos/album1/a.jpg'));
      expect(paths, contains('/photos/album2/b.jpg'));
    });
  });
}
