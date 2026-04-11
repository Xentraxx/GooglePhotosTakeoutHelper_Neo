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

    // Regression test: concurrent moveFile calls targeting the same output
    // directory must never silently overwrite each other's files.
    // Before the fix (55eb5a57), findUniqueFileName used a TOCTOU pattern:
    // the existsSync check and the subsequent rename were not atomic, so two
    // fibers could receive the same candidate path and the second rename would
    // silently destroy the first file.
    group('concurrent moveFile – no silent overwrite (TOCTOU regression)', () {
      test(
        'N concurrent moveFile calls for identically-named sources all land '
        'in the output directory with distinct paths and intact content',
        () async {
          const int concurrency = 32;
          final service = FileOperationService();
          final targetDir = fixture.createDirectory('concurrent_output');

          // Create N source files each named 'photo.jpg' in their own
          // source sub-directory (simulating N different album/year folders
          // that all want to write a file called "photo.jpg" to the same
          // flat output directory under high concurrency).
          final sources = List.generate(concurrency, (final i) {
            final srcDir = fixture.createDirectory('src_$i');
            final f = File(path.join(srcDir.path, 'photo.jpg'));
            // Each file has unique byte content so we can verify nothing was lost.
            f.writeAsBytesSync([i, i + 1, i + 2], flush: true);
            return f;
          });

          // Fire all moves concurrently.
          final results = await Future.wait(
            sources.map((final src) => service.moveFile(src, targetDir)),
          );

          // ── Assertion 1: every source file was consumed ──────────────────
          for (final src in sources) {
            expect(
              src.existsSync(),
              isFalse,
              reason: 'Source ${src.path} should have been moved away',
            );
          }

          // ── Assertion 2: every result path is distinct ───────────────────
          final resultPaths = results.map((final f) => f.path).toList();
          expect(
            resultPaths.toSet().length,
            equals(concurrency),
            reason:
                'Each concurrent move must land at a unique path; '
                'duplicates indicate a TOCTOU silent-overwrite regression',
          );

          // ── Assertion 3: each result file still exists ───────────────────
          for (final result in results) {
            expect(
              result.existsSync(),
              isTrue,
              reason: 'Result file ${result.path} must exist after move',
            );
          }

          // ── Assertion 4: no byte content was lost ─────────────────────────
          // Collect all content blobs that arrived in the output directory.
          final outputContent = results
              .map((final f) => f.readAsBytesSync())
              .map((final b) => '${b[0]},${b[1]},${b[2]}')
              .toSet();
          final expectedContent = List.generate(
            concurrency,
            (final i) => '$i,${i + 1},${i + 2}',
          ).toSet();
          expect(
            outputContent,
            equals(expectedContent),
            reason:
                'Every source file\'s content must be present in the output; '
                'missing entries mean a file was silently overwritten',
          );
        },
      );
    });
  });
}
