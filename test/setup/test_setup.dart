/// Test setup utilities for GPTH tests
/// This file contains common test data, fixtures, and helper functions
/// to make test initialization and maintenance easier.
library;

import 'dart:convert';
import 'dart:io';
import 'package:gpth_neo/gpth_lib_exports.dart';
import 'package:path/path.dart' as path;

/// Base64 encoded 1x1 green JPEG image with EXIF data
/// DateTime Original: 2022:12:16 16:06:47
const String greenImgBase64 = '''
/9j/4AAQSkZJRgABAQAAAQABAAD/4QC4RXhpZgAATU0AKgAAAAgABQEaAAUAAAABAAAASgEbAAUA
AAABAAAAUgEoAAMAAAABAAEAAAITAAMAAAABAAEAAIdpAAQAAAABAAAAWgAAAAAAAAABAAAAAQAA
AAEAAAABAAWQAAAHAAAABDAyMzKQAwACAAAAFAAAAJyRAQAHAAAABAECAwCgAAAHAAAABDAxMDCg
AQADAAAAAf//AAAAAAAAMjAyMjoxMjoxNiAxNjowNjo0NwD/2wBDAAMCAgICAgMCAgIDAwMDBAYE
BAQEBAgGBgUGCQgKCgkICQkKDA8MCgsOCwkJDRENDg8QEBEQCgwSExIQEw8QEBD/2wBDAQMDAwQD
BAgEBAgQCwkLEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQ
EBD/wAARCAABAAEDAREAAhEBAxEB/8QAFAABAAAAAAAAAAAAAAAAAAAAA//EABQQAQAAAAAAAAAA
AAAAAAAAAAD/xAAUAQEAAAAAAAAAAAAAAAAAAAAI/8QAFBEBAAAAAAAAAAAAAAAAAAAAAP/aAAwD
AQACEQMRAD8AIcgXf//Z''';

/// Base64 encoded 1x1 green JPEG image without EXIF metadata
const String greenImgNoMetaDataBase64 = '''
/9j/4AAQSkZJRgABAQAAAQABAAD/4QCYRXhpZgAATU0AKgAAAAgABQEaAAUAAAABAAA
ASgEbAAUAAAABAAAAUgEoAAMAAAABAAEAAAITAAMAAAABAAEAAIdpAAQAAAABAAAAWgAAA
AAAAAABAAAAAQAAAAEAAAABAASQAAAHAAAABDAyMzKRAQAHAAAABAECAwCgAAAHAAAABDA
xMDCgAQADAAAAAf//AAAAAAAA/9sAQwADAgICAgIDAgICAwMDAwQGBAQEBAQIBgYFBgkIC
goJCAkJCgwPDAoLDgsJCQ0RDQ4PEBAREAoMEhMSEBMPEBAQ/9sAQwEDAwMEAwQIBAQIEAs
JCxAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQ/
8AAEQgAAQABAwERAAIRAQMRAf/EABQAAQAAAAAAAAAAAAAAAAAAAAP/xAAUEAEAAAAAAAA
AAAAAAAAAAAAA/8QAFAEBAAAAAAAAAAAAAAAAAAAACP/EABQRAQAAAAAAAAAAAAAAAAAAA
AD/2gAMAwEAAhEDEQA/ACHIF3//2Q==''';

/// Test fixture class to manage test file creation and cleanup
class TestFixture {
  late String basePath;
  late Directory baseDir;
  final Set<FileSystemEntity> _createdEntities = {};

  /// Initialize the test fixture with a unique temporary directory
  Future<void> setUp() async {
    final String current = Directory.current.path;
    final String timestamp = DateTime.now().microsecondsSinceEpoch.toString();
    final String randomSuffix = DateTime.now().millisecondsSinceEpoch
        .toRadixString(36);
    // Include pid to guarantee uniqueness across parallel test processes.
    // Without this, two test files started at the same microsecond would
    // produce identical fixture paths and race on the same files.
    final String uniqueId =
        '${DateTime.now().microsecondsSinceEpoch % 1000000}';
    basePath = path.join(
      current,
      'test',
      'generated',
      'fixture_${timestamp}_${randomSuffix}_${pid}_$uniqueId',
    );
    baseDir = Directory(basePath);
    await baseDir.create(recursive: true);
    _createdEntities.add(baseDir);
  }

  /// Clean up all created files and directories
  Future<void> tearDown() async {
    // Wait longer to ensure all file operations have completed
    await Future.delayed(const Duration(milliseconds: 100));

    // Force garbage collection to help release file handles
    if (Platform.isWindows) {
      // On Windows, give extra time for file handles to be released
      // and for any external processes (like ExifTool) to finish
      await Future.delayed(const Duration(milliseconds: 100));

      // Try to close any lingering file handles by forcing a GC
      try {
        // Trigger garbage collection
        final List<List<int>> temp = [];
        for (int i = 0; i < 100; i++) {
          temp.add(List<int>.filled(1000, i));
        }
        temp.clear();
      } catch (e) {
        // Ignore GC errors
      }

      // Additional wait for Windows file system to release handles
      await Future.delayed(const Duration(milliseconds: 50));
    }

    // Fast-path for large E2E fixtures: remove the whole fixture root first.
    // This avoids very slow per-file recursive retries on huge generated trees.
    try {
      if (await baseDir.exists()) {
        try {
          await baseDir.delete(recursive: true);
        } catch (_) {
          await _forceDeleteDirectory(baseDir);
        }
      }
    } catch (_) {}

    // Fallback cleanup for any entities not covered by baseDir removal.
    final entities = _createdEntities.toList().reversed.toList();
    for (final entity in entities) {
      try {
        if (entity.path.startsWith(basePath)) continue;
      } catch (_) {}
      await _safeDelete(entity);
    }
    _createdEntities.clear();
  }

