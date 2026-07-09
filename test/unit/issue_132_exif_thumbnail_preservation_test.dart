/// Test suite for Issue #132: native JPEG EXIF writes must not drop the
/// embedded EXIF thumbnail or the JFIF (APP0) header segment.
///
/// Root cause (fixed upstream in the vendored `image` fork, commit
/// 59e2bff6139c2e4608f7591dfe912d23ab828498): `injectJpgExif` reset its
/// "preserve everything up to here" offset on every loop iteration instead
/// of advancing it, so any segment between SOI and the EXIF APP1 block (in
/// particular the JFIF APP0 header) was silently dropped, and the EXIF
/// thumbnail payload (IFD1) was not round-tripped, leaving dangling
/// offset/length tags. Both defects showed up to users as the output file
/// shrinking and losing its embedded preview thumbnail after GPTH wrote
/// date/GPS metadata into it.
///
/// These tests exercise GPTH's own call sites (WriteExifAuxiliaryService,
/// which every native JPEG date/GPS/combined write goes through) instead of
/// the `image` library directly. The library has its own regression tests
/// for the fix itself; these guard GPTH against ever depending on an
/// unpatched `image` version again (the dependency was reverted once
/// already — see pubspec history around issue #132).
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:coordinate_converter/coordinate_converter.dart';
import 'package:gpth_neo/gpth_lib_exports.dart';
import 'package:image/image.dart';
import 'package:test/test.dart';

import '../setup/test_setup.dart';

Uint8List _decodeFixture(final String base64Data) =>
    base64Decode(base64Data.replaceAll('\n', ''));

/// Builds a realistic JPEG fixture: a JFIF (APP0) header followed by an EXIF
/// (APP1) block that carries an embedded preview thumbnail (IFD1) — the
/// exact shape of file that triggered issue #132. Both source images are
/// real, valid JPEGs already used elsewhere in the test suite.
Uint8List _jpegWithJfifAndThumbnail() {
  final Uint8List base = _decodeFixture(greenImgNoMetaDataBase64);
  final Uint8List thumbBytes = _decodeFixture(greenImgBase64);

  final ExifData exif = ExifData()
    ..thumbnail = thumbBytes
    ..imageIfd['DateTime'] = '2020:01:01 00:00:00';

  final Uint8List? out = injectJpgExif(base, exif);
  if (out == null) {
    throw StateError('Failed to build fixture JPEG with thumbnail');
  }
  return out;
}

/// True if [jpeg] starts with SOI immediately followed by a JFIF APP0
/// segment, i.e. `FF D8 FF E0 xx xx 'J' 'F' 'I' 'F'`.
bool _startsWithJfifHeader(final Uint8List jpeg) =>
    jpeg.length > 10 &&
    jpeg[0] == 0xFF &&
    jpeg[1] == 0xD8 &&
    jpeg[2] == 0xFF &&
    jpeg[3] == 0xE0 &&
    jpeg[6] == 0x4A && // J
    jpeg[7] == 0x46 && // F
    jpeg[8] == 0x49 && // I
    jpeg[9] == 0x46; // F

