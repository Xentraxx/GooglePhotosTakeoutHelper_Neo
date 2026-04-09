/// # Date Extractors Test Suite
///
/// Comprehensive tests for date extraction functionality that recovers timestamp
/// information from various sources in Google Photos Takeout exports, ensuring
/// accurate chronological organization of media files.
library;

import 'dart:io';

import 'package:coordinate_converter/coordinate_converter.dart';
import 'package:gpth_neo/gpth_lib_exports.dart';
import 'package:test/test.dart';

import '../setup/test_setup.dart';

void main() {
  late ExifToolService exifTool;

  setUpAll(() async {
    exifTool = (await ExifToolService.find())!;
    await exifTool.startPersistentProcess();
    ServiceContainer.instance.exifTool = exifTool;
  });

  tearDownAll(() async {
    await exifTool.dispose();
  });

  group('Date Extractors', () {
    late TestFixture fixture;
    late GlobalConfigService globalConfig;

    setUp(() async {
      fixture = TestFixture();
      await fixture.setUp();
      globalConfig = GlobalConfigService();
    });

    tearDown(() async {
      await fixture.tearDown();
    });

    group('JSON Date Extractor', () {
      test('extracts date from valid JSON metadata', () async {
        final jsonFile = fixture.createJsonFile(
          'test.json',
          photoTakenTimestamp: '1640960007',
        );
        final result = await jsonDateTimeExtractor(jsonFile);

        // Expect strict UTC (jsonDateTimeExtractor returns isUtc DateTime)
        expect(result, DateTime.parse('2021-12-31 14:13:27.000Z'));
      });

      test('returns null for invalid JSON', () async {
        final jsonFile = fixture.createFile('invalid.json', [1, 2, 3]);

        final result = await jsonDateTimeExtractor(jsonFile);

        expect(result, isNull);
      });

      test('returns null for missing timestamp', () async {
        final jsonFile = fixture.createJsonFile('test.json');

        final result = await jsonDateTimeExtractor(jsonFile);

        expect(result, isNull);
      });
    });

    group('EXIF Date Extractor', () {
      test('extracts date from EXIF data', () async {
        final imgFile = fixture.createImageWithExif('test.jpg');

        final result = await ExifDateExtractor(
          ServiceContainer.instance.exifTool!,
        ).exifDateTimeExtractor(imgFile, globalConfig: globalConfig);

        expect(result, DateTime.parse('2022-12-16 16:06:47'));
      });

      test('returns null for image without EXIF data', () async {
        final imgFile = fixture.createImageWithoutExif('test.jpg');

        final result = await ExifDateExtractor(
          ServiceContainer.instance.exifTool!,
        ).exifDateTimeExtractor(imgFile, globalConfig: globalConfig);

        expect(result, isNull);
      });

      test('returns null for non-image files', () async {
        final txtFile = fixture.createFile('test.txt', [1, 2, 3]);

        final result = await ExifDateExtractor(
          ServiceContainer.instance.exifTool!,
        ).exifDateTimeExtractor(txtFile, globalConfig: globalConfig);

        expect(result, isNull);
      });
    });
    group('Guess Date Extractor', () {
      group('IMG filename patterns', () {
        test('extracts date from IMG_20220101_123456.jpg', () async {
          final file = File('${fixture.basePath}/IMG_20220101_123456.jpg');

          final result = await guessExtractor(file);

          expect(result, isNotNull);
          expect(result!.year, 2022);
        });

        test('extracts date from IMG_20220131_235959.png', () async {
          final file = File('${fixture.basePath}/IMG_20220131_235959.png');

          final result = await guessExtractor(file);

          expect(result, isNotNull);
          expect(result!.year, 2022);
        });

        test(
          'extracts date from IMG_20200229_000000.gif (leap year)',
          () async {
            final file = File('${fixture.basePath}/IMG_20200229_000000.gif');

            final result = await guessExtractor(file);

            expect(result, isNotNull);
            expect(result!.year, 2020);
          },
        );
      });
      test('returns null for unrecognizable filename patterns', () async {
        final file = File('${fixture.basePath}/random_name.jpg');

        final result = await guessExtractor(file);

        expect(result, isNull);
      });
    });

    group('Folder Year Extractor', () {
      test('extracts year from "Photos from YYYY" pattern', () async {
        // Create nested directory structure
        final photoDir = fixture.createDirectory(
          'Takeout/Google Photos/Photos from 2005',
        );
        final file = File('${photoDir.path}/test_image.jpg');
        await file.create();

        final result = await folderYearExtractor(file);

        expect(result, isNotNull);
        expect(result!.year, equals(2005));
        expect(result.month, equals(1));
        expect(result.day, equals(1));
      });

      test('extracts year from "YYYY Photos" pattern', () async {
        final photoDir = fixture.createDirectory('Takeout/2020 Photos');
        final file = File('${photoDir.path}/test_image.jpg');
        await file.create();

        final result = await folderYearExtractor(file);

        expect(result, isNotNull);
        expect(result!.year, equals(2020));
      });

      test('extracts year from standalone "YYYY" pattern', () async {
        final photoDir = fixture.createDirectory('Takeout/2015');
        final file = File('${photoDir.path}/test_image.jpg');
        await file.create();

        final result = await folderYearExtractor(file);

        expect(result, isNotNull);
        expect(result!.year, equals(2015));
      });

      test('extracts year from "YYYY-MM" pattern', () async {
        final photoDir = fixture.createDirectory('Takeout/2018-07');
        final file = File('${photoDir.path}/test_image.jpg');
        await file.create();

        final result = await folderYearExtractor(file);

        expect(result, isNotNull);
        expect(result!.year, equals(2018));
      });

      test('case insensitive matching for "photos from" pattern', () async {
        final photoDir = fixture.createDirectory('Takeout/PHOTOS FROM 2010');
        final file = File('${photoDir.path}/test_image.jpg');
        await file.create();

        final result = await folderYearExtractor(file);

        expect(result, isNotNull);
        expect(result!.year, equals(2010));
      });

      test('returns null for unrecognized folder patterns', () async {
        final photoDir = fixture.createDirectory('Takeout/Random Folder Name');
        final file = File('${photoDir.path}/test_image.jpg');
        await file.create();

        final result = await folderYearExtractor(file);

        expect(result, isNull);
      });

      test('returns null for invalid years', () async {
        final photoDir = fixture.createDirectory('Takeout/Photos from 1800');
        final file = File('${photoDir.path}/test_image.jpg');
        await file.create();

        final result = await folderYearExtractor(file);

        expect(result, isNull);
      });

      test('returns null for future years beyond threshold', () async {
        final futureYear = DateTime.now().year + 5;
        final photoDir = fixture.createDirectory(
          'Takeout/Photos from $futureYear',
        );
        final file = File('${photoDir.path}/test_image.jpg');
        await file.create();

        final result = await folderYearExtractor(file);

        expect(result, isNull);
      });

      test('handles file system errors gracefully', () async {
        // Create a file with problematic path
        final file = File('${fixture.basePath}/nonexistent/folder/test.jpg');

        final result = await folderYearExtractor(file);

        expect(result, isNull);
      });
    });

    group('JSON Coordinate Extractor', () {
      test('extracts coordinates from JSON with geoData', () async {
        final imageFile = fixture.createImageWithoutExif(
          'test_with_coords.jpg',
        );
        final jsonFile = File('${imageFile.path}.json');
        await jsonFile.writeAsString('''
{
  "title": "Test Image",
  "photoTakenTime": {
    "timestamp": "1609459200",
    "formatted": "01.01.2021, 00:00:00 UTC"
  },
  "geoData": {
    "latitude": 41.3221611,
    "longitude": 19.8149139,
    "altitude": 143.09,
    "latitudeSpan": 0.0,
    "longitudeSpan": 0.0
  }
}
''');

        final coordinates = await jsonCoordinatesExtractor(imageFile);

        expect(coordinates, isNotNull);
        expect(coordinates!.toDD().latitude, closeTo(41.3221611, 0.0001));
        expect(coordinates.toDD().longitude, closeTo(19.8149139, 0.0001));
        expect(coordinates.latDirection, DirectionY.north);
        expect(coordinates.longDirection, DirectionX.east);

        await jsonFile.delete();
      });

      test(
        'extracts negative coordinates (Southern/Western hemispheres)',
        () async {
          final imageFile = fixture.createImageWithoutExif(
            'test_negative_coords.jpg',
          );
          final jsonFile = File('${imageFile.path}.json');
          await jsonFile.writeAsString('''
{
  "title": "Southern Hemisphere Test",
  "photoTakenTime": {
    "timestamp": "1609459200",
    "formatted": "01.01.2021, 00:00:00 UTC"
  },
  "geoData": {
    "latitude": -33.865143,
    "longitude": -70.657437,
    "altitude": 545.0,
    "latitudeSpan": 0.0,
    "longitudeSpan": 0.0
  }
}
''');

          final coordinates = await jsonCoordinatesExtractor(imageFile);

          expect(coordinates, isNotNull);
          expect(coordinates!.toDD().latitude, closeTo(-33.865143, 0.0001));
          expect(coordinates.toDD().longitude, closeTo(-70.657437, 0.0001));
          expect(coordinates.latDirection, DirectionY.south);
          expect(coordinates.longDirection, DirectionX.west);

          await jsonFile.delete();
        },
      );

      test('returns null when geoData is missing', () async {
        final imageFile = fixture.createImageWithoutExif('test_no_coords.jpg');
        final jsonFile = File('${imageFile.path}.json');
        await jsonFile.writeAsString('''
{
  "title": "No Coordinates Test",
  "photoTakenTime": {
    "timestamp": "1609459200",
    "formatted": "01.01.2021, 00:00:00 UTC"
  }
}
''');

        final coordinates = await jsonCoordinatesExtractor(imageFile);

        expect(coordinates, isNull);

        await jsonFile.delete();
      });

      test(
        'returns null when coordinates are zero (invalid location)',
        () async {
          final imageFile = fixture.createImageWithoutExif(
            'test_zero_coords.jpg',
          );
          final jsonFile = File('${imageFile.path}.json');
          await jsonFile.writeAsString('''
{
  "title": "Zero Coordinates Test",
  "geoData": {
    "latitude": 0.0,
    "longitude": 0.0,
    "altitude": 0.0,
    "latitudeSpan": 0.0,
    "longitudeSpan": 0.0
  }
}
''');

          final coordinates = await jsonCoordinatesExtractor(imageFile);

          expect(coordinates, isNull);

          await jsonFile.delete();
        },
      );

      test('handles JSON file not found gracefully', () async {
        final imageFile = fixture.createImageWithoutExif('test_no_json.jpg');
        // No JSON file created

        final coordinates = await jsonCoordinatesExtractor(imageFile);

        expect(coordinates, isNull);
      });

      test('handles malformed JSON gracefully', () async {
        final imageFile = fixture.createImageWithoutExif('test_bad_json.jpg');
        final jsonFile = File('${imageFile.path}.json');
        await jsonFile.writeAsString('{ invalid json content }');

        final coordinates = await jsonCoordinatesExtractor(imageFile);

        expect(coordinates, isNull);

        await jsonFile.delete();
      });
    });

    group('RAW EXIF Date Extractor (cached samples)', () {
      // Use locally cached RAW samples (placed in test/raw_samples). If missing, skip.
      final cacheDir = Directory('test/raw_samples');
      if (!cacheDir.existsSync()) {
        print('RAW cache directory missing, skipping RAW EXIF tests');
      } else {
        final samples = cacheDir
            .listSync()
            .whereType<File>()
            .where(
              (final f) =>
                  f.path.toLowerCase().endsWith('.cr2') ||
                  f.path.toLowerCase().endsWith('.nef') ||
                  f.path.toLowerCase().endsWith('.dng'),
            )
            .take(3) // keep short
            .toList();
        for (final file in samples) {
          test(
            'extracts date (if present) from cached RAW ${file.path}',
            () async {
              final cfg = GlobalConfigService()..exifToolInstalled = true;
              final localCopy = fixture.createFile(
                file.uri.pathSegments.last,
                await file.readAsBytes(),
              );
              final extractor = ExifDateExtractor(
                ServiceContainer.instance.exifTool!,
              );
              final dt = await extractor.exifDateTimeExtractor(
                localCopy,
                globalConfig: cfg,
              );
              expect(dt is DateTime || dt == null, isTrue);
            },
            timeout: const Timeout(Duration(minutes: 1)),
          );
        }
        if (samples.isEmpty) {
          print('No cached RAW samples found for EXIF tests');
        }
      }
    });
  });
}
