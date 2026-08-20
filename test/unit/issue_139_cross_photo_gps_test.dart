/// Tests for Issue #139: GPS coordinates from an *unrelated* photo written to EXIF.
///
/// Root cause under investigation:
/// When a media file's *own* sidecar is missing, `JsonMetadataMatcherService`
/// falls back to aggressive strategies (`-edited` removal, cross-extension,
/// numbered patterns) that can match a *different photo's* sidecar. Because
/// `extractAllFromJson` returns BOTH date and GPS from the same matched JSON,
/// the wrong photo's GPS gets written — the exact symptom in issue #139.
///
/// For dates this cross-photo fallback is an acceptable heuristic (related
/// photos are usually close in time), but for GPS it writes another photo's
/// location, which can differ by hundreds of kilometers.
///
/// The bug is suspected to have been introduced (or amplified) by the fix for
/// issue #133, which added the cross-extension / numbered matching tiers in
/// `_tryNumberedJsonFiles`.
library;

import 'dart:convert';
import 'dart:io';

import 'package:gpth_neo/gpth_lib_exports.dart';
import 'package:path/path.dart' as path;
import 'package:test/test.dart';

import '../setup/test_setup.dart';

void main() {
  group('Issue #139: cross-photo GPS via aggressive JSON matching', () {
    late TestFixture fixture;

    setUp(() async {
      fixture = TestFixture();
      await fixture.setUp();
    });

    tearDown(() async {
      await fixture.tearDown();
    });

    /// Writes a sidecar JSON with a distinct, recognizable GPS coordinate so
    /// that a mismatch is unambiguous in assertions.
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

    group('extractAllFromJson refuses cross-photo sidecars (fix #139)', () {
      // ---------------------------------------------------------------------
      // Scenario A: `-edited` removal (basic strategy, NOT tryhard).
      // `photo-edited.jpg` has NO own sidecar. Strategy 5 strips `-edited`
      // and matches `photo.jpg`'s sidecar — a different photo.
      // ---------------------------------------------------------------------
      test(
        'A. `-edited` removal: date AND GPS dropped (not borrowed)',
        () async {
          // Two distinct photos in the same folder. The original is created so
          // its sidecar exists on disk; the edited version is the file under
          // test (it has no own sidecar).
          fixture.createImageWithExif('photo.jpg');
          final edited = fixture.createImageWithExif('photo-edited.jpg');

          // ONLY the original has a sidecar. The edited version has none.
          // GPS = (41.0, 19.0) — the original's real location.
          final originalSidecar = writeSidecar(
            'photo.jpg.supplemental-metadata.json',
            lat: 41.0,
            lon: 19.0,
            photoTakenTimestamp: '1700000000',
          );

          // Basic mode (default tryhard=false): strategy 5 strips `-edited`.
          final result = await extractAllFromJson(edited);

          // FIX: the edited photo must NOT borrow the original's date or GPS.
          // A related photo's date is not acceptable (issue #139).
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

          // The matcher still FINDS the cross-photo sidecar (heuristic matching
          // is preserved for album recovery / Step 1), but flags it as not
          // own-sidecar so extractAllFromJson can refuse it.
          final match =
              await JsonMetadataMatcherService.findJsonForFileWithConfidence(
                edited,
                tryhard: false,
              );
          expect(match.jsonFile?.path, equals(originalSidecar.path));
          expect(match.isOwnSidecar, isFalse);
        },
      );

      // ---------------------------------------------------------------------
      // Scenario B: cross-extension matching (tryhard only).
      // `IMG_2367.MP4` has NO own sidecar. Strategy 7 swaps .MP4 → .HEIC
      // and matches `IMG_2367.HEIC`'s sidecar — a different photo.
      // ---------------------------------------------------------------------
      test('B. cross-extension: date AND GPS dropped (not borrowed)', () async {
        final video = File(path.join(fixture.basePath, 'IMG_2367.MP4'));
        await video.writeAsBytes([0x00, 0x00, 0x00, 0x20]); // dummy MP4
        // The HEIC photo is created so its sidecar exists on disk; the MP4
        // is the file under test (it has no own sidecar).
        fixture.createImageWithExif('IMG_2367.HEIC');

        // ONLY the HEIC has a sidecar. The MP4 has none.
        // GPS = (48.0, 2.0) — Paris, the HEIC photo's real location.
        final heicSidecar = writeSidecar(
          'IMG_2367.HEIC.supplemental-metadata.json',
          lat: 48.0,
          lon: 2.0,
          photoTakenTimestamp: '1700000000',
        );

        // tryhard=true: strategy 7 (cross-extension) kicks in.
        final result = await extractAllFromJson(video, tryhard: true);

        // FIX: the MP4 must NOT borrow the HEIC photo's date or GPS.
        // (This was the mis-dated-video symptom from issue #139 comments.)
        expect(
          result.date,
          isNull,
          reason: 'video must not inherit HEIC photo\'s DateTime',
        );
        expect(
          result.gps,
          isNull,
          reason: 'video must not inherit HEIC photo\'s GPS',
        );

        // The matcher still finds the HEIC sidecar but flags it not-own.
        final match =
            await JsonMetadataMatcherService.findJsonForFileWithConfidence(
              video,
              tryhard: true,
            );
        expect(match.jsonFile?.path, equals(heicSidecar.path));
        expect(match.isOwnSidecar, isFalse);
      });

      // ---------------------------------------------------------------------
      // Scenario C: numbered cross-extension matching (tryhard only).
      // `IMG_1976(1).MP4` has NO own sidecar. The numbered matcher finds
      // `IMG_1976.HEIC.supplemental-metadata(1).json` — a different photo.
      // This is the tier added/extended by the issue #133 fix.
      // ---------------------------------------------------------------------
      test(
        'C. numbered cross-extension: date AND GPS dropped (not borrowed)',
        () async {
          final video = File(path.join(fixture.basePath, 'IMG_1976(1).MP4'));
          await video.writeAsBytes([0x00, 0x00, 0x00, 0x20]); // dummy MP4
          final heicPhoto = fixture.createImageWithExif('IMG_1976(1).HEIC');

          // ONLY the HEIC has a sidecar. The MP4 has none.
          // GPS = (52.0, 13.0) — Berlin, the HEIC photo's real location.
          final heicSidecar = writeSidecar(
            'IMG_1976.HEIC.supplemental-metadata(1).json',
            lat: 52.0,
            lon: 13.0,
            photoTakenTimestamp: '1700000000',
          );

          // tryhard=true: numbered cross-extension tier matches.
          final result = await extractAllFromJson(video, tryhard: true);

          // FIX: the MP4 must NOT borrow the HEIC photo's date or GPS.
          expect(
            result.date,
            isNull,
            reason: 'video must not inherit HEIC photo\'s DateTime via number',
          );
          expect(
            result.gps,
            isNull,
            reason: 'video must not inherit HEIC photo\'s GPS via number',
          );

          // The matcher still finds the cross-photo sidecar but flags it not-own.
          final match =
              await JsonMetadataMatcherService.findJsonForFileWithConfidence(
                video,
                tryhard: true,
              );
          expect(match.jsonFile?.path, equals(heicSidecar.path));
          expect(match.isOwnSidecar, isFalse);

          // Sanity: the HEIC photo itself resolves to the SAME sidecar, but as
          // its OWN sidecar (so it still gets its own date+GPS).
          final heicMatch =
              await JsonMetadataMatcherService.findJsonForFileWithConfidence(
                heicPhoto,
                tryhard: true,
              );
          expect(heicMatch.jsonFile?.path, equals(heicSidecar.path));
          expect(heicMatch.isOwnSidecar, isTrue);
        },
      );
    });

    group('own sidecar present: GPS is correct (regression guard)', () {
      test('direct supplemental-metadata sidecar yields own GPS', () async {
        final photo = fixture.createImageWithExif('mine.jpg');
        writeSidecar(
          'mine.jpg.supplemental-metadata.json',
          lat: 37.0,
          lon: -122.0,
          photoTakenTimestamp: '1700000000',
        );

        final result = await extractAllFromJson(photo);

        expect(result.gps, isNotNull);
        expect(result.date, isNotNull);
      });
    });
  });
}