void main() {
  group('Issue #132: native JPEG EXIF writer preserves thumbnail + JFIF', () {
    late TestFixture fixture;
    late WriteExifAuxiliaryService service;
    late Uint8List fixtureBytes;
    late Uint8List originalThumbnail;

    setUp(() async {
      fixture = TestFixture();
      await fixture.setUp();
      // No ExifTool needed: writeXNativeJpeg never touches it.
      service = WriteExifAuxiliaryService(null);
      fixtureBytes = _jpegWithJfifAndThumbnail();
      originalThumbnail = decodeJpgExif(fixtureBytes)!.thumbnail!;
    });

    tearDown(() async {
      await fixture.tearDown();
    });

    test('fixture sanity: has JFIF header and a decodable thumbnail', () {
      expect(_startsWithJfifHeader(fixtureBytes), isTrue);
      final exif = decodeJpgExif(fixtureBytes);
      expect(exif, isNotNull);
      expect(exif!.thumbnail, isNotNull);
      expect(exif.thumbnail!.length, greaterThan(0));
    });

    test('writeDateTimeNativeJpeg preserves thumbnail and JFIF header', () async {
      final file = fixture.createFile('date_only.jpg', fixtureBytes);
      final originalSize = fixtureBytes.length;

      final ok = await service.writeDateTimeNativeJpeg(
        file,
        DateTime(2024, 6, 15, 10, 30),
      );
      expect(
        ok,
        isTrue,
        reason:
            'native date write should succeed on a fixture with an existing EXIF block',
      );

      final updated = await file.readAsBytes();
      expect(
        _startsWithJfifHeader(updated),
        isTrue,
        reason:
            'JFIF APP0 header must survive a native EXIF update (issue #132)',
      );

      final updatedExif = decodeJpgExif(updated);
      expect(updatedExif, isNotNull);
      expect(
        updatedExif!.thumbnail,
        isNotNull,
        reason: 'EXIF thumbnail must survive a native EXIF update (issue #132)',
      );
      expect(
        updatedExif.thumbnail,
        equals(originalThumbnail),
        reason: 'thumbnail bytes must round-trip byte-for-byte',
      );

      // The directly-reported symptom in #132 was the output file
      // silently shrinking. With the thumbnail preserved the file should
      // never end up materially smaller than the original.
      expect(
        updated.length,
        greaterThanOrEqualTo(originalSize - 32),
        reason:
            'output must not shrink materially once thumbnail/JFIF are preserved',
      );

      // The write must have actually applied (not silently no-op'd).
      expect(
        updatedExif.exifIfd['DateTimeOriginal']?.toString(),
        equals('2024:06:15 10:30:00'),
      );
    });

    test('writeGpsNativeJpeg preserves thumbnail and JFIF header', () async {
      final file = fixture.createFile('gps_only.jpg', fixtureBytes);

      final coords = DMSCoordinates.fromDD(
        DDCoordinates(latitude: 48.8566, longitude: 2.3522),
      );
      final ok = await service.writeGpsNativeJpeg(file, coords);
      expect(ok, isTrue);

      final updated = await file.readAsBytes();
      expect(
        _startsWithJfifHeader(updated),
        isTrue,
        reason: 'JFIF APP0 header must survive a native GPS write',
      );

      final updatedExif = decodeJpgExif(updated);
      expect(updatedExif, isNotNull);
      expect(
        updatedExif!.thumbnail,
        equals(originalThumbnail),
        reason: 'thumbnail bytes must round-trip byte-for-byte',
      );
      expect(updatedExif.gpsIfd[0x0002], isNotNull); // GPSLatitude written
    });

    test(
      'writeCombinedNativeJpeg preserves thumbnail and JFIF header',
      () async {
        final file = fixture.createFile('combined.jpg', fixtureBytes);

        final coords = DMSCoordinates.fromDD(
          DDCoordinates(latitude: -33.8688, longitude: 151.2093),
        );
        final ok = await service.writeCombinedNativeJpeg(
          file,
          DateTime(2023, 3, 4, 8),
          coords,
        );
        expect(ok, isTrue);

        final updated = await file.readAsBytes();
        expect(
          _startsWithJfifHeader(updated),
          isTrue,
          reason: 'JFIF APP0 header must survive a native combined write',
        );

        final updatedExif = decodeJpgExif(updated);
        expect(updatedExif, isNotNull);
        expect(updatedExif!.thumbnail, equals(originalThumbnail));
        expect(
          updatedExif.exifIfd['DateTimeOriginal']?.toString(),
          equals('2023:03:04 08:00:00'),
        );
        expect(updatedExif.gpsIfd[0x0002], isNotNull);
      },
    );

    test(
      'repeated writes do not progressively shrink the file (issue #132 regression guard)',
      () async {
        final file = fixture.createFile('repeated.jpg', fixtureBytes);
        final sizesAfterEachWrite = <int>[];

        for (var i = 0; i < 3; i++) {
          final ok = await service.writeDateTimeNativeJpeg(
            file,
            DateTime(2024, 1, 1 + i),
          );
          expect(ok, isTrue);
          sizesAfterEachWrite.add(await file.length());

          final exifAfter = decodeJpgExif(await file.readAsBytes());
          expect(
            exifAfter?.thumbnail,
            equals(originalThumbnail),
            reason: 'thumbnail must survive write #$i',
          );
        }

        // Successive writes to the same tags should settle to a stable
        // size, never keep shrinking write after write.
        expect(
          sizesAfterEachWrite.last,
          greaterThanOrEqualTo(sizesAfterEachWrite.first - 16),
          reason:
              'file size must not keep decreasing across repeated metadata writes',
        );
      },
    );

    test(
      'a JPEG without a pre-existing thumbnail does not gain dangling thumbnail tags',
      () async {
        // Regression guard for the companion defect: files that never had a
        // thumbnail must not end up with offset/length tags pointing at
        // nothing after a native write.
        final file = fixture.createImageWithExif('no_thumbnail.jpg');

        final ok = await service.writeDateTimeNativeJpeg(
          file,
          DateTime(2024, 6, 15),
        );
        expect(ok, isTrue);

        final updatedExif = decodeJpgExif(await file.readAsBytes());
        expect(updatedExif, isNotNull);
        if (updatedExif!.thumbnail == null || updatedExif.thumbnail!.isEmpty) {
          expect(updatedExif.thumbnailIfd.containsKey(0x0201), isFalse);
          expect(updatedExif.thumbnailIfd.containsKey(0x0202), isFalse);
        }
      },
    );
  });
}