  /// Safely delete a file system entity with retry logic
  Future<void> _safeDelete(final FileSystemEntity entity) async {
    const maxRetries = 5; // Increased retries for Windows
    for (int retry = 0; retry < maxRetries; retry++) {
      try {
        if (await entity.exists()) {
          if (entity is File) {
            // On Windows, try to change file attributes to remove read-only before deletion
            if (Platform.isWindows) {
              try {
                await Process.run('attrib', ['-R', entity.path]);
              } catch (e) {
                // Ignore attrib errors
              }
            }
            await entity.delete();
          } else if (entity is Directory) {
            await _deleteDirectoryRecursively(entity);
          } else if (entity is Link) {
            await entity.delete();
          }
        }
        return; // Success, exit retry loop
      } catch (e) {
        if (retry == maxRetries - 1) {
          // Last retry, log but don't fail
          print(
            'Warning: Failed to delete ${entity.path} after $maxRetries attempts: $e',
          );
        } else {
          // Progressive backoff: wait longer on each retry
          final delayMs = 200 * (retry + 1); // 200ms, 400ms, 600ms, 800ms
          await Future.delayed(Duration(milliseconds: delayMs));

          // Force garbage collection on Windows to help release handles
          if (Platform.isWindows && retry > 0) {
            // Give the OS more time to release file handles
            await Future.delayed(const Duration(milliseconds: 100));
          }
        }
      }
    }
  }

  /// Recursively delete directory contents and the directory itself
  Future<void> _deleteDirectoryRecursively(final Directory dir) async {
    try {
      // followLinks:false ensures symlinks to directories are returned as Link
      // (deleted directly) instead of Directory (which would recurse into the
      // symlink target — causing a very slow tearDown on Windows shortcut runs).
      final contents = await dir.list(followLinks: false).toList();

      // Delete files first, then directories
      final files = contents.whereType<File>().toList();
      final links = contents.whereType<Link>().toList();
      final subdirs = contents.whereType<Directory>().toList();

      // Delete files and links (ignore individual failures, retry later)
      for (final file in files) {
        try {
          await _safeDelete(file);
        } catch (_) {}
      }
      for (final link in links) {
        try {
          await _safeDelete(link);
        } catch (_) {}
      }

      // Delete subdirectories recursively
      for (final subdir in subdirs) {
        await _safeDelete(subdir);
      }

      // Finally delete the directory itself
      try {
        await dir.delete();
      } on FileSystemException {
        // Fallback: attempt a recursive delete (may clear hidden leftovers)
        try {
          await dir.delete(recursive: true);
        } catch (_) {}
      }
    } catch (e) {
      // If listing fails, try force deletion
      try {
        await dir.delete(recursive: true);
      } catch (e2) {
        // As last resort, try using platform-specific commands
        await _forceDeleteDirectory(dir);
      }
    } finally {
      // Final safety: if still exists, force remove with platform command
      if (await dir.exists()) {
        await _forceDeleteDirectory(dir);
      }
    }
  }

  /// Force delete directory using platform-specific commands
  Future<void> _forceDeleteDirectory(final Directory dir) async {
    try {
      if (Platform.isWindows) {
        await Process.run('rmdir', ['/s', '/q', dir.path]);
      } else {
        await Process.run('rm', ['-rf', dir.path]);
      }
    } catch (e) {
      // Final fallback - log the error but don't fail
      print('Warning: Could not force delete ${dir.path}: $e');
    }
  }

  /// Ensures a file is fully available and accessible to external processes
  ///
  /// This helps prevent race conditions where files are created but not yet
  /// visible to other processes or tools like ExifTool
  void _ensureFileAvailable(final File file) {
    // Force file system sync and validate file accessibility
    try {
      // Multiple approaches to ensure file is committed to disk
      file.statSync(); // Force file system stat call

      if (Platform.isWindows) {
        // On Windows, verify the file is readable by opening and closing it
        // This forces Windows to flush file buffers and make it available
        final handle = file.openSync();
        handle.closeSync();

        // Small delay to allow file system to fully commit the file
        // This is especially important on Windows with antivirus scanners
        final stopwatch = Stopwatch()..start();
        while (stopwatch.elapsedMilliseconds < 100) {
          if (file.existsSync() && file.lengthSync() > 0) {
            break;
          }
          // Minimal sleep to allow file system operations to complete
          Process.runSync('ping', ['127.0.0.1', '-n', '1']);
        }
      } else {
        // On Unix systems, sync the file system
        try {
          Process.runSync('sync', []);
        } catch (e) {
          // Ignore sync failures - it's just an optimization
        }
      }

      // Final validation - ensure file exists and has content
      if (!file.existsSync()) {
        throw StateError('File ${file.path} was created but is not accessible');
      }
    } catch (e) {
      print('Warning: File availability check failed for ${file.path}: $e');
      // Continue anyway - the file might still work
    }
  }

  /// Create a test image file with EXIF data
  File createImageWithExif(final String name) {
    final file = File(path.join(basePath, name));
    file.createSync(recursive: true);
    // Use writeAsBytesSync with flush: true to ensure data is written immediately
    file.writeAsBytesSync(
      base64.decode(greenImgBase64.replaceAll('\n', '')),
      flush: true,
    );
    _createdEntities.add(file);

    // Ensure file is fully committed to disk before returning
    _ensureFileAvailable(file);

    return file;
  }

