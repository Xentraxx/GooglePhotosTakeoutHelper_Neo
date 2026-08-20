/// Unit tests for `findJsonForFileWithConfidence` and the `isOwnSidecar`
/// confidence tier (issue #139).
///
/// The confidence flag distinguishes a media file's *own* sidecar (date+GPS
/// may be trusted) from a heuristic match that can point at a *different*
/// photo's sidecar (date+GPS must be dropped — a related photo's date is not
/// acceptable, per issue #139).
library;

import 'dart:io';

import 'package:gpth_neo/gpth_lib_exports.dart';
import 'package:path/path.dart' as path;
import 'package:test/test.dart';

import '../setup/test_setup.dart';

void main() {
  group('JsonMetadataMatcherService.findJsonForFileWithConfidence', () {
    late TestFixture fixture;

    setUp(() async {
      fixture = TestFixture();
      await fixture.setUp();
    });

    tearDown(() async {
      await fixture.tearDown();
    });

    File writeJson(final String name) {
      final f = File(path.join(fixture.basePath, name));
      f.writeAsStringSync('{"title":"x"}', flush: true);
      return f;
    }

    group('isOwnSidecar == true (own sidecar — date+GPS trusted)', () {
      test('exact supplemental-metadata match', () async {
        final media = fixture.createImageWithExif('photo.jpg');
        final json = writeJson('photo.jpg.supplemental-metadata.json');

        final m =
            await JsonMetadataMatcherService.findJsonForFileWithConfidence(
              media,
              tryhard: false,
            );
        expect(m.jsonFile?.path, equals(json.path));
        expect(m.isOwnSidecar, isTrue);
      });

      test('exact legacy .json match', () async {
        final media = fixture.createImageWithExif('photo.jpg');
        final json = writeJson('photo.jpg.json');

        final m =
            await JsonMetadataMatcherService.findJsonForFileWithConfidence(
              media,
              tryhard: false,
            );
        expect(m.jsonFile?.path, equals(json.path));
        expect(m.isOwnSidecar, isTrue);
      });

      test('filesystem-truncated name (shortening strategy)', () async {
        // 43 alphanum + '.jpg' = 47 chars → '$name.json' = 52 > 51 → shortened
        final longName = '${'X' * 43}.jpg';
        final media = File(path.join(fixture.basePath, longName));
        await media.writeAsBytes([0xFF, 0xD8]);
        final json = writeJson('${longName.substring(0, 46)}.json');

        final m =
            await JsonMetadataMatcherService.findJsonForFileWithConfidence(
              media,
              tryhard: false,
            );
        expect(m.jsonFile?.path, equals(json.path));
        expect(m.isOwnSidecar, isTrue);
      });

      test('bracket-swap match (Takeout (N) repositioning)', () async {
        // image(11).jpg ↔ image.jpg(11).json — same file, Takeout just moved (N)
        final media = fixture.createImageWithExif('image(11).jpg');
        final json = writeJson('image.jpg(11).json');

        final m =
            await JsonMetadataMatcherService.findJsonForFileWithConfidence(
              media,
              tryhard: false,
            );
        expect(m.jsonFile?.path, equals(json.path));
        expect(m.isOwnSidecar, isTrue);
      });

      test('no-extension match (Google added an extension)', () async {
        final media = File(path.join(fixture.basePath, 'noext'));
        await media.writeAsBytes([1, 2, 3]);
        final json = writeJson('noext.json');

        final m =
            await JsonMetadataMatcherService.findJsonForFileWithConfidence(
              media,
              tryhard: false,
            );
        expect(m.jsonFile?.path, equals(json.path));
        expect(m.isOwnSidecar, isTrue);
      });

      test('Pixel .MP → .MP.jpg sidecar (own file)', () async {
        final media = File(path.join(fixture.basePath, 'motion.MP'));
        await media.writeAsBytes([0x00, 0x01]);
        final json = writeJson('motion.MP.jpg.supplemental-metadata.json');

        final m =
            await JsonMetadataMatcherService.findJsonForFileWithConfidence(
              media,
              tryhard: false,
            );
        expect(m.jsonFile?.path, equals(json.path));
        expect(m.isOwnSidecar, isTrue);
      });

      test('numbered same-file match: basename.suffix(N).json', () async {
        // photo(1).jpg ↔ photo.jpg.supplemental-metadata(1).json — same file
        final media = fixture.createImageWithExif('photo(1).jpg');
        final json = writeJson('photo.jpg.supplemental-metadata(1).json');

        final m =
            await JsonMetadataMatcherService.findJsonForFileWithConfidence(
              media,
              tryhard: false,
            );
        expect(m.jsonFile?.path, equals(json.path));
        expect(m.isOwnSidecar, isTrue);
      });

      test('numbered same-file match: basename(N).suffix.json', () async {
        final media = fixture.createImageWithExif('photo(1).jpg');
        final json = writeJson('photo.jpg(1).supplemental-metadata.json');

        final m =
            await JsonMetadataMatcherService.findJsonForFileWithConfidence(
              media,
              tryhard: false,
            );
        expect(m.jsonFile?.path, equals(json.path));
        expect(m.isOwnSidecar, isTrue);
      });
    });

    group('isOwnSidecar == false (heuristic — date+GPS dropped)', () {
      test('`-edited` removal matches the original\'s sidecar', () async {
        fixture.createImageWithExif('photo.jpg'); // original present too
        final edited = fixture.createImageWithExif('photo-edited.jpg');
        final originalJson = writeJson('photo.jpg.supplemental-metadata.json');

        final m =
            await JsonMetadataMatcherService.findJsonForFileWithConfidence(
              edited,
              tryhard: false,
            );
        expect(m.jsonFile?.path, equals(originalJson.path));
        expect(
          m.isOwnSidecar,
          isFalse,
          reason: 'stripping -edited matches a different photo\'s sidecar',
        );
      });

      test('cross-extension MP4 → HEIC sidecar (tryhard)', () async {
        final video = File(path.join(fixture.basePath, 'IMG_2367.MP4'));
        await video.writeAsBytes([0x00, 0x00, 0x00, 0x20]);
        final heicJson = writeJson('IMG_2367.HEIC.supplemental-metadata.json');

        final m =
            await JsonMetadataMatcherService.findJsonForFileWithConfidence(
              video,
              tryhard: true,
            );
        expect(m.jsonFile?.path, equals(heicJson.path));
        expect(
          m.isOwnSidecar,
          isFalse,
          reason: 'cross-extension match is a different photo\'s sidecar',
        );
      });

      test('cross-extension MP4 → JPG sidecar (tryhard)', () async {
        final video = File(path.join(fixture.basePath, 'IMG_4288.MP4'));
        await video.writeAsBytes([0x00, 0x00, 0x00, 0x20]);
        final jpgJson = writeJson('IMG_4288.JPG.supplemental-metadata.json');

        final m =
            await JsonMetadataMatcherService.findJsonForFileWithConfidence(
              video,
              tryhard: true,
            );
        expect(m.jsonFile?.path, equals(jpgJson.path));
        expect(m.isOwnSidecar, isFalse);
      });

      test('numbered cross-extension MP4 → HEIC sidecar (tryhard)', () async {
        final video = File(path.join(fixture.basePath, 'IMG_1976(1).MP4'));
        await video.writeAsBytes([0x00, 0x00, 0x00, 0x20]);
        final heicJson = writeJson(
          'IMG_1976.HEIC.supplemental-metadata(1).json',
        );

        final m =
            await JsonMetadataMatcherService.findJsonForFileWithConfidence(
              video,
              tryhard: true,
            );
        expect(m.jsonFile?.path, equals(heicJson.path));
        expect(
          m.isOwnSidecar,
          isFalse,
          reason: 'numbered cross-extension is a different photo\'s sidecar',
        );
      });

      test(
        'partial `-ed` removal matches the original\'s sidecar (tryhard)',
        () async {
          fixture.createImageWithExif('photo.jpg');
          final edited = fixture.createImageWithExif('photo-ed.jpg');
          final originalJson = writeJson(
            'photo.jpg.supplemental-metadata.json',
          );

          final m =
              await JsonMetadataMatcherService.findJsonForFileWithConfidence(
                edited,
                tryhard: true,
              );
          expect(m.jsonFile?.path, equals(originalJson.path));
          expect(m.isOwnSidecar, isFalse);
        },
      );
    });

    group('no match', () {
      test('returns null jsonFile and isOwnSidecar false', () async {
        final media = fixture.createImageWithExif('lonely.jpg');

        final m =
            await JsonMetadataMatcherService.findJsonForFileWithConfidence(
              media,
              tryhard: true,
            );
        expect(m.jsonFile, isNull);
        expect(m.isOwnSidecar, isFalse);
      });
    });

    group('findJsonForFile wrapper preserves file-only behavior', () {
      test('returns the same file as the confidence method', () async {
        final media = fixture.createImageWithExif('wrap.jpg');
        writeJson('wrap.jpg.supplemental-metadata.json');

        final fileOnly = await JsonMetadataMatcherService.findJsonForFile(
          media,
          tryhard: false,
        );
        final withConf =
            await JsonMetadataMatcherService.findJsonForFileWithConfidence(
              media,
              tryhard: false,
            );
        expect(fileOnly?.path, equals(withConf.jsonFile?.path));
      });
    });
  });
}
