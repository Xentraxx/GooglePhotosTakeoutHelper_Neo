/// Tests for MediaFilesCollection – the legacy value object.
///
/// Covers:
/// - single() creates a null-keyed collection
/// - fromMap() creates from a provided map
/// - withFile() adds entries (null or named album)
/// - withFile() overwrites existing entries
/// - withFile() is immutable (original unchanged)
/// - withFiles() adds multiple entries at once
/// - withoutAlbum() removes a named album
/// - withoutAlbum() removes the null (year-based) entry
/// - withoutAlbum() returns same instance when key not present
/// - getAlbumKey() returns first album name when albums exist
/// - getAlbumKey() returns null for year-only collection
/// - equality: same files produce equal instances
library;

import 'dart:io';

import 'package:gpth_neo/gpth_lib_exports.dart';
import 'package:test/test.dart';

void main() {
  // Use path constants that don't need to exist on disk (value-object tests only)
  final file1 = File('/path/to/photo1.jpg');
  final file2 = File('/path/to/photo2.jpg');
  final file3 = File('/path/to/photo3.jpg');

  group('MediaFilesCollection.single', () {
    test('creates a collection with one null-keyed entry', () {
      final coll = MediaFilesCollection.single(file1);
      expect(coll.length, equals(1));
      expect(coll.firstFile.path, equals(file1.path));
    });

    test('hasYearBasedFiles is true', () {
      expect(MediaFilesCollection.single(file1).hasYearBasedFiles, isTrue);
    });

    test('hasAlbumFiles is false', () {
      expect(MediaFilesCollection.single(file1).hasAlbumFiles, isFalse);
    });

    test('isNotEmpty is true', () {
      expect(MediaFilesCollection.single(file1).isNotEmpty, isTrue);
    });
  });

  group('MediaFilesCollection.fromMap', () {
    test('creates collection from year-only map', () {
      final coll = MediaFilesCollection.fromMap({null: file1});
      expect(coll.length, equals(1));
      expect(coll.hasYearBasedFiles, isTrue);
      expect(coll.hasAlbumFiles, isFalse);
    });

    test('creates collection with both year and album entries', () {
      final coll = MediaFilesCollection.fromMap({
        null: file1,
        'Vacation': file2,
      });
      expect(coll.length, equals(2));
      expect(coll.hasYearBasedFiles, isTrue);
      expect(coll.hasAlbumFiles, isTrue);
      expect(coll.albumNames, contains('Vacation'));
    });

    test('empty map produces empty collection', () {
      final coll = MediaFilesCollection.fromMap({});
      expect(coll.isEmpty, isTrue);
      expect(coll.length, equals(0));
      expect(coll.hasAlbumFiles, isFalse);
      expect(coll.hasYearBasedFiles, isFalse);
    });
  });

  group('MediaFilesCollection.withFile', () {
    test('adds a null (year-based) entry to empty collection', () {
      final coll = MediaFilesCollection.fromMap({});
      final updated = coll.withFile(null, file1);
      expect(updated.length, equals(1));
      expect(updated.hasYearBasedFiles, isTrue);
      expect(updated.getFileForAlbum(null)?.path, equals(file1.path));
    });

    test('adds a named album entry', () {
      final coll = MediaFilesCollection.single(file1);
      final updated = coll.withFile('Summer 2020', file2);
      expect(updated.length, equals(2));
      expect(updated.albumNames, contains('Summer 2020'));
      expect(updated.getFileForAlbum('Summer 2020')?.path, equals(file2.path));
    });

    test('overwrites an existing entry for the same key', () {
      final coll = MediaFilesCollection.single(file1);
      final updated = coll.withFile(null, file2);
      expect(updated.length, equals(1));
      expect(updated.getFileForAlbum(null)?.path, equals(file2.path));
    });

    test('is immutable – original collection is unchanged', () {
      final coll = MediaFilesCollection.single(file1);
      coll.withFile('Album', file2);
      expect(coll.length, equals(1));
      expect(coll.hasAlbumFiles, isFalse);
    });
  });

  group('MediaFilesCollection.withFiles', () {
    test('adds multiple entries at once', () {
      final coll = MediaFilesCollection.fromMap({});
      final updated = coll.withFiles({null: file1, 'Trip': file2});
      expect(updated.length, equals(2));
      expect(updated.hasYearBasedFiles, isTrue);
      expect(updated.albumNames, contains('Trip'));
    });
  });

  group('MediaFilesCollection.withoutAlbum', () {
    test('removes a named album entry', () {
      final coll = MediaFilesCollection.fromMap({
        null: file1,
        'Vacation': file2,
      });
      final updated = coll.withoutAlbum('Vacation');
      expect(updated.length, equals(1));
      expect(updated.albumNames, isNot(contains('Vacation')));
      expect(updated.hasYearBasedFiles, isTrue);
    });

    test('removes the null (year-based) entry', () {
      final coll = MediaFilesCollection.fromMap({
        null: file1,
        'Vacation': file2,
      });
      final updated = coll.withoutAlbum(null);
      expect(updated.length, equals(1));
      expect(updated.hasYearBasedFiles, isFalse);
      expect(updated.albumNames, contains('Vacation'));
    });

    test('returns identical instance when key is not present', () {
      final coll = MediaFilesCollection.single(file1);
      final updated = coll.withoutAlbum('NonExistentAlbum');
      expect(identical(coll, updated), isTrue);
    });
  });

  group('MediaFilesCollection.getAlbumKey', () {
    test('returns album name when albums exist', () {
      final coll = MediaFilesCollection.fromMap({
        null: file1,
        'Vacation': file2,
      });
      expect(coll.getAlbumKey(), equals('Vacation'));
    });

    test('returns null when only year-based files exist', () {
      final coll = MediaFilesCollection.single(file1);
      expect(coll.getAlbumKey(), isNull);
    });

    test('returns null for empty collection', () {
      final coll = MediaFilesCollection.fromMap({});
      expect(coll.getAlbumKey(), isNull);
    });
  });

  group('MediaFilesCollection.getFileForAlbum', () {
    test('returns correct file for a named album', () {
      final coll = MediaFilesCollection.fromMap({'Trip': file3});
      expect(coll.getFileForAlbum('Trip')?.path, equals(file3.path));
    });

    test('returns null for unknown album', () {
      final coll = MediaFilesCollection.single(file1);
      expect(coll.getFileForAlbum('NotAnAlbum'), isNull);
    });
  });

  group('MediaFilesCollection equality', () {
    test('two collections built from the same files are equal', () {
      final coll1 = MediaFilesCollection.fromMap({null: file1});
      final coll2 = MediaFilesCollection.fromMap({null: file1});
      expect(coll1, equals(coll2));
    });

    test('equal collections have the same hash code', () {
      final coll1 = MediaFilesCollection.fromMap({null: file1});
      final coll2 = MediaFilesCollection.fromMap({null: file1});
      expect(coll1.hashCode, equals(coll2.hashCode));
    });

    test('collections with different files are not equal', () {
      final coll1 = MediaFilesCollection.single(file1);
      final coll2 = MediaFilesCollection.single(file2);
      expect(coll1, isNot(equals(coll2)));
    });

    test('collections with different album keys are not equal', () {
      final coll1 = MediaFilesCollection.fromMap({'AlbumA': file1});
      final coll2 = MediaFilesCollection.fromMap({'AlbumB': file1});
      expect(coll1, isNot(equals(coll2)));
    });
  });
}
