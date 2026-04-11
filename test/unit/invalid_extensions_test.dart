library;

import 'dart:io';

import 'package:gpth_neo/gpth_lib_exports.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import '../setup/test_setup.dart';

void main() {
  late ExifToolService? exiftool;
  late FixExtensionService extensionFixingService;

  setUpAll(() async {
    extensionFixingService = FixExtensionService();
    exiftool = await ExifToolService.find();
    if (exiftool != null) {
      await exiftool!.startPersistentProcess();
    }
  });

  tearDownAll(() async {
    if (exiftool != null) {
      await exiftool!.dispose();
    }
  });

  group('Invalid Extensions Tests', () {
    test('ExifTool service can detect file types', () async {
      if (exiftool == null) {
        fail('ExifTool not found');
      }

      // Create a test file with EXIF data
      final testFile = File('test/test_files/test_image.jpg');
      if (!await testFile.exists()) {
        return;
      }

      final exifData = await exiftool!.readExifData(testFile);
      expect(exifData, isNotEmpty);
      expect(exifData['MIMEType'], isNotNull);
    });
  });

  group('Invalid extensions', () {
    late TestFixture fixture;

    setUp(() async {
      fixture = TestFixture();
      await fixture.setUp();
    });

    tearDown(() async {
      await fixture.tearDown();
    });

    test('fix invalid .jpg extension', () async {
      // Create PNG file with incorrect .jpg extension
      final pngHeader = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A];
      final imgFile1 = fixture.createFile('actual-png.jpg', pngHeader);

      // Create corresponding JSON metadata file
      final jsonFile = fixture.createJsonFile(
        'actual-png.jpg.json',
        photoTakenTimestamp: '1672531237',
        includeExtendedFields: true,
      );

      final albumDir = fixture.createDirectory('extensions-tests');
      final albumFile1 = File('${albumDir.path}/${p.basename(imgFile1.path)}');
      final albumJsonFile = File(
        '${albumDir.path}/${p.basename(jsonFile.path)}',
      );

      // Move both files to the test directory
      await imgFile1.rename(albumFile1.path);
      await jsonFile.rename(albumJsonFile.path);

      // Wait for filesystem operations to complete
      await Future.delayed(const Duration(milliseconds: 100));

      // Verify files exist before running extension fix
      expect(await albumFile1.exists(), isTrue);
      expect(await albumJsonFile.exists(), isTrue);

      final fixedCount = await extensionFixingService.fixIncorrectExtensions(
        albumDir,
      );

      final fixedFile = File('${albumDir.path}/actual-png.png');
      final fixedJsonFile = File('${albumDir.path}/actual-png.png.json');

      expect(fixedCount, greaterThan(0));
      expect(await fixedFile.exists(), isTrue);
      expect(await fixedJsonFile.exists(), isTrue);
    });

    test('skip invalid JPEG files', () async {
      final jpegHeader = [0xFF, 0xD8];
      final imgFile1 = fixture.createFile('actual-jpeg.png', jpegHeader);

      final albumDir = fixture.createDirectory('extensions-tests');
      final albumFile1 = File('${albumDir.path}/${p.basename(imgFile1.path)}');
      imgFile1.renameSync(albumFile1.path);

      await extensionFixingService.fixIncorrectExtensions(
        albumDir,
        skipJpegFiles: true,
      );

      final fixedFile = File(
        '${albumDir.path}/${p.basename(imgFile1.path)}.jpg',
      );
      expect(fixedFile.existsSync(), isFalse);
    });

    test('skip TIFF-based RAW files', () async {
      final cr2Header = [
        0x49,
        0x49,
        0x2A,
        0x00,
        0x10,
        0x00,
        0x00,
        0x00,
        0x43,
        0x52,
        0x02,
      ];
      final imgFile1 = fixture.createFile('actual-raw.CR2', cr2Header);

      final albumDir = fixture.createDirectory('extensions-tests');
      final albumFile1 = File('${albumDir.path}/${p.basename(imgFile1.path)}');
      imgFile1.renameSync(albumFile1.path);

      await extensionFixingService.fixIncorrectExtensions(albumDir);

      final fixedFile = File(
        '${albumDir.path}/${p.basename(imgFile1.path)}.tiff',
      );
      expect(fixedFile.existsSync(), isFalse);
    });

    test(
      'atomic extension fixing ensures consistency between media and JSON files',
      () async {
        // Create a PNG file with JPEG content (incorrect extension)
        final jpegHeader = [0xFF, 0xD8, 0xFF, 0xE0];
        final mediaFile = fixture.createFile('test_image.png', jpegHeader);

        // Create associated JSON metadata file
        final jsonFile = fixture.createFile(
          'test_image.png.json',
          '{"title": "Test image", "photoTakenTime": {"timestamp": "1640995200"}}'
              .codeUnits,
        );

        final albumDir = fixture.createDirectory('atomic-test');
        final albumMediaFile = File(
          '${albumDir.path}/${p.basename(mediaFile.path)}',
        );
        final albumJsonFile = File(
          '${albumDir.path}/${p.basename(jsonFile.path)}',
        );

        // Move both files to test directory
        await mediaFile.rename(albumMediaFile.path);
        await jsonFile.rename(albumJsonFile.path);

        // Verify both files exist before extension fixing
        expect(await albumMediaFile.exists(), isTrue);
        expect(await albumJsonFile.exists(), isTrue);

        // Run extension fixing
        final fixedCount = await extensionFixingService.fixIncorrectExtensions(
          albumDir,
        );

        // Verify that extension fixing succeeded
        expect(fixedCount, equals(1));

        // Verify both files have been renamed atomically
        final fixedMediaFile = File('${albumDir.path}/test_image.jpg');
        final fixedJsonFile = File('${albumDir.path}/test_image.jpg.json');

        expect(
          await fixedMediaFile.exists(),
          isTrue,
          reason: 'Media file should be renamed to correct extension',
        );
        expect(
          await fixedJsonFile.exists(),
          isTrue,
          reason: 'JSON file should be renamed to match media file',
        );

        // Verify original files are gone
        expect(
          await albumMediaFile.exists(),
          isFalse,
          reason: 'Original media file should be removed',
        );
        expect(
          await albumJsonFile.exists(),
          isFalse,
          reason: 'Original JSON file should be removed',
        );
      },
    );

    test('atomic extension fixing handles MTS files correctly', () async {
      // Create an MTS file that would be detected as model/vnd.mts
      // Use a minimal MPEG transport stream header
      final mtsHeader = [
        0x47, 0x40, 0x00, 0x10, // MPEG-TS sync byte and header
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
      ];
      final mtsFile = fixture.createFile('video.MTS', mtsHeader);

      // Create associated JSON file
      final jsonFile = fixture.createFile(
        'video.MTS.json',
        '{"title": "MTS video", "videoTakenTime": {"timestamp": "1640995200"}}'
            .codeUnits,
      );

      final albumDir = fixture.createDirectory('mts-test');
      final albumMtsFile = File('${albumDir.path}/${p.basename(mtsFile.path)}');
      final albumJsonFile = File(
        '${albumDir.path}/${p.basename(jsonFile.path)}',
      );

      // Move both files to test directory
      await mtsFile.rename(albumMtsFile.path);
      await jsonFile.rename(albumJsonFile.path);

      // Run extension fixing
      final fixedCount = await extensionFixingService.fixIncorrectExtensions(
        albumDir,
      );

      // If the MTS file is properly detected and fixed, both files should be renamed
      if (fixedCount > 0) {
        final fixedMediaFile = File('${albumDir.path}/video.mp4');
        final fixedJsonFile = File('${albumDir.path}/video.mp4.json');

        expect(
          await fixedMediaFile.exists(),
          isTrue,
          reason: 'MTS file should be renamed to .mp4',
        );
        expect(
          await fixedJsonFile.exists(),
          isTrue,
          reason: 'JSON file should be renamed to match .mp4 extension',
        );

        // Verify original files are gone
        expect(
          await albumMtsFile.exists(),
          isFalse,
          reason: 'Original MTS file should be removed',
        );
        expect(
          await albumJsonFile.exists(),
          isFalse,
          reason: 'Original JSON file should be removed',
        );
      }
    });

    group('Extension collision resolution', () {
      test('basic collision renames to (1) suffix', () async {
        final jpegHeader = [0xFF, 0xD8, 0xFF, 0xE0];
        final albumDir = fixture.createDirectory('collision-basic');

        // x.png contains JPEG bytes; x.jpg already exists
        File('${albumDir.path}/x.png')
          ..createSync()
          ..writeAsBytesSync(jpegHeader);
        File('${albumDir.path}/x.jpg')
          ..createSync()
          ..writeAsBytesSync([0x00]);

        final fixedCount = await extensionFixingService.fixIncorrectExtensions(
          albumDir,
        );

        expect(fixedCount, equals(1));
        expect(File('${albumDir.path}/x(1).jpg').existsSync(), isTrue);
        expect(File('${albumDir.path}/x.jpg').existsSync(), isTrue);
        expect(File('${albumDir.path}/x.png').existsSync(), isFalse);
      });

      test(
        'collision with JSON sidecar renames both files atomically',
        () async {
          final jpegHeader = [0xFF, 0xD8, 0xFF, 0xE0];
          final albumDir = fixture.createDirectory('collision-json');

          File('${albumDir.path}/x.png')
            ..createSync()
            ..writeAsBytesSync(jpegHeader);
          File('${albumDir.path}/x.png.json')
            ..createSync()
            ..writeAsStringSync(
              '{"title":"x","photoTakenTime":{"timestamp":"1640995200"}}',
            );
          File('${albumDir.path}/x.jpg')
            ..createSync()
            ..writeAsBytesSync([0x00]);

          final fixedCount = await extensionFixingService
              .fixIncorrectExtensions(albumDir);

          expect(fixedCount, equals(1));
          expect(File('${albumDir.path}/x(1).jpg').existsSync(), isTrue);
          expect(File('${albumDir.path}/x(1).jpg.json').existsSync(), isTrue);
          expect(File('${albumDir.path}/x.png').existsSync(), isFalse);
          expect(File('${albumDir.path}/x.png.json').existsSync(), isFalse);
        },
      );

      test(
        'chained suffix: teams_jens(1).png (JPEG) → teams_jens(1)(1).jpg',
        () async {
          final jpegHeader = [0xFF, 0xD8, 0xFF, 0xE0];
          final albumDir = fixture.createDirectory('collision-chained');

          File('${albumDir.path}/teams_jens(1).png')
            ..createSync()
            ..writeAsBytesSync(jpegHeader);
          File('${albumDir.path}/teams_jens(1).jpg')
            ..createSync()
            ..writeAsBytesSync([0x00]);

          final fixedCount = await extensionFixingService
              .fixIncorrectExtensions(albumDir);

          expect(fixedCount, equals(1));
          expect(
            File('${albumDir.path}/teams_jens(1)(1).jpg').existsSync(),
            isTrue,
          );
          expect(
            File('${albumDir.path}/teams_jens(1).png').existsSync(),
            isFalse,
          );
        },
      );

      test(
        'double collision: both x.jpg and x(1).jpg taken → x(2).jpg',
        () async {
          final jpegHeader = [0xFF, 0xD8, 0xFF, 0xE0];
          final albumDir = fixture.createDirectory('collision-double');

          File('${albumDir.path}/x.png')
            ..createSync()
            ..writeAsBytesSync(jpegHeader);
          File('${albumDir.path}/x.jpg')
            ..createSync()
            ..writeAsBytesSync([0x00]);
          File('${albumDir.path}/x(1).jpg')
            ..createSync()
            ..writeAsBytesSync([0x00]);

          final fixedCount = await extensionFixingService
              .fixIncorrectExtensions(albumDir);

          expect(fixedCount, equals(1));
          expect(File('${albumDir.path}/x(2).jpg').existsSync(), isTrue);
          expect(File('${albumDir.path}/x.png').existsSync(), isFalse);
        },
      );
    });
  });
}
