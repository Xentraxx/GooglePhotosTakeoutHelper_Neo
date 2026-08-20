/// Integration tests for issue #139: cross-photo date/GPS contamination.
///
/// These tests exercise the JSON-matching + extraction flow (`extractAllFromJson`
/// and `JsonMetadataMatcherService`) against realistic multi-file Takeout
/// folder layouts where a media file's *own* sidecar is missing and an
/// aggressive strategy would otherwise match a *different* photo's sidecar.
///
/// They complement:
/// - test/unit/issue_139_cross_photo_gps_test.dart  (single-file scenarios)
/// - test/unit/metadata_matcher_confidence_test.dart (confidence flag unit tests)
/// - test/e2e/e2e_issue_139_cross_photo_gps_test.dart (full pipeline + EXIF readback)
///
/// The unit tests prove the gate works in isolation; these integration tests
/// prove it holds across mixed folder contents where own-sidecar and
/// cross-photo candidates coexist, and that the right photo still gets its
/// own metadata while the wrong photo gets nothing.
// ignore_for_file: avoid_redundant_argument_values
@Timeout(Duration(seconds: 60))
library;

import 'dart:convert';
import 'dart:io';

import 'package:gpth_neo/gpth_lib_exports.dart';
import 'package:path/path.dart' as path;
import 'package:test/test.dart';

import '../setup/test_setup.dart';

/// Writes a supplemental-metadata sidecar with distinct, recognizable date
/// and GPS so a mismatch is unambiguous in assertions.
File _writeSidecar(
  final String dirPath,
  final String name, {
  required final double lat,
  required final double lon,
  required final String photoTakenTimestamp,
  final String title = 'test',
}) {
  final file = File(path.join(dirPath, name));
  file.createSync(recursive: true);
  file.writeAsStringSync(
    jsonEncode({
      'title': title,
      'photoTakenTime': {'timestamp': photoTakenTimestamp, 'formatted': 'test'},
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
    }),
    flush: true,
  );
  return file;
}

