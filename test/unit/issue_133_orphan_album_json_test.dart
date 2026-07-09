/// Test suite for Issue #133: Assets missing in album folders are recovered
/// from the year folders (ALL_PHOTOS).
///
/// Google Takeout sometimes exports album folders that contain only JSON
/// sidecars because the assets themselves were deduplicated into the
/// "Photos from YYYY" folders. The album association must be recovered from
/// the orphaned sidecar and attached to the matching year-folder entity.
library;

import 'dart:io';
import 'package:gpth_neo/gpth_lib_exports.dart';
import 'package:path/path.dart' as path;
import 'package:test/test.dart';

import '../setup/test_setup.dart';

void main() {
  group('Issue #133: Orphaned album JSON sidecars', () {
    group('JsonMetadataMatcherService.getMediaNameCandidatesForJsonName', () {
      test('extracts name from supplemental-metadata sidecar', () {
        expect(
          JsonMetadataMatcherService.getMediaNameCandidatesForJsonName(
            'photo.jpg.supplemental-metadata.json',
          ),
          equals(['photo.jpg']),
        );
      });

      test('extracts name from legacy plain sidecar', () {
        expect(
          JsonMetadataMatcherService.getMediaNameCandidatesForJsonName(
            'photo.jpg.json',
          ),
          equals(['photo.jpg']),
        );
      });

      test('extracts name from truncated supplemental suffix', () {
        expect(
          JsonMetadataMatcherService.getMediaNameCandidatesForJsonName(
            'photo.jpg.suppl.json',
          ),
          equals(['photo.jpg']),
        );
        expect(
          JsonMetadataMatcherService.getMediaNameCandidatesForJsonName(
            'photo.jpg.supplemental-met.json',
          ),
          equals(['photo.jpg']),
        );
      });

      test('handles number at the end of the suffix', () {
        expect(
          JsonMetadataMatcherService.getMediaNameCandidatesForJsonName(
            'IMG_2367.HEIC.supplemental-metadata(1).json',
          ),
          equals(['IMG_2367(1).HEIC', 'IMG_2367.HEIC']),
        );
      });

      test('handles number in the middle', () {
        expect(
          JsonMetadataMatcherService.getMediaNameCandidatesForJsonName(
            'IMG_2367.HEIC(1).supplemental-metadata.json',
          ),
          equals(['IMG_2367(1).HEIC', 'IMG_2367.HEIC']),
        );
      });

      test('returns empty list for non-JSON files', () {
        expect(
          JsonMetadataMatcherService.getMediaNameCandidatesForJsonName(
            'photo.jpg',
          ),
          isEmpty,
        );
      });
    });

    group('JsonMetadataMatcherService.isMediaJsonSidecarName', () {
      test('accepts per-media sidecars', () {
        expect(
          JsonMetadataMatcherService.isMediaJsonSidecarName(
            'photo.jpg.supplemental-metadata.json',
          ),
          isTrue,
        );
        expect(
          JsonMetadataMatcherService.isMediaJsonSidecarName('video.mp4.json'),
          isTrue,
        );
        expect(
          JsonMetadataMatcherService.isMediaJsonSidecarName(
            'clip.MP.supplemental-metadata.json',
          ),
          isTrue,
        );
      });

      test('rejects album-level metadata files', () {
        expect(
          JsonMetadataMatcherService.isMediaJsonSidecarName('metadata.json'),
          isFalse,
        );
        expect(
          JsonMetadataMatcherService.isMediaJsonSidecarName(
            'print-subscriptions.json',
          ),
          isFalse,
        );
        expect(
          JsonMetadataMatcherService.isMediaJsonSidecarName(
            'shared_album_comments.json',
          ),
          isFalse,
        );
        expect(
          JsonMetadataMatcherService.isMediaJsonSidecarName(
            'user-generated-memory-titles.json',
          ),
          isFalse,
        );
      });
    });

    group('Step 2 discovery recovers album associations', () {
      late TestFixture fixture;

      setUp(() async {
        fixture = TestFixture();
        await fixture.setUp();
      });

      tearDown(() async {
        await fixture.tearDown();
      });

      ProcessingContext makeContext() {
        final outputDir = fixture.createDirectory('output');
        return ProcessingContext(
          config: ProcessingConfig(
            inputPath: fixture.basePath,
            outputPath: outputDir.path,
          ),
          mediaCollection: MediaEntityCollection([]),
          inputDirectory: Directory(fixture.basePath),
          outputDirectory: outputDir,
        );
      }

      File writeSidecar(
        final String relativePath, {
        required final String title,
        final String? timestamp,
      }) {
        final file = File(path.join(fixture.basePath, relativePath));
        file.createSync(recursive: true);
        final String taken = timestamp != null
            ? ', "photoTakenTime": {"timestamp": "$timestamp"}'
            : '';
        file.writeAsStringSync('{"title": "$title"$taken}', flush: true);
        return file;
      }

      test('attaches album membership from a JSON-only album folder', () async {
        fixture.createImageWithExifInDir(
          path.join(fixture.basePath, 'Photos from 2023'),
          'photo.jpg',
        );
        // Album folder contains ONLY the sidecar — the asset was
        // deduplicated into the year folder by Takeout.
        writeSidecar(
          path.join('Vacation', 'photo.jpg.supplemental-metadata.json'),
          title: 'photo.jpg',
          timestamp: '1687110000', // 2023-06-18
        );

        final context = makeContext();
        final result = await const DiscoverMediaService().discover(context);

        expect(result.orphanJsonAssociations, equals(1));
        expect(result.orphanJsonUnmatched, equals(0));
        expect(context.mediaCollection.length, equals(1));
        final entity = context.mediaCollection[0];
        expect(entity.albumNames, contains('Vacation'));
        expect(
          entity.albumsMap['Vacation']!.sourceDirectories,
          contains(path.join(fixture.basePath, 'Vacation')),
        );
      });

      test('does not recover when the asset exists in the album', () async {
        fixture.createImageWithExifInDir(
          path.join(fixture.basePath, 'Photos from 2023'),
          'photo.jpg',
        );
        fixture.createImageWithExifInDir(
          path.join(fixture.basePath, 'Vacation'),
          'photo.jpg',
        );
        writeSidecar(
          path.join('Vacation', 'photo.jpg.supplemental-metadata.json'),
          title: 'photo.jpg',
        );

        final context = makeContext();
        final result = await const DiscoverMediaService().discover(context);

        expect(result.orphanJsonAssociations, equals(0));
        // Year entity must not carry the album (the album copy does).
        final yearEntity = context.mediaCollection.entities.firstWhere(
          (final e) => e.primaryFile.sourcePath.contains('Photos from 2023'),
        );
        expect(yearEntity.albumNames, isEmpty);
      });

      test('counts sidecars whose asset exists nowhere as unmatched', () async {
        fixture.createImageWithExifInDir(
          path.join(fixture.basePath, 'Photos from 2023'),
          'other.jpg',
        );
        writeSidecar(
          path.join('Vacation', 'missing.jpg.supplemental-metadata.json'),
          title: 'missing.jpg',
        );

        final context = makeContext();
        final result = await const DiscoverMediaService().discover(context);

        expect(result.orphanJsonAssociations, equals(0));
        expect(result.orphanJsonUnmatched, equals(1));
      });

      test('disambiguates same-name assets by capture year', () async {
        fixture.createImageWithExifInDir(
          path.join(fixture.basePath, 'Photos from 2022'),
          'pic.jpg',
        );
        fixture.createImageWithExifInDir(
          path.join(fixture.basePath, 'Photos from 2023'),
          'pic.jpg',
        );
        writeSidecar(
          path.join('Trip', 'pic.jpg.supplemental-metadata.json'),
          title: 'pic.jpg',
          timestamp: '1687110000', // 2023-06-18
        );

        final context = makeContext();
        final result = await const DiscoverMediaService().discover(context);

        expect(result.orphanJsonAssociations, equals(1));
        final entity2023 = context.mediaCollection.entities.firstWhere(
          (final e) => e.primaryFile.sourcePath.contains('Photos from 2023'),
        );
        final entity2022 = context.mediaCollection.entities.firstWhere(
          (final e) => e.primaryFile.sourcePath.contains('Photos from 2022'),
        );
        expect(entity2023.albumNames, contains('Trip'));
        expect(entity2022.albumNames, isEmpty);
      });

      test(
        'resolves a numbered sidecar to the numbered year-folder file, not the base file',
        () async {
          // Google Takeout commonly disambiguates sidecar *filenames* with a
          // "(1)" suffix when two same-named files were uploaded, but the
          // "title" field inside the JSON still records the plain original
          // name for every duplicate. JsonMetadataMatcherService already
          // anticipates this: getMediaNameCandidatesForJsonName returns the
          // numbered candidate first (see the "handles number at the end of
          // the suffix" test above). This test guards that the numbered
          // candidate is actually honored when a same-named base file also
          // exists, instead of the generic "title" lookup grabbing the base
          // file first.
          fixture.createImageWithExifInDir(
            path.join(fixture.basePath, 'Photos from 2023'),
            'pic.jpg',
          );
          fixture.createImageWithExifInDir(
            path.join(fixture.basePath, 'Photos from 2023'),
            'pic(1).jpg',
          );
          writeSidecar(
            path.join('Trip', 'pic.jpg.supplemental-metadata(1).json'),
            title:
                'pic.jpg', // title omits the "(1)" — only the filename has it.
            timestamp: '1687110000', // 2023-06-18
          );

          final context = makeContext();
          final result = await const DiscoverMediaService().discover(context);

          expect(result.orphanJsonAssociations, equals(1));
          final numbered = context.mediaCollection.entities.firstWhere(
            (final e) => e.primaryFile.sourcePath.endsWith('pic(1).jpg'),
          );
          final base = context.mediaCollection.entities.firstWhere(
            (final e) => e.primaryFile.sourcePath.endsWith('pic.jpg'),
          );
          expect(
            numbered.albumNames,
            contains('Trip'),
            reason:
                'the "(1)" sidecar must attach to the numbered file it names',
          );
          expect(
            base.albumNames,
            isEmpty,
            reason:
                'the base file must not be picked as a stand-in for the numbered one',
          );
        },
      );

      test(
        'does not steal an unrelated numbered file from the wrong year',
        () async {
          // The "(N)" numbering is per-directory. Here the album held two
          // photos both uploaded as "pic.jpg" (taken 2022 and 2023) — they
          // collided only inside the album folder, so only the sidecars are
          // numbered. In the year folders both keep their plain name, and
          // 2023 additionally holds an UNRELATED "pic(1).jpg" from a
          // within-year collision. The 2022 sidecar's numbered lookup must
          // not latch onto that unrelated 2023 file; the capture year has to
          // veto it and fall through to the plain name.
          fixture.createImageWithExifInDir(
            path.join(fixture.basePath, 'Photos from 2022'),
            'pic.jpg',
          );
          fixture.createImageWithExifInDir(
            path.join(fixture.basePath, 'Photos from 2023'),
            'pic.jpg',
          );
          fixture.createImageWithExifInDir(
            path.join(fixture.basePath, 'Photos from 2023'),
            'pic(1).jpg', // unrelated third photo
          );
          writeSidecar(
            path.join('Trip', 'pic.jpg.supplemental-metadata.json'),
            title: 'pic.jpg',
            timestamp: '1687110000', // 2023-06-18
          );
          writeSidecar(
            path.join('Trip', 'pic.jpg.supplemental-metadata(1).json'),
            title: 'pic.jpg',
            timestamp: '1655574000', // 2022-06-18
          );

          final context = makeContext();
          final result = await const DiscoverMediaService().discover(context);

          expect(result.orphanJsonAssociations, equals(2));
          final entity2022 = context.mediaCollection.entities.firstWhere(
            (final e) => e.primaryFile.sourcePath.contains('Photos from 2022'),
          );
          final entity2023 = context.mediaCollection.entities.firstWhere(
            (final e) =>
                e.primaryFile.sourcePath.contains('Photos from 2023') &&
                e.primaryFile.sourcePath.endsWith('pic.jpg'),
          );
          final unrelated = context.mediaCollection.entities.firstWhere(
            (final e) => e.primaryFile.sourcePath.endsWith('pic(1).jpg'),
          );
          expect(
            entity2022.albumNames,
            contains('Trip'),
            reason: 'the 2022 sidecar must resolve to the 2022 photo',
          );
          expect(entity2023.albumNames, contains('Trip'));
          expect(
            unrelated.albumNames,
            isEmpty,
            reason:
                'the unrelated 2023 "pic(1).jpg" must not inherit the album '
                'just because its name matches the numbered sidecar',
          );
        },
      );

      test(
        'derives the numbered name from the full-length title when the sidecar name is truncated',
        () async {
          // The 51-character sidecar filename cap truncates the media-name
          // portion, but the JSON "title" keeps the full name. Only
          // title + "(N)" can find the on-disk numbered duplicate here.
          fixture.createImageWithExifInDir(
            path.join(fixture.basePath, 'Photos from 2023'),
            'a_very_long_original_filename.jpg',
          );
          fixture.createImageWithExifInDir(
            path.join(fixture.basePath, 'Photos from 2023'),
            'a_very_long_original_filename(1).jpg',
          );
          writeSidecar(
            path.join('Trip', 'a_very_long_orig.jpg.suppl(1).json'),
            title: 'a_very_long_original_filename.jpg',
            timestamp: '1687110000', // 2023-06-18
          );

          final context = makeContext();
          final result = await const DiscoverMediaService().discover(context);

          expect(result.orphanJsonAssociations, equals(1));
          final numbered = context.mediaCollection.entities.firstWhere(
            (final e) => e.primaryFile.sourcePath.endsWith(
              'a_very_long_original_filename(1).jpg',
            ),
          );
          final base = context.mediaCollection.entities.firstWhere(
            (final e) => e.primaryFile.sourcePath.endsWith(
              'a_very_long_original_filename.jpg',
            ),
          );
          expect(
            numbered.albumNames,
            contains('Trip'),
            reason:
                'the numbered name derived from the full-length title must '
                'win over the truncated filename-derived candidates',
          );
          expect(base.albumNames, isEmpty);
        },
      );

      test(
        'falls back to the plain copy when the numbered duplicate exists nowhere',
        () async {
          // The "(1)" sidecar names a duplicate that has no numbered file in
          // any year folder (e.g. the twin lives under a plain name in
          // another year that was not exported). Rather than dropping the
          // membership, recovery must fall back to the plain-named copy.
          fixture.createImageWithExifInDir(
            path.join(fixture.basePath, 'Photos from 2023'),
            'pic.jpg',
          );
          writeSidecar(
            path.join('Trip', 'pic.jpg.supplemental-metadata(1).json'),
            title: 'pic.jpg',
            timestamp: '1687110000', // 2023-06-18
          );

          final context = makeContext();
          final result = await const DiscoverMediaService().discover(context);

          expect(result.orphanJsonAssociations, equals(1));
          expect(result.orphanJsonUnmatched, equals(0));
          final entity = context.mediaCollection[0];
          expect(
            entity.albumNames,
            contains('Trip'),
            reason:
                'membership must not be lost when the numbered twin cannot '
                'be found anywhere',
          );
        },
      );

      test(
        'recovers the same year-folder asset into multiple orphan albums',
        () async {
          // A single deduplicated asset can be referenced by more than one
          // album's orphaned sidecar; every membership must be recovered,
          // not just the first one encountered.
          fixture.createImageWithExifInDir(
            path.join(fixture.basePath, 'Photos from 2023'),
            'shared.jpg',
          );
          writeSidecar(
            path.join('Vacation', 'shared.jpg.supplemental-metadata.json'),
            title: 'shared.jpg',
            timestamp: '1687110000',
          );
          writeSidecar(
            path.join('Highlights', 'shared.jpg.supplemental-metadata.json'),
            title: 'shared.jpg',
            timestamp: '1687110000',
          );

          final context = makeContext();
          final result = await const DiscoverMediaService().discover(context);

          expect(result.orphanJsonAssociations, equals(2));
          expect(context.mediaCollection.length, equals(1));
          final entity = context.mediaCollection[0];
          expect(entity.albumNames, containsAll(['Vacation', 'Highlights']));
        },
      );

      test('matches year-folder files case-insensitively', () async {
        fixture.createImageWithExifInDir(
          path.join(fixture.basePath, 'Photos from 2023'),
          'CaseTest.JPG',
        );
        writeSidecar(
          path.join('Vacation', 'casetest.jpg.supplemental-metadata.json'),
          title: 'casetest.jpg',
          timestamp: '1687110000',
        );

        final context = makeContext();
        final result = await const DiscoverMediaService().discover(context);

        expect(result.orphanJsonAssociations, equals(1));
        expect(result.orphanJsonUnmatched, equals(0));
        final entity = context.mediaCollection.entities.firstWhere(
          (final e) => e.primaryFile.sourcePath.endsWith('CaseTest.JPG'),
        );
        expect(entity.albumNames, contains('Vacation'));
      });

      test('ignores album-level metadata files', () async {
        fixture.createImageWithExifInDir(
          path.join(fixture.basePath, 'Photos from 2023'),
          'photo.jpg',
        );
        fixture.createImageWithExifInDir(
          path.join(fixture.basePath, 'Vacation'),
          'photo.jpg',
        );
        final metadataFile = File(
          path.join(fixture.basePath, 'Vacation', 'metadata.json'),
        );
        metadataFile.createSync(recursive: true);
        metadataFile.writeAsStringSync('{"title": "Vacation"}', flush: true);

        final context = makeContext();
        final result = await const DiscoverMediaService().discover(context);

        expect(result.orphanJsonAssociations, equals(0));
        expect(result.orphanJsonUnmatched, equals(0));
      });
    });
  });
}
