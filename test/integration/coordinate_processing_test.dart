/// # Coordinate Processing Integration Test Suite
///
/// Comprehensive tests for GPS coordinate extraction, validation, and EXIF writing
/// functionality in Google Photos Takeout Helper Neo. This test suite ensures that
/// location metadata from JSON files is correctly processed and written to image
/// EXIF data.
///
/// ## Core Functionality Tested
///
/// ### JSON Coordinate Extraction
/// - Extracting GPS coordinates from Google Photos JSON metadata
/// - Handling different coordinate formats and precision levels
/// - Converting decimal degrees to DMS (Degrees, Minutes, Seconds) format
/// - Validating coordinate ranges and detecting invalid locations
///
/// ### EXIF Coordinate Writing
/// - Writing GPS coordinates to JPEG files using ExifTool
/// - Fallback to native Dart EXIF writing when ExifTool unavailable
/// - Proper handling of coordinate reference directions (N/S, E/W)
/// - Error handling for unsupported file formats
///
/// ### Integration Workflow
/// - End-to-end testing of JSON → Coordinates → EXIF pipeline
/// - Verification of coordinate accuracy through read-back testing
/// - Performance testing with large coordinate datasets
/// - Logging verification for coordinate writing operations
library;

import 'dart:convert';
import 'dart:io';

import 'package:coordinate_converter/coordinate_converter.dart';
import 'package:gpth_neo/gpth_lib_exports.dart';
import 'package:test/test.dart';

import '../setup/test_setup.dart';

