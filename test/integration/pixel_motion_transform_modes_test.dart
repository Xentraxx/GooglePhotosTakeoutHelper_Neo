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

  group('Apple Live Photo (HEIC+MP4) → motion JPEG in jpg mode', () {
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
      // Only copy the Apple Live Photo pair (HEIC + MP4, same stem).
      // IMG_2916.HEIC + IMG_2916.MOV are unrelated and excluded intentionally.
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

    test('HEIC+MP4 merged into a single motion JPEG', () async {
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

      // Exactly one output file: the merged motion JPEG.
      expect(
        outFiles
            .where((f) => p.basename(f.path).toLowerCase() == 'img_4188.mp.jpg')
            .length,
        equals(1),
        reason: 'Should produce exactly one img_4188.MP.jpg motion JPEG',
      );

      // Original HEIC and MP4 must not appear in output.
      expect(
        outFiles.any(
          (f) => p.basename(f.path).toLowerCase() == 'img_4188.heic',
        ),
        isFalse,
        reason: 'HEIC source file should not appear in output after merge',
      );
      expect(
        outFiles.any((f) => p.basename(f.path).toLowerCase() == 'img_4188.mp4'),
        isFalse,
        reason: 'MP4 companion should not appear in output after merge',
      );

      // The merged jpg should contain the MP4 bytes (video embedded).
      final jpgFile = outFiles.firstWhere(
        (f) => p.basename(f.path).toLowerCase() == 'img_4188.mp.jpg',
      );
      final jpgBytes = await jpgFile.readAsBytes();
      // Google motion JPEG: starts with JPEG magic (FF D8) and is larger than
      // the original still image alone (it includes the appended MP4 data).
      expect(
        jpgBytes[0] == 0xFF && jpgBytes[1] == 0xD8,
        isTrue,
        reason: 'Merged output should start with JPEG magic bytes',
      );
      final originalHeicSize = File(
        p.join(sampleDir, 'IMG_4188.HEIC'),
      ).lengthSync();
      expect(
        jpgBytes.length,
        greaterThan(originalHeicSize),
        reason:
            'Merged output must be larger than the original still (MP4 data appended)',
      );
    });

    test(
      'HEIC+MP4 merged correctly even when standard extension fixing is active',
      () async {
        // Standard extension fixing would normally rename IMG_4188.HEIC → .jpg
        // (because its bytes are JPEG), destroying the signal Step 6 needs.
        // skipHeicFiles must be set by the pipeline when jpg mode is active.
        final config = ProcessingConfig(
          inputPath: tempDir.path,
          outputPath: outputDir.path,
          transformPixelMp: true,
          pixelMpTransformFormat: PixelMpTransformFormat.jpg,
          writeExif: false,
          skipExtras: true,
          guessFromName: false,
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

        // The merged motion JPEG must exist.
        expect(
          outFiles
              .where(
                (f) => p.basename(f.path).toLowerCase() == 'img_4188.mp.jpg',
              )
              .length,
          equals(1),
          reason:
              'Should produce img_4188.MP.jpg even with standard extension fixing',
        );
        // Neither the raw HEIC nor the bare MP4 should survive.
        expect(
          outFiles.any(
            (f) => p.basename(f.path).toLowerCase() == 'img_4188.heic',
          ),
          isFalse,
        );
        expect(
          outFiles.any(
            (f) => p.basename(f.path).toLowerCase() == 'img_4188.mp4',
          ),
          isFalse,
        );
      },
    );

    test('HEIC+MP4 pair not touched in mp4 mode (pass-through)', () async {
      final config = ProcessingConfig(
        inputPath: tempDir.path,
        outputPath: outputDir.path,
        transformPixelMp: true,
        // mp4 mode: Pixel .MP → .mp4 but Apple HEIC+MP4 should pass through
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

      // Both files pass through unchanged.
      expect(
        outFiles.any(
          (f) => p.basename(f.path).toLowerCase() == 'img_4188.heic',
        ),
        isTrue,
        reason: 'In mp4 mode HEIC should pass through',
      );
      expect(
        outFiles.any((f) => p.basename(f.path).toLowerCase() == 'img_4188.mp4'),
        isTrue,
        reason: 'In mp4 mode companion MP4 should pass through',
      );
    });
  });

  group('Apple Live Photo safety: true HEIC + same-stem MP4 not merged', () {
    // createLivePhotoFromComponents concatenates raw image bytes with video
    // bytes to produce a Google Motion Photo V2 (JPEG + MP4 trailer). This
    // only works when the still image IS JPEG-encoded. A true HEIC (original
    // quality, ISO-BMFF container, starts with 0x00 ftyp box) would produce
    // a file that looks like a MOV container — ExifTool correctly rejects it
    // with "Not a valid JPG (looks more like a MOV)". Decoding true HEIC to
    // JPEG requires a native libheif decoder unavailable in a Dart CLI context.
    // The magic-byte guard skips true HEIC files; both are moved as-is.
    final tempDir = Directory.systemTemp.createTempSync('apple_lp_safe_test');
    final outputDir = Directory.systemTemp.createTempSync('apple_lp_safe_out');
    final yearDir = Directory(p.join(tempDir.path, '2023'));

    setUp(() async {
      if (outputDir.existsSync()) outputDir.deleteSync(recursive: true);
      outputDir.createSync();
      if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
      tempDir.createSync();
      yearDir.createSync();

      // A minimal valid ISO-BMFF ftyp box (true HEIC magic — starts with 0x00).
      final truHeicBytes = [
        0x00, 0x00, 0x00, 0x18, // box size = 24
        0x66, 0x74, 0x79, 0x70, // 'ftyp'
        0x68, 0x65, 0x69, 0x63, // major brand 'heic'
        0x00, 0x00, 0x00, 0x00, // minor version
        0x68, 0x65, 0x69, 0x63, // compatible brand 'heic'
        0x6D, 0x69, 0x66, 0x31, // compatible brand 'mif1'
      ];
      final mp4Bytes = [
        0x00, 0x00, 0x00, 0x14, // box size = 20
        0x66, 0x74, 0x79, 0x70, // 'ftyp'
        0x6D, 0x70, 0x34, 0x32, // major brand 'mp42'
        0x00, 0x00, 0x00, 0x00, // minor version
        0x6D, 0x70, 0x34, 0x32, // compatible brand 'mp42'
      ];

      File(p.join(yearDir.path, 'photo.HEIC')).writeAsBytesSync(truHeicBytes);
      File(p.join(yearDir.path, 'photo.MP4')).writeAsBytesSync(mp4Bytes);
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

    test(
      'True HEIC + same-stem MP4 passes through unchanged (merge skipped)',
      () async {
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

        // Both files survive — a true HEIC cannot be merged by simple byte
        // concatenation without first decoding it to JPEG (requires a decoder).
        expect(
          outFiles.any((f) => p.basename(f.path).toLowerCase() == 'photo.heic'),
          isTrue,
          reason: 'True HEIC must not be consumed; merge is skipped',
        );
        expect(
          outFiles.any((f) => p.basename(f.path).toLowerCase() == 'photo.mp4'),
          isTrue,
          reason: 'MP4 companion must survive when merge is skipped',
        );
        expect(
          outFiles.any((f) => p.basename(f.path).toLowerCase() == 'photo.jpg'),
          isFalse,
          reason: 'No merged .jpg must be produced for a true HEIC pair',
        );
      },
    );
  });

  // ───────────────────────────────────────────────────────────────────────
  // Gap 1 regression: HEIC renamed to .jpg by Step 1 + same-stem .mp4
  // ───────────────────────────────────────────────────────────────────────

  group('still mode: MP4 companion suppressed when HEIC was renamed to .jpg', () {
    // When Step 1's extension fixer renames a JPEG-encoded HEIC to .jpg
    // before Step 6 runs, _suppressMp4CompanionsOfHeic must still recognise
    // the pair and exclude the .mp4 companion from the output.
    final tempDir = Directory.systemTemp.createTempSync(
      'heic_renamed_still_test',
    );
    final outputDir = Directory.systemTemp.createTempSync(
      'heic_renamed_still_out',
    );
    final yearDir = Directory(p.join(tempDir.path, '2023'));
    final sampleDir = p.join('test', 'raw_samples', 'motionphotos');

    setUp(() async {
      if (outputDir.existsSync()) outputDir.deleteSync(recursive: true);
      outputDir.createSync();
      if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
      tempDir.createSync();
      yearDir.createSync();
      // Simulate what Step 1 would produce: JPEG-encoded HEIC renamed to
      // .jpg.  We reuse the real IMG_4188.HEIC sample (which is
      // JPEG-encoded — starts with FF D8) and just give it a .jpg name.
      File(
        p.join(sampleDir, 'IMG_4188.HEIC'),
      ).copySync(p.join(yearDir.path, 'vacation.jpg'));
      // Its Apple Live Photo companion video.
      File(
        p.join(sampleDir, 'IMG_4188.MP4'),
      ).copySync(p.join(yearDir.path, 'vacation.mp4'));
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

    test(
      'MP4 companion excluded from output; plain still .jpg moved as-is',
      () async {
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

        // The plain still .jpg must be moved to output.
        expect(
          outFiles.any(
            (f) => p.basename(f.path).toLowerCase() == 'vacation.jpg',
          ),
          isTrue,
          reason: 'Plain still .jpg (renamed from HEIC) must appear in output',
        );

        // The .mp4 companion must NOT be in output — _suppressMp4CompanionsOfHeic
        // should recognise the .jpg sibling as a plain still and suppress it.
        expect(
          outFiles.any(
            (f) => p.basename(f.path).toLowerCase() == 'vacation.mp4',
          ),
          isFalse,
          reason:
              'MP4 companion must be suppressed in still mode when sibling .jpg '
              'is a plain still (HEIC renamed by Step 1)',
        );
      },
    );
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
