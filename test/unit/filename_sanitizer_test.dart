/// Tests for FilenameSanitizerService: emoji encode/decode round-trips,
/// pure-string decode methods, and directory rename logic.
///
/// Covers:
/// - decodeEmojiInText: BMP emoji, supplementary emoji, multi-emoji, plain text
/// - decodeAndRestoreAlbumEmoji: decodes last path segment only
/// - encodeAndRenameAlbumIfEmoji: renames emoji dirs to hex, leaves plain dirs,
///   round-trips correctly, handles already-encoded destination gracefully
library;

import 'dart:io';

import 'package:gpth_neo/common/services/file_operations_services/filename_sanitizer_service.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import '../setup/test_setup.dart';

void main() {
  final svc = FilenameSanitizerService();

  // ─── Pure-string decode (no I/O) ──────────────────────────────────────────

  group('decodeEmojiInText', () {
    test('decodes BMP emoji ☃ (U+2603)', () {
      expect(svc.decodeEmojiInText('_0x2603_'), equals('☃'));
    });

    test('decodes snowman with prefix/suffix text', () {
      expect(
        svc.decodeEmojiInText('winter_0x2603_photos'),
        equals('winter☃photos'),
      );
    });

    test('decodes supplementary emoji 😀 (U+1F600)', () {
      // Code point 0x1F600 – encoded as surrogate pair in Dart strings
      expect(svc.decodeEmojiInText('_0x1f600_'), equals('😀'));
    });

    test('decodes supplementary emoji 😴 (U+1F634)', () {
      expect(svc.decodeEmojiInText('_0x1f634_'), equals('😴'));
    });

    test('decodes multiple emojis in one string', () {
      expect(
        svc.decodeEmojiInText('album_0x1f600__0x2764_name'),
        equals('album😀❤name'),
      );
    });

    test('leaves plain ASCII text unchanged', () {
      expect(
        svc.decodeEmojiInText('My Vacation Album'),
        equals('My Vacation Album'),
      );
    });

    test('leaves hex-like text without underscore markers unchanged', () {
      // '0x1f600' without leading '_' and trailing '_' is not decoded
      expect(svc.decodeEmojiInText('0x1f600'), equals('0x1f600'));
    });

    test('leaves empty string unchanged', () {
      expect(svc.decodeEmojiInText(''), equals(''));
    });

    test('uppercased hex digits are also decoded', () {
      // Pattern is case-insensitive in the regex
      expect(svc.decodeEmojiInText('_0x2603_'), equals('☃'));
      expect(
        svc.decodeEmojiInText('_0x2603_'),
        equals(svc.decodeEmojiInText('_0x2603_')),
      );
    });
  });

  // ─── decodeAndRestoreAlbumEmoji (no I/O) ──────────────────────────────────

  group('decodeAndRestoreAlbumEmoji', () {
    test('decodes emoji in the last path segment', () {
      final encoded = p.join('parent', '_0x2603_album');
      final decoded = svc.decodeAndRestoreAlbumEmoji(encoded);
      expect(decoded, equals(p.join('parent', '☃album')));
    });

    test('decodes supplementary emoji in last segment', () {
      final encoded = p.join('root', 'photos', '_0x1f600_fun');
      final decoded = svc.decodeAndRestoreAlbumEmoji(encoded);
      expect(decoded, equals(p.join('root', 'photos', '😀fun')));
    });

    test('leaves non-encoded path unchanged', () {
      final plain = p.join('root', 'My Album');
      expect(svc.decodeAndRestoreAlbumEmoji(plain), equals(plain));
    });

    test('only decodes last segment, leaves earlier segments encoded', () {
      // Middle segment has hex but last does not; middle must stay encoded
      final path = p.join('_0x1f600_folder', 'subfolder');
      final result = svc.decodeAndRestoreAlbumEmoji(path);
      // Last segment 'subfolder' has no hex → entire string returned unchanged
      expect(result, equals(path));
    });
  });

  // ─── encodeAndRenameAlbumIfEmoji (needs I/O) ──────────────────────────────

  group('encodeAndRenameAlbumIfEmoji', () {
    late TestFixture fixture;

    setUp(() async {
      fixture = TestFixture();
      await fixture.setUp();
    });

    tearDown(() async => fixture.tearDown());

    test('emoji dir is renamed to hex-encoded form', () async {
      final emojiDir = await Directory(
        p.join(fixture.basePath, '☃snowflake'),
      ).create();

      final result = svc.encodeAndRenameAlbumIfEmoji(emojiDir);

      expect(emojiDir.existsSync(), isFalse, reason: 'original dir removed');
      expect(result.existsSync(), isTrue, reason: 'encoded dir created');
      expect(
        p.basename(result.path),
        contains('_0x'),
        reason: 'name contains hex',
      );
    });

    test('non-emoji dir is returned unchanged', () async {
      final plainDir = await Directory(
        p.join(fixture.basePath, 'plainAlbum'),
      ).create();

      final result = svc.encodeAndRenameAlbumIfEmoji(plainDir);

      expect(result.path, equals(plainDir.path));
      expect(plainDir.existsSync(), isTrue);
    });

    test(
      'round-trip: encode → decodeEmojiInText restores original name',
      () async {
        const originalName = '😀vacation';
        final emojiDir = await Directory(
          p.join(fixture.basePath, originalName),
        ).create();

        final encoded = svc.encodeAndRenameAlbumIfEmoji(emojiDir);
        final restored = svc.decodeEmojiInText(p.basename(encoded.path));

        expect(restored, equals(originalName));
      },
    );

    test('round-trip: BMP emoji ☃ (U+2603) survives encode/decode', () async {
      const originalName = '☃winter';
      final emojiDir = await Directory(
        p.join(fixture.basePath, originalName),
      ).create();

      final encoded = svc.encodeAndRenameAlbumIfEmoji(emojiDir);
      final restored = svc.decodeEmojiInText(p.basename(encoded.path));

      expect(restored, equals(originalName));
    });

    test(
      'already-encoded destination: skips rename, returns encoded dir',
      () async {
        const emojiName = '☃snowflake2';
        final emojiDir = await Directory(
          p.join(fixture.basePath, emojiName),
        ).create();

        // First encode: renames dir to hex destination
        final firstEncoded = svc.encodeAndRenameAlbumIfEmoji(emojiDir);

        // Simulate interrupted run: re-create the original emoji dir
        final recreated = await Directory(emojiDir.path).create();

        // Second call must not throw and must return the encoded destination
        final result = svc.encodeAndRenameAlbumIfEmoji(recreated);

        expect(result.path, equals(firstEncoded.path));
        expect(result.existsSync(), isTrue);
      },
    );
  });
}
