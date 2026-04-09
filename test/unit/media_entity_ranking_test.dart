/// Tests for MediaEntity tie-breaker ranking logic.
///
/// The ranking rules (lower rank = higher priority):
/// 1) Year-folder canonical files beat album-folder non-canonical files
/// 2) On tie, shorter basename wins
/// 3) On tie, shorter full path wins
/// 4) Stable tie-breaker by alphabetical path
///
/// After ranking, files in the same folder as a better-ranked file become
/// duplicatesFiles; files in different folders become secondaryFiles.
library;

import 'package:gpth_neo/gpth_lib_exports.dart';
import 'package:test/test.dart';

// ─────────────────────────────────────────────────────────────────────────────
// Helpers – build FileEntity instances with explicit year/album paths
// ─────────────────────────────────────────────────────────────────────────────

FileEntity inYear(final String filename, {final String year = '2020'}) =>
    FileEntity(sourcePath: '/Takeout/Photos from $year/$filename');

FileEntity inYearDir(final String filename, {final String year = '2020'}) =>
    FileEntity(sourcePath: '/Takeout/$year/$filename');

FileEntity inAlbum(final String filename, {final String album = 'Vacation'}) =>
    FileEntity(sourcePath: '/Takeout/$album/$filename');

// ─────────────────────────────────────────────────────────────────────────────
// Tests
// ─────────────────────────────────────────────────────────────────────────────

