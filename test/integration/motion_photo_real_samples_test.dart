import 'dart:io';

import 'package:motion_photos/motion_photos.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  group('Motion photo real sample handling', () {
    final sampleDir = p.join('test', 'raw_samples', 'motionphotos');

    test(
      'PXL_20230519_101651057.MP and .MP.jpg: .MP.jpg is a motion photo, .MP is redundant',
      () async {
        final mpPath = p.join(sampleDir, 'PXL_20230519_101651057.MP');
        final jpgPath = p.join(sampleDir, 'PXL_20230519_101651057.MP.jpg');
        expect(File(mpPath).existsSync(), isTrue);
        expect(File(jpgPath).existsSync(), isTrue);

        final isMotionJpg = await MotionPhotos(jpgPath).isMotionPhoto();
        expect(
          isMotionJpg,
          isTrue,
          reason: '.MP.jpg should be detected as motion photo',
        );
      },
    );

    test(
      'IMG_4188.HEIC and IMG_4188.MP4: HEIC is JPEG-encoded and passes through as a separate file (not embedded motion photo)',
      () async {
        final heicPath = p.join(sampleDir, 'IMG_4188.HEIC');
        final mp4Path = p.join(sampleDir, 'IMG_4188.MP4');
        expect(File(heicPath).existsSync(), isTrue);
        expect(File(mp4Path).existsSync(), isTrue);

        // The HEIC file is actually JPEG-encoded (FF D8 FF magic bytes),
        // so it can be combined with the MP4 to form a Google motion JPEG.
        final heicBytes = await File(heicPath).readAsBytes();
        expect(
          heicBytes[0] == 0xFF && heicBytes[1] == 0xD8,
          isTrue,
          reason:
              'IMG_4188.HEIC is JPEG-encoded and can be used in motion photo creation',
        );

        // The MotionPhotos plugin does not see the HEIC itself as a motion photo —
        // the video is a separate companion file, not embedded.
        final isMotionHeic = await MotionPhotos(heicPath).isMotionPhoto();
        expect(
          isMotionHeic,
          isFalse,
          reason:
              'HEIC should not be detected as a self-contained motion photo',
        );
      },
    );

    test('IMG_2916.HEIC and IMG_2916.MOV: not related, do not merge', () async {
      final heicPath = p.join(sampleDir, 'IMG_2916.HEIC');
      final movPath = p.join(sampleDir, 'IMG_2916.MOV');
      expect(File(heicPath).existsSync(), isTrue);
      expect(File(movPath).existsSync(), isTrue);

      final isMotionHeic = await MotionPhotos(heicPath).isMotionPhoto();
      expect(
        isMotionHeic,
        isFalse,
        reason: 'HEIC should not be detected as motion photo',
      );
      // .MOV is not paired or merged with .HEIC
    });
  });
}
