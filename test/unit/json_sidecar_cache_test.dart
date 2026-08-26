/// Tests for the JSON sidecar path + content caching (Change C).
///
/// Verifies that:
/// - Step 2 caches the resolved sidecar path and isOwnSidecar flag on FileEntity
/// - Step 4 reuses the cached path, skipping the expensive findJsonForFileWithConfidence lookup
/// - The isOwnSidecar confidence flag is respected from the cache (issue #139 guard)
/// - The JSON content cache avoids redundant file reads
/// - Fallback to full lookup works when no cached path is available
library;

import 'dart:convert';
import 'dart:io';

import 'package:gpth_neo/gpth_lib_exports.dart';
import 'package:path/path.dart' as path;
import 'package:test/test.dart';

import '../setup/test_setup.dart';

void main() {
  group('JSON sidecar caching (Change C)', () {
    late TestFixture fixture;

    setUp(() async {
      fixture = TestFixture();
      await fixture.setUp();
      // Clear the JSON content cache between tests to avoid cross-contamination
      JsonMetadataMatcherService.clearJsonContentCache();
    });

    tearDown(() async {
      await fixture.tearDown();
    });

    /// Writes a sidecar JSON with a distinct, recognizable GPS coordinate and
    /// timestamp so that a mismatch is unambiguous in assertions.
    File writeSidecar(
      final String name, {
      required final double lat,
      required final double lon,
      required final String photoTakenTimestamp,
    }) {
      final file = File(path.join(fixture.basePath, name));
      final json = jsonEncode({
        'title': name,
        'photoTakenTime': {
          'timestamp': photoTakenTimestamp,
          'formatted': 'test',
        },
        'geoData': {
          'latitude': lat,
          'longitude': lon,
          'altitude': 0.0,
          'latitudeSpan': 0.0,
          'longitudeSpan': 0.0,
        },
        'geoDataExif': {
          'latitude': lat,
          'longitude': lon,
          'altitude': 0.0,
          'latitudeSpan': 0.0,
          'longitudeSpan': 0.0,
        },
      });
      file.writeAsStringSync(json, flush: true);
      return file;
    }

    group('FileEntity jsonSidecarPath / jsonIsOwnSidecar fields', () {
      test('fields are null by default', () {
        final entity = FileEntity(sourcePath: '/some/path.jpg');
        expect(entity.jsonSidecarPath, isNull);
        expect(entity.jsonIsOwnSidecar, isNull);
      });

      test('fields can be set and read back', () {
        final entity = FileEntity(sourcePath: '/some/path.jpg');
        entity.jsonSidecarPath = '/some/path.jpg.supplemental-metadata.json';
        entity.jsonIsOwnSidecar = true;
        expect(
          entity.jsonSidecarPath,
          equals('/some/path.jpg.supplemental-metadata.json'),
        );
        expect(entity.jsonIsOwnSidecar, isTrue);
      });

      test('fields survive JSON round-trip', () {
        final entity = FileEntity(sourcePath: '/some/path.jpg');
        entity.jsonSidecarPath = '/some/path.jpg.supplemental-metadata.json';
        entity.jsonIsOwnSidecar = true;

        final json = entity.toJson();
        final restored = FileEntity.fromJson(json);

        expect(
          restored.jsonSidecarPath,
          equals('/some/path.jpg.supplemental-metadata.json'),
        );
        expect(restored.jsonIsOwnSidecar, isTrue);
      });

      test('fields survive JSON round-trip when null', () {
        final entity = FileEntity(sourcePath: '/some/path.jpg');

        final json = entity.toJson();
        final restored = FileEntity.fromJson(json);

        expect(restored.jsonSidecarPath, isNull);
        expect(restored.jsonIsOwnSidecar, isNull);
      });
    });

    group('extractAllFromJsonCached', () {
      test(
        'uses cached sidecar path and returns date+GPS for own sidecar',
        () async {
          final media = fixture.createImageWithExif('photo.jpg');
          final sidecar = writeSidecar(
            'photo.jpg.supplemental-metadata.json',
            lat: 41.0,
            lon: 19.0,
            photoTakenTimestamp: '1700000000',
          );

          final entity = FileEntity(sourcePath: media.path);
          entity.jsonSidecarPath = sidecar.path;
          entity.jsonIsOwnSidecar = true;

          final result = await extractAllFromJsonCached(entity);

          expect(result.date, isNotNull);
          expect(
            result.date,
            equals(
              DateTime.fromMillisecondsSinceEpoch(
                1700000000 * 1000,
                isUtc: true,
              ),
            ),
          );
          expect(result.gps, isNotNull);
          expect(result.gps!.toDD().latitude, closeTo(41.0, 0.001));
          expect(result.gps!.toDD().longitude, closeTo(19.0, 0.001));
        },
      );

      test(
        'drops date+GPS when cached isOwnSidecar is false (issue #139)',
        () async {
          // The edited photo has no own sidecar; the original's sidecar was
          // cached as a heuristic match (isOwnSidecar=false).
          fixture.createImageWithExif('photo.jpg');
          final edited = fixture.createImageWithExif('photo-edited.jpg');
          final originalSidecar = writeSidecar(
            'photo.jpg.supplemental-metadata.json',
            lat: 41.0,
            lon: 19.0,
            photoTakenTimestamp: '1700000000',
          );

          final entity = FileEntity(sourcePath: edited.path);
          entity.jsonSidecarPath = originalSidecar.path;
          entity.jsonIsOwnSidecar = false;

          final result = await extractAllFromJsonCached(entity);

          expect(
            result.date,
            isNull,
            reason: 'edited photo must not inherit original\'s DateTime',
          );
          expect(
            result.gps,
            isNull,
            reason: 'edited photo must not inherit original\'s GPS',
          );
        },
      );

      test(
        'falls back to full lookup when no cached path is available',
        () async {
          final media = fixture.createImageWithExif('photo.jpg');
          writeSidecar(
            'photo.jpg.supplemental-metadata.json',
            lat: 41.0,
            lon: 19.0,
            photoTakenTimestamp: '1700000000',
          );

          // No cached path — should fall back to findJsonForFileWithConfidence
          final entity = FileEntity(sourcePath: media.path);

          final result = await extractAllFromJsonCached(entity);

          expect(result.date, isNotNull);
          expect(result.gps, isNotNull);
        },
      );

      test(
        'falls back to full lookup for secondary files without cached path',
        () async {
          // Secondary files are not processed during Step 2 discovery, so they
          // won't have a cached sidecar path. The fallback must still work.
          final media = fixture.createImageWithExif('photo.jpg');
          writeSidecar(
            'photo.jpg.supplemental-metadata.json',
            lat: 41.0,
            lon: 19.0,
            photoTakenTimestamp: '1700000000',
          );

          final entity = FileEntity(sourcePath: media.path);
          // Explicitly do NOT set jsonSidecarPath — simulates a secondary file

          final result = await extractAllFromJsonCached(entity);

          expect(result.date, isNotNull);
          expect(result.gps, isNotNull);
        },
      );

      test(
        'returns null date+GPS when cached sidecar file no longer exists',
        () async {
          final media = fixture.createImageWithExif('photo.jpg');
          final sidecar = writeSidecar(
            'photo.jpg.supplemental-metadata.json',
            lat: 41.0,
            lon: 19.0,
            photoTakenTimestamp: '1700000000',
          );

          final entity = FileEntity(sourcePath: media.path);
          entity.jsonSidecarPath = sidecar.path;
          entity.jsonIsOwnSidecar = true;

          // Delete the sidecar after caching the path
          await sidecar.delete();

          final result = await extractAllFromJsonCached(entity);

          expect(result.date, isNull);
          expect(result.gps, isNull);
        },
      );
    });

    group('JsonMetadataMatcherService.readJsonContentCached', () {
      test('returns parsed JSON content', () async {
        final sidecar = writeSidecar(
          'photo.jpg.supplemental-metadata.json',
          lat: 41.0,
          lon: 19.0,
          photoTakenTimestamp: '1700000000',
        );

        final data = await JsonMetadataMatcherService.readJsonContentCached(
          sidecar,
        );

        expect(data, isNotNull);
        expect(data!['title'], equals('photo.jpg.supplemental-metadata.json'));
        expect(data['photoTakenTime']['timestamp'], equals('1700000000'));
      });

      test('returns null for non-existent file', () async {
        final data = await JsonMetadataMatcherService.readJsonContentCached(
          File(path.join(fixture.basePath, 'nonexistent.json')),
        );

        expect(data, isNull);
      });

      test('returns null for invalid JSON', () async {
        final badFile = File(path.join(fixture.basePath, 'bad.json'));
        badFile.writeAsStringSync('not valid json', flush: true);

        final data = await JsonMetadataMatcherService.readJsonContentCached(
          badFile,
        );

        expect(data, isNull);
      });

      test('caches content across multiple reads', () async {
        final sidecar = writeSidecar(
          'photo.jpg.supplemental-metadata.json',
          lat: 41.0,
          lon: 19.0,
          photoTakenTimestamp: '1700000000',
        );

        // First read populates the cache
        final data1 = await JsonMetadataMatcherService.readJsonContentCached(
          sidecar,
        );
        expect(data1, isNotNull);

        // Delete the file — second read should still return cached content
        await sidecar.delete();
        final data2 = await JsonMetadataMatcherService.readJsonContentCached(
          sidecar,
        );
        expect(data2, isNotNull);
        expect(data2, equals(data1));
      });
    });

    group('Step 2 → Step 4 integration', () {
      test(
        'Step 2 caches sidecar path; Step 4 reuses it without re-resolving',
        () async {
          // Create a year folder with a photo and its sidecar
          final yearDir = Directory(
            path.join(fixture.basePath, 'Photos from 2023'),
          );
          await yearDir.create(recursive: true);

          final media = File(path.join(yearDir.path, 'photo.jpg'));
          await media.writeAsBytes([0xFF, 0xD8, 0xFF, 0xE0]); // JPEG header

          final sidecar = File(
            path.join(yearDir.path, 'photo.jpg.supplemental-metadata.json'),
          );
          sidecar.writeAsStringSync(
            jsonEncode({
              'title': 'photo.jpg',
              'photoTakenTime': {
                'timestamp': '1700000000',
                'formatted': 'test',
              },
              'geoData': {
                'latitude': 41.0,
                'longitude': 19.0,
                'altitude': 0.0,
                'latitudeSpan': 0.0,
                'longitudeSpan': 0.0,
              },
            }),
            flush: true,
          );

          // Run Step 2 discovery
          final config = ProcessingConfig(
            inputPath: fixture.basePath,
            outputPath: path.join(fixture.basePath, 'output'),
          );
          final context = ProcessingContext(
            config: config,
            mediaCollection: MediaEntityCollection(),
            inputDirectory: Directory(fixture.basePath),
            outputDirectory: Directory(path.join(fixture.basePath, 'output')),
          );

          final result = await const DiscoverMediaService().discover(context);

          expect(result.yearFolderFiles, equals(1));
          expect(context.mediaCollection.length, equals(1));

          // Verify the sidecar path was cached on the FileEntity
          final entity = context.mediaCollection[0];
          expect(entity.primaryFile.jsonSidecarPath, isNotNull);
          expect(entity.primaryFile.jsonIsOwnSidecar, isTrue);

          // Verify Step 4 can use the cached path
          final dateResult = await extractAllFromJsonCached(entity.primaryFile);
          expect(dateResult.date, isNotNull);
          expect(
            dateResult.date,
            equals(
              DateTime.fromMillisecondsSinceEpoch(
                1700000000 * 1000,
                isUtc: true,
              ),
            ),
          );
          expect(dateResult.gps, isNotNull);
        },
      );

      test(
        'Step 2 caches isOwnSidecar=false for cross-extension matches; Step 4 drops date+GPS',
        () async {
          // Create a year folder with an MP4 video and a HEIC photo's sidecar
          final yearDir = Directory(
            path.join(fixture.basePath, 'Photos from 2023'),
          );
          await yearDir.create(recursive: true);

          final video = File(path.join(yearDir.path, 'IMG_2367.MP4'));
          await video.writeAsBytes([0x00, 0x00, 0x00, 0x20]); // MP4 header

          // Only the HEIC has a sidecar — the MP4 has none
          final heicSidecar = File(
            path.join(yearDir.path, 'IMG_2367.HEIC.supplemental-metadata.json'),
          );
          heicSidecar.writeAsStringSync(
            jsonEncode({
              'title': 'IMG_2367.HEIC',
              'photoTakenTime': {
                'timestamp': '1700000000',
                'formatted': 'test',
              },
              'geoData': {
                'latitude': 48.0,
                'longitude': 2.0,
                'altitude': 0.0,
                'latitudeSpan': 0.0,
                'longitudeSpan': 0.0,
              },
            }),
            flush: true,
          );

          // Run Step 2 discovery
          final config = ProcessingConfig(
            inputPath: fixture.basePath,
            outputPath: path.join(fixture.basePath, 'output'),
          );
          final context = ProcessingContext(
            config: config,
            mediaCollection: MediaEntityCollection(),
            inputDirectory: Directory(fixture.basePath),
            outputDirectory: Directory(path.join(fixture.basePath, 'output')),
          );

          final result = await const DiscoverMediaService().discover(context);

          expect(result.yearFolderFiles, equals(1));
          expect(context.mediaCollection.length, equals(1));

          // Verify the sidecar path was cached with isOwnSidecar=false
          final entity = context.mediaCollection[0];
          expect(entity.primaryFile.jsonSidecarPath, isNotNull);
          expect(entity.primaryFile.jsonIsOwnSidecar, isFalse);

          // Verify Step 4 drops date+GPS from the cross-photo sidecar
          final dateResult = await extractAllFromJsonCached(entity.primaryFile);
          expect(
            dateResult.date,
            isNull,
            reason: 'video must not inherit HEIC photo\'s DateTime',
          );
          expect(
            dateResult.gps,
            isNull,
            reason: 'video must not inherit HEIC photo\'s GPS',
          );
        },
      );
    });
  });
}
