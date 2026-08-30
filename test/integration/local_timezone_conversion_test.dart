// ignore_for_file: lines_longer_than_80_chars, prefer_const_constructors, avoid_redundant_argument_values

/// Integration tests for local timezone conversion (issue #145).
///
/// Verifies that when a [TimezoneOffset] is configured on the global config,
/// the native JPEG EXIF writer writes the local clock (UTC instant + offset)
/// together with the correct `OffsetTime` tag, so that re-uploading to Google
/// Photos reproduces the original timeline.
///
/// Google Photos ignores the EXIF `OffsetTime` tag and treats the naive
/// `DateTimeOriginal` clock as local time. By writing the local clock + the
/// correct offset, the re-uploaded photos appear at the correct local time.
library;

import 'dart:io';

import 'package:coordinate_converter/coordinate_converter.dart';
import 'package:gpth_neo/gpth_lib_exports.dart';
import 'package:image/image.dart' as img;
import 'package:test/test.dart';

import '../setup/test_setup.dart';

void main() {
  group('Local timezone conversion (issue #145) - native JPEG EXIF', () {
    late WriteExifAuxiliaryService service;
    late TestFixture fixture;

    setUp(() async {
      await ServiceContainer.instance.initialize();
      service = WriteExifAuxiliaryService(null);
      fixture = TestFixture();
      await fixture.setUp();
    });

    tearDown(() async {
      ServiceContainer.instance.globalConfig.localTimezoneOffset = null;
      await ServiceContainer.reset();
      await fixture.tearDown();
    });

    test(
      'writes local clock + configured OffsetTime when offset is set',
      () async {
        // photoTakenTime equivalent: 2026-01-05 12:56:39 UTC (the issue's example).
        final utcInstant = DateTime.utc(2026, 1, 5, 12, 56, 39);
        // GMT+8 → local clock should be 2026-01-05 20:56:39.
        final offset = TimezoneOffset(Duration(hours: 8));

        final file = fixture.createImageWithExif('photo.jpg');

        // Simulate what Step 7 does: convert UTC instant to local clock.
        final writeDate = utcInstant.toUtc().add(offset.duration);

        final ok = await service.writeDateTimeNativeJpeg(
          file,
          writeDate,
          isUtc: true,
          offsetString: offset.exifString,
        );
        expect(ok, isTrue);

        final exif = img.decodeJpgExif(await file.readAsBytes());
        expect(exif, isNotNull);
        expect(
          exif!.exifIfd['DateTimeOriginal']?.toString(),
          equals('2026:01:05 20:56:39'),
          reason: 'EXIF clock should be the local time (UTC + 8h)',
        );
        expect(
          exif.exifIfd['OffsetTime']?.toString(),
          equals('+08:00'),
          reason: 'OffsetTime should reflect the configured offset',
        );
        expect(
          exif.exifIfd['OffsetTimeOriginal']?.toString(),
          equals('+08:00'),
        );
        expect(
          exif.exifIfd['OffsetTimeDigitized']?.toString(),
          equals('+08:00'),
        );
      },
    );

    test('writes UTC clock + +00:00 when no offset is configured', () async {
      // Default behaviour (no --local-timezone): UTC clock + OffsetTime=+00:00.
      final utcInstant = DateTime.utc(2026, 1, 5, 12, 56, 39);

      final file = fixture.createImageWithExif('photo_utc.jpg');

      final ok = await service.writeDateTimeNativeJpeg(
        file,
        utcInstant,
        isUtc: true,
        offsetString: '+00:00',
      );
      expect(ok, isTrue);

      final exif = img.decodeJpgExif(await file.readAsBytes());
      expect(exif, isNotNull);
      expect(
        exif!.exifIfd['DateTimeOriginal']?.toString(),
        equals('2026:01:05 12:56:39'),
        reason: 'EXIF clock should be the UTC time when no offset is set',
      );
      expect(exif.exifIfd['OffsetTime']?.toString(), equals('+00:00'));
    });

    test('negative offset produces earlier local clock', () async {
      // GMT-5 → 2026-01-05 07:56:39 local.
      final utcInstant = DateTime.utc(2026, 1, 5, 12, 56, 39);
      final offset = TimezoneOffset(Duration(hours: -5));

      final file = fixture.createImageWithExif('photo_neg.jpg');

      final writeDate = utcInstant.toUtc().add(offset.duration);
      final ok = await service.writeDateTimeNativeJpeg(
        file,
        writeDate,
        isUtc: true,
        offsetString: offset.exifString,
      );
      expect(ok, isTrue);

      final exif = img.decodeJpgExif(await file.readAsBytes());
      expect(exif, isNotNull);
      expect(
        exif!.exifIfd['DateTimeOriginal']?.toString(),
        equals('2026:01:05 07:56:39'),
        reason: 'EXIF clock should be UTC - 5h',
      );
      expect(exif.exifIfd['OffsetTime']?.toString(), equals('-05:00'));
    });

    test('half-hour offset (+05:30) is handled correctly', () async {
      final utcInstant = DateTime.utc(2026, 1, 5, 12, 56, 39);
      final offset = TimezoneOffset(Duration(hours: 5, minutes: 30));

      final file = fixture.createImageWithExif('photo_ist.jpg');

      final writeDate = utcInstant.toUtc().add(offset.duration);
      final ok = await service.writeDateTimeNativeJpeg(
        file,
        writeDate,
        isUtc: true,
        offsetString: offset.exifString,
      );
      expect(ok, isTrue);

      final exif = img.decodeJpgExif(await file.readAsBytes());
      expect(exif, isNotNull);
      expect(
        exif!.exifIfd['DateTimeOriginal']?.toString(),
        equals('2026:01:05 18:26:39'),
        reason: 'EXIF clock should be UTC + 5h30m',
      );
      expect(exif.exifIfd['OffsetTime']?.toString(), equals('+05:30'));
    });

    test('combined native write (date+gps) applies offset to both', () async {
      final utcInstant = DateTime.utc(2026, 1, 5, 12, 56, 39);
      final offset = TimezoneOffset(Duration(hours: 8));
      final coords = DMSCoordinates.fromDD(
        DDCoordinates(latitude: 40.7128, longitude: -74.0060),
      );

      final file = fixture.createImageWithExif('combined.jpg');

      final writeDate = utcInstant.toUtc().add(offset.duration);
      final ok = await service.writeCombinedNativeJpeg(
        file,
        writeDate,
        coords,
        isUtc: true,
        offsetString: offset.exifString,
      );
      expect(ok, isTrue);

      final exif = img.decodeJpgExif(await file.readAsBytes());
      expect(exif, isNotNull);
      expect(
        exif!.exifIfd['DateTimeOriginal']?.toString(),
        equals('2026:01:05 20:56:39'),
      );
      expect(exif.exifIfd['OffsetTime']?.toString(), equals('+08:00'));
      // GPS should still be written.
      expect(exif.gpsIfd[0x0002], isNotNull); // GPSLatitude
    });
  });

  group('Local timezone conversion (issue #145) - folder naming', () {
    late TestFixture fixture;

    setUp(() async {
      await ServiceContainer.instance.initialize();
      fixture = TestFixture();
      await fixture.setUp();
    });

    tearDown(() async {
      ServiceContainer.instance.globalConfig.localTimezoneOffset = null;
      await ServiceContainer.reset();
      await fixture.tearDown();
    });

    test('date folder uses local date when offset is configured', () {
      ServiceContainer.instance.globalConfig.localTimezoneOffset =
          TimezoneOffset(Duration(hours: 8));

      final pathGen = PathGeneratorService();
      // 2026-01-05 23:00:00 UTC → 2026-01-06 07:00:00 local (GMT+8).
      // The folder should be 2026/01/06, not 2026/01/05.
      final utcInstant = DateTime.utc(2026, 1, 5, 23, 0, 0);
      final context = MovingContext(
        outputDirectory: Directory(fixture.basePath),
        allPhotosDirectoryName: kAllPhotosDirectoryName,
        dateDivision: DateDivisionLevel.day,
        albumBehavior: AlbumBehavior.nothing,
        dividePartnerShared: false,
      );

      final dir = pathGen.generateTargetDirectory(
        null, // albumKey null → ALL_PHOTOS, date division applies
        utcInstant,
        context,
      );

      expect(
        dir.path,
        contains(pathSeparatorJoin('2026', '01', '06')),
        reason: 'folder should use the local date after timezone conversion',
      );
    });

    test('date folder uses UTC date when no offset is configured', () {
      // No offset set → current behaviour (UTC date).
      final pathGen = PathGeneratorService();
      final utcInstant = DateTime.utc(2026, 1, 5, 23, 0, 0);
      final context = MovingContext(
        outputDirectory: Directory(fixture.basePath),
        allPhotosDirectoryName: kAllPhotosDirectoryName,
        dateDivision: DateDivisionLevel.day,
        albumBehavior: AlbumBehavior.nothing,
        dividePartnerShared: false,
      );

      final dir = pathGen.generateTargetDirectory(null, utcInstant, context);

      expect(
        dir.path,
        contains(pathSeparatorJoin('2026', '01', '05')),
        reason: 'folder should use the UTC date when no offset is set',
      );
    });
  });
}

/// Builds a platform-correct joined path segment (uses the OS separator).
String pathSeparatorJoin(final String a, final String b, [final String? c]) {
  // Use path.join semantics without importing path directly to avoid clashes.
  final sep = Platform.pathSeparator;
  if (c != null) return '$a$sep$b$sep$c';
  return '$a$sep$b';
}
