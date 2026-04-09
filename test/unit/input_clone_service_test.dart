/// Tests for InputCloneService.cloneToSiblingTmp().
///
/// Covers:
/// - Creates a sibling _tmp directory next to the source
/// - Cloned directory contains all source files
/// - Nested subdirectory structure is preserved
/// - Collision: increments suffix if _tmp already exists (_tmp2, _tmp3…)
/// - Throws StateError for non-existent source
/// - Source directory is not modified by the clone operation
/// - Custom suffix is respected
/// - Empty source directory is cloned without errors
library;

import 'dart:io';

import 'package:gpth_neo/gpth_lib_exports.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import '../setup/test_setup.dart';

void main() {
  group('InputCloneService', () {
    late InputCloneService service;
    late TestFixture fixture;

    setUp(() async {
      service = InputCloneService();
      fixture = TestFixture();
      await fixture.setUp();
    });

    tearDown(() async {
      await fixture.tearDown();
    });

    test('creates a sibling directory with _tmp suffix', () async {
      final src = fixture.createDirectory('myinput');
      fixture.createImageWithExifInDir(src.path, 'photo.jpg');

      final clone = await service.cloneToSiblingTmp(src);

      expect(clone.existsSync(), isTrue);
      expect(p.basename(clone.path), equals('myinput_tmp'));
    });

    test('clone is inside the same parent as source', () async {
      final src = fixture.createDirectory('sourceA');
      fixture.createImageWithExifInDir(src.path, 'img.jpg');

      final clone = await service.cloneToSiblingTmp(src);

      expect(p.dirname(clone.path), equals(p.dirname(src.path)));
    });

    test('cloned directory contains all source files', () async {
      final src = fixture.createDirectory('srcdir');
      fixture.createImageWithExifInDir(src.path, 'img1.jpg');
      fixture.createImageWithExifInDir(src.path, 'img2.jpg');

      final clone = await service.cloneToSiblingTmp(src);

      final clonedFiles = Directory(
        clone.path,
      ).listSync().whereType<File>().toList();
      expect(clonedFiles.length, equals(2));
      expect(
        clonedFiles.map((final f) => p.basename(f.path)).toSet(),
        containsAll(['img1.jpg', 'img2.jpg']),
      );
    });

    test('nested subdirectory structure is preserved', () async {
      final src = fixture.createDirectory('nested_src');
      final sub = Directory(p.join(src.path, 'sub'))..createSync();
      fixture.createImageWithExifInDir(src.path, 'root.jpg');
      fixture.createImageWithExifInDir(sub.path, 'child.jpg');

      final clone = await service.cloneToSiblingTmp(src);

      expect(File(p.join(clone.path, 'root.jpg')).existsSync(), isTrue);
      expect(File(p.join(clone.path, 'sub', 'child.jpg')).existsSync(), isTrue);
    });

    test('increments to _tmp2 when _tmp already exists', () async {
      final src = fixture.createDirectory('origdir');
      fixture.createImageWithExifInDir(src.path, 'photo.jpg');
      // Pre-create the _tmp sibling to force a collision
      fixture.createDirectory('origdir_tmp');

      final clone = await service.cloneToSiblingTmp(src);

      expect(p.basename(clone.path), equals('origdir_tmp2'));
    });

    test('increments to _tmp3 when _tmp and _tmp2 already exist', () async {
      final src = fixture.createDirectory('multi_src');
      fixture.createImageWithExifInDir(src.path, 'photo.jpg');
      fixture.createDirectory('multi_src_tmp');
      fixture.createDirectory('multi_src_tmp2');

      final clone = await service.cloneToSiblingTmp(src);

      expect(p.basename(clone.path), equals('multi_src_tmp3'));
    });

    test('throws StateError for non-existent source directory', () async {
      final nonExistent = Directory(p.join(fixture.basePath, 'does_not_exist'));

      await expectLater(
        () => service.cloneToSiblingTmp(nonExistent),
        throwsA(isA<StateError>()),
      );
    });

    test('source directory is unmodified after clone', () async {
      final src = fixture.createDirectory('readonly_src');
      fixture.createImageWithExifInDir(src.path, 'original.jpg');
      final sourceCountBefore = Directory(src.path).listSync().length;

      await service.cloneToSiblingTmp(src);

      final sourceCountAfter = Directory(src.path).listSync().length;
      expect(sourceCountAfter, equals(sourceCountBefore));
    });

    test('source file content is preserved in clone', () async {
      final src = fixture.createDirectory('content_src');
      final original = fixture.createImageWithExifInDir(src.path, 'img.jpg');
      final originalBytes = original.readAsBytesSync();

      final clone = await service.cloneToSiblingTmp(src);

      final clonedBytes = File(p.join(clone.path, 'img.jpg')).readAsBytesSync();
      expect(clonedBytes, equals(originalBytes));
    });

    test('custom suffix is used instead of _tmp', () async {
      final src = fixture.createDirectory('mysrc');
      fixture.createImageWithExifInDir(src.path, 'photo.jpg');

      final clone = await service.cloneToSiblingTmp(src, suffix: '_backup');

      expect(p.basename(clone.path), equals('mysrc_backup'));
    });

    test('empty source directory is cloned without errors', () async {
      final src = fixture.createDirectory('empty_src');

      await expectLater(service.cloneToSiblingTmp(src), completes);

      final clone = await service.cloneToSiblingTmp(
        Directory(p.join(fixture.basePath, 'empty_src')),
        suffix: '_check',
      );
      expect(clone.existsSync(), isTrue);
      expect(Directory(clone.path).listSync(), isEmpty);
    });
  });
}
