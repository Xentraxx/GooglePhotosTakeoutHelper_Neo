library;

import 'dart:io';

import 'package:gpth_neo/gpth_lib_exports.dart';
import 'package:test/test.dart';

import '../setup/test_setup.dart';

void main() {
  group('Issue #110 theory verification', () {
    late TestFixture fixture;

    setUp(() async {
      fixture = TestFixture();
      await fixture.setUp();
      await ServiceContainer.instance.initialize();
    });

    tearDown(() async {
      await ServiceContainer.reset();
      await fixture.tearDown();
    });

    test(
      'folder classifier and FileEntity canonical logic agree for Dutch year folders',
      () {
        final yearDir = fixture.createDirectory('Foto_s van 2024');
        final mediaFile = fixture.createFile('Foto_s van 2024/photo.jpg', [
          1,
          2,
          3,
        ]);

        expect(isYearFolder(yearDir), isTrue);

        final fileEntity = FileEntity(sourcePath: mediaFile.path);
        expect(
          fileEntity.isCanonical,
          isTrue,
          reason:
              'Canonical detection should use the same multilingual year-folder regex as classifier.',
        );
      },
    );

    test('ignore albums strategy moves Dutch year file as canonical', () async {
      final mediaFile = fixture.createFile('Foto_s van 2024/photo.jpg', [
        1,
        2,
        3,
      ]);
      final outDir = fixture.createDirectory('out');

      final entity = MediaEntity.single(
        file: FileEntity(sourcePath: mediaFile.path),
      );
      expect(entity.primaryFile.isCanonical, isTrue);

      final strategy = IgnoreAlbumsMovingStrategy(
        FileOperationService(),
        PathGeneratorService(),
      );

      final context = MovingContext(
        outputDirectory: Directory(outDir.path),
        dateDivision: DateDivisionLevel.none,
        albumBehavior: AlbumBehavior.ignoreAlbums,
      );

      final results = await strategy
          .processMediaEntity(entity, context)
          .toList();

      expect(results, isNotEmpty);
      expect(results.first.success, isTrue);
      expect(
        results.first.operation.operationType,
        MediaEntityOperationType.move,
      );
      expect(await File(mediaFile.path).exists(), isFalse);
      expect(
        await File('${outDir.path}/ALL_PHOTOS/photo.jpg').exists(),
        isTrue,
      );
    });
  });
}
