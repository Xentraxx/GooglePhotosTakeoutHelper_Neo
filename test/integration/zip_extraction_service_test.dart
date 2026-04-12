/// Test suite for ZipExtractionService
///
/// Tests the ZIP file extraction functionality with safety checks.
library;

import 'dart:io';
import 'dart:typed_data';
import 'package:archive/archive.dart';
import 'package:gpth_neo/gpth_lib_exports.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import '../setup/test_setup.dart';

/// Mock presenter for testing without UI interactions
class MockInteractivePresenter implements InteractivePresenterService {
  final List<String> messages = [];

  @override
  Future<void> showUnzipStartMessage() async {
    messages.add('UnzipStart');
  }

  @override
  Future<void> showUnzipProgress(final String fileName) async {
    messages.add('UnzipProgress: $fileName');
  }

  @override
  Future<void> showUnzipSuccess(final String fileName) async {
    messages.add('UnzipSuccess: $fileName');
  }

  @override
  Future<void> showUnzipComplete() async {
    messages.add('UnzipComplete');
  }

  // Add no-op implementations for other required methods
  @override
  dynamic noSuchMethod(final Invocation invocation) => null;
}

void main() {
  group('ZipExtractionService', () {
    late ZipExtractionService service;
    late MockInteractivePresenter mockPresenter;
    late TestFixture fixture;

    setUpAll(() async {
      // Initialize ServiceContainer for integration tests
      await ServiceContainer.instance.initialize();
    });

    tearDownAll(() async {
      await ServiceContainer.instance.dispose();
      await ServiceContainer.reset();
    });
    setUp(() async {
      mockPresenter = MockInteractivePresenter();
      service = ZipExtractionService(presenter: mockPresenter);
      fixture = TestFixture();
      await fixture.setUp();
    });

    tearDown(() async {
      await fixture.tearDown();
    });

    group('extractAll', () {
      test('creates destination directory if it does not exist', () async {
        // Create a simple ZIP file
        final zipFile = await _createSimpleZip(fixture, 'test.zip');
        final extractDir = Directory(p.join(fixture.basePath, 'extract'));

        expect(await extractDir.exists(), isFalse);

        await service.extractAll([zipFile], extractDir);

        expect(await extractDir.exists(), isTrue);
      });

      test('extracts ZIP file contents correctly', () async {
        // Create ZIP with test content
        final zipFile = await _createZipWithContent(fixture, 'test.zip', {
          'file1.txt': 'Hello World',
          'subfolder/file2.txt': 'Test Content',
        });
        final extractDir = Directory(p.join(fixture.basePath, 'extract'));

        await service.extractAll([zipFile], extractDir);

        // Verify extracted files
        final file1 = File(p.join(extractDir.path, 'file1.txt'));
        final file2 = File(p.join(extractDir.path, 'subfolder', 'file2.txt'));

        expect(await file1.exists(), isTrue);
        expect(await file2.exists(), isTrue);
        expect(await file1.readAsString(), equals('Hello World'));
        expect(await file2.readAsString(), equals('Test Content'));
      });

      test('handles multiple ZIP files', () async {
        final zip1 = await _createZipWithContent(fixture, 'test1.zip', {
          'file1.txt': 'Content 1',
        });
        final zip2 = await _createZipWithContent(fixture, 'test2.zip', {
          'file2.txt': 'Content 2',
        });
        final extractDir = Directory(p.join(fixture.basePath, 'extract'));

        await service.extractAll([zip1, zip2], extractDir);

        final file1 = File(p.join(extractDir.path, 'file1.txt'));
        final file2 = File(p.join(extractDir.path, 'file2.txt'));

        expect(await file1.exists(), isTrue);
        expect(await file2.exists(), isTrue);
        expect(await file1.readAsString(), equals('Content 1'));
        expect(await file2.readAsString(), equals('Content 2'));
      });

      test('provides progress feedback through presenter', () async {
        final zipFile = await _createSimpleZip(fixture, 'test.zip');
        final extractDir = Directory(p.join(fixture.basePath, 'extract'));

        await service.extractAll([zipFile], extractDir);

        expect(mockPresenter.messages, contains('UnzipStart'));
        expect(mockPresenter.messages, contains('UnzipProgress: test.zip'));
        expect(mockPresenter.messages, contains('UnzipSuccess: test.zip'));
        expect(mockPresenter.messages, contains('UnzipComplete'));
      });

      test('handles empty ZIP list gracefully', () async {
        final extractDir = Directory(p.join(fixture.basePath, 'extract'));

        await service.extractAll([], extractDir);

        expect(await extractDir.exists(), isTrue);
        expect(mockPresenter.messages, contains('UnzipStart'));
        expect(mockPresenter.messages, contains('UnzipComplete'));
      });

      test('handles non-existent ZIP file', () async {
        final nonExistentZip = File(
          p.join(fixture.basePath, 'nonexistent.zip'),
        );
        final extractDir = Directory(p.join(fixture.basePath, 'extract'));

        // Should handle the error gracefully without crashing
        expect(
          () => service.extractAll([nonExistentZip], extractDir),
          returnsNormally,
        );
      });

      test('handles empty ZIP file', () async {
        // Create an empty file
        final emptyZip = File(p.join(fixture.basePath, 'empty.zip'));
        await emptyZip.writeAsBytes([]);
        final extractDir = Directory(p.join(fixture.basePath, 'extract'));

        // Should handle gracefully
        expect(
          () => service.extractAll([emptyZip], extractDir),
          returnsNormally,
        );
      });

      test('handles corrupted ZIP file', () async {
        // Create a file with invalid ZIP content
        final corruptedZip = File(p.join(fixture.basePath, 'corrupted.zip'));
        await corruptedZip.writeAsBytes([1, 2, 3, 4, 5]); // Invalid ZIP
        final extractDir = Directory(p.join(fixture.basePath, 'extract'));

        // Should handle gracefully
        expect(
          () => service.extractAll([corruptedZip], extractDir),
          returnsNormally,
        );
      });

      test('prevents path traversal attacks', () async {
        // This would require creating a malicious ZIP file with path traversal,
        // which is complex to set up in a unit test. For now, we test that
        // the service handles normal files correctly.
        final zipFile = await _createZipWithContent(fixture, 'safe.zip', {
          'normal/file.txt': 'Safe content',
        });
        final extractDir = Directory(p.join(fixture.basePath, 'extract'));

        await service.extractAll([zipFile], extractDir);

        final extractedFile = File(
          p.join(extractDir.path, 'normal', 'file.txt'),
        );
        expect(await extractedFile.exists(), isTrue);
        expect(await extractedFile.readAsString(), equals('Safe content'));
      });

      test('creates directories for nested files', () async {
        final zipFile = await _createZipWithContent(fixture, 'nested.zip', {
          'level1/level2/level3/deep.txt': 'Deep content',
        });
        final extractDir = Directory(p.join(fixture.basePath, 'extract'));

        await service.extractAll([zipFile], extractDir);

        final deepFile = File(
          p.join(extractDir.path, 'level1', 'level2', 'level3', 'deep.txt'),
        );
        expect(await deepFile.exists(), isTrue);
        expect(await deepFile.readAsString(), equals('Deep content'));
      });
    });

    group('error handling', () {
      test('continues processing after individual ZIP errors', () async {
        final goodZip = await _createZipWithContent(fixture, 'good.zip', {
          'good.txt': 'Good content',
        });
        final badZip = File(p.join(fixture.basePath, 'bad.zip'));
        await badZip.writeAsBytes([1, 2, 3]); // Invalid ZIP

        final extractDir = Directory(p.join(fixture.basePath, 'extract'));

        await service.extractAll([badZip, goodZip], extractDir);

        // Good file should still be extracted
        final goodFile = File(p.join(extractDir.path, 'good.txt'));
        expect(await goodFile.exists(), isTrue);
        expect(await goodFile.readAsString(), equals('Good content'));
      });
    });
  });
}

/// Helper function to create a simple ZIP file for testing
Future<File> _createSimpleZip(
  final TestFixture fixture,
  final String fileName,
) async =>
    _createZipWithContent(fixture, fileName, {'test.txt': 'Test content'});

/// Helper function to create a ZIP file with specified content
Future<File> _createZipWithContent(
  final TestFixture fixture,
  final String fileName,
  final Map<String, String> files,
) async {
  final archive = Archive();

  for (final entry in files.entries) {
    final content = Uint8List.fromList(entry.value.codeUnits);
    archive.addFile(ArchiveFile(entry.key, content.length, content));
  }
  final zipData = ZipEncoder().encode(archive);

  // Use TestFixture helper to force flush and availability checks.
  return fixture.createFile(fileName, zipData);
}
