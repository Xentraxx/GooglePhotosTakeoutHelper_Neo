/// End-to-end tests for Issue #133: Google Photos Takeout album folders that
/// contain only JSON sidecars (the asset was deduplicated into a year
/// folder) must still end up represented in the album's output, in
/// whatever form the chosen --albums mode uses.
///
/// test/unit/issue_133_orphan_album_json_test.dart already covers discovery
/// (Step 2) recovering the album *association*; these tests drive the full
/// pipeline (through Step 6 moving) to confirm each moving strategy
/// actually materializes that association into something the user sees on
/// disk: a link (shortcut/reverse-shortcut), a real copy (duplicate-copy),
/// or a JSON entry (json) -- and that json mode does not also leave a
/// stray physical file in the album folder.
// ignore_for_file: avoid_redundant_argument_values
@Timeout(Duration(seconds: 120))
library;

import 'dart:convert';
import 'dart:io';

import 'package:gpth_neo/gpth_lib_exports.dart';
import 'package:path/path.dart' as path;
import 'package:test/test.dart';

import '../setup/test_setup.dart';

void main() {
  group('E2E Issue #133: orphan album recovery materializes on disk', () {
    late TestFixture fixture;
    late ProcessingPipeline pipeline;
    late String outputPath;

    setUpAll(() async {
      await ServiceContainer.instance.initialize();
    });

    setUp(() async {
      fixture = TestFixture();
      await fixture.setUp();
      pipeline = const ProcessingPipeline();
      outputPath = path.join(fixture.basePath, 'output_${uniqueTestId()}');
      await Directory(outputPath).create(recursive: true);
    });

    tearDown(() async {
      await fixture.tearDown();
    });

    tearDownAll(() async {
      await ServiceContainer.instance.dispose();
      await ServiceContainer.reset();
      await cleanupAllFixtures();
    });

    /// Builds a Takeout tree with a photo that lives only in the year folder
    /// plus one album folder per name in [albumNames], each containing only
    /// an orphaned sidecar for it (the asset itself was deduplicated away by
    /// Takeout, per issue #133).
    String buildOrphanAlbumTakeout({
      required final List<String> albumNames,
      final String photoBasename = 'orphan.jpg',
    }) {
      final takeoutDir = fixture.createDirectory('Takeout_${uniqueTestId()}');
      final googlePhotosDir = fixture.createDirectory(
        path.join(takeoutDir.path, 'Google Photos'),
      );
      final yearDir = fixture.createDirectory(
        path.join(googlePhotosDir.path, 'Photos from 2023'),
      );

      fixture.createImageWithExifInDir(yearDir.path, photoBasename);
      fixture.createFile(
        path.join(yearDir.path, '$photoBasename.json'),
        utf8.encode(
          jsonEncode({
            'title': photoBasename,
            'photoTakenTime': {'timestamp': '1687110000'},
          }),
        ),
      );

      for (final albumName in albumNames) {
        fixture.createFile(
          path.join(
            googlePhotosDir.path,
            albumName,
            '$photoBasename.supplemental-metadata.json',
          ),
          utf8.encode(
            jsonEncode({
              'title': photoBasename,
              'photoTakenTime': {'timestamp': '1687110000'},
            }),
          ),
        );
      }

      return PathResolverService.resolveGooglePhotosPath(takeoutDir.path);
    }

    Future<File?> findFile(final Directory dir, final String basename) async {
      if (!await dir.exists()) return null;
      await for (final e in dir.list()) {
        if (e is File && path.basename(e.path) == basename) return e;
      }
      return null;
    }

    bool bytesEqual(final List<int> a, final List<int> b) {
      if (a.length != b.length) return false;
      for (var i = 0; i < a.length; i++) {
        if (a[i] != b[i]) return false;
      }
      return true;
    }

    test(
      'shortcut mode materializes the orphan album with a link to ALL_PHOTOS',
      () async {
        final googlePhotosPath = buildOrphanAlbumTakeout(
          albumNames: ['Vacation'],
        );
        final config = ProcessingConfig(
          inputPath: googlePhotosPath,
          outputPath: outputPath,
          albumBehavior: AlbumBehavior.shortcut,
          dateDivision: DateDivisionLevel.none,
          writeExif: false,
        );

        final result = await pipeline.execute(
          config: config,
          inputDirectory: Directory(googlePhotosPath),
          outputDirectory: Directory(outputPath),
        );
        expect(result.isSuccess, isTrue);

        final allPhotosFile = await findFile(
          Directory(path.join(outputPath, 'ALL_PHOTOS')),
          'orphan.jpg',
        );
        expect(
          allPhotosFile,
          isNotNull,
          reason: 'the orphan asset should still be moved to ALL_PHOTOS',
        );

        final albumDir = Directory(path.join(outputPath, 'Albums', 'Vacation'));
        final albumFile = await findFile(albumDir, 'orphan.jpg');
        expect(
          albumFile,
          isNotNull,
          reason:
              'recovered orphan album membership should materialize as a '
              'link inside the album folder (issue #133)',
        );

        expect(
          bytesEqual(
            await albumFile!.readAsBytes(),
            await allPhotosFile!.readAsBytes(),
          ),
          isTrue,
          reason: 'album link must resolve to the same content as ALL_PHOTOS',
        );
      },
    );

    test(
      'reverse-shortcut mode materializes the orphan album with a link to ALL_PHOTOS',
      () async {
        final googlePhotosPath = buildOrphanAlbumTakeout(
          albumNames: ['Vacation'],
        );
        final config = ProcessingConfig(
          inputPath: googlePhotosPath,
          outputPath: outputPath,
          albumBehavior: AlbumBehavior.reverseShortcut,
          dateDivision: DateDivisionLevel.none,
          writeExif: false,
        );

        final result = await pipeline.execute(
          config: config,
          inputDirectory: Directory(googlePhotosPath),
          outputDirectory: Directory(outputPath),
        );
        expect(result.isSuccess, isTrue);

        final allPhotosFile = await findFile(
          Directory(path.join(outputPath, 'ALL_PHOTOS')),
          'orphan.jpg',
        );
        expect(allPhotosFile, isNotNull);

        final albumDir = Directory(path.join(outputPath, 'Albums', 'Vacation'));
        final albumFile = await findFile(albumDir, 'orphan.jpg');
        expect(
          albumFile,
          isNotNull,
          reason:
              'recovered orphan album membership should materialize as a '
              'link inside the album folder (issue #133)',
        );
        expect(
          bytesEqual(
            await albumFile!.readAsBytes(),
            await allPhotosFile!.readAsBytes(),
          ),
          isTrue,
        );
      },
    );

    test(
      'duplicate-copy mode materializes the orphan album with a real file copy',
      () async {
        final googlePhotosPath = buildOrphanAlbumTakeout(
          albumNames: ['Vacation'],
        );
        final config = ProcessingConfig(
          inputPath: googlePhotosPath,
          outputPath: outputPath,
          albumBehavior: AlbumBehavior.duplicateCopy,
          dateDivision: DateDivisionLevel.none,
          writeExif: false,
        );

        final result = await pipeline.execute(
          config: config,
          inputDirectory: Directory(googlePhotosPath),
          outputDirectory: Directory(outputPath),
        );
        expect(result.isSuccess, isTrue);

        final allPhotosFile = await findFile(
          Directory(path.join(outputPath, 'ALL_PHOTOS')),
          'orphan.jpg',
        );
        expect(allPhotosFile, isNotNull);

        final albumDir = Directory(path.join(outputPath, 'Albums', 'Vacation'));
        final albumFile = await findFile(albumDir, 'orphan.jpg');
        expect(
          albumFile,
          isNotNull,
          reason:
              'recovered orphan album membership should materialize as a '
              'real copy inside the album folder (issue #133)',
        );
        expect(
          bytesEqual(
            await albumFile!.readAsBytes(),
            await allPhotosFile!.readAsBytes(),
          ),
          isTrue,
        );
      },
    );

    test(
      'json mode records the orphan album membership without a stray file',
      () async {
        final googlePhotosPath = buildOrphanAlbumTakeout(
          albumNames: ['Vacation'],
        );
        final config = ProcessingConfig(
          inputPath: googlePhotosPath,
          outputPath: outputPath,
          albumBehavior: AlbumBehavior.json,
          dateDivision: DateDivisionLevel.none,
          writeExif: false,
        );

        final result = await pipeline.execute(
          config: config,
          inputDirectory: Directory(googlePhotosPath),
          outputDirectory: Directory(outputPath),
        );
        expect(result.isSuccess, isTrue);

        final albumsInfoFile = File(path.join(outputPath, 'albums-info.json'));
        expect(await albumsInfoFile.exists(), isTrue);

        final payload =
            jsonDecode(await albumsInfoFile.readAsString())
                as Map<String, dynamic>;
        final albums = payload['albums'] as Map<String, dynamic>;
        expect(
          albums.keys,
          contains('Vacation'),
          reason:
              'recovered orphan album membership must be recorded in '
              'albums-info.json (issue #133)',
        );
        final entries = albums['Vacation'] as List<dynamic>;
        expect(
          entries.any((final e) => (e as Map)['fileName'] == 'orphan.jpg'),
          isTrue,
          reason:
              'the recovered orphan file name should appear in the album entry',
        );

        // JSON mode must not also drop a physical file into the album folder.
        final albumDir = Directory(path.join(outputPath, 'Albums', 'Vacation'));
        final strayFile = await findFile(albumDir, 'orphan.jpg');
        expect(
          strayFile,
          isNull,
          reason:
              'json mode should not materialize a physical file in the album folder',
        );
      },
    );

    test(
      'the same orphaned asset is recovered into every album that references it',
      () async {
        final googlePhotosPath = buildOrphanAlbumTakeout(
          albumNames: ['Vacation', 'Highlights'],
        );
        final config = ProcessingConfig(
          inputPath: googlePhotosPath,
          outputPath: outputPath,
          albumBehavior: AlbumBehavior.shortcut,
          dateDivision: DateDivisionLevel.none,
          writeExif: false,
        );

        final result = await pipeline.execute(
          config: config,
          inputDirectory: Directory(googlePhotosPath),
          outputDirectory: Directory(outputPath),
        );
        expect(result.isSuccess, isTrue);

        for (final albumName in ['Vacation', 'Highlights']) {
          final albumDir = Directory(
            path.join(outputPath, 'Albums', albumName),
          );
          final albumFile = await findFile(albumDir, 'orphan.jpg');
          expect(
            albumFile,
            isNotNull,
            reason: 'album "$albumName" should also recover the orphan asset',
          );
        }
      },
    );
  });
}
