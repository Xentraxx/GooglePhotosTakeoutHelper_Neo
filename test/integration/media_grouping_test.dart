/// Test suite for Modern Media Entity Grouping and Collection Management
///
/// This test suite validates the modern media management system using
/// MediaEntity and MediaEntityCollection classes for processing photos
/// and videos from Google Photos Takeout exports.
library;

import 'dart:io';
import 'dart:typed_data';

import 'package:gpth_neo/gpth_lib_exports.dart';
import 'package:path/path.dart' as path;
import 'package:test/test.dart';

import '../setup/test_setup.dart';

void main() {
  group('Modern Media Entity and Collection Tests', () {
    late TestFixture fixture;

    setUp(() async {
      fixture = TestFixture();
      await fixture.setUp();
      await ServiceContainer.instance.initialize();
    });

    tearDown(() async {
      await ServiceContainer.reset();
      await fixture.tearDown();
    });

    group('MediaEntity - Object Creation and Property Management', () {
      test('creates MediaEntity with single file', () {
        final file = fixture.createFile(
          'test.jpg',
          Uint8List.fromList([1, 2, 3]),
        );
        final entity = MediaEntity.single(
          file: FileEntity(sourcePath: file.path),
        );
        final expectedAlbum = path.basename(
          path.dirname(file.path),
        ); // p.ej. "Vacation" o "fixture_..."

        expect(entity.primaryFile.path, file.path);
        expect(
          entity.hasAlbumAssociations,
          isTrue,
        ); // the parent folder of any file will always be consideer as Album, except for those cannonical year folder ("Photos from yyyy", "yyyy", "yyyy/mm", "yyyy-mm")
        expect(
          entity.albumNames,
          contains(expectedAlbum),
        ); // The album name is the name of the parent folder (in this case always start with 'fixture_')
        expect(entity.dateTaken, isNull);
        expect(entity.dateAccuracy, isNull);
      });

      test('creates MediaEntity with date information', () {
        final file = fixture.createFile(
          'test.jpg',
          Uint8List.fromList([1, 2, 3]),
        );
        final date = DateTime(2023, 1, 15);
        final entity = MediaEntity.single(
          file: FileEntity(sourcePath: file.path),
          dateTaken: date,
          dateAccuracy: DateAccuracy.good,
          dateTimeExtractionMethod: DateTimeExtractionMethod.exif,
        );

        expect(entity.dateTaken, date);
        expect(entity.dateAccuracy, DateAccuracy.good);
        expect(entity.dateTimeExtractionMethod, DateTimeExtractionMethod.exif);
      });

      test('MediaEntity gains album associations after merge', () async {
        // same content in year folder and in Albums/... →
        // after detection, a single entity with that album
        final bytes = Uint8List.fromList([4, 5, 6]);
        final yearFile = fixture.createFile('2023/test.jpg', bytes);
        final albumFile = fixture.createFile(
          'Albums/Album Name/test.jpg',
          bytes,
        );

        final merged = await ServiceContainer.instance.albumRelationshipService
            .detectAndMergeAlbums([
              MediaEntity.single(
                file: FileEntity(sourcePath: yearFile.path),
                dateTaken: DateTime(2023, 1, 15),
                dateAccuracy: DateAccuracy.good,
                dateTimeExtractionMethod: DateTimeExtractionMethod.exif,
              ),
              MediaEntity.single(
                file: FileEntity(sourcePath: albumFile.path),
                dateTaken: DateTime(2023, 1, 15),
              ),
            ]);

        expect(merged.length, 1);
        final entity = merged.first;
        expect(entity.hasAlbumAssociations, isTrue);
        expect(entity.albumNames, contains('Album Name'));
        expect(entity.dateAccuracy, DateAccuracy.good);
      });
    });

    group('MediaEntityCollection - Collection Management', () {
      test('creates empty collection', () {
        final collection = MediaEntityCollection();

        expect(collection.isEmpty, isTrue);
        expect(collection.length, 0);
        expect(collection.entities, isEmpty);
      });

      test('creates collection with initial entities', () {
        final file1 = fixture.createFile(
          'test1.jpg',
          Uint8List.fromList([1, 2, 3]),
        );
        final file2 = fixture.createFile(
          'test2.jpg',
          Uint8List.fromList([4, 5, 6]),
        );

        final entity1 = MediaEntity.single(
          file: FileEntity(sourcePath: file1.path),
        );
        final entity2 = MediaEntity.single(
          file: FileEntity(sourcePath: file2.path),
        );

        final collection = MediaEntityCollection([entity1, entity2]);

        expect(collection.length, 2);
        expect(collection.isNotEmpty, isTrue);
        expect(collection.entities.contains(entity1), isTrue);
        expect(collection.entities.contains(entity2), isTrue);
      });

      test('adds entities to collection', () {
        final collection = MediaEntityCollection();
        final file = fixture.createFile(
          'test.jpg',
          Uint8List.fromList([1, 2, 3]),
        );
        final entity = MediaEntity.single(
          file: FileEntity(sourcePath: file.path),
        );

        collection.add(entity);

        expect(collection.length, 1);
        expect(collection.entities.first, entity);
      });

      test('removes entities from collection', () {
        final file = fixture.createFile(
          'test.jpg',
          Uint8List.fromList([1, 2, 3]),
        );
        final entity = MediaEntity.single(
          file: FileEntity(sourcePath: file.path),
        );
        final collection = MediaEntityCollection([entity]);

        final removed = collection.remove(entity);

        expect(removed, isTrue);
        expect(collection.isEmpty, isTrue);
      });
    });

    group('MediaEntityCollection - Duplicate Detection', () {
      test('removes duplicate entities successfully', () async {
        // Explicit config for this test (pass required paths; other options use defaults)
        final cfg = ProcessingConfig(
          disableResumeCheck: true,
          inputPath: fixture.basePath,
          outputPath: fixture.basePath,
        );

        final file1 = fixture.createFile(
          'test1.jpg',
          Uint8List.fromList([1, 2, 3, 4, 5]),
        );
        final file2 = fixture.createFile(
          'test2.jpg',
          Uint8List.fromList([1, 2, 3, 4, 5]),
        ); // same content
        final file3 = fixture.createFile(
          'test3.jpg',
          Uint8List.fromList([6, 7, 8, 9, 10]),
        ); // different content

        final entity1 = MediaEntity.single(
          file: FileEntity(sourcePath: file1.path),
        );
        final entity2 = MediaEntity.single(
          file: FileEntity(sourcePath: file2.path),
        );
        final entity3 = MediaEntity.single(
          file: FileEntity(sourcePath: file3.path),
        );

        final collection = MediaEntityCollection([entity1, entity2, entity3]);

        final mergeResult = await const MergeMediaEntitiesStep().execute(
          ProcessingContext(
            config: cfg,
            mediaCollection: collection,
            inputDirectory: Directory(cfg.inputPath),
            outputDirectory: Directory(cfg.outputPath),
          ),
        );
        final removedCount = (mergeResult.data['entitiesMerged'] as int?) ?? 0;

        expect(collection.length, 2);
        expect(removedCount, 1);
      });

      test('handles collection with no duplicates', () async {
        // Explicit config for this test (pass required paths; other options use defaults)
        final cfg = ProcessingConfig(
          inputPath: fixture.basePath,
          outputPath: fixture.basePath,
          disableResumeCheck: true,
        );
        final file1 = fixture.createFile(
          'test1.jpg',
          Uint8List.fromList([1, 2, 3]),
        );
        final file2 = fixture.createFile(
          'test2.jpg',
          Uint8List.fromList([4, 5, 6]),
        );

        final entity1 = MediaEntity.single(
          file: FileEntity(sourcePath: file1.path),
        );
        final entity2 = MediaEntity.single(
          file: FileEntity(sourcePath: file2.path),
        );

        final collection = MediaEntityCollection([entity1, entity2]);

        final mergeResult = await const MergeMediaEntitiesStep().execute(
          ProcessingContext(
            config: cfg,
            mediaCollection: collection,
            inputDirectory: Directory(cfg.inputPath),
            outputDirectory: Directory(cfg.outputPath),
          ),
        );
        final removedCount = (mergeResult.data['entitiesMerged'] as int?) ?? 0;

        expect(collection.length, 2);
        expect(removedCount, 0);
      });
    });

    group('MediaEntityCollection - Album Detection', () {
      test('finds albums in collection (no-op when none present)', () async {
        // Explicit config for this test (pass required paths; other options use defaults)
        final cfg = ProcessingConfig(
          inputPath: fixture.basePath,
          outputPath: fixture.basePath,
        );

        final file1 = fixture.createFile(
          'test1.jpg',
          Uint8List.fromList([1, 2, 3]),
        );
        final file2 = fixture.createFile(
          'test2.jpg',
          Uint8List.fromList([4, 5, 6]),
        );

        final entity1 = MediaEntity.single(
          file: FileEntity(sourcePath: file1.path),
        );
        final entity2 = MediaEntity.single(
          file: FileEntity(sourcePath: file2.path),
        );

        final collection = MediaEntityCollection([entity1, entity2]);

        await const FindAlbumsStep().execute(
          ProcessingContext(
            config: cfg,
            mediaCollection: collection,
            inputDirectory: Directory(cfg.inputPath),
            outputDirectory: Directory(cfg.outputPath),
          ),
        );

        expect(collection.length, 2);
      });

      test(
        'processes entities with album associations after detection',
        () async {
          // Explicit config for this test (pass required paths; other options use defaults)
          final cfg = ProcessingConfig(
            inputPath: fixture.basePath,
            outputPath: fixture.basePath,
          );

          final bytesA = Uint8List.fromList([7, 7, 7]);
          final year = fixture.createFile('2023/test.jpg', bytesA);
          final album = fixture.createFile(
            'Albums/Vacation 2023/test.jpg',
            bytesA,
          );

          final collection = MediaEntityCollection([
            MediaEntity.single(file: FileEntity(sourcePath: year.path)),
            MediaEntity.single(file: FileEntity(sourcePath: album.path)),
          ]);

          await const FindAlbumsStep().execute(
            ProcessingContext(
              config: cfg,
              mediaCollection: collection,
              inputDirectory: Directory(cfg.inputPath),
              outputDirectory: Directory(cfg.outputPath),
            ),
          );

          expect(collection.length, 2);
          final entity1 = collection.entities.first;
          final entity2 = collection.entities.last;
          expect(entity1.hasAlbumAssociations, isFalse);
          expect(entity2.hasAlbumAssociations, isTrue);
          expect(entity2.albumNames, contains('Vacation 2023'));
        },
      );
    });
  });
}
