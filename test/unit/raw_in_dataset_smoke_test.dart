import 'dart:io';
import 'package:test/test.dart';
import '../setup/test_setup.dart';

void main() {
  test('realistic dataset can include RAW samples (smoke)', () async {
    final fixture = TestFixture();
    await fixture.setUp();
    try {
      final takeoutPath = await fixture.generateRealisticTakeoutDataset(
        includeRawSamples: true,
        photosPerYear: 2,
        yearSpan: 1,
        albumCount: 1,
        albumOnlyPhotos: 0,
      );
      final dir = Directory(takeoutPath);
      final cacheDir = Directory('test/raw_samples');
      final rawExts = ['.CR2', '.RAF', '.NEF', '.ARW', '.RW2', '.DNG'];
      final files = <File>[];
      await for (final entity in dir.list(recursive: true)) {
        if (entity is File) files.add(entity);
      }
      final hasRaw = files.any(
        (final f) => rawExts.any((final e) => f.path.toUpperCase().endsWith(e)),
      );
      expect(dir.existsSync(), isTrue);
      expect(files.isNotEmpty, isTrue);
      if (cacheDir.existsSync() && cacheDir.listSync().isNotEmpty) {
        // If cache has samples we expect at least one RAW file copied
        expect(
          hasRaw,
          isTrue,
          reason: 'Cached RAW samples should be included in dataset',
        );
      } else {
        // Without cache we just log
        print('RAW cache directory empty; RAW inclusion not asserted');
      }
    } finally {
      await fixture.tearDown();
    }
  }, timeout: const Timeout(Duration(minutes: 2)));
}
