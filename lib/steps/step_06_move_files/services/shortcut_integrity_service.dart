import 'dart:io';

import 'package:gpth_neo/gpth_lib_exports.dart';
import 'package:path/path.dart' as path;

/// Verifies album shortcuts after later pipeline stages have finished.
///
/// Shortcut mode deliberately stores only one physical file in ALL_PHOTOS. A
/// later stage must therefore never silently turn an album entry back into a
/// regular file. Missing links are restored from the entity's canonical output
/// file. Existing regular files are reported, but deliberately not replaced:
/// replacing an unexpected file by name alone could discard user data.
class ShortcutIntegrityService with LoggerMixin {
  Future<ShortcutIntegritySummary> verifyAndRestore(
    final MediaEntityCollection collection, {
    required final Directory outputDirectory,
  }) async {
    var verified = 0;
    var restored = 0;
    var conflicts = 0;

    for (final entity in collection.asList()) {
      final String? canonicalPath = entity.primaryFile.targetPath;
      if (canonicalPath == null || canonicalPath.isEmpty) continue;

      final File canonicalFile = File(canonicalPath);
      if (!await canonicalFile.exists()) continue;

      for (final shortcut in entity.secondaryFiles.where(
        (final file) => file.isShortcut && file.targetPath != null,
      )) {
        final String shortcutPath = shortcut.targetPath!;
        final Link link = Link(shortcutPath);
        if (await link.exists()) {
          verified++;
          continue;
        }

        final FileSystemEntityType entryType = await FileSystemEntity.type(
          shortcutPath,
          followLinks: false,
        );
        if (entryType == FileSystemEntityType.link) {
          // A broken link occupies the pathname and must be removed before it
          // can be recreated against the canonical file.
          try {
            await link.delete();
          } catch (error) {
            conflicts++;
            logError(
              "[Step 7/8] Could not remove broken album shortcut '$shortcutPath': $error",
              forcePrint: true,
            );
            continue;
          }
        }

        final File regularFile = File(shortcutPath);
        if (await regularFile.exists()) {
          try {
            final Directory conflictsDir = Directory(
              path.join(
                outputDirectory.path,
                'Shortcut Conflicts',
                'Post EXIF validation',
              ),
            );
            final File preserved = await FileOperationService().moveFile(
              regularFile,
              conflictsDir,
            );
            logWarning(
              '[Step 7/8] Moved unexpected physical album entry outside '
              "Albums before restoring shortcut: '$shortcutPath' -> '${preserved.path}'.",
              forcePrint: true,
            );
          } catch (error) {
            conflicts++;
            logError(
              '[Step 7/8] Could not move unexpected physical album entry '
              "'$shortcutPath' before restoring shortcut: $error",
              forcePrint: true,
            );
            continue;
          }
        }

        try {
          final Directory parent = Directory(path.dirname(shortcutPath));
          await parent.create(recursive: true);
          final String relativeTarget = path.relative(
            canonicalPath,
            from: parent.path,
          );
          await link.create(relativeTarget);
          restored++;
        } catch (error) {
          conflicts++;
          logError(
            '[Step 7/8] Could not restore album shortcut '
            "'$shortcutPath' -> '$canonicalPath': $error",
            forcePrint: true,
          );
        }
      }
    }

    if (restored > 0 || conflicts > 0) {
      logPrint(
        '[Step 7/8] Album shortcut integrity: $verified verified, '
        '$restored restored, $conflicts unresolved conflict(s).',
      );
    }

    return ShortcutIntegritySummary(
      verified: verified,
      restored: restored,
      conflicts: conflicts,
    );
  }
}

class ShortcutIntegritySummary {
  const ShortcutIntegritySummary({
    required this.verified,
    required this.restored,
    required this.conflicts,
  });

  final int verified;
  final int restored;
  final int conflicts;
}
