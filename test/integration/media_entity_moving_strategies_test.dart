/// Test suite for MediaEntity moving strategies
///
/// Tests the complete implementation of all album behavior strategies including
/// shortcut, duplicate-copy, reverse-shortcut, json, and nothing modes.
// ignore_for_file: prefer_foreach

library;

import 'dart:convert';
import 'dart:io';
import 'package:gpth_neo/gpth_lib_exports.dart';
import 'package:test/test.dart';

import '../setup/test_setup.dart';

void main() {
  group('MediaEntity Moving Strategies', () {
    late TestFixture fixture;
    late FileOperationService fileService;
    late PathGeneratorService pathService;
    late SymlinkService symlinkService;
    late Directory outputDir;
    late MovingContext context;
    late AlbumRelationshipService albumSvc;

    setUp(() async {
      fixture = TestFixture();
      await fixture.setUp();

      // Initialize ServiceContainer
      await ServiceContainer.instance.initialize();
      albumSvc = ServiceContainer.instance.albumRelationshipService;

      fileService = FileOperationService();
      pathService = PathGeneratorService();
      symlinkService = SymlinkService();

      outputDir = fixture.createDirectory('output');
      context = MovingContext(
        outputDirectory: outputDir,
        dateDivision: DateDivisionLevel.year,
        albumBehavior: AlbumBehavior.shortcut,
      );
    });

    tearDown(() async {
      await fixture.tearDown();
      await ServiceContainer.reset();
    });

    /// Helper: build a MediaEntity with the new FileEntity-based model.
    MediaEntity entityFromFile(final File f, final DateTime dt) => MediaEntity(
      primaryFile: FileEntity(sourcePath: f.path),
      secondaryFiles: const <FileEntity>[],
      albumsMap: const <String, AlbumEntity>{},
      dateTaken: dt,
      dateTimeExtractionMethod: DateTimeExtractionMethod.none,
    );

    group('MediaEntityMovingStrategyFactory', () {
      late MoveMediaEntityStrategyFactory factory;

      setUp(() {
        factory = MoveMediaEntityStrategyFactory(
          fileService,
          pathService,
          symlinkService,
        );
      });

      test('creates shortcut strategy', () {
        final strategy = factory.createStrategy(AlbumBehavior.shortcut);
        expect(strategy, isA<ShortcutMovingStrategy>());
        expect(strategy.name, equals('Shortcut'));
        expect(strategy.createsShortcuts, isTrue);
        expect(strategy.createsDuplicates, isFalse);
      });

      test('creates duplicate-copy strategy', () {
        final strategy = factory.createStrategy(AlbumBehavior.duplicateCopy);
        expect(strategy, isA<DuplicateCopyMovingStrategy>());
        expect(strategy.name, equals('Duplicate Copy'));
        expect(strategy.createsShortcuts, isFalse);
        expect(strategy.createsDuplicates, isTrue);
      });

      test('creates reverse-shortcut strategy', () {
        final strategy = factory.createStrategy(AlbumBehavior.reverseShortcut);
        expect(strategy, isA<ReverseShortcutMovingStrategy>());
        expect(strategy.name, equals('Reverse Shortcut'));
        expect(strategy.createsShortcuts, isTrue);
        expect(strategy.createsDuplicates, isFalse);
      });

      test('creates json strategy', () {
        final strategy = factory.createStrategy(AlbumBehavior.json);
        expect(strategy, isA<JsonMovingStrategy>());
        expect(strategy.name, equals('JSON'));
        expect(strategy.createsShortcuts, isFalse);
        expect(strategy.createsDuplicates, isFalse);
      });

      test('creates nothing strategy', () {
        final strategy = factory.createStrategy(AlbumBehavior.nothing);
        expect(strategy, isA<NothingMovingStrategy>());
        expect(strategy.name, equals('Nothing'));
        expect(strategy.createsShortcuts, isFalse);
        expect(strategy.createsDuplicates, isFalse);
      });
    });

    group('ShortcutMovingStrategy', () {
      late ShortcutMovingStrategy strategy;

      setUp(() {
        strategy = ShortcutMovingStrategy(
          fileService,
          pathService,
          symlinkService,
        );
      });

      test('moves file to ALL_PHOTOS and creates album shortcuts', () async {
        // Same content in year and album → after merge there is 1 entity with albumNames=['Vacation']
        final content = [1, 2, 3];
        final yearFile = fixture.createFile('2023/test.jpg', content);
        final albumFile = fixture.createFile(
          'Albums/Vacation/test.jpg',
          content,
        );

        final merged = await albumSvc.detectAndMergeAlbums([
          entityFromFile(yearFile, DateTime(2023, 6, 15)),
          entityFromFile(albumFile, DateTime(2023, 6, 15)),
        ]);
        final entity = merged.single;

        final results = <MoveMediaEntityResult>[];
        await for (final r in strategy.processMediaEntity(entity, context)) {
          results.add(r);
        }

        expect(results.length, equals(2)); // move + symlink
        expect(results[0].success, isTrue);
        expect(
          results[0].operation.operationType,
          equals(MediaEntityOperationType.move),
        );
        expect(results[1].success, isTrue);
        expect(
          results[1].operation.operationType,
          equals(MediaEntityOperationType.createSymlink),
        );

        // Validate ALL_PHOTOS directory using the path generator (avoid hardcoded structure)
        final allPhotosDir = pathService.generateTargetDirectory(
          null,
          entity.dateTaken,
          context,
          isPartnerShared: entity.partnerShared,
        );
        expect(allPhotosDir.existsSync(), isTrue);

        // Validate album directory exists too (shortcut target location)
        final albumDir = pathService.generateTargetDirectory(
          'Vacation',
          entity.dateTaken,
          context,
          isPartnerShared: entity.partnerShared,
        );
        expect(albumDir.existsSync(), isTrue);
      });

      test(
        'creates album links for HEIC, MP4, and MOV files',
        () async {
          final files = <String>['live.HEIC', 'live.MP4', 'movie.MOV'];

          for (final name in files) {
            final source = fixture.createFile('Album/$name', [1, 2, 3]);
            final entity = MediaEntity.single(
              file: FileEntity(sourcePath: source.path),
              dateTaken: DateTime(2023, 6, 15),
              albumsMap: {
                'Album': AlbumEntity(
                  name: 'Album',
                  sourceDirectories: {source.parent.path},
                ),
              },
            );

            final results = <MoveMediaEntityResult>[];
            await for (final result in strategy.processMediaEntity(
              entity,
              context,
            )) {
              results.add(result);
            }

            final linkResult = results.singleWhere(
              (final result) =>
                  result.operation.operationType ==
                  MediaEntityOperationType.createSymlink,
            );
            final shortcut = Link(linkResult.resultFile!.path);
            expect(
              await shortcut.exists(),
              isTrue,
              reason: '$name must remain an album symlink in shortcut mode',
            );
          }
        },
      );

      test('restores a missing shortcut after later processing stages', () async {
        final source = fixture.createFile('Album/live.MP4', [1, 2, 3]);
        final entity = MediaEntity.single(
          file: FileEntity(sourcePath: source.path),
          dateTaken: DateTime(2023, 6, 15),
          albumsMap: {
            'Album': AlbumEntity(
              name: 'Album',
              sourceDirectories: {source.parent.path},
            ),
          },
        );

        await for (final _ in strategy.processMediaEntity(entity, context)) {}

        final shortcut = entity.secondaryFiles.singleWhere(
          (final file) => file.isShortcut,
        );
        await Link(shortcut.targetPath!).delete();

        final summary = await ShortcutIntegrityService().verifyAndRestore(
          MediaEntityCollection([entity]),
          outputDirectory: outputDir,
        );

        expect(summary.restored, equals(1));
        expect(await Link(shortcut.targetPath!).exists(), isTrue);
      });

      test('replaces an identical stale physical video with a shortcut', () async {
        final source = fixture.createFile('Album/live.MP4', [1, 2, 3]);
        final staleOutput = fixture.createFile(
          'output/Albums/Album/live.MP4',
          [1, 2, 3],
        );
        final entity = MediaEntity.single(
          file: FileEntity(sourcePath: source.path),
          dateTaken: DateTime(2023, 6, 15),
          albumsMap: {
            'Album': AlbumEntity(
              name: 'Album',
              sourceDirectories: {source.parent.path},
            ),
          },
        );

        await for (final _ in strategy.processMediaEntity(entity, context)) {}

        expect(await File(staleOutput.path).exists(), isTrue);
        expect(await Link(staleOutput.path).exists(), isTrue);
      });

      test('moves a distinct physical album entry outside Albums before linking',
          () async {
        final source = fixture.createFile('Album/live.MP4', [1, 2, 3]);
        final staleOutput = fixture.createFile(
          'output/Albums/Album/live.MP4',
          [4, 5, 6],
        );
        final entity = MediaEntity.single(
          file: FileEntity(sourcePath: source.path),
          dateTaken: DateTime(2023, 6, 15),
          albumsMap: {
            'Album': AlbumEntity(
              name: 'Album',
              sourceDirectories: {source.parent.path},
            ),
          },
        );

        await for (final _ in strategy.processMediaEntity(entity, context)) {}

        expect(await Link(staleOutput.path).exists(), isTrue);
        expect(
          Directory('${outputDir.path}/Shortcut Conflicts/Album').existsSync(),
          isTrue,
        );
      });

      test(
        'uses hard links in shortcut mode when hardlink is enabled on Windows',
        () async {
          if (!Platform.isWindows) return;

          final content = [1, 2, 3];
          final yearFile = fixture.createFile(
            '2023/hardlink_test.jpg',
            content,
          );
          final albumFile = fixture.createFile(
            'Albums/Vacation/hardlink_test.jpg',
            content,
          );

          final merged = await albumSvc.detectAndMergeAlbums([
            entityFromFile(yearFile, DateTime(2023, 6, 15)),
            entityFromFile(albumFile, DateTime(2023, 6, 15)),
          ]);
          final entity = merged.single;

          final hardlinkContext = MovingContext(
            outputDirectory: outputDir,
            dateDivision: DateDivisionLevel.year,
            albumBehavior: AlbumBehavior.shortcut,
            hardlink: true,
          );

          final results = <MoveMediaEntityResult>[];
          await for (final r in strategy.processMediaEntity(
            entity,
            hardlinkContext,
          )) {
            results.add(r);
          }

          expect(results.length, equals(2));

          final moveResult = results.firstWhere(
            (final r) =>
                r.success &&
                r.operation.operationType == MediaEntityOperationType.move,
          );
          final linkResult = results.firstWhere(
            (final r) =>
                r.success &&
                r.operation.operationType ==
                    MediaEntityOperationType.createSymlink,
          );

          final movedFile = moveResult.resultFile!;
          final hardlinkFile = linkResult.resultFile!;

          expect(await File(hardlinkFile.path).exists(), isTrue);
          expect(
            await Link(hardlinkFile.path).exists(),
            isFalse,
            reason: 'hardlink mode should produce a hard link, not a symlink',
          );

          // Hard links survive deleting another path to the same file.
          await movedFile.delete();
          expect(await File(hardlinkFile.path).exists(), isTrue);
          expect(await File(hardlinkFile.path).readAsBytes(), equals(content));
        },
      );

      test(
        'handles entity without album associations but not in cannonical folder',
        () async {
          final sourceFile = fixture.createFile('test.jpg', [1, 2, 3]);
          final entity = entityFromFile(sourceFile, DateTime(2023, 6, 15));

          final results = <MoveMediaEntityResult>[];
          await for (final r in strategy.processMediaEntity(entity, context)) {
            results.add(r);
          }

          expect(
            results.length,
            equals(2),
          ); // strategy used: shortcut (default). results should be two files (one in ALL_PHOTOS (created with move) and other in Albums folder (created as symlink))
          expect(results[0].success, isTrue);
          expect(
            results[0].operation.operationType,
            equals(MediaEntityOperationType.move),
          );
          expect(results[1].success, isTrue);
          expect(
            results[1].operation.operationType,
            equals(MediaEntityOperationType.createSymlink),
          );
        },
      );
    });

    group('DuplicateCopyMovingStrategy', () {
      late DuplicateCopyMovingStrategy strategy;

      setUp(() {
        strategy = DuplicateCopyMovingStrategy(fileService, pathService);
      });

      test(
        'moves canonical file to ALL_PHOTOS and moves (not copies) non-canonical files to album folders',
        () async {
          final content = [1, 2, 3];
          final yearFile = fixture.createFile('2023/test.jpg', content);
          final albumFile = fixture.createFile(
            'Albums/Vacation/test.jpg',
            content,
          );

          final merged = await albumSvc.detectAndMergeAlbums([
            entityFromFile(yearFile, DateTime(2023, 6, 15)),
            entityFromFile(albumFile, DateTime(2023, 6, 15)),
          ]);
          final entity = merged.single;

          final results = <MoveMediaEntityResult>[];
          await for (final r in strategy.processMediaEntity(entity, context)) {
            results.add(r);
          }

          expect(results.length, equals(2)); // move + copy
          expect(results[0].success, isTrue);
          expect(
            results[0].operation.operationType,
            equals(MediaEntityOperationType.move),
          );
          expect(results[1].success, isTrue);
          // expect(results[1].operation.operationType, equals(MediaEntityOperationType.copy));
          expect(
            results[1].operation.operationType,
            equals(MediaEntityOperationType.move),
          ); // Now is move operaions expected

          // Validate ALL_PHOTOS directory using the path generator
          final allPhotosDir = pathService.generateTargetDirectory(
            null,
            entity.dateTaken,
            context,
            isPartnerShared: entity.partnerShared,
          );
          expect(allPhotosDir.existsSync(), isTrue);

          // Validate album directory using the path generator
          final albumDir = pathService.generateTargetDirectory(
            'Vacation',
            entity.dateTaken,
            context,
            isPartnerShared: entity.partnerShared,
          );
          expect(albumDir.existsSync(), isTrue);
        },
      );
    });

    group('JsonMovingStrategy', () {
      late JsonMovingStrategy strategy;

      setUp(() {
        strategy = JsonMovingStrategy(fileService, pathService);
      });

      test('moves files to ALL_PHOTOS and creates albums-info.json', () async {
        // Entity 1: year + album Vacation
        final c1 = [1, 2, 3];
        final y1 = fixture.createFile('2023/test1.jpg', c1);
        final a1 = fixture.createFile('Albums/Vacation/test1.jpg', c1);

        // Entity 2: year + album Family
        final c2 = [4, 5, 6];
        final y2 = fixture.createFile('2023/test2.jpg', c2);
        final a2 = fixture.createFile('Albums/Family/test2.jpg', c2);

        final merged = await albumSvc.detectAndMergeAlbums([
          entityFromFile(y1, DateTime(2023, 6, 15)),
          entityFromFile(a1, DateTime(2023, 6, 15)),
          entityFromFile(y2, DateTime(2023, 7, 20)),
          entityFromFile(a2, DateTime(2023, 7, 20)),
        ]);

        // Process both merged entities
        final results1 = <MoveMediaEntityResult>[];
        await for (final r in strategy.processMediaEntity(merged[0], context)) {
          results1.add(r);
        }
        final results2 = <MoveMediaEntityResult>[];
        await for (final r in strategy.processMediaEntity(merged[1], context)) {
          results2.add(r);
        }

        expect(
          results1.length,
          equals(2),
        ); // 2 operarions (1. MOVE for the primary and 2. DELETE for the secondary)
        expect(
          results2.length,
          equals(2),
        ); // 2 operarions (1. MOVE for the primary and 2. DELETE for the secondary)
        expect(results1[0].success, isTrue);
        expect(results2[0].success, isTrue);

        // Finalize to create albums-info.json (resolve path via service)
        final finalizationResults = await strategy.finalize(context, merged);
        expect(finalizationResults.length, equals(1));
        expect(finalizationResults[0].success, isTrue);

        final jsonPath = pathService.generateAlbumsInfoJsonPath(outputDir);
        final jsonFile = File(jsonPath);
        expect(jsonFile.existsSync(), isTrue);

        final jsonContent = await jsonFile.readAsString();
        final albumData = jsonDecode(jsonContent) as Map<String, dynamic>;
        expect(albumData['albums'], isA<Map<String, dynamic>>());
        expect(albumData['metadata']['total_albums'], equals(2));
      });
    });

    group('NothingMovingStrategy', () {
      late NothingMovingStrategy strategy;

      setUp(() {
        strategy = NothingMovingStrategy(fileService, pathService);
      });

      test('moves only year-based files to ALL_PHOTOS', () async {
        final sourceFile = fixture.createFile('test.jpg', [1, 2, 3]);
        final entity = entityFromFile(sourceFile, DateTime(2023, 6, 15));

        final results = <MoveMediaEntityResult>[];
        await for (final r in strategy.processMediaEntity(entity, context)) {
          results.add(r);
        }

        expect(results.length, equals(1));
        expect(results[0].success, isTrue);
        expect(
          results[0].operation.operationType,
          equals(MediaEntityOperationType.move),
        );
      });

      test('processes album-only files (fixed behavior)', () async {
        // Exists only in album → should still be processed (move)
        final albumOnly = fixture.createFile('Albums/Vacation/test.jpg', [
          1,
          2,
          3,
        ]);
        final entity = entityFromFile(albumOnly, DateTime(2023, 6, 15));

        final results = <MoveMediaEntityResult>[];
        await for (final r in strategy.processMediaEntity(entity, context)) {
          results.add(r);
        }

        expect(results.length, equals(1));
        expect(results[0].success, isTrue);
        expect(
          results[0].operation.operationType,
          equals(MediaEntityOperationType.move),
        );
      });
    });

    group('Integration Tests', () {
      test('all strategies can be created and validate context', () {
        final factory = MoveMediaEntityStrategyFactory(
          fileService,
          pathService,
          symlinkService,
        );

        for (final behavior in AlbumBehavior.values) {
          final strategy = factory.createStrategy(behavior);
          expect(strategy, isA<MoveMediaEntityStrategy>());
          expect(() => strategy.validateContext(context), returnsNormally);
        }
      });

      test('strategies handle file operation errors gracefully', () async {
        final strategy = ShortcutMovingStrategy(
          fileService,
          pathService,
          symlinkService,
        );

        final nonExistentFile = File('${fixture.basePath}/nonexistent.jpg');
        final entity = entityFromFile(nonExistentFile, DateTime(2023, 6, 15));

        final results = <MoveMediaEntityResult>[];
        await for (final r in strategy.processMediaEntity(entity, context)) {
          results.add(r);
        }

        expect(results.length, equals(1));
        expect(results[0].success, isFalse);
        expect(
          results[0].errorMessage,
          contains('Failed to move primary file'),
        );
      });
    });
  });
}
