/// Test suite for FileSystemService
///
/// Tests file system operations and file type detection functionality.
library;

import 'dart:io';
import 'package:gpth_neo/gpth_lib_exports.dart';
import 'package:test/test.dart';

import '../setup/test_setup.dart';

void main() {
  group('FileSystemService', () {
    late FileSystemService service;
    late TestFixture fixture;

    setUp(() async {
      service = const FileSystemService();
      fixture = TestFixture();
      await fixture.setUp();
    });

    tearDown(() async {
      await fixture.tearDown();
    });

    group('File Type Detection', () {
      test('identifies photo files correctly', () {
        final jpegFile = fixture.createFile('photo.jpg', [1, 2, 3]);
        final pngFile = fixture.createFile('image.png', [4, 5, 6]);
        final heicFile = fixture.createFile('image.heic', [7, 8, 9]);

        expect(service.isPhotoOrVideo(jpegFile), isTrue);
        expect(service.isPhotoOrVideo(pngFile), isTrue);
        expect(service.isPhotoOrVideo(heicFile), isTrue);
      });

      test('identifies video files correctly', () {
        final mp4File = fixture.createFile('video.mp4', [1, 2, 3]);
        final aviFile = fixture.createFile('movie.avi', [4, 5, 6]);
        final movFile = fixture.createFile('clip.mov', [7, 8, 9]);

        expect(service.isPhotoOrVideo(mp4File), isTrue);
        expect(service.isPhotoOrVideo(aviFile), isTrue);
        expect(service.isPhotoOrVideo(movFile), isTrue);
      });

      test('identifies special extensions correctly', () {
        final dngFile = fixture.createFile('raw.dng', [1, 2, 3]);
        final cr2File = fixture.createFile('canon.cr2', [4, 5, 6]);
        final mpFile = fixture.createFile('motion.mp', [7, 8, 9]);
        final mvFile = fixture.createFile('motion.mv', [10, 11, 12]);

        expect(service.isPhotoOrVideo(dngFile), isTrue);
        expect(service.isPhotoOrVideo(cr2File), isTrue);
        expect(service.isPhotoOrVideo(mpFile), isTrue);
        expect(service.isPhotoOrVideo(mvFile), isTrue);
      });

      test('rejects non-media files', () {
        final txtFile = fixture.createFile('document.txt', [1, 2, 3]);
        final pdfFile = fixture.createFile('document.pdf', [4, 5, 6]);
        final jsonFile = fixture.createFile('metadata.json', [7, 8, 9]);

        expect(service.isPhotoOrVideo(txtFile), isFalse);
        expect(service.isPhotoOrVideo(pdfFile), isFalse);
        expect(service.isPhotoOrVideo(jsonFile), isFalse);
      });

      test('handles files without extensions', () {
        final noExtFile = fixture.createFile('noextension', [1, 2, 3]);

        expect(service.isPhotoOrVideo(noExtFile), isFalse);
      });

      test('handles case-insensitive extensions', () {
        final upperJpgFile = fixture.createFile('PHOTO.JPG', [1, 2, 3]);
        final mixedPngFile = fixture.createFile('Image.PNG', [4, 5, 6]);

        expect(service.isPhotoOrVideo(upperJpgFile), isTrue);
        expect(service.isPhotoOrVideo(mixedPngFile), isTrue);
      });
    });

    group('File Filtering', () {
      test('filters mixed file list correctly', () {
        final jpegFile = fixture.createFile('photo.jpg', [1, 2, 3]);
        final mp4File = fixture.createFile('video.mp4', [4, 5, 6]);
        final txtFile = fixture.createFile('document.txt', [7, 8, 9]);
        final pngFile = fixture.createFile('image.png', [10, 11, 12]);
        final jsonFile = fixture.createFile('metadata.json', [13, 14, 15]);

        final allFiles = [jpegFile, mp4File, txtFile, pngFile, jsonFile];
        final mediaFiles = service.filterPhotoVideoFiles(allFiles);

        expect(mediaFiles.length, equals(3));
        expect(mediaFiles, contains(jpegFile));
        expect(mediaFiles, contains(mp4File));
        expect(mediaFiles, contains(pngFile));
        expect(mediaFiles, isNot(contains(txtFile)));
        expect(mediaFiles, isNot(contains(jsonFile)));
      });

      test('handles empty file list', () {
        final result = service.filterPhotoVideoFiles([]);

        expect(result, isEmpty);
      });

      test('handles list with no media files', () {
        final txtFile = fixture.createFile('document.txt', [1, 2, 3]);
        final jsonFile = fixture.createFile('metadata.json', [4, 5, 6]);

        final result = service.filterPhotoVideoFiles([txtFile, jsonFile]);

        expect(result, isEmpty);
      });

      test('handles list with only media files', () {
        final jpegFile = fixture.createFile('photo.jpg', [1, 2, 3]);
        final mp4File = fixture.createFile('video.mp4', [4, 5, 6]);

        final result = service.filterPhotoVideoFiles([jpegFile, mp4File]);

        expect(result.length, equals(2));
        expect(result, contains(jpegFile));
        expect(result, contains(mp4File));
      });
    });

    group('File Operations', () {
      test('copies file successfully', () async {
        final sourceFile = fixture.createFile('source.txt', [1, 2, 3, 4, 5]);
        final destinationPath = '${fixture.basePath}/copy.txt';
        final destination = File(destinationPath);

        final result = await service.copyFile(sourceFile, destination);

        expect(result.existsSync(), isTrue);
        expect(result.path, equals(destinationPath));
        expect(sourceFile.existsSync(), isTrue); // Original should still exist
        expect(await result.readAsBytes(), equals([1, 2, 3, 4, 5]));
      });

      test('copy creates destination directory if needed', () async {
        final sourceFile = fixture.createFile('source.txt', [1, 2, 3]);
        final destinationPath = '${fixture.basePath}/subdir/copy.txt';
        final destination = File(destinationPath);

        final result = await service.copyFile(sourceFile, destination);

        expect(result.existsSync(), isTrue);
        expect(Directory('${fixture.basePath}/subdir').existsSync(), isTrue);
      });

      test('copy fails when source does not exist', () async {
        final nonExistentSource = File('${fixture.basePath}/nonexistent.txt');
        final destination = File('${fixture.basePath}/copy.txt');

        expect(
          () => service.copyFile(nonExistentSource, destination),
          throwsA(isA<FileSystemException>()),
        );
      });

      test(
        'copy fails when destination exists and overwrite is false',
        () async {
          final sourceFile = fixture.createFile('source.txt', [1, 2, 3]);
          final destinationFile = fixture.createFile('existing.txt', [4, 5, 6]);

          expect(
            () => service.copyFile(sourceFile, destinationFile),
            throwsA(isA<FileSystemException>()),
          );
        },
      );

      test(
        'copy succeeds when destination exists and overwrite is true',
        () async {
          final sourceFile = fixture.createFile('source.txt', [1, 2, 3]);
          final destinationFile = fixture.createFile('existing.txt', [4, 5, 6]);

          final result = await service.copyFile(
            sourceFile,
            destinationFile,
            overwrite: true,
          );

          expect(result.existsSync(), isTrue);
          expect(await result.readAsBytes(), equals([1, 2, 3]));
        },
      );

      test('moves file successfully', () async {
        final sourceFile = fixture.createFile('source.txt', [1, 2, 3, 4, 5]);
        final destinationPath = '${fixture.basePath}/moved.txt';
        final destination = File(destinationPath);

        final result = await service.moveFile(sourceFile, destination);

        expect(result.existsSync(), isTrue);
        expect(result.path, equals(destinationPath));
        expect(sourceFile.existsSync(), isFalse); // Original should be gone
        expect(await result.readAsBytes(), equals([1, 2, 3, 4, 5]));
      });

      test('move creates destination directory if needed', () async {
        final sourceFile = fixture.createFile('source.txt', [1, 2, 3]);
        final destinationPath = '${fixture.basePath}/subdir/moved.txt';
        final destination = File(destinationPath);

        final result = await service.moveFile(sourceFile, destination);

        expect(result.existsSync(), isTrue);
        expect(Directory('${fixture.basePath}/subdir').existsSync(), isTrue);
      });

      test('move fails when source does not exist', () async {
        final nonExistentSource = File('${fixture.basePath}/nonexistent.txt');
        final destination = File('${fixture.basePath}/moved.txt');

        expect(
          () => service.moveFile(nonExistentSource, destination),
          throwsA(isA<FileSystemException>()),
        );
      });
    });

    group('File Size Operations', () {
      test('gets file size correctly', () async {
        final file = fixture.createFile('test.txt', [1, 2, 3, 4, 5]);

        final size = await service.getFileSize(file);

        expect(size, equals(5));
      });

      test('getFileSize throws for non-existent file', () async {
        final nonExistentFile = File('${fixture.basePath}/nonexistent.txt');

        expect(
          () => service.getFileSize(nonExistentFile),
          throwsA(isA<FileSystemException>()),
        );
      });
    });

    group('Directory Operations', () {
      test('detects empty directory correctly', () async {
        final emptyDir = fixture.createDirectory('empty');

        final isEmpty = await service.isDirectoryEmpty(emptyDir);

        expect(isEmpty, isTrue);
      });

      test('detects non-empty directory correctly', () async {
        final dir = fixture.createDirectory('nonempty');
        fixture.createFile('nonempty/file.txt', [1, 2, 3]);

        final isEmpty = await service.isDirectoryEmpty(dir);

        expect(isEmpty, isFalse);
      });

      test('treats non-existent directory as empty', () async {
        final nonExistentDir = Directory('${fixture.basePath}/nonexistent');

        final isEmpty = await service.isDirectoryEmpty(nonExistentDir);

        expect(isEmpty, isTrue);
      });
      test('validates existing directory correctly', () async {
        final existingDir = fixture.createDirectory('existing');

        final result = await service.validateDirectory(existingDir);

        expect(result.isSuccess, isTrue);
      });

      test('validates non-existing directory correctly', () async {
        final nonExistentDir = Directory('${fixture.basePath}/nonexistent');

        final result = await service.validateDirectory(
          nonExistentDir,
          shouldExist: false,
        );

        expect(result.isSuccess, isTrue);
      });

      test(
        'validation fails when directory should exist but does not',
        () async {
          final nonExistentDir = Directory('${fixture.basePath}/nonexistent');

          final result = await service.validateDirectory(nonExistentDir);

          expect(result.isFailure, isTrue);
          expect(result.message, contains('does not exist'));
        },
      );

      test(
        'validation fails when directory should not exist but does',
        () async {
          final existingDir = fixture.createDirectory('existing');

          final result = await service.validateDirectory(
            existingDir,
            shouldExist: false,
          );

          expect(result.isFailure, isTrue);
          expect(result.message, contains('already exists'));
        },
      );

      test('safely creates directory', () async {
        final newDir = Directory('${fixture.basePath}/newdir/subdir');

        final success = await service.safeCreateDirectory(newDir);

        expect(success, isTrue);
        expect(newDir.existsSync(), isTrue);
      });

      test('safely creates directory handles existing directory', () async {
        final existingDir = fixture.createDirectory('existing');

        final success = await service.safeCreateDirectory(existingDir);

        expect(success, isTrue);
        expect(existingDir.existsSync(), isTrue);
      });
    });

    group('Error Handling', () {
      test('handles permission errors gracefully in copy operation', () async {
        final sourceFile = fixture.createFile('source.txt', [1, 2, 3]);

        final invalidPath = Platform.isWindows
            // <> are illegal filename characters on Windows
            ? r'C:\invalid<>path\file.txt'
            // /root is not writable by the CI runner user on Linux/macOS
            : '/root/invalid0path/file.txt';

        final invalidDestination = File(invalidPath);

        await expectLater(
          service.copyFile(sourceFile, invalidDestination),
          throwsA(isA<FileSystemException>()),
        );
      });

      test('handles permission errors gracefully in move operation', () async {
        final sourceFile = fixture.createFile('source.txt', [1, 2, 3]);

        final invalidPath = Platform.isWindows
            ? r'C:\invalid<>path\file.txt'
            : '/root/invalid0path/file.txt';

        final invalidDestination = File(invalidPath);

        await expectLater(
          service.moveFile(sourceFile, invalidDestination),
          throwsA(isA<FileSystemException>()),
        );
      });
    });
  });
}
