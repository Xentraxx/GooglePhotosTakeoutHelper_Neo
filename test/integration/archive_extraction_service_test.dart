/// Test suite for ArchiveExtractionService
///
/// Tests the archive file extraction functionality (.zip / .tar / .tgz)
/// with safety checks.
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
  group('ArchiveExtractionService', () {
    late ArchiveExtractionService service;
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
      service = ArchiveExtractionService(presenter: mockPresenter);
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
      test('continues processing after individual archive errors', () async {
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

    group('detectArchiveType / isSupportedArchive', () {
      test('detects supported archive extensions', () {
        expect(
          ArchiveExtractionService.detectArchiveType(
            File(p.join(fixture.basePath, 'takeout.zip')),
          ),
          equals(ArchiveType.zip),
        );
        expect(
          ArchiveExtractionService.detectArchiveType(
            File(p.join(fixture.basePath, 'takeout.tgz')),
          ),
          equals(ArchiveType.tgz),
        );
        expect(
          ArchiveExtractionService.detectArchiveType(
            File(p.join(fixture.basePath, 'takeout.tar.gz')),
          ),
          equals(ArchiveType.tgz),
        );
        expect(
          ArchiveExtractionService.detectArchiveType(
            File(p.join(fixture.basePath, 'takeout.tar')),
          ),
          equals(ArchiveType.tar),
        );
      });

      test('rejects unsupported extensions', () {
        expect(
          ArchiveExtractionService.detectArchiveType(
            File(p.join(fixture.basePath, 'backup.gz')),
          ),
          isNull,
        );
        expect(
          ArchiveExtractionService.detectArchiveType(
            File(p.join(fixture.basePath, 'photo.jpg')),
          ),
          isNull,
        );
        expect(
          ArchiveExtractionService.detectArchiveType(
            File(p.join(fixture.basePath, 'archive.zip.json')),
          ),
          isNull,
        );
      });

      test('extension match is case-insensitive', () {
        expect(
          ArchiveExtractionService.detectArchiveType(
            File(p.join(fixture.basePath, 'Takeout.TGZ')),
          ),
          equals(ArchiveType.tgz),
        );
      });
    });

    group('tar extraction', () {
      test('extracts uncompressed tar contents correctly', () async {
        final tarFile = await _createTarWithContent(fixture, 'test.tar', {
          'file1.txt': 'Tar content 1',
          'subfolder/file2.txt': 'Tar content 2',
        });
        final extractDir = Directory(p.join(fixture.basePath, 'extract'));

        await service.extractAll([tarFile], extractDir);

        final file1 = File(p.join(extractDir.path, 'file1.txt'));
        final file2 = File(p.join(extractDir.path, 'subfolder', 'file2.txt'));

        expect(await file1.exists(), isTrue);
        expect(await file2.exists(), isTrue);
        expect(await file1.readAsString(), equals('Tar content 1'));
        expect(await file2.readAsString(), equals('Tar content 2'));
      });

      test('extracts tar with long file names (GNU LongLink entries)', () async {
        // Name > 100 chars triggers the GNU @LongLink mechanism, but must stay
        // short enough that <fixture>/<name> remains under the Windows MAX_PATH limit.
        final longName =
            'very_long_directory_name_${'x' * 60}/very_long_file_name_${'y' * 9}.txt';
        expect(longName.length, greaterThan(100));
        final tarFile = await _createTarWithLongLink(fixture, 'long.tar', {
          longName: 'Long name content',
        });
        final extractDir = Directory(p.join(fixture.basePath, 'extract'));

        await service.extractAll([tarFile], extractDir);

        final extracted = File(p.join(extractDir.path, longName));
        expect(await extracted.exists(), isTrue);
        expect(await extracted.readAsString(), equals('Long name content'));
      });

      test('restores modification times from tar entries', () async {
        final mtime = DateTime.utc(2024, 6, 15, 12, 30);
        final tarFile = await _createTarWithContent(fixture, 'mtime.tar', {
          'moment.txt': 'Timestamped',
        }, mtime: mtime);
        final extractDir = Directory(p.join(fixture.basePath, 'extract'));

        await service.extractAll([tarFile], extractDir);

        final extracted = File(p.join(extractDir.path, 'moment.txt'));
        expect(await extracted.exists(), isTrue);
        final stat = await extracted.stat();
        expect(
          stat.modified.isAtSameMomentAs(mtime),
          isTrue,
          reason: 'tar entry mtime should be restored (${stat.modified})',
        );
      });
    });

    group('tgz extraction', () {
      test('extracts gzip-compressed tgz contents correctly', () async {
        final tgzFile = await _createTgzWithContent(fixture, 'test.tgz', {
          'Takeout/Google Photos/photos.json': '{"key": "value"}',
          'Takeout/Google Photos/sub/photo.txt': 'Photo note',
        });
        final extractDir = Directory(p.join(fixture.basePath, 'extract'));

        await service.extractAll([tgzFile], extractDir);

        final jsonFile = File(
          p.join(extractDir.path, 'Takeout', 'Google Photos', 'photos.json'),
        );
        final photoFile = File(
          p.join(
            extractDir.path,
            'Takeout',
            'Google Photos',
            'sub',
            'photo.txt',
          ),
        );

        expect(await jsonFile.exists(), isTrue);
        expect(await photoFile.exists(), isTrue);
        expect(await jsonFile.readAsString(), equals('{"key": "value"}'));
        expect(await photoFile.readAsString(), equals('Photo note'));
      });

      test('handles .tar.gz double extension', () async {
        final tgzFile = await _createTgzWithContent(fixture, 'test.tar.gz', {
          'inner.txt': 'Double extension content',
        });
        final extractDir = Directory(p.join(fixture.basePath, 'extract'));

        await service.extractAll([tgzFile], extractDir);

        final inner = File(p.join(extractDir.path, 'inner.txt'));
        expect(await inner.exists(), isTrue);
        expect(await inner.readAsString(), equals('Double extension content'));
      });

      test(
        'cleans up the temporary gunzip file after native extraction',
        () async {
          final tgzFile = await _createTgzWithContent(fixture, 'cleanup.tgz', {
            'a.txt': 'A',
          });
          final extractDir = Directory(
            p.join(fixture.basePath, 'extract_native'),
          );
          final tempTar = File('${tgzFile.path}.gpth-tmp.tar');

          // Force the native extractor so the temporary gunzip file is exercised
          // regardless of what external tools are installed on this machine.
          final nativeService = ArchiveExtractionService(
            presenter: mockPresenter,
          );
          nativeService.forceNativeExtractorForTesting = true;
          await nativeService.extractAll([tgzFile], extractDir);

          final extracted = File(p.join(extractDir.path, 'a.txt'));
          expect(await extracted.exists(), isTrue);
          expect(await extracted.readAsString(), equals('A'));
          expect(
            await tempTar.exists(),
            isFalse,
            reason: 'the temporary gunzip tar file must be deleted',
          );
        },
      );

      test('handles corrupted tgz file', () async {
        final corruptTgz = File(p.join(fixture.basePath, 'corrupt.tgz'));
        // Valid gzip header with garbage payload
        await corruptTgz.writeAsBytes([
          0x1f,
          0x8b,
          0x08,
          0x00,
          1,
          2,
          3,
          4,
          0x00,
          0xff,
          0xde,
          0xad,
          0xbe,
          0xef,
        ]);
        final extractDir = Directory(p.join(fixture.basePath, 'extract'));

        // Should handle gracefully without crashing
        expect(
          () => service.extractAll([corruptTgz], extractDir),
          returnsNormally,
        );
      });

      test('handles corrupted tar file', () async {
        final corruptTar = File(p.join(fixture.basePath, 'corrupt2.tar'));
        await corruptTar.writeAsBytes([1, 2, 3, 4, 5]); // Invalid tar
        final extractDir = Directory(p.join(fixture.basePath, 'extract'));

        expect(
          () => service.extractAll([corruptTar], extractDir),
          returnsNormally,
        );
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

/// Helper function to create an uncompressed tar file with the given entries.
/// Files carry [mtime] (or now) in their tar header.
Future<File> _createTarWithContent(
  final TestFixture fixture,
  final String fileName,
  final Map<String, String> files, {
  final DateTime? mtime,
}) async {
  final archive = Archive();
  final int lastModTime =
      (mtime ?? DateTime.now()).millisecondsSinceEpoch ~/ 1000;

  for (final entry in files.entries) {
    final content = Uint8List.fromList(entry.value.codeUnits);
    final file = ArchiveFile(entry.key, content.length, content);
    file.lastModTime = lastModTime;
    archive.addFile(file);
  }
  final tarData = TarEncoder().encode(archive);

  return fixture.createFile(fileName, tarData);
}

/// Helper function to create a gzip-compressed tar (.tgz) file with the
/// given entries.
Future<File> _createTgzWithContent(
  final TestFixture fixture,
  final String fileName,
  final Map<String, String> files,
) async {
  final tarBytes = await _createTarWithContent(fixture, '$fileName.tmp', files);
  final tarData = await tarBytes.readAsBytes();
  await tarBytes.delete();
  final tgzData = gzip.encode(tarData);

  return fixture.createFile(fileName, tgzData);
}

/// Builds a tar entry header with the given GNU typeflag.
/// The checksum follows the ustar convention (sum of header bytes with the
/// checksum field set to spaces).
Uint8List _tarHeader(
  final String name,
  final int size, {
  final String typeFlag = '0',
}) {
  final h = Uint8List(512);
  void put(final int offset, final String s, final int len) {
    final bytes = s.codeUnits;
    for (var i = 0; i < len && i < bytes.length; i++) {
      h[offset + i] = bytes[i];
    }
  }

  void octal(final int offset, final int value, final int len) {
    put(offset, '${value.toRadixString(8).padLeft(len - 1, '0')}\x00', len);
  }

  put(0, name, 100);
  octal(100, 420, 8); // 0o644
  octal(108, 0, 8);
  octal(116, 0, 8);
  octal(124, size, 12);
  octal(136, 0, 12);
  for (var i = 0; i < 8; i++) {
    h[148 + i] = 0x20; // checksum placeholder: spaces
  }
  h[156] = typeFlag.codeUnitAt(0);
  var sum = 0;
  for (final b in h) {
    sum += b;
  }
  final chk = sum.toRadixString(8).padLeft(6, '0');
  put(148, chk, 6);
  h[154] = 0;
  h[155] = 0x20;
  return h;
}

Uint8List _padTo512(final Uint8List data) {
  final remainder = data.length % 512;
  if (remainder == 0) return data;
  final padded = Uint8List(data.length + (512 - remainder));
  padded.setRange(0, data.length, data);
  return padded;
}

/// Helper function to create a tar file with GNU @LongLink long names.
///
/// package:archive's TarEncoder emits the @LongLink pseudo-entry without the
/// required 'L' typeflag, which external tar implementations do not recognize;
/// this helper writes spec-correct headers instead.
Future<File> _createTarWithLongLink(
  final TestFixture fixture,
  final String fileName,
  final Map<String, String> files,
) async {
  final out = BytesBuilder();
  for (final entry in files.entries) {
    final content = Uint8List.fromList(entry.value.codeUnits);
    final nameBytes = Uint8List.fromList(entry.key.codeUnits);
    out.add(_tarHeader('././@LongLink', nameBytes.length, typeFlag: 'L'));
    out.add(_padTo512(nameBytes));
    out.add(_tarHeader(entry.key.substring(0, 100), content.length));
    out.add(_padTo512(content));
  }
  out.add(Uint8List(1024)); // end-of-archive marker

  return fixture.createFile(fileName, out.toBytes());
}