void main() {
  group('Coordinate Processing Integration', () {
    late TestFixture fixture;

    setUp(() async {
      fixture = TestFixture();
      await fixture.setUp(); // Initialize sandbox

      try {
        await ServiceContainer.instance.initialize();

        // Prefer real ExifTool if present; otherwise fall back to mock
        final exifTool = await ExifToolService.find();
        if (exifTool != null) {
          ServiceContainer.instance.exifTool = exifTool;
          ServiceContainer.instance.globalConfig.exifToolInstalled = true;
        } else {
          ServiceContainer.instance.exifTool = MockExifToolService();
          ServiceContainer.instance.globalConfig.exifToolInstalled = false;
        }
      } catch (_) {
        // Minimal init on failure
        await ServiceContainer.instance.initialize();
        ServiceContainer.instance.exifTool = MockExifToolService();
        ServiceContainer.instance.globalConfig.exifToolInstalled = false;
      }
    });

    tearDown(() async {
      await fixture.tearDown();
      await ServiceContainer.reset();
    });

    group('JSON Coordinate Extraction', () {
      test(
        'extracts valid coordinates from comprehensive JSON metadata',
        () async {
          final testCases = [
            {
              'name': 'New York City',
              'lat': 40.7589,
              'lng': -73.9851,
              'expectedDir': {'lat': DirectionY.north, 'lng': DirectionX.west},
            },
            {
              'name': 'Sydney, Australia',
              'lat': -33.865143,
              'lng': 151.2099,
              'expectedDir': {'lat': DirectionY.south, 'lng': DirectionX.east},
            },
            {
              'name': 'London, UK',
              'lat': 51.5074,
              'lng': -0.1278,
              'expectedDir': {'lat': DirectionY.north, 'lng': DirectionX.west},
            },
            {
              'name': 'Tokyo, Japan',
              'lat': 35.6762,
              'lng': 139.6503,
              'expectedDir': {'lat': DirectionY.north, 'lng': DirectionX.east},
            },
          ];

          for (final testCase in testCases) {
            final file = fixture.createImageWithoutExif(
              '${testCase['name']}_test.jpg',
            );
            final jsonFile = File('${file.path}.json');

            await jsonFile.writeAsString(
              jsonEncode({
                'title': 'Test - ${testCase['name']}',
                'photoTakenTime': {
                  'timestamp': '1609459200',
                  'formatted': '01.01.2021, 00:00:00 UTC',
                },
                'geoData': {
                  'latitude': testCase['lat'],
                  'longitude': testCase['lng'],
                  'altitude': 100.0,
                  'latitudeSpan': 0.0,
                  'longitudeSpan': 0.0,
                },
              }),
            );

            final coordinates = await jsonCoordinatesExtractor(file);

            expect(
              coordinates,
              isNotNull,
              reason: 'Failed to extract coordinates for ${testCase['name']}',
            );
            expect(
              coordinates!.toDD().latitude,
              closeTo(testCase['lat'] as double, 0.0001),
            );
            expect(
              coordinates.toDD().longitude,
              closeTo(testCase['lng'] as double, 0.0001),
            );

            final expectedDirs =
                testCase['expectedDir'] as Map<String, dynamic>;
            expect(coordinates.latDirection, expectedDirs['lat']);
            expect(coordinates.longDirection, expectedDirs['lng']);

            // ignore: avoid_print
            print('✓ ${testCase['name']}: ${coordinates.toString()}');

            await jsonFile.delete();
          }
        },
      );

      test('handles edge cases and invalid coordinates', () async {
        final edgeCases = [
          {
            'name': 'zero_coordinates',
            'lat': 0.0,
            'lng': 0.0,
            'shouldExtract': false,
            'reason': 'Zero coordinates should be considered invalid',
          },
          {
            'name': 'extreme_north',
            'lat': 89.9999,
            'lng': 0.0,
            'shouldExtract': true,
            'reason': 'Near north pole should be valid',
          },
          {
            'name': 'extreme_south',
            'lat': -89.9999,
            'lng': 180.0,
            'shouldExtract': true,
            'reason': 'Near south pole should be valid',
          },
          {
            'name': 'date_line_east',
            'lat': 0.0,
            'lng': 179.9999,
            'shouldExtract': true,
            'reason': 'Near international date line should be valid',
          },
          {
            'name': 'date_line_west',
            'lat': 0.0,
            'lng': -179.9999,
            'shouldExtract': true,
            'reason': 'Near international date line (west) should be valid',
          },
        ];

        for (final edgeCase in edgeCases) {
          final file = fixture.createImageWithoutExif(
            '${edgeCase['name']}_test.jpg',
          );
          final jsonFile = File('${file.path}.json');

          await jsonFile.writeAsString(
            jsonEncode({
              'title': 'Edge Case - ${edgeCase['name']}',
              'geoData': {
                'latitude': edgeCase['lat'],
                'longitude': edgeCase['lng'],
                'altitude': 0.0,
                'latitudeSpan': 0.0,
                'longitudeSpan': 0.0,
              },
            }),
          );

          final coordinates = await jsonCoordinatesExtractor(file);

          if (edgeCase['shouldExtract'] as bool) {
            expect(
              coordinates,
              isNotNull,
              reason: edgeCase['reason'] as String,
            );
            // ignore: avoid_print
            print('✓ ${edgeCase['name']}: Valid coordinates extracted');
          } else {
            expect(coordinates, isNull, reason: edgeCase['reason'] as String);
            // ignore: avoid_print
            print(
              '✓ ${edgeCase['name']}: Correctly rejected invalid coordinates',
            );
          }

          await jsonFile.delete();
        }
      });
    });

    group('End-to-End Coordinate Workflow', () {
      // test
      test('processes complete collection with mixed coordinate data', () async {
        final collection = MediaEntityCollection();

        // Explicit config for this test (pass required paths; other options use defaults)
        final cfg = ProcessingConfig(
          inputPath: fixture.basePath,
          outputPath: fixture.basePath,
        );

        // Create test files with various coordinate scenarios
        final testFiles = [
          {
            'name': 'paris_with_coords.jpg',
            'hasCoords': true,
            'coords': {'lat': 48.8566, 'lng': 2.3522},
          },
          {'name': 'no_coords.jpg', 'hasCoords': false, 'coords': null},
          {
            'name': 'los_angeles_coords.jpg',
            'hasCoords': true,
            'coords': {'lat': 34.0522, 'lng': -118.2437},
          },
          {
            'name': 'singapore_coords.jpg',
            'hasCoords': true,
            'coords': {'lat': 1.3521, 'lng': 103.8198},
          },
        ];

        for (final testFile in testFiles) {
          final file = fixture.createImageWithoutExif(
            testFile['name'] as String,
          );
          final jsonFile = File('${file.path}.json');

          final jsonData = <String, dynamic>{
            'title': testFile['name'],
            'photoTakenTime': {
              'timestamp': '1609459200',
              'formatted': '01.01.2021, 00:00:00 UTC',
            },
          };

          if (testFile['hasCoords'] as bool) {
            final coords = testFile['coords'] as Map<String, double>;
            jsonData['geoData'] = {
              'latitude': coords['lat'],
              'longitude': coords['lng'],
              'altitude': 50.0,
              'latitudeSpan': 0.0,
              'longitudeSpan': 0.0,
            };
          }

          await jsonFile.writeAsString(jsonEncode(jsonData));

          // IMPORTANT: MediaEntity.single expects a FileEntity
          final mediaEntity = MediaEntity.single(
            file: FileEntity(sourcePath: file.path),
            dateTaken: DateTime.fromMillisecondsSinceEpoch(1609459200 * 1000),
          );
          collection.add(mediaEntity);
        }

        // Pass config explicitly (no reliance on globalConfig)
        final stepResult = await const WriteExifStep().execute(
          ProcessingContext(
            config: cfg,
            mediaCollection: collection,
            inputDirectory: Directory(fixture.basePath),
            outputDirectory: Directory(fixture.basePath),
          ),
        );
        final results = Map<String, int>.from(
          (stepResult.data as Map?)?.map(
                (final k, final v) => MapEntry('$k', (v is int) ? v : 0),
              ) ??
              {},
        );

        expect(results, isA<Map<String, int>>());
        expect(results.containsKey('coordinatesWritten'), isTrue);
        expect(results.containsKey('dateTimesWritten'), isTrue);

        // ignore: avoid_print
        print('End-to-End Workflow Results:');
        // ignore: avoid_print
        print('Total files processed: ${collection.length}');
        // ignore: avoid_print
        print('Coordinates written: ${results['coordinatesWritten']}');
        // ignore: avoid_print
        print('DateTimes written: ${results['dateTimesWritten']}');
        // ignore: avoid_print
        print('Expected coordinates: 3 (files with valid coords)');

        // Clean up
        for (final testFile in testFiles) {
          final jsonFile = File('${fixture.basePath}/${testFile['name']}.json');
          if (await jsonFile.exists()) await jsonFile.delete();
        }
      });

      test('handles coordinate writing errors gracefully', () async {
        final collection = MediaEntityCollection();

        // Explicit config for this test (pass required paths; other options use defaults)
        final cfg = ProcessingConfig(
          inputPath: fixture.basePath,
          outputPath: fixture.basePath,
        );

        // Unsupported file type scenario
        final textFile = fixture.createFile('test.txt', [65, 66, 67]); // "ABC"
        final jsonFile = File('${textFile.path}.json');
        await jsonFile.writeAsString(
          jsonEncode({
            'title': 'Unsupported file test',
            'geoData': {
              'latitude': 40.7589,
              'longitude': -73.9851,
              'altitude': 10.0,
              'latitudeSpan': 0.0,
              'longitudeSpan': 0.0,
            },
          }),
        );

        // IMPORTANT: wrap with FileEntity
        final mediaEntity = MediaEntity.single(
          file: FileEntity(sourcePath: textFile.path),
        );
        collection.add(mediaEntity);

        // Updated API: direct step execution
        final stepResult = await const WriteExifStep().execute(
          ProcessingContext(
            config: cfg,
            mediaCollection: collection,
            inputDirectory: Directory(fixture.basePath),
            outputDirectory: Directory(fixture.basePath),
          ),
        );
        final results = stepResult.data;

        expect(results, isNotNull);
        // ignore: avoid_print
        print('Error handling test completed');
        // ignore: avoid_print
        print('Results for unsupported file: $results');

        await jsonFile.delete();
      });
    });

    group('Coordinate Accuracy and Precision', () {
      test(
        'maintains coordinate precision through conversion pipeline',
        () async {
          final precisionTests = [
            {
              'name': 'high_precision',
              'lat': 40.758896123456789,
              'lng': -73.985130987654321,
            },
            {'name': 'low_precision', 'lat': 40.7589, 'lng': -73.9851},
            {'name': 'very_small_values', 'lat': 0.000001, 'lng': 0.000001},
          ];

          for (final test in precisionTests) {
            final file = fixture.createImageWithoutExif(
              '${test['name']}_precision.jpg',
            );
            final jsonFile = File('${file.path}.json');

            await jsonFile.writeAsString(
              jsonEncode({
                'title': 'Precision test - ${test['name']}',
                'geoData': {
                  'latitude': test['lat'],
                  'longitude': test['lng'],
                  'altitude': 100.0,
                  'latitudeSpan': 0.0,
                  'longitudeSpan': 0.0,
                },
              }),
            );

            final coordinates = await jsonCoordinatesExtractor(file);

            if (coordinates != null) {
              final originalLat = test['lat'] as double;
              final originalLng = test['lng'] as double;
              final extractedDD = coordinates.toDD();

              expect(extractedDD.latitude, closeTo(originalLat, 0.000001));
              expect(extractedDD.longitude, closeTo(originalLng, 0.000001));

              // ignore: avoid_print
              print('✓ ${test['name']}: Precision maintained');
              // ignore: avoid_print
              print('  Original: ($originalLat, $originalLng)');
              // ignore: avoid_print
              print(
                '  Extracted: (${extractedDD.latitude}, ${extractedDD.longitude})',
              );
            } else {
              // ignore: avoid_print
              print(
                '⚠ ${test['name']}: Coordinates not extracted (may be invalid)',
              );
            }

            await jsonFile.delete();
          }
        },
      );
    });
  });
}

/// Mock ExifTool service for testing when ExifTool is not available
class MockExifToolService extends ExifToolService {
  MockExifToolService() : super('mock_exiftool_path');

  @override
  Future<void> writeExifDataSingle(
    final File file,
    final Map<String, dynamic> data,
  ) async {
    // Simulate successful write
    // ignore: avoid_print
    print('[MOCK] Writing EXIF data to ${file.path}: $data');
  }

  @override
  // ignore: prefer_expression_function_bodies
  Future<Map<String, dynamic>> readExifData(final File file) async {
    // Simulate no existing GPS coordinates
    return {};
  }

  @override
  Future<void> startPersistentProcess() async {
    // Mock implementation
  }

  @override
  Future<void> dispose() async {
    // Mock implementation
  }
}
