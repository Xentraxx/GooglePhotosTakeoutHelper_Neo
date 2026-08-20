/// Unit tests for [MediaExtensions.isMotionPhotoExtension].
///
/// Validates the single source of truth for Pixel motion-photo extension
/// recognition, including the `.cover` (album cover) and `.mp~<digits>`
/// (edited alternate) families added for issue #138.
library;

import 'package:gpth_neo/gpth_lib_exports.dart';
import 'package:test/test.dart';

void main() {
  group('MediaExtensions.isMotionPhotoExtension', () {
    group('recognizes standard motion-photo extensions', () {
      test('lowercase .mp', () {
        expect(MediaExtensions.isMotionPhotoExtension('IMG_0001.mp'), isTrue);
      });

      test('uppercase .MP', () {
        expect(MediaExtensions.isMotionPhotoExtension('IMG_0001.MP'), isTrue);
      });

      test('mixed case .Mv', () {
        expect(MediaExtensions.isMotionPhotoExtension('IMG_0001.Mv'), isTrue);
      });

      test('lowercase .mv', () {
        expect(MediaExtensions.isMotionPhotoExtension('IMG_0001.mv'), isTrue);
      });

      test('with full path', () {
        expect(
          MediaExtensions.isMotionPhotoExtension(
            '/takeout/2023/Photos/IMG_0001.MP',
          ),
          isTrue,
        );
      });
    });

    group('recognizes .cover album-cover extension (issue #138)', () {
      test('lowercase .cover', () {
        expect(MediaExtensions.isMotionPhotoExtension('album.cover'), isTrue);
      });

      test('uppercase .COVER', () {
        expect(MediaExtensions.isMotionPhotoExtension('album.COVER'), isTrue);
      });

      test('with full path', () {
        expect(
          MediaExtensions.isMotionPhotoExtension(
            '/takeout/Albums/Summer/cover.cover',
          ),
          isTrue,
        );
      });
    });

    group('recognizes .mp~<digits> edited-alternate family (issue #138)', () {
      test('.mp~2 (the exact case reported)', () {
        expect(MediaExtensions.isMotionPhotoExtension('video.mp~2'), isTrue);
      });

      test('.mp~1', () {
        expect(MediaExtensions.isMotionPhotoExtension('video.mp~1'), isTrue);
      });

      test('.mp~12 (multi-digit)', () {
        expect(MediaExtensions.isMotionPhotoExtension('video.mp~12'), isTrue);
      });

      test('uppercase .MP~3', () {
        expect(MediaExtensions.isMotionPhotoExtension('video.MP~3'), isTrue);
      });

      test('with full path', () {
        expect(
          MediaExtensions.isMotionPhotoExtension(
            '/takeout/2023/Photos/IMG_0002.mp~2',
          ),
          isTrue,
        );
      });
    });

    group('rejects non-motion-photo extensions', () {
      test('.jpg', () {
        expect(MediaExtensions.isMotionPhotoExtension('photo.jpg'), isFalse);
      });

      test('.mp4 (not .mp)', () {
        expect(MediaExtensions.isMotionPhotoExtension('video.mp4'), isFalse);
      });

      test('.heic', () {
        expect(MediaExtensions.isMotionPhotoExtension('photo.heic'), isFalse);
      });

      test('.dng (raw, not motion)', () {
        expect(MediaExtensions.isMotionPhotoExtension('photo.dng'), isFalse);
      });

      test('.mpx (similar but not .mp)', () {
        expect(MediaExtensions.isMotionPhotoExtension('photo.mpx'), isFalse);
      });

      test('no extension', () {
        expect(MediaExtensions.isMotionPhotoExtension('photo'), isFalse);
      });

      test('empty string', () {
        expect(MediaExtensions.isMotionPhotoExtension(''), isFalse);
      });
    });

    group('rejects malformed .mp~ variants', () {
      test('.mp~ with no digits', () {
        expect(MediaExtensions.isMotionPhotoExtension('video.mp~'), isFalse);
      });

      test('.mp~abc with non-digit suffix', () {
        expect(MediaExtensions.isMotionPhotoExtension('video.mp~abc'), isFalse);
      });

      test('.mp~2.jpg (extension is .jpg, not .mp~2)', () {
        expect(
          MediaExtensions.isMotionPhotoExtension('video.mp~2.jpg'),
          isFalse,
        );
      });

      test('.cover.jpg (extension is .jpg, not .cover)', () {
        expect(
          MediaExtensions.isMotionPhotoExtension('album.cover.jpg'),
          isFalse,
        );
      });
    });
  });

  group('MediaExtensions.additional', () {
    test('includes .cover (issue #138)', () {
      expect(MediaExtensions.additional.contains('.cover'), isTrue);
    });

    test('still includes .mp and .mv', () {
      expect(MediaExtensions.additional.contains('.mp'), isTrue);
      expect(MediaExtensions.additional.contains('.mv'), isTrue);
    });

    test('still includes raw formats .dng and .cr2', () {
      expect(MediaExtensions.additional.contains('.dng'), isTrue);
      expect(MediaExtensions.additional.contains('.cr2'), isTrue);
    });
  });
}