void main() {
  group('MediaEntity ranking – rule 1: year folder beats album folder', () {
    test(
      'year-folder file becomes primary when album file is provided first',
      () {
        final yearFile = inYear('photo.jpg');
        final albumFile = inAlbum('photo.jpg');

        final entity = MediaEntity(
          primaryFile: albumFile, // album provided first
          secondaryFiles: [yearFile],
        );

        expect(entity.primaryFile.sourcePath, contains('Photos from'));
        expect(entity.secondaryFiles.first.sourcePath, contains('Vacation'));
      },
    );

    test('pure 4-digit year directory is treated as canonical', () {
      final yearDirFile = inYearDir('photo.jpg');
      final albumFile = inAlbum('photo.jpg');

      final entity = MediaEntity(
        primaryFile: albumFile,
        secondaryFiles: [yearDirFile],
      );

      expect(entity.primaryFile.sourcePath, contains('2020'));
      expect(entity.primaryFile.isCanonical, isTrue);
    });

    test('year-folder file isCanonical=true', () {
      final yearFile = inYear('photo.jpg');
      final entity = MediaEntity.single(file: yearFile);
      expect(entity.primaryFile.isCanonical, isTrue);
    });

    test('album-folder file isCanonical=false', () {
      final albumFile = inAlbum('photo.jpg');
      final entity = MediaEntity.single(file: albumFile);
      expect(entity.primaryFile.isCanonical, isFalse);
    });
  });

  group('MediaEntity ranking – rule 2: shorter basename wins on tie', () {
    test('shorter name beats longer name in the same year folder', () {
      // Both files are in year-folder (same canonicality tier).
      final shortFile = inYear('a.jpg');
      final longFile = inYear('abcdefg.jpg');

      final entity = MediaEntity(
        primaryFile: longFile, // longer provided first
        secondaryFiles: [shortFile],
      );

      // After normalization, shorter basename should be primary
      expect(entity.primaryFile.sourcePath, endsWith('/a.jpg'));
    });

    test('shorter name beats longer name in the same album folder', () {
      final shortFile = inAlbum('b.jpg');
      final longFile = inAlbum('bcdefghij.jpg');

      final entity = MediaEntity(
        primaryFile: longFile,
        secondaryFiles: [shortFile],
      );

      expect(entity.primaryFile.sourcePath, endsWith('/b.jpg'));
    });
  });

  group('MediaEntity ranking – rule 3: shorter path wins on secondary tie', () {
    test('shorter path wins when basenames have equal length', () {
      // Same basename length, different path depths
      final shortPath = FileEntity(sourcePath: '/a/2020/x.jpg');
      final longPath = FileEntity(
        sourcePath: '/a/very/long/nested/path/2020/x.jpg',
      );

      final entity = MediaEntity(
        primaryFile: longPath,
        secondaryFiles: [shortPath],
      );

      expect(
        entity.primaryFile.sourcePath.length,
        lessThanOrEqualTo(entity.secondaryFiles.first.sourcePath.length),
      );
    });
  });

  group('MediaEntity – same-folder vs cross-folder partitioning', () {
    test('two files in the same folder: better-ranked becomes primary, '
        'worse-ranked goes to duplicatesFiles', () {
      final better = FileEntity(sourcePath: '/Takeout/2020/a.jpg');
      final worse = FileEntity(sourcePath: '/Takeout/2020/abcdefg.jpg');

      final entity = MediaEntity(primaryFile: worse, secondaryFiles: [better]);

      expect(entity.primaryFile.sourcePath, endsWith('/a.jpg'));
      expect(entity.secondaryFiles, isEmpty);
      expect(entity.duplicatesFiles.length, equals(1));
      expect(entity.duplicatesFiles.first.sourcePath, endsWith('/abcdefg.jpg'));
    });

    test('files in different folders: best is primary, other is secondary; '
        'duplicatesFiles is empty', () {
      final yearFile = inYear('photo.jpg');
      final albumFile = inAlbum('photo.jpg');

      final entity = MediaEntity(
        primaryFile: albumFile,
        secondaryFiles: [yearFile],
      );

      expect(entity.primaryFile.sourcePath, contains('Photos from'));
      expect(entity.secondaryFiles.length, equals(1));
      expect(entity.duplicatesFiles, isEmpty);
    });

    test(
      'three files: year > album-short > album-long, correct distribution',
      () {
        final yearFile = inYear('b.jpg'); // canonical, rank 1
        final shortAlbum = inAlbum(
          'c.jpg',
          album: 'A1',
        ); // non-canonical, rank 2
        final longAlbum = inAlbum(
          'cdefghij.jpg',
          album: 'A1',
        ); // same dir as shortAlbum

        final entity = MediaEntity(
          primaryFile: longAlbum,
          secondaryFiles: [yearFile, shortAlbum],
        );

        // Year file must be primary
        expect(entity.primaryFile.sourcePath, contains('Photos from'));
        // shortAlbum is the best in its folder (A1), becomes secondary
        expect(entity.secondaryFiles.length, equals(1));
        expect(entity.secondaryFiles.first.sourcePath, endsWith('/c.jpg'));
        // longAlbum is not best in its folder, becomes duplicate
        expect(entity.duplicatesFiles.length, equals(1));
        expect(
          entity.duplicatesFiles.first.sourcePath,
          endsWith('/cdefghij.jpg'),
        );
      },
    );

    test('single file entity has no secondaries or duplicates', () {
      final entity = MediaEntity.single(file: inYear('solo.jpg'));
      expect(entity.secondaryFiles, isEmpty);
      expect(entity.duplicatesFiles, isEmpty);
    });
  });

  group('MediaEntity – sequential ranking assignment (1..N)', () {
    test('all files in entity receive sequential rankings starting at 1', () {
      final f1 = inYear('a.jpg');
      final f2 = inAlbum('b.jpg', album: 'A1');
      final f3 = inAlbum('c.jpg', album: 'A2');

      final entity = MediaEntity(primaryFile: f3, secondaryFiles: [f1, f2]);

      final allRanks = entity.getAllFiles().map((final f) => f.ranking).toList()
        ..sort();
      expect(
        allRanks,
        equals(List.generate(allRanks.length, (final i) => i + 1)),
      );
    });

    test('primary file always has ranking 1', () {
      final yearFile = inYear('photo.jpg');
      final albumFile = inAlbum('photo.jpg');

      final entity = MediaEntity(
        primaryFile: albumFile,
        secondaryFiles: [yearFile],
      );

      expect(entity.primaryFile.ranking, equals(1));
    });
  });

  group('MediaEntity.mergeWith – ranking across merged entities', () {
    test('merged entity selects the overall best primary', () {
      final yearFile = inYear('photo.jpg');
      final albumFile = inAlbum('photo.jpg');

      final entity1 = MediaEntity.single(file: albumFile);
      final entity2 = MediaEntity.single(file: yearFile);

      final merged = entity1.mergeWith(entity2);
      expect(merged.primaryFile.sourcePath, contains('Photos from'));
    });

    test('merge preserves all files from both entities', () {
      final f1 = inYear('a.jpg');
      final f2 = inAlbum('b.jpg', album: 'Album1');
      final f3 = inAlbum('c.jpg', album: 'Album2');

      final e1 = MediaEntity(primaryFile: f1, secondaryFiles: [f2]);
      final e2 = MediaEntity.single(file: f3);

      final merged = e1.mergeWith(e2);
      expect(merged.totalFilesCount, equals(3));
    });
  });

  group('MediaEntity.withPrimaryFile – forced promotion override', () {
    test('withPrimaryFile promotes a secondary to primary', () {
      final yearFile = inYear('photo.jpg');
      final albumFile = inAlbum('photo.jpg');

      final entity = MediaEntity(
        primaryFile: albumFile,
        secondaryFiles: [yearFile],
      );

      // Force albumFile to be primary (even though year is normally preferred)
      final promoted = entity.withPrimaryFile(albumFile);
      expect(promoted.primaryFile.sourcePath, contains('Vacation'));
    });
  });
}
