/// Tests for Unicode normalization in FileEntity (GitHub Issue #99).
///
/// On macOS, HFS+/APFS stores filenames in NFD (decomposed) Unicode form.
/// For example, 'ö' is stored as 'o' + combining diaeresis (U+0308).
/// This caused PathNotFoundException for files with German umlauts
/// (ä, ö, ü, ß) and other accented characters.
///
/// The fix normalizes all paths to NFC (composed) form in FileEntity,
/// ensuring consistent path handling across platforms.
library;

import 'package:gpth_neo/gpth_lib_exports.dart';
import 'package:test/test.dart';
import 'package:unorm_dart/unorm_dart.dart' as unorm;

void main() {
  group('FileEntity Unicode NFC normalization (Issue #99)', () {
    // NFD (decomposed): 'ö' = 'o' + U+0308 (combining diaeresis)
    // NFC (composed):   'ö' = U+00F6
    const nfdOUmlaut = 'o\u0308'; // decomposed ö
    const nfcOUmlaut = 'ö'; // composed ö (U+00F6)

    const nfdAUmlaut = 'a\u0308'; // decomposed ä
    const nfcAUmlaut = 'ä'; // composed ä

    const nfdUUmlaut = 'u\u0308'; // decomposed ü
    const nfcUUmlaut = 'ü'; // composed ü

    test('precondition: NFD and NFC forms are different strings', () {
      // Verify our test constants are indeed different byte representations
      expect(nfdOUmlaut.length, 2, reason: 'NFD ö should be 2 code units');
      expect(nfcOUmlaut.length, 1, reason: 'NFC ö should be 1 code unit');
      expect(
        nfdOUmlaut,
        isNot(equals(nfcOUmlaut)),
        reason: 'NFD and NFC should differ at string level',
      );
    });

    test('sourcePath is normalized from NFD to NFC', () {
      final path =
          '/Volumes/drive/Takeout/Google Fotos/Fotos von 2026/${nfdOUmlaut}jendorfer See.jpg';
      final fe = FileEntity(sourcePath: path);

      // The stored path should be NFC
      expect(fe.sourcePath, contains(nfcOUmlaut));
      expect(fe.sourcePath, isNot(contains(nfdOUmlaut)));
      expect(
        fe.sourcePath,
        '/Volumes/drive/Takeout/Google Fotos/Fotos von 2026/öjendorfer See.jpg',
      );
    });

    test('targetPath is normalized from NFD to NFC', () {
      final source = '/input/photo.jpg';
      final target = '/output/ALL_PHOTOS/2026/01/B${nfdAUmlaut}ume am Ufer.jpg';
      final fe = FileEntity(sourcePath: source, targetPath: target);

      expect(fe.targetPath, contains(nfcAUmlaut));
      expect(fe.targetPath, isNot(contains(nfdAUmlaut)));
      expect(fe.targetPath, '/output/ALL_PHOTOS/2026/01/Bäume am Ufer.jpg');
    });

    test('sourcePath setter normalizes NFD to NFC', () {
      final fe = FileEntity(sourcePath: '/input/photo.jpg');
      fe.sourcePath = '/Volumes/drive/pr${nfdAUmlaut}si~2.mp4';

      expect(fe.sourcePath, contains(nfcAUmlaut));
      expect(fe.sourcePath, '/Volumes/drive/präsi~2.mp4');
    });

    test('targetPath setter normalizes NFD to NFC', () {
      final fe = FileEntity(sourcePath: '/input/photo.jpg');
      fe.targetPath = '/output/Gr${nfdUUmlaut}ne Bl${nfdAUmlaut}tter.jpg';

      expect(fe.targetPath, contains(nfcUUmlaut));
      expect(fe.targetPath, contains(nfcAUmlaut));
      expect(fe.targetPath, '/output/Grüne Blätter.jpg');
    });

    test('asFile() returns File with NFC-normalized path', () {
      final nfdPath =
          '/Volumes/drive/${nfdOUmlaut}jendorfer See B${nfdAUmlaut}ume.jpg';
      final fe = FileEntity(sourcePath: nfdPath);
      final file = fe.asFile();

      // The File path should be NFC
      expect(file.path, contains(nfcOUmlaut));
      expect(file.path, contains(nfcAUmlaut));
      expect(file.path, '/Volumes/drive/öjendorfer See Bäume.jpg');
    });

    test('path getter returns NFC-normalized effective path', () {
      final fe = FileEntity(
        sourcePath: '/input/${nfdOUmlaut}jendorfer.jpg',
        targetPath: '/output/${nfdAUmlaut}pfel.jpg',
      );

      // path returns targetPath when set
      expect(fe.path, '/output/äpfel.jpg');

      // Without targetPath, returns sourcePath
      final fe2 = FileEntity(sourcePath: '/input/${nfdOUmlaut}jendorfer.jpg');
      expect(fe2.path, '/input/öjendorfer.jpg');
    });

    test('NFC paths are preserved as-is (idempotent)', () {
      const nfcPath = '/Volumes/drive/Öjendorfer See Bäume am Ufer.jpg';
      final fe = FileEntity(sourcePath: nfcPath);

      expect(fe.sourcePath, nfcPath);
    });

    test('ASCII-only paths are unaffected', () {
      const asciiPath = '/home/user/Photos/IMG_2367.jpg';
      final fe = FileEntity(sourcePath: asciiPath);

      expect(fe.sourcePath, asciiPath);
    });

    test('Windows paths with umlauts are normalized', () {
      final winPath =
          'C:\\Users\\Benutzer\\Fotos\\${nfdOUmlaut}jendorfer See.jpg';
      final fe = FileEntity(sourcePath: winPath);

      expect(fe.sourcePath, contains(nfcOUmlaut));
      expect(fe.sourcePath, 'C:\\Users\\Benutzer\\Fotos\\öjendorfer See.jpg');
    });

    test('mixed NFD and NFC in same path are fully normalized', () {
      // Simulate a path where some parts are NFC and some NFD
      final mixedPath =
          '/drive/${nfcOUmlaut}jendorfer/${nfdAUmlaut}pfel/${nfdUUmlaut}bung.jpg';
      final fe = FileEntity(sourcePath: mixedPath);

      expect(fe.sourcePath, '/drive/öjendorfer/äpfel/übung.jpg');
      // Verify it's fully NFC
      expect(fe.sourcePath, unorm.nfc(fe.sourcePath));
    });

    test('French accented characters are normalized', () {
      // é in NFD = e + U+0301 (combining acute accent)
      const nfdE = 'e\u0301';
      final fe = FileEntity(sourcePath: '/drive/Photo modifi${nfdE}e.jpg');

      expect(fe.sourcePath, '/drive/Photo modifiée.jpg');
    });

    test('FileEntity equality behavior with normalized paths', () {
      // Two FileEntities with NFD and NFC versions of the same path
      // should have the same sourcePath after normalization
      final nfdPath = '/drive/${nfdOUmlaut}jendorfer.jpg';
      final nfcPath = '/drive/öjendorfer.jpg';

      final fe1 = FileEntity(sourcePath: nfdPath);
      final fe2 = FileEntity(sourcePath: nfcPath);

      expect(fe1.sourcePath, equals(fe2.sourcePath));
    });

    test('isCanonical is computed correctly with normalized paths', () {
      // Source in a "Photos from YYYY" folder with NFD umlauts
      final fe = FileEntity(
        sourcePath: '/drive/Photos from 2026/${nfdOUmlaut}jendorfer.jpg',
      );

      // Should still detect the canonical "Photos from 2026" pattern
      expect(fe.isCanonical, isTrue);
    });

    test('targetPath null is preserved (not normalized)', () {
      final fe = FileEntity(sourcePath: '/input/photo.jpg');

      expect(fe.targetPath, isNull);
    });
  });
}
