import 'dart:io';

import 'package:gpth_neo/gpth_lib_exports.dart';
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
            .where((f) => p.basename(f.path).toLowerCase() == 'img_4188.jpg')
            .length,
        equals(1),
        reason: 'Should produce exactly one img_4188.jpg motion JPEG',
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
        (f) => p.basename(f.path).toLowerCase() == 'img_4188.jpg',
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
              .where((f) => p.basename(f.path).toLowerCase() == 'img_4188.jpg')
              .length,
          equals(1),
          reason:
              'Should produce img_4188.jpg even with standard extension fixing',
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

  group('Apple Live Photo safety: true HEIC + same-stem MP4 merged correctly', () {
    // A true HEIC (ISO-BMFF, starts 0x00) + same-stem MP4 represents an Apple
    // Live Photo captured at original quality (no storage-saver re-encoding).
    // It MUST be merged just like a storage-saver HEIC (JPEG bytes, .HEIC ext).
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
      'True HEIC + same-stem MP4 is merged (original quality Live Photo)',
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

        // The pair should be merged into a single motion JPEG.
        expect(
          outFiles.any((f) => p.basename(f.path).toLowerCase() == 'photo.jpg'),
          isTrue,
          reason: 'True HEIC + MP4 pair should produce a merged motion JPEG',
        );
        expect(
          outFiles.any((f) => p.basename(f.path).toLowerCase() == 'photo.heic'),
          isFalse,
          reason: 'HEIC source must be consumed by the merge',
        );
        expect(
          outFiles.any((f) => p.basename(f.path).toLowerCase() == 'photo.mp4'),
          isFalse,
          reason: 'MP4 companion must be consumed by the merge',
        );
      },
    );
  });
}
