/// Unit tests for the refactored moving logic services
///
/// These tests validate the individual components of the new moving architecture
/// and ensure proper functionality of each service in isolation.
library;

import 'dart:io';
import 'package:gpth_neo/gpth_lib_exports.dart';
import 'package:path/path.dart' as path;
import 'package:test/test.dart';

import '../setup/test_setup.dart';

void main() {
  group('Refactored Moving Logic - Unit Tests', () {
    late TestFixture fixture;

    setUp(() async {
      fixture = TestFixture();
      await fixture.setUp();
      await ServiceContainer.instance.initialize();
    });

    tearDown(() async {
      await fixture.tearDown();
      await ServiceContainer.reset();
    });

    group('FileOperationService', () {
      late FileOperationService service;

      setUp(() {
        service = FileOperationService();
      });
      test('findUniqueFileName generates unique names', () {
        final originalFile = fixture.createFile('test.jpg', [1, 2, 3]);

        // Create a file with the same name to force collision
        final conflictFile = File(originalFile.path);
        conflictFile.createSync();

        final uniqueFile = ServiceContainer.instance.utilityService
            .findUniqueFileName(originalFile);

        expect(uniqueFile.path, contains('test(1).jpg'));
        expect(uniqueFile.existsSync(), isFalse);
      });
      test('copyFile copies file while preserving original', () async {
        final sourceFile = fixture.createFile('source.jpg', [1, 2, 3]);
        final targetDir = fixture.createDirectory('target');

        final result = await service.copyFile(sourceFile, targetDir);

        // Original file should still exist
        expect(sourceFile.existsSync(), isTrue);

        // Result file should exist in target directory
        expect(result.existsSync(), isTrue);
        expect(result.parent.path, equals(targetDir.path));
        expect(result.readAsBytesSync(), equals([1, 2, 3]));
      });
      test('moveFile moves file to target directory', () async {
        final sourceFile = fixture.createFile('source.jpg', [1, 2, 3]);
        final targetDir = fixture.createDirectory('target');

        final result = await service.moveFile(sourceFile, targetDir);

        // Original file should no longer exist
        expect(sourceFile.existsSync(), isFalse);

        // Result file should exist in target directory
        expect(result.existsSync(), isTrue);
        expect(result.parent.path, equals(targetDir.path));
        expect(result.readAsBytesSync(), equals([1, 2, 3]));
      });

      test('setFileTimestamp sets file modification time', () async {
        final file = fixture.createFile('test.jpg', [1, 2, 3]);
        final timestamp = DateTime(2023, 6, 15, 10, 30);

        await service.setFileTimestamp(file, timestamp);

        final modTime = await file.lastModified();
        expect(modTime.year, equals(2023));
        expect(modTime.month, equals(6));
        expect(modTime.day, equals(15));
      });

      test(
        'setFileTimestamp handles Windows date limitations',
        () async {
          final file = fixture.createFile('test.jpg', [1, 2, 3]);
          final earlyTimestamp = DateTime(1960); // Before 1970

          // Should not throw and should adjust to 1970 on Windows
          await service.setFileTimestamp(file, earlyTimestamp);

          final modTime = await file.lastModified();
          if (Platform.isWindows) {
            expect(modTime.year, greaterThanOrEqualTo(1970));
          } else {
            // On non-Windows platforms we just assert the file still exists; some
            // *nix filesystems may not support negative (pre-epoch) mtimes reliably.
            expect(file.existsSync(), isTrue);
          }
        },
        skip: !Platform.isWindows
            ? 'Windows-specific behavior (date clamped to >= 1970)'
            : null,
      );

      test(
        'ensureDirectoryExists creates directory if it does not exist',
        () async {
          final dir = Directory(path.join(fixture.basePath, 'new_directory'));
          expect(await dir.exists(), isFalse);

          await service.ensureDirectoryExists(dir);

          expect(await dir.exists(), isTrue);
        },
      );
    });

    group('PathGeneratorService', () {
      late PathGeneratorService service;
      late MovingContext context;

      setUp(() {
        service = PathGeneratorService();
        context = MovingContext(
          outputDirectory: fixture.createDirectory('output'),
          dateDivision: DateDivisionLevel.year,
          albumBehavior: AlbumBehavior.shortcut,
        );
      });
      test('generateTargetDirectory creates ALL_PHOTOS for null album', () {
        final result = service.generateTargetDirectory(
          null,
          DateTime(2023, 6, 15),
          context,
        );

        // The path should be output/ALL_PHOTOS/2023
        // Check that ALL_PHOTOS is in the path components
        final pathComponents = path.split(result.path);
        expect(pathComponents, contains('ALL_PHOTOS'));
        expect(pathComponents, contains('2023'));
      });

      test('generateTargetDirectory creates album folder for named album', () {
        final result = service.generateTargetDirectory(
          'Vacation Photos',
          DateTime(2023, 6, 15),
          context,
        );

        expect(result.path, contains('Vacation Photos'));
        expect(result.path, isNot(contains('2023')));
      });

      test(
        'generateTargetDirectory handles different date division levels',
        () {
          final date = DateTime(2023, 6, 15);
          final outputPath = context.outputDirectory.path;

          // Test year division
          context = MovingContext(
            outputDirectory: context.outputDirectory,
            dateDivision: DateDivisionLevel.year,
            albumBehavior: context.albumBehavior,
          );
          var result = service.generateTargetDirectory(null, date, context);
          // Check only the relative portion so fixture directory names with
          // coincidental digits (e.g. "...06...") don't cause false failures.
          var relComponents = path.split(
            path.relative(result.path, from: outputPath),
          );
          expect(relComponents, contains('2023'));
          expect(relComponents, isNot(contains('06')));

          // Test month division
          context = MovingContext(
            outputDirectory: context.outputDirectory,
            dateDivision: DateDivisionLevel.month,
            albumBehavior: context.albumBehavior,
          );
          result = service.generateTargetDirectory(null, date, context);
          relComponents = path.split(
            path.relative(result.path, from: outputPath),
          );
          expect(relComponents, contains('2023'));
          expect(relComponents, contains('06'));

          // Test day division
          context = MovingContext(
            outputDirectory: context.outputDirectory,
            dateDivision: DateDivisionLevel.day,
            albumBehavior: context.albumBehavior,
          );
          result = service.generateTargetDirectory(null, date, context);
          relComponents = path.split(
            path.relative(result.path, from: outputPath),
          );
          expect(relComponents, contains('2023'));
          expect(relComponents, contains('06'));
          expect(relComponents, contains('15'));
        },
      );

      test('generateTargetDirectory handles null date', () {
        final result = service.generateTargetDirectory(null, null, context);

        expect(result.path, contains('date-unknown'));
      });

      test('sanitizeFileName removes illegal characters', () {
        final result = service.sanitizeFileName('file<>:"/\\|?*name.jpg');
        expect(result, equals('file_________name.jpg'));
      });

      test('generateAlbumsInfoJsonPath creates correct path', () {
        final result = service.generateAlbumsInfoJsonPath(
          context.outputDirectory,
        );
        expect(path.basename(result), equals('albums-info.json'));
        expect(result, contains(context.outputDirectory.path));
      });
    });

    group('MovingContext', () {
      test('fromConfig creates context from ProcessingConfig', () {
        final outputDir = fixture.createDirectory('output');
        final config = ProcessingConfig(
          inputPath: fixture.basePath,
          outputPath: outputDir.path,
          albumBehavior: AlbumBehavior.json,
          dateDivision: DateDivisionLevel.month,
          verbose: true,
        );

        final context = MovingContext.fromConfig(config, outputDir);

        expect(context.outputDirectory.path, equals(outputDir.path));
        expect(context.albumBehavior, equals(AlbumBehavior.json));
        expect(context.dateDivision, equals(DateDivisionLevel.month));
        expect(context.verbose, isTrue);
      });
    });
  });
}
