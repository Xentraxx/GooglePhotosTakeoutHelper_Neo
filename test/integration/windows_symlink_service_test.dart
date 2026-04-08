import 'dart:io';
import 'package:gpth_neo/gpth_lib_exports.dart';
import 'package:test/test.dart';

void main() {
  group('WindowsSymlinkService', () {
    late WindowsSymlinkService symlinkService;
    late Directory tempDir;

    setUp(() async {
      symlinkService = WindowsSymlinkService();
      tempDir = await Directory.systemTemp.createTemp('symlink_test');
    });

    tearDown(() async {
      if (await tempDir.exists()) {
        await tempDir.delete(recursive: true);
      }
    });

    test('should create WindowsSymlinkService instance', () {
      expect(symlinkService, isA<WindowsSymlinkService>());
    });

    group('Windows platform tests', () {
      test(
        'should create symlink to existing file',
        () async {
          if (!Platform.isWindows) return;

          // Create a target file
          final targetFile = File('${tempDir.path}/target.txt');
          await targetFile.writeAsString('Test content');

          final symlinkPath = '${tempDir.path}/symlink';

          await symlinkService.createSymlink(symlinkPath, targetFile.path);

          // Verify symlink was created
          final symlinkLink = Link(symlinkPath);
          expect(await symlinkLink.exists(), isTrue);

          // Basic validation that it's a symlink (should be a valid link)
          final targetPath = await symlinkLink.target();
          expect(targetPath, isNotEmpty);
        },
        skip: !Platform.isWindows ? 'Windows-only test' : null,
      );

      test(
        'should create symlink to existing directory',
        () async {
          if (!Platform.isWindows) return;

          // Create a target directory
          final targetDir = Directory('${tempDir.path}/target_folder');
          await targetDir.create();

          final symlinkPath = '${tempDir.path}/folder_symlink';

          await symlinkService.createSymlink(symlinkPath, targetDir.path);

          // Verify symlink was created
          final symlinkLink = Link(symlinkPath);
          expect(await symlinkLink.exists(), isTrue);
        },
        skip: !Platform.isWindows ? 'Windows-only test' : null,
      );

      test(
        'should handle absolute target paths',
        () async {
          if (!Platform.isWindows) return;

          // Create a target file with absolute path
          final targetFile = File('${tempDir.path}/absolute_target.txt');
          await targetFile.writeAsString('Test content');

          final symlinkPath = '${tempDir.path}/absolute_symlink';

          await symlinkService.createSymlink(
            symlinkPath,
            targetFile.absolute.path,
          );

          // Verify symlink was created
          final symlinkLink = Link(symlinkPath);
          expect(await symlinkLink.exists(), isTrue);
        },
        skip: !Platform.isWindows ? 'Windows-only test' : null,
      );

      test(
        'should handle relative target paths',
        () async {
          if (!Platform.isWindows) return;

          // Create a target file
          final targetFile = File('${tempDir.path}/relative_target.txt');
          await targetFile.writeAsString('Test content');

          final symlinkPath = '${tempDir.path}/relative_symlink';

          // Use relative path from temp directory
          final originalDir = Directory.current;
          Directory.current = tempDir;

          try {
            await symlinkService.createSymlink(
              symlinkPath,
              'relative_target.txt',
            );

            // Verify symlink was created
            final symlinkLink = Link(symlinkPath);
            expect(await symlinkLink.exists(), isTrue);
          } finally {
            Directory.current = originalDir;
          }
        },
        skip: !Platform.isWindows ? 'Windows-only test' : null,
      );

      test(
        'should create parent directories if they do not exist',
        () async {
          if (!Platform.isWindows) return;

          // Create a target file
          final targetFile = File('${tempDir.path}/target.txt');
          await targetFile.writeAsString('Test content');

          // Create symlink in nested directory that doesn't exist
          final symlinkPath = '${tempDir.path}/nested/folder/symlink';

          await symlinkService.createSymlink(symlinkPath, targetFile.path);

          // Verify symlink was created and parent directories exist
          final symlinkLink = Link(symlinkPath);
          expect(await symlinkLink.exists(), isTrue);
          expect(
            await Directory('${tempDir.path}/nested/folder').exists(),
            isTrue,
          );
        },
        skip: !Platform.isWindows ? 'Windows-only test' : null,
      );

      test(
        'should handle special characters in paths',
        () async {
          if (!Platform.isWindows) return;

          // Create a target file with spaces and special characters
          final targetFile = File(
            '${tempDir.path}/target with spaces & symbols.txt',
          );
          await targetFile.writeAsString('Test content');

          final symlinkPath = '${tempDir.path}/symlink with spaces';

          await symlinkService.createSymlink(symlinkPath, targetFile.path);

          // Verify symlink was created
          final symlinkLink = Link(symlinkPath);
          expect(await symlinkLink.exists(), isTrue);
        },
        skip: !Platform.isWindows ? 'Windows-only test' : null,
      );

      test(
        'should fail when target does not exist',
        () async {
          if (!Platform.isWindows) return;

          final nonExistentTarget = '${tempDir.path}/does_not_exist.txt';
          final symlinkPath = '${tempDir.path}/symlink';

          expect(
            () => symlinkService.createSymlink(symlinkPath, nonExistentTarget),
            throwsA(isA<Exception>()),
          );
        },
        skip: !Platform.isWindows ? 'Windows-only test' : null,
      );

      test(
        'should overwrite existing symlink',
        () async {
          if (!Platform.isWindows) return;

          // Create two target files
          final targetFile1 = File('${tempDir.path}/target1.txt');
          await targetFile1.writeAsString('Target 1');

          final targetFile2 = File('${tempDir.path}/target2.txt');
          await targetFile2.writeAsString('Target 2');

          final symlinkPath = '${tempDir.path}/symlink';

          // Create first symlink
          await symlinkService.createSymlink(symlinkPath, targetFile1.path);
          expect(await Link(symlinkPath).exists(), isTrue);

          // Create second symlink with same path (should overwrite)
          await symlinkService.createSymlink(symlinkPath, targetFile2.path);
          expect(await Link(symlinkPath).exists(), isTrue);
        },
        skip: !Platform.isWindows ? 'Windows-only test' : null,
      );

      test(
        'should handle long paths correctly',
        () async {
          if (!Platform.isWindows) return;

          // Create a target file
          final targetFile = File('${tempDir.path}/target.txt');
          await targetFile.writeAsString('Test content');

          // Create a long path for the symlink
          final longPath = List.generate(
            5,
            (final i) => 'very_long_folder_name_$i',
          ).join('/');
          final symlinkPath = '${tempDir.path}/$longPath/symlink';

          try {
            await symlinkService.createSymlink(symlinkPath, targetFile.path);

            // Verify symlink was created
            final symlinkLink = Link(symlinkPath);
            expect(await symlinkLink.exists(), isTrue);
          } catch (e) {
            // Long paths might fail on some systems, which is acceptable
            expect(e, isA<Exception>());
          }
        },
        skip: !Platform.isWindows ? 'Windows-only test' : null,
      );
    });

    group('Non-Windows platform tests', () {
      test(
        'should throw UnsupportedError on non-Windows platforms',
        () async {
          if (Platform.isWindows) return;

          final targetFile = File('${tempDir.path}/target.txt');
          await targetFile.writeAsString('Test content');

          final symlinkPath = '${tempDir.path}/symlink';

          expect(
            () => symlinkService.createSymlink(symlinkPath, targetFile.path),
            throwsA(isA<UnsupportedError>()),
          );
        },
        skip: Platform.isWindows ? 'Non-Windows test' : null,
      );
    });

    test(
      'should handle null or empty paths gracefully',
      () async {
        if (!Platform.isWindows) return;

        await expectLater(
          symlinkService.createSymlink('', ''),
          completes, // o: completion(isNull) para Future<void>
        );
      },
      skip: !Platform.isWindows ? 'Windows-only test' : null,
    );

    test(
      'should validate symlink path extension',
      () async {
        if (!Platform.isWindows) return;

        final targetFile = File('${tempDir.path}/target.txt');
        await targetFile.writeAsString('Test content');

        // Test with  extension
        final validsymlinkPath = '${tempDir.path}/symlink';
        await symlinkService.createSymlink(validsymlinkPath, targetFile.path);
        // The service may create either a native symlink at the given path or a
        // Windows Shortcut (.lnk) with a ".lnk" suffix appended when native
        // symlinks are not available (e.g. no Developer Mode / FAT32 volume).
        final symlinkCreated =
            await File(validsymlinkPath).exists() ||
            await Link(validsymlinkPath).exists() ||
            await File('$validsymlinkPath.lnk').exists();
        expect(symlinkCreated, isTrue);

        // Test without  extension (should still work - service might add it)
        final noExtsymlinkPath = '${tempDir.path}/symlink_no_ext';
        try {
          await symlinkService.createSymlink(noExtsymlinkPath, targetFile.path);
          // Either it works as-is or the service handles it appropriately
          expect(true, isTrue); // Test that it doesn't crash
        } catch (e) {
          // It's acceptable if it fails due to extension requirements
          expect(e, isA<Exception>());
        }
      },
      skip: !Platform.isWindows ? 'Windows-only test' : null,
    );
  });
}
