library;

import 'dart:io';

import 'package:gpth_neo/gpth_lib_exports.dart';
import 'package:path/path.dart' as path;
import 'package:test/test.dart';

import '../../bin/gpth.dart' as cli;

void main() {
  group('output directory validation', () {
    late Directory tempDir;
    late Directory inputDir;
    late ProcessingConfig config;

    setUp(() async {
      tempDir = await Directory.systemTemp.createTemp(
        'gpth_output_validation_',
      );
      inputDir = Directory(path.join(tempDir.path, 'input'));
      await inputDir.create(recursive: true);
      config = ProcessingConfig(
        inputPath: inputDir.path,
        outputPath: tempDir.path,
        writeExif: false,
      );
    });

    tearDown(() async {
      if (await tempDir.exists()) {
        await tempDir.delete(recursive: true);
      }
    });

    test(
      'does not require cleaning when output contains only log files',
      () async {
        await File(
          path.join(tempDir.path, 'previous-run.log'),
        ).writeAsString('log');

        final needsClean = await cli.needsCleanOutputDirectoryForTest(
          tempDir,
          config,
        );

        expect(needsClean, isFalse);
      },
    );

    test('requires cleaning when output contains non-log files', () async {
      await File(path.join(tempDir.path, 'notes.txt')).writeAsString('data');

      final needsClean = await cli.needsCleanOutputDirectoryForTest(
        tempDir,
        config,
      );

      expect(needsClean, isTrue);
    });

    test('cleaning preserves log files and removes other files', () async {
      final logFile = File(path.join(tempDir.path, 'previous-run.log'));
      final otherFile = File(path.join(tempDir.path, 'notes.txt'));
      await logFile.writeAsString('log');
      await otherFile.writeAsString('data');

      await cli.cleanOutputDirectoryForTest(tempDir, config);

      expect(await logFile.exists(), isTrue);
      expect(await otherFile.exists(), isFalse);
    });
  });
}