void main() {
  group('Integration Issue #139: cross-photo date/GPS contamination', () {
    late TestFixture fixture;

    setUp(() async {
      fixture = TestFixture();
      await fixture.setUp();
    });

    tearDown(() async {
      await fixture.tearDown();
    });

    group('mixed folder: own-sidecar photo keeps metadata, sibling does not', () {
      // A realistic album/year folder containing:
      //   photo.jpg            + photo.jpg.supplemental-metadata.json   (own)
      //   photo-edited.jpg     (no own sidecar → would match photo.jpg's)
      // Both present. The edited version must NOT borrow the original's
      // date/GPS, while the original keeps its own.
      test(
        '`-edited` sibling does not inherit original\'s date+GPS, original keeps its own',
        () async {
          final dir = fixture.basePath;
          final original = fixture.createImageWithExif('photo.jpg');
          final edited = fixture.createImageWithExif('photo-edited.jpg');

          // Original's sidecar: Paris, 2023-06-18.
          _writeSidecar(
            dir,
            'photo.jpg.supplemental-metadata.json',
            lat: 48.8566,
            lon: 2.3522,
            photoTakenTimestamp: '1687110000', // 2023-06-18 17:40:00 UTC
            title: 'photo.jpg',
          );

          // Original: own sidecar → keeps date + GPS.
          final originalResult = await extractAllFromJson(original);
          expect(originalResult.date, isNotNull);
          expect(
            originalResult.date,
            equals(
              DateTime.fromMillisecondsSinceEpoch(
                1687110000 * 1000,
                isUtc: true,
              ),
            ),
          );
          expect(originalResult.gps, isNotNull);

          // Edited: no own sidecar; `-edited` removal would match the
          // original's sidecar → must yield NEITHER date nor GPS.
          final editedResult = await extractAllFromJson(edited);
          expect(
            editedResult.date,
            isNull,
            reason: 'edited must not borrow original\'s DateTime',
          );
          expect(
            editedResult.gps,
            isNull,
            reason: 'edited must not borrow original\'s GPS',
          );
        },
      );

      // A folder with a Live-Photo-style pair where only the HEIC has a
      // sidecar. The MP4 companion must not borrow the HEIC's metadata.
      test(
        'MP4 companion does not inherit HEIC still\'s date+GPS via cross-extension',
        () async {
          final dir = fixture.basePath;
          final heic = fixture.createImageWithExif('IMG_2367.HEIC');
          final mp4 = File(path.join(dir, 'IMG_2367.MP4'));
          await mp4.writeAsBytes([0x00, 0x00, 0x00, 0x20]); // dummy MP4

          // HEIC's sidecar: Berlin, 2023-01-01.
          _writeSidecar(
            dir,
            'IMG_2367.HEIC.supplemental-metadata.json',
            lat: 52.52,
            lon: 13.405,
            photoTakenTimestamp: '1672531200', // 2023-01-01 00:00:00 UTC
            title: 'IMG_2367.HEIC',
          );

          // HEIC: own sidecar → keeps date + GPS.
          final heicResult = await extractAllFromJson(heic, tryhard: true);
          expect(heicResult.date, isNotNull);
          expect(
            heicResult.date,
            equals(
              DateTime.fromMillisecondsSinceEpoch(
                1672531200 * 1000,
                isUtc: true,
              ),
            ),
          );
          expect(heicResult.gps, isNotNull);

          // MP4: no own sidecar; cross-extension would match HEIC's sidecar
          // → must yield NEITHER date nor GPS (tryhard).
          final mp4Result = await extractAllFromJson(mp4, tryhard: true);
          expect(
            mp4Result.date,
            isNull,
            reason: 'MP4 must not borrow HEIC\'s DateTime',
          );
          expect(
            mp4Result.gps,
            isNull,
            reason: 'MP4 must not borrow HEIC\'s GPS',
          );
        },
      );
    });

    group(
      'numbered duplicates: each copy uses only its own numbered sidecar',
      () {
        // Realistic Takeout layout with two same-named photos in one folder,
        // disambiguated by Takeout's "(N)" suffix. Each has its OWN numbered
        // sidecar. Both must resolve to their own metadata (own-sidecar),
        // proving the numbered same-file tiers are classified correctly.
        test(
          'two numbered copies each resolve to their own numbered sidecar',
          () async {
            final dir = fixture.basePath;
            final copy1 = fixture.createImageWithExif('IMG_0001(1).jpg');
            final copy2 = fixture.createImageWithExif('IMG_0001(2).jpg');

            // Copy 1's sidecar: NYC, 2023-03-01.
            _writeSidecar(
              dir,
              'IMG_0001.jpg.supplemental-metadata(1).json',
              lat: 40.7128,
              lon: -74.0060,
              photoTakenTimestamp: '1677628800', // 2023-03-01 00:00:00 UTC
              title: 'IMG_0001.jpg',
            );
            // Copy 2's sidecar: Tokyo, 2023-04-01.
            _writeSidecar(
              dir,
              'IMG_0001.jpg.supplemental-metadata(2).json',
              lat: 35.6762,
              lon: 139.6503,
              photoTakenTimestamp: '1680307200', // 2023-04-01 00:00:00 UTC
              title: 'IMG_0001.jpg',
            );

            final r1 = await extractAllFromJson(copy1);
            final r2 = await extractAllFromJson(copy2);

            // Each copy gets its OWN date and GPS — no cross-contamination.
            expect(r1.date, isNotNull);
            expect(
              r1.date,
              equals(
                DateTime.fromMillisecondsSinceEpoch(
                  1677628800 * 1000,
                  isUtc: true,
                ),
              ),
            );
            expect(r1.gps, isNotNull);

            expect(r2.date, isNotNull);
            expect(
              r2.date,
              equals(
                DateTime.fromMillisecondsSinceEpoch(
                  1680307200 * 1000,
                  isUtc: true,
                ),
              ),
            );
            expect(r2.gps, isNotNull);

            // Sanity: the two GPS coordinates differ (NYC vs Tokyo).
            expect(r1.gps, isNot(equals(r2.gps)));
          },
        );

        // A numbered MP4 whose own sidecar is missing, but a numbered HEIC
        // sidecar exists. The MP4 must NOT borrow the HEIC's metadata via the
        // numbered cross-extension tier (the tier added by the issue #133 fix).
        test(
          'numbered MP4 does not inherit numbered HEIC\'s date+GPS (cross-ext tier)',
          () async {
            final dir = fixture.basePath;
            final mp4 = File(path.join(dir, 'IMG_1976(1).MP4'));
            await mp4.writeAsBytes([0x00, 0x00, 0x00, 0x20]); // dummy MP4
            fixture.createImageWithExif('IMG_1976(1).HEIC');

            // ONLY the HEIC has a sidecar. The MP4 has none.
            _writeSidecar(
              dir,
              'IMG_1976.HEIC.supplemental-metadata(1).json',
              lat: 52.52,
              lon: 13.405,
              photoTakenTimestamp: '1672531200',
              title: 'IMG_1976.HEIC',
            );

            final mp4Result = await extractAllFromJson(mp4, tryhard: true);
            expect(
              mp4Result.date,
              isNull,
              reason: 'numbered MP4 must not borrow HEIC\'s DateTime',
            );
            expect(
              mp4Result.gps,
              isNull,
              reason: 'numbered MP4 must not borrow HEIC\'s GPS',
            );
          },
        );
      },
    );

    group('tryhard escalation does not re-introduce contamination', () {
      // A file with no own sidecar and no aggressive match at all. Basic
      // returns null; tryhard also returns null. Confirms the gate doesn't
      // accidentally produce a non-null heuristic match.
      test(
        'file with no sidecar at all yields null date+GPS (tryhard)',
        () async {
          final lonely = fixture.createImageWithExif('lonely.jpg');

          final basic = await extractAllFromJson(lonely);
          final tryhard = await extractAllFromJson(lonely, tryhard: true);

          expect(basic.date, isNull);
          expect(basic.gps, isNull);
          expect(tryhard.date, isNull);
          expect(tryhard.gps, isNull);
        },
      );

      // A file whose own sidecar exists but is only reachable via an
      // own-sidecar strategy (bracket swap). It must still get its metadata,
      // proving own-sidecar strategies are not over-gated.
      test('bracket-swap own sidecar still yields date+GPS', () async {
        final dir = fixture.basePath;
        final media = fixture.createImageWithExif('image(11).jpg');
        _writeSidecar(
          dir,
          'image.jpg(11).json',
          lat: 51.5074,
          lon: -0.1278,
          photoTakenTimestamp: '1672531200',
          title: 'image.jpg',
        );

        final result = await extractAllFromJson(media);
        expect(
          result.date,
          isNotNull,
          reason: 'bracket-swap is an own-sidecar strategy',
        );
        expect(result.gps, isNotNull);
      });
    });

    group('GPS coordinate values are correct (not just non-null)', () {
      // Verifies the actual lat/lon round-trip from the own sidecar, so a
      // future regression that returns the right *type* but wrong *value*
      // is caught.
      test('own sidecar GPS matches the JSON geoDataExif values', () async {
        final dir = fixture.basePath;
        final media = fixture.createImageWithExif('precise.jpg');
        _writeSidecar(
          dir,
          'precise.jpg.supplemental-metadata.json',
          lat: 40.758896,
          lon: -73.98513,
          photoTakenTimestamp: '1672531200',
          title: 'precise.jpg',
        );

        final result = await extractAllFromJson(media);
        expect(result.gps, isNotNull);
        // DMSCoordinates.fromDD round-trips; compare decimal degrees.
        final dd = result.gps!.toDD();
        expect(dd.latitude, closeTo(40.758896, 0.0001));
        expect(dd.longitude, closeTo(-73.98513, 0.0001));
      });
    });
  });
}