  /// Create a test image file without EXIF data
  File createImageWithoutExif(final String name) {
    final file = File(path.join(basePath, name));
    file.createSync(recursive: true);
    // Use writeAsBytesSync with flush: true to ensure data is written immediately
    file.writeAsBytesSync(
      base64.decode(greenImgNoMetaDataBase64.replaceAll('\n', '')),
      flush: true,
    );
    _createdEntities.add(file);
    _ensureFileAvailable(file);
    return file;
  }

  /// Create a test file with custom content
  File createFile(final String name, final List<int> content) {
    final file = File(path.join(basePath, name));
    file.createSync(recursive: true);
    // Use writeAsBytesSync with flush: true to ensure data is written immediately
    file.writeAsBytesSync(content, flush: true);
    _createdEntities.add(file);

    // Ensure file is fully committed to disk before returning
    _ensureFileAvailable(file);

    return file;
  }

  /// Create a test directory
  Directory createDirectory(final String name) {
    final dir = Directory(path.join(basePath, name));
    dir.createSync(recursive: true);
    _createdEntities.add(dir);
    return dir;
  }

  /// Create a JSON file with test metadata
  /// Create a JSON sidecar file.
  ///
  /// - [photoTakenTimestamp]: Unix epoch string for the `photoTakenTime` field.
  ///   Pass `null` to omit the field entirely (simulates missing date).
  /// - [includeExtendedFields]: when `true`, also writes `geoData`, `geoDataExif`,
  ///   `archived`, `url`, and `googlePhotosOrigin` (mirrors a full Google Photos export).
  File createJsonFile(
    final String name, {
    final String? photoTakenTimestamp,
    final bool includeExtendedFields = false,
  }) {
    final file = File(path.join(basePath, name));
    file.createSync(recursive: true);
    final Map<String, dynamic> json = {
      'title': 'test.jpg',
      'description': '',
      'imageViews': '1',
      'creationTime': {
        'timestamp': '1702198242',
        'formatted': '10.12.2023, 08:50:42 UTC',
      },
      if (photoTakenTimestamp != null)
        'photoTakenTime': {
          'timestamp': photoTakenTimestamp,
          'formatted': '01.05.2023, 14:32:37 UTC',
        },
      if (includeExtendedFields) ...{
        'geoData': {
          'latitude': 41.3221611,
          'longitude': 19.8149139,
          'altitude': 143.09,
          'latitudeSpan': 0.0,
          'longitudeSpan': 0.0,
        },
        'geoDataExif': {
          'latitude': 41.3221611,
          'longitude': 19.8149139,
          'altitude': 143.09,
          'latitudeSpan': 0.0,
          'longitudeSpan': 0.0,
        },
        'archived': true,
        'url': 'https://photos.google.com/photo/xyz',
        'googlePhotosOrigin': {
          'mobileUpload': {'deviceType': 'IOS_PHONE'},
        },
      },
    };
    file.writeAsStringSync(jsonEncode(json), flush: true);
    _createdEntities.add(file);
    _ensureFileAvailable(file);
    return file;
  }

  /// Create a test image file with EXIF data in a specific directory
  File createImageWithExifInDir(final String dirPath, final String name) {
    final dir = Directory(dirPath);
    if (!dir.existsSync()) {
      dir.createSync(recursive: true);
      _createdEntities.add(dir);
    }

    final file = File(path.join(dirPath, name));
    file.createSync(recursive: true);
    // Use writeAsBytesSync with flush: true to ensure data is written immediately
    file.writeAsBytesSync(
      base64.decode(greenImgBase64.replaceAll('\n', '')),
      flush: true,
    );
    _createdEntities.add(file);

    // Ensure file is fully committed to disk before returning
    _ensureFileAvailable(file);

    return file;
  }

  /// Generate a realistic Google Photos Takeout dataset within this fixture
  ///
  /// This is a convenience method that calls generateRealisticDataset() using
  /// the current fixture's base path and manages the created entities for cleanup.
  ///
  /// Returns the path to the generated Takeout directory.
  Future<String> generateRealisticTakeoutDataset({
    final int yearSpan = 3,
    final int albumCount = 5,
    final int photosPerYear = 10,
    final int albumOnlyPhotos = 3,
    final double exifRatio = 0.7,
    final bool includeRawSamples = false,
  }) async {
    // Use a unique dataset folder per invocation to avoid cross-test collisions
    // when tests in the same suite execute concurrently.
    final timestamp = DateTime.now().microsecondsSinceEpoch;
    final randomSuffix = DateTime.now().millisecondsSinceEpoch.toRadixString(
      36,
    );
    final datasetPath = path.join(
      basePath,
      'realistic_dataset_${timestamp}_${pid}_$randomSuffix',
    );

    await generateRealisticDataset(
      basePath: datasetPath,
      yearSpan: yearSpan,
      albumCount: albumCount,
      photosPerYear: photosPerYear,
      albumOnlyPhotos: albumOnlyPhotos,
      exifRatio: exifRatio,
      includeRawSamples: includeRawSamples,
    );

    return path.join(datasetPath, 'Takeout');
  }

