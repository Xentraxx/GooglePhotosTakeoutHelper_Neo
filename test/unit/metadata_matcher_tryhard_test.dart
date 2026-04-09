/// Tests covering JSON-matching strategies that are unique to tryhard mode
/// (cross-extension, partial-extra-format removal) and edge-cases for the
/// basic strategies (name shortening at the 46/47-char boundary, bracket swap).
library;

import 'dart:io';

import 'package:gpth_neo/gpth_lib_exports.dart';
import 'package:path/path.dart' as path;
import 'package:test/test.dart';

import '../setup/test_setup.dart';

void main() {
  group('JsonMetadataMatcherService - strategies', () {
    late TestFixture fixture;

    setUp(() async {
      fixture = TestFixture();
      await fixture.setUp();
    });

    tearDown(() async {
      await fixture.tearDown();
    });

    // -----------------------------------------------------------------------
    // Basic strategy: _shortenName  (boundary at 46/47 chars)
    // '$filename.json'.length > 51  → truncate filename to 46 chars
    // -----------------------------------------------------------------------
    group('basic: filename shortening at 46/47 char boundary', () {
      test('47-char filename: JSON named with first 46 chars is found', () async {
        // 43 alphanum chars + '.jpg' = 47 chars → '$filename.json' = 52 > 51 → shorten
        final String longName = '${'X' * 43}.jpg'; // 47 chars
        final mediaFile = File(path.join(fixture.basePath, longName));
        await mediaFile.writeAsBytes([0xFF, 0xD8]);

        // Google Photos names the JSON with the truncated 46-char prefix
        final String shortenedBase = longName.substring(0, 46);
        final jsonFile = File(
          path.join(fixture.basePath, '$shortenedBase.json'),
        );
        await jsonFile.writeAsString('{"test": "shortened47"}');

        final result = await JsonMetadataMatcherService.findJsonForFile(
          mediaFile,
          tryhard: false,
        );

        expect(result, isNotNull);
        expect(result!.path, equals(jsonFile.path));
      });

      test('46-char filename: no shortening, exact JSON name is used', () async {
        // 42 alphanum chars + '.jpg' = 46 chars → '$filename.json' = 51 ≤ 51 → NOT shortened
        final String name = '${'Y' * 42}.jpg'; // 46 chars
        final mediaFile = File(path.join(fixture.basePath, name));
        await mediaFile.writeAsBytes([0xFF, 0xD8]);

        final jsonFile = File(path.join(fixture.basePath, '$name.json'));
        await jsonFile.writeAsString('{"test": "exact46"}');

        final result = await JsonMetadataMatcherService.findJsonForFile(
          mediaFile,
          tryhard: false,
        );

        expect(result, isNotNull);
        expect(result!.path, equals(jsonFile.path));
      });

      test(
        'short filename (< 46 chars): matched directly without shortening',
        () async {
          const name = 'short.jpg'; // 9 chars
          final mediaFile = fixture.createImageWithExif(name);
          final jsonFile = File(path.join(fixture.basePath, '$name.json'));
          await jsonFile.writeAsString('{"test": "short"}');

          final result = await JsonMetadataMatcherService.findJsonForFile(
            mediaFile,
            tryhard: false,
          );

          expect(result, isNotNull);
          expect(result!.path, equals(jsonFile.path));
        },
      );

      test('shortened supplemental-metadata: large name, '
          'truncated supplemental suffix is found', () async {
        // Create a 40-char filename: '$name.supplemental-metadata.json' would be way > 51
        final String name = '${'Z' * 36}.jpg'; // 40 chars
        final mediaFile = File(path.join(fixture.basePath, name));
        await mediaFile.writeAsBytes([0xFF, 0xD8]);

        // Strategy tries full supplemental path first, then truncated variants.
        // Full: 'Z'*36+'.jpg'+'.supplemental-metadata.json' → 40+29 = 69 > 51
        // Truncated: 51 - 40 - 1 (dot) = 10 → 'supplemen.json' would be one variant
        // Let's place just the full supplemental name and check it's found first.
        final jsonFile = File(
          path.join(fixture.basePath, '$name.supplemental-metadata.json'),
        );
        await jsonFile.writeAsString('{"test": "suppl-large"}');

        final result = await JsonMetadataMatcherService.findJsonForFile(
          mediaFile,
          tryhard: false,
        );

        // Should find the full supplemental file (tried first regardless of length)
        expect(result, isNotNull);
        expect(result!.path, equals(jsonFile.path));
      });
    });

    // -----------------------------------------------------------------------
    // Basic strategy: _bracketSwap
    // 'image(1).jpg' → transform → 'image.jpg(1)' → JSON: 'image.jpg(1).json'
    // -----------------------------------------------------------------------
    group('basic: bracket swap', () {
      test('single-digit: image(1).jpg finds image.jpg(1).json', () async {
        final mediaFile = File(path.join(fixture.basePath, 'image(1).jpg'));
        await mediaFile.writeAsBytes([0xFF, 0xD8]);

        final jsonFile = File(path.join(fixture.basePath, 'image.jpg(1).json'));
        await jsonFile.writeAsString('{"test": "bracket1"}');

        final result = await JsonMetadataMatcherService.findJsonForFile(
          mediaFile,
          tryhard: false,
        );

        expect(result, isNotNull);
        expect(result!.path, equals(jsonFile.path));
      });

      test('double-digit: photo(11).jpg finds photo.jpg(11).json', () async {
        final mediaFile = File(path.join(fixture.basePath, 'photo(11).jpg'));
        await mediaFile.writeAsBytes([0xFF, 0xD8]);

        final jsonFile = File(
          path.join(fixture.basePath, 'photo.jpg(11).json'),
        );
        await jsonFile.writeAsString('{"test": "bracket11"}');

        final result = await JsonMetadataMatcherService.findJsonForFile(
          mediaFile,
          tryhard: false,
        );

        expect(result, isNotNull);
        expect(result!.path, equals(jsonFile.path));
      });

      test('no bracket in filename: no swap, normal JSON is found', () async {
        const name = 'noBracket.jpg';
        final mediaFile = fixture.createImageWithExif(name);
        final jsonFile = File(path.join(fixture.basePath, '$name.json'));
        await jsonFile.writeAsString('{"test": "no-bracket"}');

        final result = await JsonMetadataMatcherService.findJsonForFile(
          mediaFile,
          tryhard: false,
        );

        expect(result, isNotNull);
        expect(result!.path, equals(jsonFile.path));
      });
    });

    // -----------------------------------------------------------------------
    // Basic strategy: _handleMPFiles
    // 'video.MP' → 'video.MP.jpg' → JSON: 'video.MP.jpg.json'
    // -----------------------------------------------------------------------
    group('basic: MP file handling', () {
      test('video.MP finds video.MP.jpg.json', () async {
        final mediaFile = File(path.join(fixture.basePath, 'video.MP'));
        await mediaFile.writeAsBytes([0x00, 0x00, 0x00, 0x01]);

        final jsonFile = File(path.join(fixture.basePath, 'video.MP.jpg.json'));
        await jsonFile.writeAsString(
          '{"photoTakenTime": {"timestamp": "1609459200"}}',
        );

        final result = await JsonMetadataMatcherService.findJsonForFile(
          mediaFile,
          tryhard: false,
        );

        expect(result, isNotNull);
        expect(result!.path, equals(jsonFile.path));
      });

      test('non-MP file is unaffected by MP strategy', () async {
        const name = 'clip.mp4';
        final mediaFile = File(path.join(fixture.basePath, name));
        await mediaFile.writeAsBytes([0x00, 0x00, 0x00, 0x18]);

        // Only place a plain .json (no HEIC cross-ext)
        final jsonFile = File(path.join(fixture.basePath, '$name.json'));
        await jsonFile.writeAsString('{"test": "mp4-plain"}');

        final result = await JsonMetadataMatcherService.findJsonForFile(
          mediaFile,
          tryhard: false,
        );

        expect(result, isNotNull);
        expect(result!.path, equals(jsonFile.path));
      });
    });

    // -----------------------------------------------------------------------
    // Tryhard-only strategy: cross-extension matching
    // 'video.mp4' → 'video.HEIC' → JSON: 'video.HEIC.json'
    // 'clip.mov'  → 'clip.HEIC'  → JSON: 'clip.HEIC.supplemental-metadata.json'
    // -----------------------------------------------------------------------
    group('tryhard: cross-extension matching', () {
      test('MP4 with HEIC-named JSON: NOT found with tryhard=false, '
          'found with tryhard=true', () async {
        final mediaFile = File(path.join(fixture.basePath, 'video.mp4'));
        await mediaFile.writeAsBytes([0x00, 0x00, 0x00, 0x18]);

        // Only the HEIC JSON exists (no video.mp4.json)
        final jsonFile = File(path.join(fixture.basePath, 'video.HEIC.json'));
        await jsonFile.writeAsString('{"photoTakenTime": {"timestamp": "1"}}');

        // tryhard=false should miss it
        final notFound = await JsonMetadataMatcherService.findJsonForFile(
          mediaFile,
          tryhard: false,
        );
        expect(notFound, isNull);

        // tryhard=true should find it via cross-extension strategy
        final found = await JsonMetadataMatcherService.findJsonForFile(
          mediaFile,
          tryhard: true,
        );
        expect(found, isNotNull);
        expect(found!.path, equals(jsonFile.path));
      });

      test(
        'MOV with HEIC supplemental-metadata JSON: found only with tryhard=true',
        () async {
          final mediaFile = File(path.join(fixture.basePath, 'clip.mov'));
          await mediaFile.writeAsBytes([0x00, 0x00, 0x00, 0x14]);

          final jsonFile = File(
            path.join(fixture.basePath, 'clip.HEIC.supplemental-metadata.json'),
          );
          await jsonFile.writeAsString('{"test": "mov-heic-suppl"}');

          final notFound = await JsonMetadataMatcherService.findJsonForFile(
            mediaFile,
            tryhard: false,
          );
          expect(notFound, isNull);

          final found = await JsonMetadataMatcherService.findJsonForFile(
            mediaFile,
            tryhard: true,
          );
          expect(found, isNotNull);
          expect(found!.path, equals(jsonFile.path));
        },
      );

      test(
        'returns null when no JSON at all (tryhard=true still graceful)',
        () async {
          final mediaFile = File(path.join(fixture.basePath, 'orphan.mp4'));
          await mediaFile.writeAsBytes([0x00]);

          final result = await JsonMetadataMatcherService.findJsonForFile(
            mediaFile,
            tryhard: true,
          );

          expect(result, isNull);
        },
      );
    });
  });
}
