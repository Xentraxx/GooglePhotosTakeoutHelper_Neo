library;

import 'dart:io';

import 'package:gpth_neo/gpth_lib_exports.dart';
import 'package:test/test.dart';

import '../setup/test_setup.dart';

void main() {
  group('LivePhoto metadata copy integration', () {
    late TestFixture fixture;
    ExifToolService? exifTool;

    setUp(() async {
      fixture = TestFixture();
      await fixture.setUp();

      await ServiceContainer.instance.initialize();
      exifTool = await ExifToolService.find();
      ServiceContainer.instance.exifTool = exifTool;
      ServiceContainer.instance.globalConfig.exifToolInstalled =
          exifTool != null;
    });

    tearDown(() async {
      await fixture.tearDown();
      await ServiceContainer.reset();
    });

    test(
      'copies DateTimeOriginal, Make/Model, and GPS tags from JPG sidecar to resulting .heic',
      () async {
        if (exifTool == null) {
          return;
        }

        const dateTimeOriginal = '2024:03:14 15:09:26';
        const make = 'GPTH Test Camera';
        const model = 'GPTH Test Model';
        const latitude = 12.3456;
        const longitude = 78.9012;

        final stillImage = fixture.createImageWithoutExif('sidecar_source.jpg');

        await exifTool!.writeExifDataSingle(stillImage, {
          'DateTimeOriginal': dateTimeOriginal,
          'Make': make,
          'Model': model,
          'GPSLatitude': latitude,
          'GPSLatitudeRef': 'N',
          'GPSLongitude': longitude,
          'GPSLongitudeRef': 'E',
        });

        final embeddedPreview = fixture
            .createImageWithoutExif('embedded_preview.jpg')
            .readAsBytesSync();

        final motionPhoto = fixture.createFile('motion_source.MP', [
          0x00,
          0x00,
          0x00,
          0x20,
          0x66,
          0x74,
          0x79,
          0x70,
          0x69,
          0x73,
          0x6F,
          0x6D,
          0xAA,
          0xBB,
          0xCC,
          0xDD,
          ...embeddedPreview,
          0x10,
          0x11,
          0x12,
          0x13,
        ]);

        final outputHeic = File(
          '${fixture.basePath}${Platform.pathSeparator}out.heic',
        );

        final result = await LivePhotoService()
            .convertMotionPhotoToLivePhotoWithStillImage(
              inputPath: motionPhoto.path,
              stillImagePath: stillImage.path,
              outputPath: outputHeic.path,
            );

        expect(result.success, isTrue, reason: result.errorMessage);
        expect(outputHeic.existsSync(), isTrue);

        final copiedTags = await exifTool!.readExifData(outputHeic);

        final copiedDate = _firstTag(copiedTags, [
          'DateTimeOriginal',
          'EXIF:DateTimeOriginal',
          'XMP:DateTimeOriginal',
        ]);
        final copiedMake = _firstTag(copiedTags, ['Make', 'EXIF:Make']);
        final copiedModel = _firstTag(copiedTags, ['Model', 'EXIF:Model']);
        final copiedLatitude = _toDouble(
          _firstTag(copiedTags, ['GPSLatitude', 'XMP:GPSLatitude']),
        );
        final copiedLongitude = _toDouble(
          _firstTag(copiedTags, ['GPSLongitude', 'XMP:GPSLongitude']),
        );

        expect(
          copiedDate,
          isNotNull,
          reason: 'Expected DateTimeOriginal or XMP equivalent on output .heic',
        );
        expect(copiedDate.toString(), contains(dateTimeOriginal));

        expect(copiedMake, equals(make));
        expect(copiedModel, equals(model));

        expect(
          copiedLatitude,
          isNotNull,
          reason: 'Expected GPS latitude tag on output .heic',
        );
        expect(
          copiedLongitude,
          isNotNull,
          reason: 'Expected GPS longitude tag on output .heic',
        );

        expect(copiedLatitude!, closeTo(latitude, 0.0002));
        expect(copiedLongitude!, closeTo(longitude, 0.0002));
      },
    );
  });
}

dynamic _firstTag(final Map<String, dynamic> tags, final List<String> keys) {
  for (final key in keys) {
    if (tags.containsKey(key)) {
      return tags[key];
    }
  }
  return null;
}

// ignore: strict_top_level_inference
double? _toDouble(final value) {
  if (value == null) return null;
  if (value is num) return value.toDouble();
  if (value is String) return double.tryParse(value.trim());
  return null;
}
