import 'dart:io';

import 'package:gpth_neo/gpth_lib_exports.dart';
import 'package:test/test.dart';

import '../setup/test_setup.dart';

void main() {
  group('Issue #46 Fix - Original File Removal Verification', () {
    late TestFixture fixture;

    setUp(() async {
      fixture = TestFixture();
      await fixture.setUp();
    });

    tearDown(() async {
      await fixture.tearDown();
    });

    test(
      'verifies original file is removed after extension correction',
      () async {
        // Create a PNG file with .jpg extension
        final pngHeader = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A];
        final incorrectFile = fixture.createFile('test_image.jpg', pngHeader);

        final albumDir = fixture.createDirectory('extension-fix-test');
        final testFile = File('${albumDir.path}/test_image.jpg');

        // Move file to test directory
        await incorrectFile.rename(testFile.path);

        // Verify the incorrect file exists before fixing
        expect(await testFile.exists(), isTrue);

        final extensionFixingService = FixExtensionService();

        // Fix the extension
        final fixedCount = await extensionFixingService.fixIncorrectExtensions(
          albumDir,
        );

        // Verify the fix was applied
        expect(fixedCount, equals(1));

        // Verify the corrected file exists
        final correctedFile = File('${albumDir.path}/test_image.png');
        expect(await correctedFile.exists(), isTrue);

        // CRITICAL: Verify the original file is REMOVED
        expect(
          await testFile.exists(),
          isFalse,
          reason: 'Original file should be removed after extension correction',
        );
      },
    );
  });
}
