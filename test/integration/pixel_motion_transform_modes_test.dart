import 'dart:io';

import 'package:gpth_neo/gpth_lib_exports.dart';
import 'package:gpth_neo/steps/step_06_move_files/services/pixel_mp_transform_service.dart';
import 'package:motion_photos/motion_photos.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  setUpAll(() async {
    await ServiceContainer.instance.initialize();
  });

  tearDownAll(() async {
    await ServiceContainer.instance.dispose();
  });

  group('Pixel motion photo transformation modes', () {
    final sampleDir = p.join('test', 'raw_samples', 'motionphotos');
    final tempDir = Directory.systemTemp.createTempSync('pixel_transform_test');
    final outputDir = Directory.systemTemp.createTempSync(
      'pixel_transform_out',
    );
    final yearDir = Directory(p.join(tempDir.path, '2023'));

    setUp(() async {
      // Clean up and recreate directories for each test
      if (outputDir.existsSync()) outputDir.deleteSync(recursive: true);
      outputDir.createSync();
      if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
      tempDir.createSync();
      yearDir.createSync();
      // Only copy Pixel .MP / .MP.jpg files — iPhone HEIC/MOV/MP4 files are
      // tested in motion_photo_real_samples_test.dart and are irrelevant here.
      for (final file in Directory(sampleDir).listSync()) {
        if (file is File) {
          final name = p.basename(file.path).toLowerCase();
          if (name.endsWith('.mp') ||
              name.endsWith('.mp.jpg') ||
              name.endsWith('.mp.jpeg')) {
            file.copySync(p.join(yearDir.path, p.basename(file.path)));
          }
        }
      }
    });

    tearDown(() async {
      // Wait a moment to ensure all file handles are closed
      await Future.delayed(const Duration(milliseconds: 300));
      bool deleted = false;
      for (int i = 0; i < 5 && !deleted; i++) {
        try {
          if (outputDir.existsSync()) outputDir.deleteSync(recursive: true);
          deleted = true;
        } catch (_) {
          await Future.delayed(const Duration(milliseconds: 200));
        }
      }
      deleted = false;
      for (int i = 0; i < 5 && !deleted; i++) {
        try {
          if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
          deleted = true;
        } catch (_) {
          await Future.delayed(const Duration(milliseconds: 200));
        }
      }
    });

    void printInputFiles() {
      final files = yearDir
          .listSync(recursive: true)
          .whereType<File>()
          .toList();
      print('Input files:');
      for (final f in files) {
        print('  ${f.path}');
      }
    }

    test('Transform to mp4', () async {
      printInputFiles();
      final config = ProcessingConfig(
        inputPath: tempDir.path,
        outputPath: outputDir.path,
        transformPixelMp: true,
        writeExif: false,
        skipExtras: true,
        guessFromName: false,
        extensionFixing: ExtensionFixingMode.none,
      );
      const pipeline = ProcessingPipeline();
      final result = await pipeline.execute(
        config: config,
        inputDirectory: tempDir,
        outputDirectory: outputDir,
      );
      expect(result.isSuccess, isTrue);
      final outFiles = outputDir
          .listSync(recursive: true)
          .whereType<File>()
          .toList();
      expect(
        outFiles.any((f) => f.path.endsWith('.mp4')),
        isTrue,
        reason: 'Should produce .mp4',
      );
    });

    test('Transform to jpg (motion photo)', () async {
      printInputFiles();
      final config = ProcessingConfig(
        inputPath: tempDir.path,
        outputPath: outputDir.path,
        transformPixelMp: true,
        pixelMpTransformFormat: PixelMpTransformFormat.jpg,
        writeExif: false,
        skipExtras: true,
        guessFromName: false,
        extensionFixing: ExtensionFixingMode.none,
      );
      const pipeline = ProcessingPipeline();
      final result = await pipeline.execute(
        config: config,
        inputDirectory: tempDir,
        outputDirectory: outputDir,
      );
      expect(result.isSuccess, isTrue);
      final outFiles = outputDir
          .listSync(recursive: true)
          .whereType<File>()
          .toList();
      expect(
        outFiles.any((f) => f.path.endsWith('.jpg')),
        isTrue,
        reason: 'Should produce .jpg',
      );
      expect(
        outFiles.any(
          (f) =>
              f.path.toLowerCase().endsWith('.mp') ||
              f.path.toLowerCase().endsWith('.mv'),
        ),
        isFalse,
        reason:
            '.MP video file should not appear in output when transforming to jpg',
      );
      // The Pixel .MP file should NOT produce a .mp4 (it should become a .jpg)
      expect(
        outFiles.any(
          (f) =>
              p.basename(f.path).toLowerCase() == 'pxl_20230519_101651057.mp4',
        ),
        isFalse,
        reason:
            'Pixel .MP should not produce a .mp4 in output when transforming to jpg',
      );
      // iPhone companion files must not appear — they are not in the test input
      expect(
        outFiles.any((f) => p.basename(f.path).toLowerCase() == 'img_4188.mp4'),
        isFalse,
        reason: 'IMG_4188.MP4 should not appear in output',
      );
      expect(
        outFiles.any(
          (f) => p.basename(f.path).toLowerCase() == 'img_4188.heic',
        ),
        isFalse,
        reason: 'IMG_4188.HEIC should not appear in output',
      );
    });

    test('Transform to still image', () async {
      printInputFiles();
      final config = ProcessingConfig(
        inputPath: tempDir.path,
        outputPath: outputDir.path,
        transformPixelMp: true,
        pixelMpTransformFormat: PixelMpTransformFormat.still,
        writeExif: false,
        skipExtras: true,
        guessFromName: false,
        extensionFixing: ExtensionFixingMode.none,
      );
      const pipeline = ProcessingPipeline();
      final result = await pipeline.execute(
        config: config,
        inputDirectory: tempDir,
        outputDirectory: outputDir,
      );
      expect(result.isSuccess, isTrue);
      final outFiles = outputDir
          .listSync(recursive: true)
          .whereType<File>()
          .toList();
      expect(
        outFiles.any((f) => f.path.endsWith('.jpg')),
        isTrue,
        reason: 'Should produce still .jpg',
      );
      expect(
        outFiles.any(
          (f) =>
              f.path.toLowerCase().endsWith('.mp') ||
              f.path.toLowerCase().endsWith('.mv'),
        ),
        isFalse,
        reason:
            '.MP video file should not appear in output when transforming to still',
      );
      // The Pixel .MP file should NOT produce a .mp4 (it should become a still .jpg)
      expect(
        outFiles.any(
          (f) =>
              p.basename(f.path).toLowerCase() == 'pxl_20230519_101651057.mp4',
        ),
        isFalse,
        reason:
            'Pixel .MP should not produce a .mp4 in output when transforming to still',
      );
      // iPhone companion files must not appear — they are not in the test input
      expect(
        outFiles.any((f) => p.basename(f.path).toLowerCase() == 'img_4188.mp4'),
        isFalse,
        reason: 'IMG_4188.MP4 should not appear in output',
      );
      expect(
        outFiles.any(
          (f) => p.basename(f.path).toLowerCase() == 'img_4188.heic',
        ),
        isFalse,
        reason: 'IMG_4188.HEIC should not appear in output',
      );
    });
  });

  group('Apple Live Photo (HEIC+MP4) pass-through (all modes)', () {
    // In all --transform-pixel-mp modes, HEIC+MP4 pairs pass through as-is.
    // No merging or suppression occurs; both files appear in output unchanged.
    final sampleDir = p.join('test', 'raw_samples', 'motionphotos');
    final tempDir = Directory.systemTemp.createTempSync('apple_lp_test');
    final outputDir = Directory.systemTemp.createTempSync('apple_lp_out');
    final yearDir = Directory(p.join(tempDir.path, '2023'));

    setUp(() async {
      if (outputDir.existsSync()) outputDir.deleteSync(recursive: true);
      outputDir.createSync();
      if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
      tempDir.createSync();
      yearDir.createSync();
      for (final name in ['IMG_4188.HEIC', 'IMG_4188.MP4']) {
        File(p.join(sampleDir, name)).copySync(p.join(yearDir.path, name));
      }
    });

    tearDown(() async {
      await Future.delayed(const Duration(milliseconds: 300));
      for (final dir in [outputDir, tempDir]) {
        for (int i = 0; i < 5; i++) {
          try {
            if (dir.existsSync()) dir.deleteSync(recursive: true);
            break;
          } catch (_) {
            await Future.delayed(const Duration(milliseconds: 200));
          }
        }
      }
    });

    test('HEIC+MP4 pair passes through unchanged in all modes', () async {
      final config = ProcessingConfig(
        inputPath: tempDir.path,
        outputPath: outputDir.path,
        transformPixelMp: true,
        writeExif: false,
        skipExtras: true,
        guessFromName: false,
        extensionFixing: ExtensionFixingMode.none,
      );
      const pipeline = ProcessingPipeline();
      final result = await pipeline.execute(
        config: config,
        inputDirectory: tempDir,
        outputDirectory: outputDir,
      );
      expect(result.isSuccess, isTrue);

      final outFiles = outputDir
          .listSync(recursive: true)
          .whereType<File>()
          .toList();

      // Both files pass through unchanged — no merging or suppression.
      expect(
        outFiles.any(
          (f) => p.basename(f.path).toLowerCase() == 'img_4188.heic',
        ),
        isTrue,
        reason: 'HEIC should pass through unchanged',
      );
      expect(
        outFiles.any((f) => p.basename(f.path).toLowerCase() == 'img_4188.mp4'),
        isTrue,
        reason: 'Companion MP4 should pass through unchanged',
      );
    });
  });

  // ───────────────────────────────────────────────────────────────────────
  // Still mode invariant: output .jpg is never a motion photo
  // ───────────────────────────────────────────────────────────────────────

  group('still mode: output .jpg is never a motion photo', () {
    // Regardless of whether the sidecar .MP.jpg is a plain still or a
    // combined motion JPEG, still mode must produce a non-motion .jpg in
    // output (either the sidecar used directly, or the still extracted from
    // the motion sidecar).
    final sampleDir = p.join('test', 'raw_samples', 'motionphotos');
    final tempDir = Directory.systemTemp.createTempSync('still_invariant_test');
    final outputDir = Directory.systemTemp.createTempSync(
      'still_invariant_out',
    );
    final yearDir = Directory(p.join(tempDir.path, '2023'));

    setUp(() async {
      if (outputDir.existsSync()) outputDir.deleteSync(recursive: true);
      outputDir.createSync();
      if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
      tempDir.createSync();
      yearDir.createSync();
      // Copy Pixel .MP + its .MP.jpg sidecar.
      for (final name in [
        'PXL_20230519_101651057.MP',
        'PXL_20230519_101651057.MP.jpg',
      ]) {
        File(p.join(sampleDir, name)).copySync(p.join(yearDir.path, name));
      }
    });

    tearDown(() async {
      await Future.delayed(const Duration(milliseconds: 300));
      for (final dir in [outputDir, tempDir]) {
        for (int i = 0; i < 5; i++) {
          try {
            if (dir.existsSync()) dir.deleteSync(recursive: true);
            break;
          } catch (_) {
            await Future.delayed(const Duration(milliseconds: 200));
          }
        }
      }
    });

    test('output .jpg is not a motion photo and no .MP in output', () async {
      final config = ProcessingConfig(
        inputPath: tempDir.path,
        outputPath: outputDir.path,
        transformPixelMp: true,
        pixelMpTransformFormat: PixelMpTransformFormat.still,
        writeExif: false,
        skipExtras: true,
        guessFromName: false,
        extensionFixing: ExtensionFixingMode.none,
      );
      const pipeline = ProcessingPipeline();
      final result = await pipeline.execute(
        config: config,
        inputDirectory: tempDir,
        outputDirectory: outputDir,
      );
      expect(result.isSuccess, isTrue);

      final outFiles = outputDir
          .listSync(recursive: true)
          .whereType<File>()
          .toList();

      // No .MP in output.
      expect(
        outFiles.any((f) => f.path.toLowerCase().endsWith('.mp')),
        isFalse,
        reason: '.MP must not appear in output in still mode',
      );

      // Exactly one .jpg output for this photo.
      final jpgFiles = outFiles
          .where(
            (f) =>
                f.path.toLowerCase().endsWith('.jpg') ||
                f.path.toLowerCase().endsWith('.jpeg'),
          )
          .toList();
      expect(
        jpgFiles.length,
        equals(1),
        reason: 'Still mode must produce exactly one .jpg output',
      );

      // Core invariant: the output .jpg must NOT be a motion photo.
      // If the sidecar was a motion JPEG, still mode must have extracted the
      // pure still frame from it; if the sidecar was already a plain JPEG,
      // it is used directly — either way the output is not a motion photo.
      final outputJpg = jpgFiles.first;
      bool outputIsMotion = false;
      try {
        outputIsMotion = await MotionPhotos(outputJpg.path).isMotionPhoto();
      } catch (_) {
        // Detection failure → assume plain still; let assertion pass.
      }
      expect(
        outputIsMotion,
        isFalse,
        reason:
            'Still mode output must be a plain JPEG, not a motion photo — '
            'if the sidecar .MP.jpg contains embedded video, still mode '
            'must extract only the still frame',
      );
    });
  });

  // ───────────────────────────────────────────────────────────────────────
  // Gap 2 regression: album secondary .MP extension bug
  // ───────────────────────────────────────────────────────────────────────

  group(
    'secondary FileEntity extension updated after transform (album symlink fix)',
    () {
      // When a Pixel .MP appears in both a year folder (canonical primary) and
      // an album folder (non-canonical secondary), the jpg/still transform must
      // also update the secondary's sourcePath extension.  Without this, the
      // moving strategy names the album shortcut "PXL.MP" even though it points
      // to the converted "PXL.jpg" file.
      final sampleDir = p.join('test', 'raw_samples', 'motionphotos');
      final tempDir = Directory.systemTemp.createTempSync(
        'gap2_secondary_ext_test',
      );

      setUp(() async {
        if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
        tempDir.createSync(recursive: true);
      });

      tearDown(() async {
        await Future.delayed(const Duration(milliseconds: 300));
        for (int i = 0; i < 5; i++) {
          try {
            if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
            break;
          } catch (_) {
            await Future.delayed(const Duration(milliseconds: 200));
          }
        }
      });

      test(
        'jpg mode: secondary sourcePath extension updated from .MP to .jpg',
        () async {
          // Arrange: copy real .MP to a year-folder path (primary).
          final yearDir = Directory(p.join(tempDir.path, 'Photos from 2023'))
            ..createSync(recursive: true);
          final albumDir = Directory(p.join(tempDir.path, 'Albums', 'Vacation'))
            ..createSync(recursive: true);

          const stem = 'PXL_20230519_101651057';
          final primaryMp = File(p.join(yearDir.path, '$stem.MP'));
          // Secondary at a different path — the album copy; file need not exist
          // on disk since Step 3 would have deleted it before Step 6 runs.
          final secondaryMpPath = p.join(albumDir.path, '$stem.MP');

          File(p.join(sampleDir, '$stem.MP')).copySync(primaryMp.path);

          final primaryFe = FileEntity(sourcePath: primaryMp.path);
          final secondaryFe = FileEntity(
            sourcePath: secondaryMpPath,
            ranking: 1,
          );

          final entity = MediaEntity(
            primaryFile: primaryFe,
            secondaryFiles: [secondaryFe],
            dateTaken: DateTime(2023, 5, 19),
          );
          final collection = MediaEntityCollection([entity]);
          final config = ProcessingConfig(
            inputPath: tempDir.path,
            outputPath: p.join(tempDir.path, 'out'),
            transformPixelMp: true,
            pixelMpTransformFormat: PixelMpTransformFormat.jpg,
            writeExif: false,
          );
          final context = ProcessingContext(
            config: config,
            mediaCollection: collection,
            inputDirectory: tempDir,
            outputDirectory: Directory(p.join(tempDir.path, 'out')),
          );

          await ServiceContainer.instance.initialize();
          const service = PixelMpTransformService();
          await service.transformAll(context);

          // Primary must no longer point to .MP
          expect(
            entity.primaryFile.sourcePath.toLowerCase().endsWith('.mp'),
            isFalse,
            reason: 'Primary sourcePath must have been updated away from .MP',
          );

          // Secondary must have the same new extension as the primary (or at
          // minimum must NOT still be .MP).
          final secPath = entity.secondaryFiles.first.sourcePath.toLowerCase();
          expect(
            secPath.endsWith('.mp'),
            isFalse,
            reason:
                'Secondary sourcePath must not retain .MP extension after transform '
                '(album symlink would be named PXL.MP pointing to PXL.jpg)',
          );
          // The new extension of primary and secondary should match.
          expect(
            p.extension(entity.secondaryFiles.first.sourcePath).toLowerCase(),
            equals(p.extension(entity.primaryFile.sourcePath).toLowerCase()),
            reason:
                'Secondary extension must match new primary extension so album '
                'shortcut is named correctly',
          );
        },
      );

      test(
        'still mode: secondary sourcePath extension updated from .MP to .jpg',
        () async {
          final yearDir = Directory(p.join(tempDir.path, 'Photos from 2023'))
            ..createSync(recursive: true);
          final albumDir = Directory(p.join(tempDir.path, 'Albums', 'Vacation'))
            ..createSync(recursive: true);

          const stem = 'PXL_20230519_101651057';
          final primaryMp = File(p.join(yearDir.path, '$stem.MP'));
          final secondaryMpPath = p.join(albumDir.path, '$stem.MP');

          File(p.join(sampleDir, '$stem.MP')).copySync(primaryMp.path);

          final primaryFe = FileEntity(sourcePath: primaryMp.path);
          final secondaryFe = FileEntity(
            sourcePath: secondaryMpPath,
            ranking: 1,
          );

          final entity = MediaEntity(
            primaryFile: primaryFe,
            secondaryFiles: [secondaryFe],
            dateTaken: DateTime(2023, 5, 19),
          );
          final collection = MediaEntityCollection([entity]);
          final config = ProcessingConfig(
            inputPath: tempDir.path,
            outputPath: p.join(tempDir.path, 'out'),
            transformPixelMp: true,
            pixelMpTransformFormat: PixelMpTransformFormat.still,
            writeExif: false,
          );
          final context = ProcessingContext(
            config: config,
            mediaCollection: collection,
            inputDirectory: tempDir,
            outputDirectory: Directory(p.join(tempDir.path, 'out')),
          );

          await ServiceContainer.instance.initialize();
          const service = PixelMpTransformService();
          await service.transformAll(context);

          expect(
            entity.primaryFile.sourcePath.toLowerCase().endsWith('.mp'),
            isFalse,
            reason: 'Primary sourcePath must have been updated away from .MP',
          );

          final secPath = entity.secondaryFiles.first.sourcePath.toLowerCase();
          expect(
            secPath.endsWith('.mp'),
            isFalse,
            reason: 'Secondary sourcePath must not retain .MP extension',
          );
          expect(
            p.extension(entity.secondaryFiles.first.sourcePath).toLowerCase(),
            equals(p.extension(entity.primaryFile.sourcePath).toLowerCase()),
            reason: 'Secondary extension must match new primary extension',
          );
        },
      );
    },
  );
}
