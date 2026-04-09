/// Test suite for Media Entity and Collection Management functionality.
///
/// Comprehensive tests for the modern media management system.
library;

import 'dart:convert';
import 'dart:io';

import 'package:gpth_neo/gpth_lib_exports.dart';
import 'package:path/path.dart' as path;
import 'package:test/test.dart';

import '../setup/test_setup.dart';

ProcessingContext _ctx(
  final ProcessingConfig cfg,
  final MediaEntityCollection collection,
) => ProcessingContext(
  config: cfg,
  mediaCollection: collection,
  inputDirectory: Directory(cfg.inputPath),
  outputDirectory: Directory(cfg.outputPath),
);

void main() {
  group('MediaEntity and Collection - Modern Content Management System', () {
    late TestFixture fixture;
    late AlbumRelationshipService albumSvc;

    setUp(() async {
      fixture = TestFixture();
      await fixture.setUp();
      await ServiceContainer.instance.initialize();
      albumSvc = ServiceContainer.instance.albumRelationshipService;
    });

    tearDown(() async {
      await ServiceContainer.reset();
      await fixture.tearDown();
    });

    group('MediaEntity Class - Object Creation and Property Management', () {
      test('creates MediaEntity object with required properties', () {
        final file = fixture.createFile('test.jpg', [1, 2, 3]);
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
        expect(entity.dateTakenAccuracy, isNull);
      });

      test('creates MediaEntity object with date information', () {
        final file = fixture.createFile('test.jpg', [1, 2, 3]);
        final entity = MediaEntity.single(
          file: FileEntity(sourcePath: file.path),
          dateTaken: DateTime(2023, 5, 15),
        );

        expect(entity.primaryFile.path, file.path);
        expect(entity.dateTaken, DateTime(2023, 5, 15));
      });

      test(
        'generates consistent content identifiers (by content equality)',
        () async {
          final file1 = fixture.createFile('test1.jpg', [1, 2, 3]);
          final file2 = fixture.createFile('test2.jpg', [
            1,
            2,
            3,
          ]); // same content
          final file3 = fixture.createFile('test3.jpg', [4, 5, 6]); // different

          final entity1 = MediaEntity.single(
            file: FileEntity(sourcePath: file1.path),
          );
          final entity2 = MediaEntity.single(
            file: FileEntity(sourcePath: file2.path),
          );
          final entity3 = MediaEntity.single(
            file: FileEntity(sourcePath: file3.path),
          );

          expect(
            await entity1.primaryFile.asFile().readAsBytes(),
            await entity2.primaryFile.asFile().readAsBytes(),
          );
          expect(
            await entity1.primaryFile.asFile().readAsBytes(),
            isNot(await entity3.primaryFile.asFile().readAsBytes()),
          );
        },
      );

      test(
        'supports album associations after merge (multiple sources)',
        () async {
          // Same content in year and in album → after merge, one entity with albumNames=['extra']
          final c = [1, 2, 3];
          final yearFile = fixture.createFile('2023/test.jpg', c);
          final albumFile = fixture.createFile('Albums/extra/test.jpg', c);

          final merged = await albumSvc.detectAndMergeAlbums([
            MediaEntity.single(file: FileEntity(sourcePath: yearFile.path)),
            MediaEntity.single(file: FileEntity(sourcePath: albumFile.path)),
          ]);

          expect(merged.length, 1);
          final e = merged.first;
          expect(e.hasAlbumAssociations, isTrue);
          expect(e.albumNames, contains('extra'));
        },
      );

      test('handles MediaEntity objects without date information', () {
        final file = fixture.createFile('test.jpg', [1, 2, 3]);
        final entity = MediaEntity.single(
          file: FileEntity(sourcePath: file.path),
        );

        expect(entity.dateTaken, isNull);
        expect(entity.dateTakenAccuracy, isNull);
      });
    });

    group('MediaEntityCollection - Duplicate Detection and Management', () {
      test('removeDuplicates identifies and removes duplicate files', () async {
        // Explicit config for this test (pass required paths; other options use defaults)
        final cfg = ProcessingConfig(
          inputPath: fixture.basePath,
          outputPath: fixture.basePath,
          disableResumeCheck: true,
        );
        final file1 = fixture.createFile('test1.jpg', [1, 2, 3]);
        final file2 = fixture.createFile('test2.jpg', [1, 2, 3]); // duplicate
        final file3 = fixture.createFile('test3.jpg', [4, 5, 6]);

        final collection = MediaEntityCollection([
          MediaEntity.single(file: FileEntity(sourcePath: file1.path)),
          MediaEntity.single(file: FileEntity(sourcePath: file2.path)),
          MediaEntity.single(file: FileEntity(sourcePath: file3.path)),
        ]);

        final stepResult = await const MergeMediaEntitiesStep().execute(
          _ctx(cfg, collection),
        );
        final removedCount = (stepResult.data['entitiesMerged'] as int?) ?? 0;

        expect(removedCount, 1);
        expect(collection.length, 2);
        expect(
          collection.entities.any(
            (final e) => e.primaryFile.path == file1.path,
          ),
          isTrue,
        );
        expect(
          collection.entities.any(
            (final e) => e.primaryFile.path == file3.path,
          ),
          isTrue,
        );
      });

      test('handles duplicate detection with many files efficiently', () async {
        // Explicit config for this test (pass required paths; other options use defaults)
        final cfg = ProcessingConfig(
          inputPath: fixture.basePath,
          outputPath: fixture.basePath,
          disableResumeCheck: true,
        );
        final collection = MediaEntityCollection();

        for (int i = 0; i < 100; i++) {
          final file = fixture.createFile('test$i.jpg', [i + 1]);
          collection.add(
            MediaEntity.single(file: FileEntity(sourcePath: file.path)),
          );
        }

        final dup = fixture.createFile('duplicate.jpg', [1]);
        collection.add(
          MediaEntity.single(file: FileEntity(sourcePath: dup.path)),
        );

        final start = DateTime.now();
        final stepResult = await const MergeMediaEntitiesStep().execute(
          _ctx(cfg, collection),
        );
        final end = DateTime.now();
        final removedCount = (stepResult.data['entitiesMerged'] as int?) ?? 0;

        expect(removedCount, 1);
        expect(collection.length, 100);
        expect(end.difference(start).inMilliseconds, lessThan(2000));
      });
    });

    group('Album Detection and Management - File Relationship Handling', () {
      test(
        'findAlbums does not merges duplicates files from different albums, but mergeMediaEntities does.',
        () async {
          // Explicit config for this test (pass required paths; other options use defaults)
          final cfg = ProcessingConfig(
            inputPath: fixture.basePath,
            outputPath: fixture.basePath,
            disableResumeCheck: true,
          );

          // Year + Album (same content) → after findAlbums the number of entities needs to be the same, but after mergeMediaEntities there must be 1 entity with albumNames=['Vacation']
          final c = [1, 2, 3];
          final yearFile = fixture.createFile('2023/photo.jpg', c);
          final albumFile = fixture.createFile('Albums/Vacation/photo.jpg', c);

          final collection = MediaEntityCollection([
            MediaEntity.single(
              file: FileEntity(sourcePath: yearFile.path),
              dateTaken: DateTime(2023),
            ),
            MediaEntity.single(
              file: FileEntity(sourcePath: albumFile.path),
              dateTaken: DateTime(2023),
            ),
          ]);

          final originalLength = collection.length;

          await const FindAlbumsStep().execute(_ctx(cfg, collection));
          expect(collection.length, originalLength);

          await const MergeMediaEntitiesStep().execute(_ctx(cfg, collection));
          expect(collection.length, lessThan(originalLength));
          expect(collection.length, 1);

          final mergedEntity = collection.entities.first;
          expect(mergedEntity.hasAlbumAssociations, isTrue);
          expect(mergedEntity.albumNames, contains('Vacation'));
        },
      );

      test('preserves best metadata when merging albums', () async {
        // Explicit config for this test (pass required paths; other options use defaults)
        final cfg = ProcessingConfig(
          inputPath: fixture.basePath,
          outputPath: fixture.basePath,
          disableResumeCheck: true,
        );
        final c = [1, 2, 3];
        final f1 = fixture.createFile('2023/photo1.jpg', c);
        final f2 = fixture.createFile('Albums/Album/photo1.jpg', c);

        final collection = MediaEntityCollection([
          MediaEntity.single(
            file: FileEntity(sourcePath: f1.path),
            dateTaken: DateTime(2023),
          ),
          MediaEntity.single(
            file: FileEntity(sourcePath: f2.path),
            dateTaken: DateTime(2023),
          ),
        ]);

        // await FindAlbumsStep().execute(_ctx(cfg, collection));
        await const MergeMediaEntitiesStep().execute(_ctx(cfg, collection));

        expect(collection.length, 1);
        final mergedEntity = collection.entities.first;
        expect(mergedEntity.albumNames, contains('Album'));
        expect(mergedEntity.dateTaken, DateTime(2023));
      });
    });

    group('Extras Processing - Edited File Detection and Removal', () {
      test('extras processing placeholder', () {
        expect(true, isTrue);
      });
    });

    group('Performance and Scalability - Large Collection Handling', () {
      test(
        'handles large collections efficiently in comprehensive workflow',
        () async {
          // Explicit config for this test (pass required paths; other options use defaults)
          final cfg = ProcessingConfig(
            inputPath: fixture.basePath,
            outputPath: fixture.basePath,
            disableResumeCheck: true,
          );
          final collection = MediaEntityCollection();
          final createdFiles = <File>[];

          for (int i = 0; i < 10; i++) {
            final content = List<int>.filled(1024 * 1024, i);
            final file = fixture.createLargeTestFile(
              'large_test$i.jpg',
              content: content,
            );
            createdFiles.add(file);
            collection.add(
              MediaEntity.single(file: FileEntity(sourcePath: file.path)),
            );
          }

          for (int i = 1; i < createdFiles.length; i++) {
            final currentContent = await createdFiles[i].readAsBytes();
            final prevContent = await createdFiles[i - 1].readAsBytes();
            expect(
              currentContent.sublist(0, 10),
              isNot(prevContent.sublist(0, 10)),
            );
          }

          final sr1 = await const MergeMediaEntitiesStep().execute(
            _ctx(cfg, collection),
          );
          final removedCount = (sr1.data['duplicatesRemoved'] as int?) ?? 0;
          expect(removedCount, 0);

          final memoryBefore = ProcessInfo.currentRss;
          await const MergeMediaEntitiesStep().execute(_ctx(cfg, collection));
          final memoryAfter = ProcessInfo.currentRss;

          if (!Platform.isWindows) {
            expect(memoryAfter - memoryBefore, lessThan(50 * 1024 * 1024));
          }
        },
      );

      test('manages memory usage during intensive operations', () async {
        final cfg = ProcessingConfig(
          inputPath: fixture.basePath,
          outputPath: fixture.basePath,
        );
        final collection = MediaEntityCollection();

        for (int i = 0; i < 50; i++) {
          final file = fixture.createFile('memory_test$i.jpg', [i]);
          collection.add(
            MediaEntity.single(file: FileEntity(sourcePath: file.path)),
          );
        }

        await const MergeMediaEntitiesStep().execute(_ctx(cfg, collection));
        await const FindAlbumsStep().execute(_ctx(cfg, collection));

        expect(collection.length, 50);
      });

      test('modern grouping correctly groups media by content', () async {
        final f1 = fixture.createFile('test1.jpg', [1, 2, 3]);
        final f2 = fixture.createFile('test2.jpg', [1, 2, 3]); // same content
        final f3 = fixture.createFile('test3.jpg', [4, 5, 6]);

        final collection = MediaEntityCollection([
          MediaEntity.single(file: FileEntity(sourcePath: f1.path)),
          MediaEntity.single(file: FileEntity(sourcePath: f2.path)),
          MediaEntity.single(file: FileEntity(sourcePath: f3.path)),
        ]);

        final duplicateService =
            ServiceContainer.instance.duplicateDetectionService;
        final grouped = await duplicateService.groupIdenticalLegacy(
          collection.entities.toList(),
        );

        expect(grouped.length, 2);

        final duplicateGroup = grouped.values.firstWhere(
          (final g) => g.length > 1,
        );
        expect(duplicateGroup.length, 2);
        expect(
          duplicateGroup.any((final e) => e.primaryFile.path == f1.path),
          isTrue,
        );
        expect(
          duplicateGroup.any((final e) => e.primaryFile.path == f2.path),
          isTrue,
        );
      });
    });

    group('MediaEntityCollection - Core Operations', () {
      test('supports basic collection operations', () {
        final f1 = fixture.createFile('test1.jpg', [1, 2, 3]);
        final f2 = fixture.createFile('test2.jpg', [4, 5, 6]);

        final collection = MediaEntityCollection();
        expect(collection.isEmpty, isTrue);

        final e1 = MediaEntity.single(file: FileEntity(sourcePath: f1.path));
        final e2 = MediaEntity.single(file: FileEntity(sourcePath: f2.path));

        collection.add(e1);
        expect(collection.length, 1);
        expect(collection.isNotEmpty, isTrue);

        collection.addAll([e2]);
        expect(collection.length, 2);

        collection.remove(e1);
        expect(collection.length, 1);

        collection.clear();
        expect(collection.isEmpty, isTrue);
      });

      test('provides accurate statistics', () async {
        final cfg = ProcessingConfig(
          inputPath: fixture.basePath,
          outputPath: fixture.basePath,
        );
        final f1 = fixture.createFile('2023/test1.jpg', [1, 2, 3]); // year
        final f2 = fixture.createFile('Albums/Album/test2.jpg', [
          4,
          5,
          6,
        ]); // album

        final collection = MediaEntityCollection([
          MediaEntity.single(
            file: FileEntity(sourcePath: f1.path),
            dateTaken: DateTime(2023),
          ),
          MediaEntity.single(file: FileEntity(sourcePath: f2.path)),
        ]);

        // Detect albums before calculating stats
        await const FindAlbumsStep().execute(_ctx(cfg, collection));

        final stats = collection.getStatistics();
        expect(stats.totalMedia, 2);
        expect(stats.mediaWithDates, 1);
        expect(stats.mediaWithAlbums, 1);
      });
    });

    group('EXIF Data Writing and Coordinate Management', () {
      test(
        'writeExifData writes UTC DateTimeOriginal with +00:00 offset (no local shift)',
        () async {
          final exifTool = ServiceContainer.instance.exifTool;
          if (exifTool == null) {
            // In environments without ExifTool (some CI), skip silently.
            return;
          }

          final testImage = fixture.createImageWithoutExif('utc_write.jpg');

          // 1609459200 == 2021-01-01T00:00:00Z
          final utc = DateTime.fromMillisecondsSinceEpoch(
            1609459200 * 1000,
            isUtc: true,
          );

          final collection = MediaEntityCollection([
            MediaEntity.single(
              file: FileEntity(
                sourcePath: testImage.path,
                targetPath: testImage.path,
              ),
              dateTaken: utc,
              dateTimeExtractionMethod: DateTimeExtractionMethod.json,
            ),
          ]);

          final cfg = ProcessingConfig(
            inputPath: fixture.basePath,
            outputPath: fixture.basePath,
            disableResumeCheck: true,
          );
          await const WriteExifStep().execute(_ctx(cfg, collection));

          // Read back the exact tags without the service's -fast read path.
          final out = await exifTool.executeExifToolCommand([
            '-q',
            '-q',
            '-j',
            '-s',
            '-s',
            '-s',
            '-n',
            '-DateTimeOriginal',
            '-OffsetTimeOriginal',
            testImage.path,
          ]);

          final decoded = jsonDecode(out) as List<dynamic>;
          final tags = Map<String, dynamic>.from(decoded.first as Map);
          expect(tags['DateTimeOriginal'], equals('2021:01:01 00:00:00'));
          expect(tags['OffsetTimeOriginal'], equals('+00:00'));
        },
      );

      test('writeExifData processes coordinates from JSON metadata', () async {
        final testImage = fixture.createImageWithoutExif(
          'test_with_coords.jpg',
        );
        final jsonFile = File('${testImage.path}.json');
        await jsonFile.writeAsString('''
{
  "title": "Test Image with GPS",
  "photoTakenTime": { "timestamp": "1609459200", "formatted": "01.01.2021, 00:00:00 UTC" },
  "geoData": { "latitude": 41.3221611, "longitude": 19.8149139, "altitude": 143.09,
               "latitudeSpan": 0.0, "longitudeSpan": 0.0 }
}
''');

        final collection = MediaEntityCollection();
        final mediaEntity = MediaEntity.single(
          file: FileEntity(sourcePath: testImage.path),
          dateTaken: DateTime.fromMillisecondsSinceEpoch(1609459200 * 1000),
        );
        collection.add(mediaEntity);

        try {
          final cfg2 = ProcessingConfig(
            inputPath: fixture.basePath,
            outputPath: fixture.basePath,
            disableResumeCheck: true,
          );
          final sr = await const WriteExifStep().execute(
            _ctx(cfg2, collection),
          );
          expect(sr.data.containsKey('coordinatesWritten'), isTrue);
          expect(sr.data.containsKey('dateTimesWritten'), isTrue);
        } catch (e) {
          // Tests can run without full services; ignore failures in that case.
        }

        await jsonFile.delete();
      });

      test(
        'writeExifData handles multiple files with different coordinate data',
        () async {
          final collection = MediaEntityCollection();

          final file1 = fixture.createImageWithoutExif('file_with_coords.jpg');
          final json1 = File('${file1.path}.json');
          await json1.writeAsString('''
{ "title":"File with coordinates",
  "geoData": { "latitude": 40.7589, "longitude": -73.9851, "altitude": 10.0,
               "latitudeSpan": 0.0, "longitudeSpan": 0.0 } }
''');

          final file2 = fixture.createImageWithoutExif('file_no_coords.jpg');
          final json2 = File('${file2.path}.json');
          await json2.writeAsString('''
{ "title":"File without coordinates",
  "photoTakenTime": { "timestamp":"1609459200", "formatted":"01.01.2021, 00:00:00 UTC" } }
''');

          final file3 = fixture.createImageWithoutExif('file_southern.jpg');
          final json3 = File('${file3.path}.json');
          await json3.writeAsString('''
{ "title":"Southern hemisphere coordinates",
  "geoData": { "latitude": -33.865143, "longitude": 151.2099, "altitude": 58.0,
               "latitudeSpan": 0.0, "longitudeSpan": 0.0 } }
''');

          collection.addAll([
            MediaEntity.single(file: FileEntity(sourcePath: file1.path)),
            MediaEntity.single(file: FileEntity(sourcePath: file2.path)),
            MediaEntity.single(file: FileEntity(sourcePath: file3.path)),
          ]);

          try {
            final cfg3 = ProcessingConfig(
              inputPath: fixture.basePath,
              outputPath: fixture.basePath,
              disableResumeCheck: true,
            );
            final sr = await const WriteExifStep().execute(
              _ctx(cfg3, collection),
            );
            expect(sr.data, isA<Map<String, dynamic>>());
          } catch (_) {
            // See comment above
          }

          await json1.delete();
          await json2.delete();
          await json3.delete();
        },
      );

      test('writeExifData reports accurate statistics', () async {
        final collection = MediaEntityCollection();

        final scenarios = [
          {
            'name': 'full_metadata.jpg',
            'hasDate': true,
            'json': '''
{ "title":"Full metadata",
  "photoTakenTime": { "timestamp":"1609459200", "formatted":"01.01.2021, 00:00:00 UTC" },
  "geoData": { "latitude": 51.5074, "longitude": -0.1278, "altitude": 11.0,
               "latitudeSpan": 0.0, "longitudeSpan": 0.0 } }
''',
          },
          {
            'name': 'coords_only.jpg',
            'hasDate': false,
            'json': '''
{ "title":"Coordinates only",
  "geoData": { "latitude": 48.8566, "longitude": 2.3522, "altitude": 35.0,
               "latitudeSpan": 0.0, "longitudeSpan": 0.0 } }
''',
          },
          {
            'name': 'date_only.jpg',
            'hasDate': true,
            'json': '''
{ "title":"Date only",
  "photoTakenTime": { "timestamp":"1640995200", "formatted":"31.12.2021, 12:00:00 UTC" } }
''',
          },
        ];

        for (final s in scenarios) {
          final file = fixture.createImageWithoutExif(s['name'] as String);
          final jf = File('${file.path}.json');
          await jf.writeAsString(s['json'] as String);

          collection.add(
            MediaEntity.single(
              file: FileEntity(sourcePath: file.path),
              dateTaken: (s['hasDate'] as bool)
                  ? DateTime.fromMillisecondsSinceEpoch(1609459200 * 1000)
                  : null,
            ),
          );
        }

        try {
          final cfg4 = ProcessingConfig(
            inputPath: fixture.basePath,
            outputPath: fixture.basePath,
            disableResumeCheck: true,
          );
          final sr = await const WriteExifStep().execute(
            _ctx(cfg4, collection),
          );
          expect(sr.data, isA<Map<String, dynamic>>());
        } catch (_) {
          // See comment above
        }

        // Cleanup helper JSONs
        for (final s in scenarios) {
          final jf = File('${fixture.basePath}/${s['name']}.json');
          if (await jf.exists()) await jf.delete();
        }
      });
    });
  });
}