  /// Create a large test file for performance testing
  File createLargeTestFile(
    final String name, {
    final int sizeInMB = 1,
    final List<int>? content,
  }) {
    final file = File(path.join(basePath, name));
    file.createSync(recursive: true);

    // Use provided content or create a buffer of the specified size
    final buffer = content ?? List<int>.filled(sizeInMB * 1024 * 1024, 0);

    // Write the buffer to the file
    file.writeAsBytesSync(buffer, flush: true);
    _createdEntities.add(file);
    _ensureFileAvailable(file);
    return file;
  }
}

/// Test data patterns for filename-based date extraction
final List<List<String>> testDatePatterns = [
  ['Screenshot_20190919-053857_Camera-edited.jpg', '2019-09-19 05:38:57'],
  ['MVIMG_20190215_193501.MP4', '2019-02-15 19:35:01'],
  ['Screenshot_2019-04-16-11-19-37-232_com.jpg', '2019-04-16 11:19:37'],
  ['signal-2020-10-26-163832.jpg', '2020-10-26 16:38:32'],
  ['VID_20220107_113306.mp4', '2022-01-07 11:33:06'],
  ['00004XTR_00004_BURST20190216172030.jpg', '2019-02-16 17:20:30'],
  ['00055IMG_00055_BURST20190216172030_COVER.jpg', '2019-02-16 17:20:30'],
  ['2016_01_30_11_49_15.mp4', '2016-01-30 11:49:15'],
  ['201801261147521000.jpg', '2018-01-26 11:47:52'],
  ['IMG_1_BURST20160623205107_COVER.jpg', '2016-06-23 20:51:07'],
  ['IMG_1_BURST20160520195318.jpg', '2016-05-20 19:53:18'],
  ['1990_06_16_07_30_00.jpg', '1990-06-16 07:30:00'],
  ['1869_12_30_16_59_57.jpg', '1869-12-30 16:59:57'],
];

