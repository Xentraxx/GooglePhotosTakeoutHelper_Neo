import 'dart:io';
import 'package:gpth_neo/gpth_lib_exports.dart';
import 'package:path/path.dart' as path;
import 'package:test/test.dart';

import '../setup/test_setup.dart';

void main() {
  group('Partner Sharing Integration Tests', () {
    late TestFixture fixture;
    late PathGeneratorService pathGenerator;

    setUp(() async {
      fixture = TestFixture();
      await fixture.setUp();
      // PathGeneratorService reads ServiceContainer.instance.globalConfig
      // (e.g. localTimezoneOffset) when generating date folders, so the
      // container must be initialized before any path generation call.
      await ServiceContainer.instance.initialize();
      pathGenerator = PathGeneratorService();
    });

    tearDown(() async {
      await ServiceContainer.reset();
      await fixture.tearDown();
    });

    group('Path Generation with Partner Sharing', () {
      test(
        'generates PARTNER_SHARED folder when dividePartnerShared is enabled',
        () {
          final context = MovingContext(
            outputDirectory: Directory('/output'),
            dateDivision: DateDivisionLevel.none,
            albumBehavior: AlbumBehavior.shortcut,
            dividePartnerShared: true,
          );

          final targetDir = pathGenerator.generateTargetDirectory(
            null, // main folder
            DateTime(2023, 1, 15),
            context,
            isPartnerShared: true,
          );

          expect(
            targetDir.path,
            equals(path.join('/output', 'PARTNER_SHARED', 'ALL_PHOTOS')),
          );
        },
      );

      test('generates ALL_PHOTOS folder for non-partner-shared media', () {
        final context = MovingContext(
          outputDirectory: Directory('/output'),
          dateDivision: DateDivisionLevel.none,
          albumBehavior: AlbumBehavior.shortcut,
          dividePartnerShared: true,
        );

        final targetDir = pathGenerator.generateTargetDirectory(
          null, // main folder
          DateTime(2023, 1, 15),
          context,
        );

        expect(targetDir.path, equals(path.join('/output', 'ALL_PHOTOS')));
      });

      test('applies date division to PARTNER_SHARED folder', () {
        final context = MovingContext(
          outputDirectory: Directory('/output'),
          dateDivision: DateDivisionLevel.month,
          albumBehavior: AlbumBehavior.shortcut,
          dividePartnerShared: true,
        );

        final targetDir = pathGenerator.generateTargetDirectory(
          null, // main folder
          DateTime(2023, 1, 15),
          context,
          isPartnerShared: true,
        );

        expect(
          targetDir.path,
          equals(
            path.join('/output', 'PARTNER_SHARED', 'ALL_PHOTOS', '2023', '01'),
          ),
        );
      });

      test('handles partner shared album folders correctly', () {
        final context = MovingContext(
          outputDirectory: Directory('/output'),
          dateDivision: DateDivisionLevel.month,
          albumBehavior: AlbumBehavior.shortcut,
          dividePartnerShared: true,
        );

        final targetDir = pathGenerator.generateTargetDirectory(
          'Family Album', // album folder
          DateTime(2023, 1, 15),
          context,
          isPartnerShared: true,
        );

        // Album folders don't get date division
        expect(
          targetDir.path,
          equals(
            path.join('/output', 'PARTNER_SHARED', 'Albums', 'Family Album'),
          ),
        );
      });

      test('ignores partner sharing when dividePartnerShared is disabled', () {
        final context = MovingContext(
          outputDirectory: Directory('/output'),
          dateDivision: DateDivisionLevel.none,
          albumBehavior: AlbumBehavior.shortcut,
        );

        final targetDir = pathGenerator.generateTargetDirectory(
          null, // main folder
          DateTime(2023, 1, 15),
          context,
          isPartnerShared: true,
        );

        // Should go to ./ALL_PHOTOS if dividePartnerShared is disabled
        expect(targetDir.path, equals(path.join('/output', 'ALL_PHOTOS')));
      });
    });

    group('Processing Config Integration', () {
      test('ProcessingConfig includes dividePartnerShared in builder', () {
        final builder = ProcessingConfig.builder(
          inputPath: '/input',
          outputPath: '/output',
        );
        builder.dividePartnerShared = true;
        final config = builder.build();

        expect(config.dividePartnerShared, isTrue);
      });

      test(
        'MovingContext.fromConfig preserves dividePartnerShared setting',
        () {
          const config = ProcessingConfig(
            inputPath: '/input',
            outputPath: '/output',
            dividePartnerShared: true,
          );

          final context = MovingContext.fromConfig(
            config,
            Directory('/output'),
          );

          expect(context.dividePartnerShared, isTrue);
        },
      );

      test('ProcessingConfig copyWith preserves dividePartnerShared', () {
        const originalConfig = ProcessingConfig(
          inputPath: '/input',
          outputPath: '/output',
          dividePartnerShared: true,
        );

        final copiedConfig = originalConfig.copyWith(verbose: true);

        expect(copiedConfig.dividePartnerShared, isTrue);
        expect(copiedConfig.verbose, isTrue);
      });
    });

    group('MediaEntity Partner Sharing Integration', () {
      test('partner shared flag is preserved through path generation', () {
        final file = fixture.createFile('partner_photo.jpg', [1, 2, 3]);

        // Wrap the File in a FileEntity for the new API
        final entity = MediaEntity.single(
          file: FileEntity(sourcePath: file.path),
          partnerShared: true, // NOTE: property is camelCase now
          dateTaken: DateTime(2023, 5, 15),
        );

        final context = MovingContext(
          outputDirectory: Directory('/output'),
          dateDivision: DateDivisionLevel.year,
          albumBehavior: AlbumBehavior.shortcut,
          dividePartnerShared: true,
        );

        final targetDir = pathGenerator.generateTargetDirectory(
          null,
          entity.dateTaken,
          context,
          isPartnerShared: entity.partnerShared,
        );

        expect(
          targetDir.path,
          equals(path.join('/output', 'PARTNER_SHARED', 'ALL_PHOTOS', '2023')),
        );
      });

      test(
        'mixed partner shared and personal media are separated correctly',
        () {
          final context = MovingContext(
            outputDirectory: Directory('/output'),
            dateDivision: DateDivisionLevel.none,
            albumBehavior: AlbumBehavior.shortcut,
            dividePartnerShared: true,
          );

          // Partner shared media
          final partnerDir = pathGenerator.generateTargetDirectory(
            null,
            DateTime(2023, 5, 15),
            context,
            isPartnerShared: true,
          );

          // Personal media
          final personalDir = pathGenerator.generateTargetDirectory(
            null,
            DateTime(2023, 5, 15),
            context,
          );

          expect(
            partnerDir.path,
            equals(path.join('/output', 'PARTNER_SHARED', 'ALL_PHOTOS')),
          );
          expect(personalDir.path, equals(path.join('/output', 'ALL_PHOTOS')));
        },
      );
    });

    group('Edge Cases', () {
      test('handles null date with partner sharing', () {
        final context = MovingContext(
          outputDirectory: Directory('/output'),
          dateDivision: DateDivisionLevel.month,
          albumBehavior: AlbumBehavior.shortcut,
          dividePartnerShared: true,
        );

        final targetDir = pathGenerator.generateTargetDirectory(
          null,
          null, // no date
          context,
          isPartnerShared: true,
        );

        expect(
          targetDir.path,
          equals(
            path.join(
              '/output',
              'PARTNER_SHARED',
              'ALL_PHOTOS',
              'date-unknown',
            ),
          ),
        );
      });

      test('handles all date division levels with partner sharing', () {
        final context = MovingContext(
          outputDirectory: Directory('/output'),
          dateDivision: DateDivisionLevel.day,
          albumBehavior: AlbumBehavior.shortcut,
          dividePartnerShared: true,
        );

        final targetDir = pathGenerator.generateTargetDirectory(
          null,
          DateTime(2023, 5, 15),
          context,
          isPartnerShared: true,
        );

        expect(
          targetDir.path,
          equals(
            path.join(
              '/output',
              'PARTNER_SHARED',
              'ALL_PHOTOS',
              '2023',
              '05',
              '15',
            ),
          ),
        );
      });
    });
  });
}