/// Generate a realistic Google Photos Takeout dataset for testing
///
/// Creates a complete test structure that mimics real Google Photos exports with:
/// - Year folders (Photos from YYYY) containing original photos
/// - Album folders with various naming patterns including emojis
/// - JPG files with and without EXIF data
/// - Corresponding JSON metadata files with realistic timestamps
/// - Album-only photos and multi-album relationships
/// - Various naming patterns found in real exports
Future<void> generateRealisticDataset({
  required final String basePath,
  final int yearSpan = 5,
  final int albumCount = 8,
  final int photosPerYear = 15,
  final int albumOnlyPhotos = 5,
  final double exifRatio = 0.7, // 70% of photos have EXIF data
  final bool includeRawSamples = false,
}) async {
  final Set<FileSystemEntity> createdEntities = {};

  // Create base directory structure
  final baseDir = Directory(basePath);
  await baseDir.create(recursive: true);
  createdEntities.add(baseDir);

  final takeoutDir = Directory(path.join(basePath, 'Takeout'));
  await takeoutDir.create(recursive: true);
  createdEntities.add(takeoutDir);

  final googlePhotosDir = Directory(
    path.join(takeoutDir.path, 'Google Photos'),
  );
  await googlePhotosDir.create(recursive: true);
  createdEntities.add(googlePhotosDir);

  // Define realistic album names including emojis
  // On Windows, hex-encode emoji characters to match what the production
  // pipeline does before any filesystem operations (see main_pipeline.dart).
  final List<String> albumNames =
      [
            'Vacation 2023 🏖️',
            'Family Photos 👨‍👩‍👧‍👦',
            'Holiday Memories 🎄',
            'Wedding Photos 💒',
            'Travel Adventures ✈️',
            'Pet Photos 🐕🐱',
            'Cooking & Food 🍕',
            'Nature & Landscapes 🌄',
            'Friends & Fun 🎉',
            'Work & Office 💼',
            'Art & Creative 🎨',
            'Summer Fun ☀️',
          ]
          .map(
            (final name) => Platform.isWindows
                ? FilenameSanitizerService.encodeEmojiInText(name)
                : name,
          )
          .toList();

  // Define realistic photo filename patterns
  final List<String Function(DateTime, int)> filenamePatterns = [
    (final date, final index) =>
        'IMG_${date.year}${date.month.toString().padLeft(2, '0')}${date.day.toString().padLeft(2, '0')}_${date.hour.toString().padLeft(2, '0')}${date.minute.toString().padLeft(2, '0')}${date.second.toString().padLeft(2, '0')}.jpg',
    (final date, final index) =>
        'Screenshot_${date.year}-${date.month.toString().padLeft(2, '0')}-${date.day.toString().padLeft(2, '0')}-${date.hour.toString().padLeft(2, '0')}-${date.minute.toString().padLeft(2, '0')}-${date.second.toString().padLeft(2, '0')}.jpg',
    (final date, final index) =>
        'MVIMG_${date.year}${date.month.toString().padLeft(2, '0')}${date.day.toString().padLeft(2, '0')}_${date.hour.toString().padLeft(2, '0')}${date.minute.toString().padLeft(2, '0')}${date.second.toString().padLeft(2, '0')}.jpg',
    (final date, final index) =>
        'signal-${date.year}-${date.month.toString().padLeft(2, '0')}-${date.day.toString().padLeft(2, '0')}-${date.hour.toString().padLeft(2, '0')}${date.minute.toString().padLeft(2, '0')}${date.second.toString().padLeft(2, '0')}.jpg',
    (final date, final index) =>
        'VID_${date.year}${date.month.toString().padLeft(2, '0')}${date.day.toString().padLeft(2, '0')}_${date.hour.toString().padLeft(2, '0')}${date.minute.toString().padLeft(2, '0')}${date.second.toString().padLeft(2, '0')}.jpg',
    (final date, final index) =>
        '${date.year}_${date.month.toString().padLeft(2, '0')}_${date.day.toString().padLeft(2, '0')}_${date.hour.toString().padLeft(2, '0')}_${date.minute.toString().padLeft(2, '0')}_${date.second.toString().padLeft(2, '0')}.jpg',
    (final date, final index) =>
        'PXL_${date.year}${date.month.toString().padLeft(2, '0')}${date.day.toString().padLeft(2, '0')}_${date.hour.toString().padLeft(2, '0')}${date.minute.toString().padLeft(2, '0')}${date.second.toString().padLeft(2, '0')}${index.toString().padLeft(3, '0')}.jpg',
    (final date, final index) =>
        'Photo_${date.year}-${date.month.toString().padLeft(2, '0')}-${date.day.toString().padLeft(2, '0')}_${index.toString().padLeft(4, '0')}.jpg',
  ];

  final currentYear = DateTime.now().year;
  final List<String> createdPhotos = [];
  final Map<String, List<String>> albumToPhotos = {};
  // Optional RAW sample URLs (public domain test samples from pixls.us)
  const rawSampleUrls = <String>[
    'https://raw.pixls.us/data/Canon/EOS-1D%20Mark%20IV/IMG_5398.CR2',
    'https://raw.pixls.us/data/Fujifilm/FinePix%20F550EXR/DSCF6714.RAF',
    'https://raw.pixls.us/data/Nikon/D1/RAW_NIKON_D1.NEF',
    'https://raw.pixls.us/data/Sony/ILCE-7M4/ILCE-7M4_DSC06673_FullFrame-Raw-Uncompressed.ARW',
    'https://raw.pixls.us/data/Panasonic/DC-GX9/gx9_1_1.RW2',
    'https://raw.pixls.us/data/Adobe%20DNG%20Converter/Canon%20EOS%205D%20Mark%20III/5G4A9394-uncompressed.DNG',
  ];

  // Create year folders and photos
  for (int i = 0; i < yearSpan; i++) {
    final year = currentYear - yearSpan + i + 1;
    final yearDir = Directory(
      path.join(googlePhotosDir.path, 'Photos from $year'),
    );
    await yearDir.create(recursive: true);
    createdEntities.add(yearDir);

    // Create photos for this year
    for (int j = 0; j < photosPerYear; j++) {
      final photoDate = DateTime(
        year,
        (j % 12) + 1,
        ((j * 3) % 28) + 1,
        (j * 2) % 24,
        (j * 7) % 60,
        (j * 11) % 60,
      );

      final patternIndex = j % filenamePatterns.length;
      final filename = filenamePatterns[patternIndex](photoDate, j);
      final photoPath = path.join(yearDir.path, filename);

      // Determine if this photo should have EXIF data
      final hasExif =
          (j / photosPerYear) <
          exifRatio; // Create photo file with unique content
      final photoFile = File(photoPath);
      if (hasExif) {
        final baseBytes = base64.decode(greenImgBase64.replaceAll('\n', ''));
        // Add unique content to make each photo different
        final uniqueBytes = List<int>.from(baseBytes);
        uniqueBytes.addAll('unique_${i}_${j}_$filename'.codeUnits);
        photoFile.writeAsBytesSync(uniqueBytes, flush: true);
      } else {
        final baseBytes = base64.decode(
          greenImgNoMetaDataBase64.replaceAll('\n', ''),
        );
        // Add unique content to make each photo different
        final uniqueBytes = List<int>.from(baseBytes);
        uniqueBytes.addAll('unique_${i}_${j}_$filename'.codeUnits);
        photoFile.writeAsBytesSync(uniqueBytes, flush: true);
      }
      createdEntities.add(photoFile);

      // Ensure photo file is available before creating JSON
      photoFile.statSync(); // Force file system sync
      if (Platform.isWindows) {
        // Small delay to ensure file is visible to other processes
        final stopwatch = Stopwatch()..start();
        while (stopwatch.elapsedMilliseconds < 50 && !photoFile.existsSync()) {
          // Wait for file to become available
        }
      }

      createdPhotos.add(filename); // Create JSON metadata file
      final jsonFile = File('$photoPath.json');
      jsonFile.writeAsStringSync(
        jsonEncode({
          'title': filename,
          'description': '',
          'imageViews': '${(j % 50) + 1}',
          'creationTime': {
            'timestamp': '${(photoDate.millisecondsSinceEpoch / 1000).floor()}',
            'formatted':
                '${photoDate.day.toString().padLeft(2, '0')}.${photoDate.month.toString().padLeft(2, '0')}.${photoDate.year}, ${photoDate.hour.toString().padLeft(2, '0')}:${photoDate.minute.toString().padLeft(2, '0')}:${photoDate.second.toString().padLeft(2, '0')} UTC',
          },
          'photoTakenTime': {
            'timestamp': '${(photoDate.millisecondsSinceEpoch / 1000).floor()}',
            'formatted':
                '${photoDate.day.toString().padLeft(2, '0')}.${photoDate.month.toString().padLeft(2, '0')}.${photoDate.year}, ${photoDate.hour.toString().padLeft(2, '0')}:${photoDate.minute.toString().padLeft(2, '0')}:${photoDate.second.toString().padLeft(2, '0')} UTC',
          },
          'geoData': j % 3 == 0
              ? {
                  'latitude': 41.3221611 + (j * 0.001),
                  'longitude': 19.8149139 + (j * 0.001),
                  'altitude': 143.09 + (j * 2.5),
                  'latitudeSpan': 0.0,
                  'longitudeSpan': 0.0,
                }
              : null,
          'geoDataExif': j % 3 == 0
              ? {
                  'latitude': 41.3221611 + (j * 0.001),
                  'longitude': 19.8149139 + (j * 0.001),
                  'altitude': 143.09 + (j * 2.5),
                  'latitudeSpan': 0.0,
                  'longitudeSpan': 0.0,
                }
              : null,
          'archived': j % 7 == 0,
          'url':
              'https://photos.google.com/photo/${DateTime.now().millisecondsSinceEpoch}_$j',
          if (j % 4 == 0)
            'googlePhotosOrigin': {
              'mobileUpload': {
                'deviceType': ['IOS_PHONE', 'ANDROID_PHONE', 'CAMERA'][j % 3],
              },
            },
        }),
        flush: true,
      );
      createdEntities.add(jsonFile);
    }
  }

  // Optionally include cached RAW samples (downloaded once into test/raw_samples)
  if (includeRawSamples) {
    final cacheDir = Directory(
      path.join(Directory.current.path, 'test', 'raw_samples'),
    );
    if (!await cacheDir.exists()) {
      await cacheDir.create(recursive: true);
    }
    // Download missing samples only once and keep them cached
    for (final url in rawSampleUrls) {
      final uri = Uri.parse(url);
      final fileName = uri.pathSegments.last;
      final cachedFile = File(path.join(cacheDir.path, fileName));
      if (!await cachedFile.exists()) {
        try {
          print('Downloading RAW sample $fileName for cache...');
          final httpClient = HttpClient();
          final request = await httpClient
              .getUrl(uri)
              .timeout(const Duration(seconds: 15));
          final response = await request.close().timeout(
            const Duration(seconds: 30),
          );
          if (response.statusCode == 200) {
            final bytes = await response.fold<List<int>>(<int>[], (
              final a,
              final b,
            ) {
              a.addAll(b);
              return a;
            });
            if (bytes.isNotEmpty) {
              await cachedFile.writeAsBytes(bytes, flush: true);
            }
          } else {
            print('Failed HTTP ${response.statusCode} for $fileName');
          }
        } catch (e) {
          print('Failed to cache RAW sample $fileName: $e');
        }
      }
    }
    // Copy cached samples into first year folder with generated JSON sidecars
    final int firstYear = currentYear - yearSpan + 1;
    final firstYearDir = Directory(
      path.join(googlePhotosDir.path, 'Photos from $firstYear'),
    );
    if (await firstYearDir.exists()) {
      int rawIndex = 0;
      await for (final entity in cacheDir.list()) {
        if (entity is! File) continue;
        final nameUpper = entity.path.toUpperCase();
        if (!(nameUpper.endsWith('.CR2') ||
            nameUpper.endsWith('.RAF') ||
            nameUpper.endsWith('.NEF') ||
            nameUpper.endsWith('.ARW') ||
            nameUpper.endsWith('.RW2') ||
            nameUpper.endsWith('.DNG'))) {
          continue;
        }
        final target = File(
          path.join(firstYearDir.path, path.basename(entity.path)),
        );
        if (!await target.exists()) {
          FileSystemException? copyError;
          for (int attempt = 0; attempt < 6; attempt++) {
            try {
              await entity.copy(target.path);
              copyError = null;
              break;
            } on FileSystemException catch (e) {
              final code = e.osError?.errorCode;
              // Transient Windows lock/race errors: retry with backoff.
              if (code == 5 || code == 32 || code == 145) {
                copyError = e;
                await Future<void>.delayed(
                  Duration(milliseconds: 120 * (attempt + 1)),
                );
                continue;
              }
              rethrow;
            }
          }
          if (copyError != null) throw copyError;

          createdEntities.add(target);
          final takenDate = DateTime(firstYear, 1, 1, 12, 0, rawIndex % 60);
          final jsonMeta = File('${target.path}.json');
          jsonMeta.writeAsStringSync(
            jsonEncode({
              'title': path.basename(entity.path),
              'description': 'RAW sample test file (cached)',
              'imageViews': '1',
              'creationTime': {
                'timestamp':
                    '${(takenDate.millisecondsSinceEpoch / 1000).floor()}',
                'formatted':
                    '${takenDate.day.toString().padLeft(2, '0')}.${takenDate.month.toString().padLeft(2, '0')}.${takenDate.year}, ${takenDate.hour.toString().padLeft(2, '0')}:${takenDate.minute.toString().padLeft(2, '0')}:${takenDate.second.toString().padLeft(2, '0')} UTC',
              },
              'photoTakenTime': {
                'timestamp':
                    '${(takenDate.millisecondsSinceEpoch / 1000).floor()}',
                'formatted':
                    '${takenDate.day.toString().padLeft(2, '0')}.${takenDate.month.toString().padLeft(2, '0')}.${takenDate.year}, ${takenDate.hour.toString().padLeft(2, '0')}:${takenDate.minute.toString().padLeft(2, '0')}:${takenDate.second.toString().padLeft(2, '0')} UTC',
              },
            }),
            flush: true,
          );
          createdEntities.add(jsonMeta);
          // Ensure the RAW file and its JSON sidecar are fully visible to subsequent
          // steps (mitigates intermittent PathNotFoundException on Linux CI runners).
          try {
            for (int attempt = 0; attempt < 5; attempt++) {
              final exists = await target.exists();
              final lenOk = exists ? await target.length() > 0 : false;
              final sidecarExists = await jsonMeta.exists();
              if (exists && lenOk && sidecarExists) break;
              await Future.delayed(const Duration(milliseconds: 40));
            }
          } catch (_) {
            // Swallow – best effort stabilization.
          }
          rawIndex++;
        }
      }
    }
  }

  // Create album folders
  final selectedAlbums = albumNames.take(albumCount).toList();
  for (int i = 0; i < selectedAlbums.length; i++) {
    final albumName = selectedAlbums[i];
    final albumDir = Directory(path.join(googlePhotosDir.path, albumName));
    await albumDir.create(recursive: true);
    createdEntities.add(albumDir);

    albumToPhotos[albumName] = [];

    // Add random photos from year folders to this album
    final photosInAlbum = (createdPhotos.length * 0.3)
        .round(); // 30% of photos in each album
    final albumPhotos = <String>[];

    for (int j = 0; j < photosInAlbum; j++) {
      final randomPhotoIndex =
          (i * 13 + j * 7) % createdPhotos.length; // Deterministic but varied
      final photoName = createdPhotos[randomPhotoIndex];
      albumPhotos.add(photoName);

      // Find original photo file
      File? originalPhoto;
      for (int yearOffset = 0; yearOffset < yearSpan; yearOffset++) {
        final year = currentYear - yearSpan + yearOffset + 1;
        final yearDir = Directory(
          path.join(googlePhotosDir.path, 'Photos from $year'),
        );
        final potentialPath = path.join(yearDir.path, photoName);
        if (File(potentialPath).existsSync()) {
          originalPhoto = File(potentialPath);
          break;
        }
      }
      if (originalPhoto != null) {
        // Copy photo to album (creating identical files as in real Google Photos Takeout).
        // Guard against PathExistsException on re-run (e.g. repeated setUp calls that
        // share the same realistic_dataset/ directory): silently skip existing files
        // since the content is deterministic and identical.
        final albumPhotoPath = path.join(albumDir.path, photoName);
        if (!File(albumPhotoPath).existsSync()) {
          originalPhoto.copySync(albumPhotoPath);
        }

        // Copy JSON file too
        final originalJsonPath = '${originalPhoto.path}.json';
        if (File(originalJsonPath).existsSync() &&
            !File('$albumPhotoPath.json').existsSync()) {
          File(originalJsonPath).copySync('$albumPhotoPath.json');
        }
      }
    }

    albumToPhotos[albumName] = albumPhotos;
  }

  // Create album-only photos (photos that exist only in albums, not in year folders)
  final currentAlbums = selectedAlbums
      .take(3)
      .toList(); // Use first 3 albums for album-only photos
  for (int i = 0; i < albumOnlyPhotos; i++) {
    final albumIndex = i % currentAlbums.length;
    final albumName = currentAlbums[albumIndex];
    final albumDir = Directory(path.join(googlePhotosDir.path, albumName));
    // Ensure the directory exists even under heavy parallel I/O — creation is
    // idempotent (no-op if already present) and guards against race conditions
    // on Windows where the earlier create() may not yet be visible to writes.
    await albumDir.create(recursive: true);
    final albumOnlyDate = DateTime(
      currentYear,
      (i % 12) + 1,
      ((i * 5) % 28) + 1,
      (i * 3) % 24,
      (i * 13) % 60,
      (i * 17) % 60,
    );

    final filename =
        'album_only_${albumName.replaceAll(RegExp(r'[^\w\s-]'), '')}_${albumOnlyDate.year}${albumOnlyDate.month.toString().padLeft(2, '0')}${albumOnlyDate.day.toString().padLeft(2, '0')}_$i.jpg';
    final photoPath = path.join(
      albumDir.path,
      filename,
    ); // Create album-only photo with EXIF data and unique content
    final photoFile = File(photoPath);
    final baseBytes = base64.decode(greenImgBase64.replaceAll('\n', ''));
    // Add unique content to make each album-only photo different
    final uniqueBytes = List<int>.from(baseBytes);
    uniqueBytes.addAll('album_only_${albumName}_${i}_$filename'.codeUnits);
    photoFile.writeAsBytesSync(uniqueBytes, flush: true);
    createdEntities.add(photoFile); // Create JSON metadata for album-only photo
    final jsonFile = File('$photoPath.json');
    jsonFile.writeAsStringSync(
      jsonEncode({
        'title': filename,
        'description': 'Album-only photo for testing',
        'imageViews': '${i + 1}',
        'creationTime': {
          'timestamp':
              '${(albumOnlyDate.millisecondsSinceEpoch / 1000).floor()}',
          'formatted':
              '${albumOnlyDate.day.toString().padLeft(2, '0')}.${albumOnlyDate.month.toString().padLeft(2, '0')}.${albumOnlyDate.year}, ${albumOnlyDate.hour.toString().padLeft(2, '0')}:${albumOnlyDate.minute.toString().padLeft(2, '0')}:${albumOnlyDate.second.toString().padLeft(2, '0')} UTC',
        },
        'photoTakenTime': {
          'timestamp':
              '${(albumOnlyDate.millisecondsSinceEpoch / 1000).floor()}',
          'formatted':
              '${albumOnlyDate.day.toString().padLeft(2, '0')}.${albumOnlyDate.month.toString().padLeft(2, '0')}.${albumOnlyDate.year}, ${albumOnlyDate.hour.toString().padLeft(2, '0')}:${albumOnlyDate.minute.toString().padLeft(2, '0')}:${albumOnlyDate.second.toString().padLeft(2, '0')} UTC',
        },
        'geoData': {
          'latitude': 40.7128 + (i * 0.01),
          'longitude': -74.0060 + (i * 0.01),
          'altitude': 10.0 + (i * 5.0),
          'latitudeSpan': 0.0,
          'longitudeSpan': 0.0,
        },
        'geoDataExif': {
          'latitude': 40.7128 + (i * 0.01),
          'longitude': -74.0060 + (i * 0.01),
          'altitude': 10.0 + (i * 5.0),
          'latitudeSpan': 0.0,
          'longitudeSpan': 0.0,
        },
        'archived': false,
        'url':
            'https://photos.google.com/photo/album_only_${DateTime.now().millisecondsSinceEpoch}_$i',
        'googlePhotosOrigin': {
          'mobileUpload': {'deviceType': 'IOS_PHONE'},
        },
      }),
      flush: true,
    );
    createdEntities.add(jsonFile);

    albumToPhotos[albumName]!.add(filename);
  }

  // Create some special folders that commonly appear in Google Takeout
  final specialFolders = ['Archive', 'Trash', 'Screenshots', 'Camera'];

  for (final folderName in specialFolders) {
    final specialDir = Directory(path.join(googlePhotosDir.path, folderName));
    await specialDir.create(recursive: true);
    createdEntities.add(specialDir);

    // Add a few photos to special folders
    if (folderName == 'Screenshots') {
      for (int i = 0; i < 3; i++) {
        final screenshotDate = DateTime.now().subtract(Duration(days: i * 30));
        final filename =
            'Screenshot_${screenshotDate.year}-${screenshotDate.month.toString().padLeft(2, '0')}-${screenshotDate.day.toString().padLeft(2, '0')}-${screenshotDate.hour.toString().padLeft(2, '0')}-${screenshotDate.minute.toString().padLeft(2, '0')}-${screenshotDate.second.toString().padLeft(2, '0')}_com.example.app.jpg';
        final photoPath = path.join(specialDir.path, filename);
        final photoFile = File(photoPath);
        photoFile.writeAsBytesSync(
          base64.decode(greenImgNoMetaDataBase64.replaceAll('\n', '')),
          flush: true,
        );
        createdEntities.add(photoFile); // Create JSON metadata
        final jsonFile = File('$photoPath.json');
        jsonFile.writeAsStringSync(
          jsonEncode({
            'title': filename,
            'description': 'Screenshot from mobile device',
            'imageViews': '1',
            'creationTime': {
              'timestamp':
                  '${(screenshotDate.millisecondsSinceEpoch / 1000).floor()}',
              'formatted':
                  '${screenshotDate.day.toString().padLeft(2, '0')}.${screenshotDate.month.toString().padLeft(2, '0')}.${screenshotDate.year}, ${screenshotDate.hour.toString().padLeft(2, '0')}:${screenshotDate.minute.toString().padLeft(2, '0')}:${screenshotDate.second.toString().padLeft(2, '0')} UTC',
            },
            'photoTakenTime': {
              'timestamp':
                  '${(screenshotDate.millisecondsSinceEpoch / 1000).floor()}',
              'formatted':
                  '${screenshotDate.day.toString().padLeft(2, '0')}.${screenshotDate.month.toString().padLeft(2, '0')}.${screenshotDate.year}, ${screenshotDate.hour.toString().padLeft(2, '0')}:${screenshotDate.minute.toString().padLeft(2, '0')}:${screenshotDate.second.toString().padLeft(2, '0')} UTC',
            },
            'archived': false,
            'url':
                'https://photos.google.com/photo/screenshot_${DateTime.now().millisecondsSinceEpoch}_$i',
            'googlePhotosOrigin': {
              'mobileUpload': {'deviceType': 'ANDROID_PHONE'},
            },
          }),
          flush: true,
        );
        createdEntities.add(jsonFile);
      }
    }
  }

  print('Generated realistic dataset at: $basePath');
  print('Created ${createdPhotos.length} photos across $yearSpan years');
  print(
    'Created ${selectedAlbums.length} albums: ${selectedAlbums.join(', ')}',
  );
  print('Created $albumOnlyPhotos album-only photos');
  print('${(exifRatio * 100).round()}% of photos have EXIF data');
  print('Total files created: ${createdEntities.length}');
}

/// Clean up all leftover fixture directories
///
/// This function finds and removes any leftover fixture directories that
/// might have been created by tests but not properly cleaned up.
/// Should be called periodically to maintain test environment cleanliness.
Future<void> cleanupAllFixtures() async {
  final testDir = Directory('test');
  if (!await testDir.exists()) return;

  final generatedDir = Directory(path.join(testDir.path, 'generated'));
  if (!await generatedDir.exists()) return;

  // Fast-path cleanup: remove the entire generated tree in one operation.
  // This avoids long per-fixture recursive deletions that can exceed test timeouts.
  try {
    if (Platform.isWindows) {
      await Process.run('cmd', ['/c', 'rmdir', '/s', '/q', generatedDir.path]);
    } else {
      await Process.run('rm', ['-rf', generatedDir.path]);
    }
  } catch (_) {
    // Fall back to Dart recursive delete if shell command fails.
    try {
      await generatedDir.delete(recursive: true);
    } catch (_) {
      // Best effort cleanup: ignore failures to keep tearDown deterministic.
    }
  }

  // Recreate the generated folder to keep tests that assume it exists stable.
  try {
    await generatedDir.create(recursive: true);
  } catch (_) {}
}
