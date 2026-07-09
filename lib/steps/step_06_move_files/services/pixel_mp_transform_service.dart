import 'dart:io';
import 'package:gpth_neo/common/services/media_services/motion_photos.dart';
import 'package:gpth_neo/gpth_lib_exports.dart';
import 'package:path/path.dart' as path;

/// Handles all in-place pre-move transformations for Pixel .MP/.MV files
/// before the main move pipeline runs.
///
/// All methods mutate [ProcessingContext.mediaCollection] in-place:
///   - `primaryFile.sourcePath` is updated to point at the transformed file.
///   - Entities whose files are consumed or suppressed are removed from the
///     collection so the move pipeline never sees them.
///
/// No source files are ever deleted. Original input files are left behind with
/// a `[left-behind]` verbose log entry.
class PixelMpTransformService with LoggerMixin {
  const PixelMpTransformService();

  // ─────────────────────────────────────────────────────────────────────────
  // Public entry point
  // ─────────────────────────────────────────────────────────────────────────

  /// Runs all configured transform passes and returns the total count of
  /// entities whose [primaryFile.sourcePath] was updated.
  Future<int> transformAll(final ProcessingContext context) async {
    final total = await _transformPixelPrimaries(context);

    if (context.config.verbose) {
      logDebug(
        '[Step 6/8] Transformed $total Pixel .MP/.MV primary files to ${describeFormat(context.config.pixelMpTransformFormat)}',
        forcePrint: true,
      );
    }

    return total;
  }

  /// Human-readable label for the configured output format.
  String describeFormat(final PixelMpTransformFormat format) {
    switch (format) {
      case PixelMpTransformFormat.mp4:
        return '.mp4';
      case PixelMpTransformFormat.jpg:
        return '.jpg';
      case PixelMpTransformFormat.still:
        return 'still image';
    }
  }

  // ─────────────────────────────────────────────────────────────────────────
  // Dispatcher
  // ─────────────────────────────────────────────────────────────────────────

  Future<int> _transformPixelPrimaries(final ProcessingContext context) async {
    switch (context.config.pixelMpTransformFormat) {
      case PixelMpTransformFormat.jpg:
        return _transformPixelPrimariesToMotionJpg(context);
      case PixelMpTransformFormat.still:
        return _transformPixelPrimariesToStill(context);
      case PixelMpTransformFormat.mp4:
        return _transformPixelPrimariesToMp4(context);
    }
  }

  // ─────────────────────────────────────────────────────────────────────────
  // mp4 mode
  // ─────────────────────────────────────────────────────────────────────────

  Future<int> _transformPixelPrimariesToMp4(
    final ProcessingContext context,
  ) async {
    int transformed = 0;

    final collection = context.mediaCollection;
    final entities = collection.asList(); // snapshot
    final transformedPathMap = <String, String>{};

    for (final entity in entities) {
      final files = <FileEntity>[entity.primaryFile, ...entity.secondaryFiles];

      for (final fileEntity in files) {
        final oldPath = fileEntity.sourcePath;
        final oldPathKey = oldPath.toLowerCase();

        // Reuse already-transformed path when multiple FileEntity instances
        // reference the same underlying file.
        final mappedPath = transformedPathMap[oldPathKey];
        if (mappedPath != null) {
          fileEntity.sourcePath = mappedPath;
          continue;
        }

        final lower = oldPath.toLowerCase();
        if (!(lower.endsWith('.mp') || lower.endsWith('.mv'))) {
          continue;
        }

        final dot = oldPath.lastIndexOf('.');
        final newPath = dot > 0
            ? '${oldPath.substring(0, dot)}.mp4'
            : '$oldPath.mp4';

        try {
          final sourceFile = File(oldPath);
          if (!await sourceFile.exists()) {
            final transformedFile = File(newPath);
            if (await transformedFile.exists()) {
              fileEntity.sourcePath = transformedFile.path;
              transformedPathMap[oldPathKey] = transformedFile.path;
            }
            continue;
          }

          final renamed = await sourceFile.rename(newPath);
          // IMPORTANT: still input → update sourcePath, not targetPath
          fileEntity.sourcePath = renamed.path;
          transformedPathMap[oldPathKey] = renamed.path;
          transformed++;

          // #120 fix: if this is the entity's PRIMARY .MP file and the entity
          // has a sidecar (.MP.jpg) as a secondary, remove any standalone entity
          // whose primary matches that sidecar. Without this, the sidecar is
          // moved twice (once via the entity's secondary, once via the standalone
          // primary) causing a collision and stray (1).jpg output files.
          if (fileEntity == entity.primaryFile) {
            final sidecarCandidates = [
              '$oldPath.jpg',
              '$oldPath.JPG',
              '$oldPath.jpeg',
              '$oldPath.JPEG',
            ];
            for (final sidecarPath in sidecarCandidates) {
              final normalizedSidecar = sidecarPath
                  .replaceAll('\\', '/')
                  .toLowerCase();
              final hasSidecarAsSecondary = entity.secondaryFiles.any(
                (final s) =>
                    s.sourcePath.replaceAll('\\', '/').toLowerCase() ==
                    normalizedSidecar,
              );
              if (hasSidecarAsSecondary) {
                _removeEntityDuplicates(collection, entity, sidecarPath);
                break;
              }
            }
          }
        } catch (e) {
          logPrint('[Step 6/8] Warning: Failed to transform $oldPath: $e');
        }
      }
    }

    return transformed;
  }

  // ─────────────────────────────────────────────────────────────────────────
  // jpg mode — Pixel .MP/.MV
  // ─────────────────────────────────────────────────────────────────────────

  Future<int> _transformPixelPrimariesToMotionJpg(
    final ProcessingContext context,
  ) async {
    int transformed = 0;
    final collection = context.mediaCollection;
    final entities = collection.asList();
    final livePhotoService = LivePhotoService();
    // Tracks old-path (lower-case) → new-path for post-pass secondary update.
    final transformedPathMap = <String, String>{};

    for (final entity in entities) {
      final primary = entity.primaryFile;
      final lower = primary.path.toLowerCase();

      if (!(lower.endsWith('.mp') || lower.endsWith('.mv'))) continue;

      final oldPath = primary.path;
      final dot = oldPath.lastIndexOf('.');
      final newPath = dot > 0
          ? '${oldPath.substring(0, dot)}.jpg'
          : '$oldPath.jpg';

      try {
        LivePhotoConversionResult result;
        final preferredStillPath = await _findPreferredStillImagePath(oldPath);

        if (preferredStillPath != null) {
          // If the sidecar is already a motion photo (e.g. a *.MP.jpg that
          // Google exported as a complete JPEG+MP4 container), use it
          // directly as the output. Passing it to
          // convertMotionPhotoToLivePhotoWithStillImage would read its full
          // bytes as "still image data" and then concatenate the video from
          // the .MP file on top, producing a malformed file with two
          // embedded MP4 streams.
          bool sidecarIsAlreadyMotion = false;
          try {
            sidecarIsAlreadyMotion = await MotionPhotos(
              preferredStillPath,
            ).isMotionPhoto();
          } catch (_) {
            // If detection fails, treat as a plain still and let conversion handle it.
          }

          if (sidecarIsAlreadyMotion) {
            if (context.config.verbose) {
              logDebug(
                '[Step 6/8] [left-behind] Sidecar is already a complete motion photo — using directly: $preferredStillPath (source .MP left in input: $oldPath)',
                forcePrint: true,
              );
            }
            primary.sourcePath = preferredStillPath;
            transformedPathMap[oldPath.toLowerCase()] = preferredStillPath;
            _updateEntitySecondaryExtensions(
              entity,
              path.extension(preferredStillPath),
            );
            _removeEntityDuplicates(collection, entity, preferredStillPath);
            transformed++;
            continue;
          }

          result = await livePhotoService
              .convertMotionPhotoToLivePhotoWithStillImage(
                inputPath: oldPath,
                stillImagePath: preferredStillPath,
                outputPath: newPath,
              );

          if (!result.success) {
            logPrint(
              '[Step 6/8] Warning: Sidecar-still motion .jpg conversion failed for ${primary.path}. Falling back to embedded JPEG conversion.',
            );
            final fallbackTarget = File(newPath);
            if (context.config.verbose && await fallbackTarget.exists()) {
              logDebug(
                '[Step 6/8] [left-behind] Incomplete .jpg from failed sidecar conversion left in input; retry with embedded JPEG will overwrite it: ${fallbackTarget.path}',
                forcePrint: true,
              );
            }
            result = await livePhotoService.convertMotionPhotoToLivePhoto(
              inputPath: oldPath,
              outputPath: newPath,
            );
          }
        } else {
          result = await livePhotoService.convertMotionPhotoToLivePhoto(
            inputPath: oldPath,
            outputPath: newPath,
          );
        }

        if (result.success) {
          if (context.config.verbose) {
            logDebug(
              '[Step 6/8] [left-behind] Source .MP left in input after motion .jpg conversion: $oldPath',
              forcePrint: true,
            );
          }
          primary.sourcePath = newPath;
          transformedPathMap[oldPath.toLowerCase()] = newPath;
          _updateEntitySecondaryExtensions(entity, path.extension(newPath));
          if (preferredStillPath != null) {
            _removeEntityDuplicates(collection, entity, preferredStillPath);
          }
          transformed++;
        } else {
          // Conversion failed — fall back to .mp4 rename so the video is preserved.
          final mp4Path = dot > 0
              ? '${oldPath.substring(0, dot)}.mp4'
              : '$oldPath.mp4';
          try {
            final renamed = await File(oldPath).rename(mp4Path);
            primary.sourcePath = renamed.path;
            transformedPathMap[oldPath.toLowerCase()] = renamed.path;
            _updateEntitySecondaryExtensions(
              entity,
              path.extension(renamed.path),
            );
            logPrint(
              '[Step 6/8] Info: ${path.basename(oldPath)} has no embeddable JPEG; renamed to .mp4 as fallback (${result.errorMessage ?? 'unknown error'}).',
            );
          } catch (_) {
            logPrint(
              '[Step 6/8] Warning: Failed to transform ${primary.path} to motion .jpg: ${result.errorMessage ?? 'unknown error'}',
            );
          }
        }
      } catch (e) {
        // Conversion threw — fall back to .mp4 rename so the video is preserved.
        final mp4Path = dot > 0
            ? '${oldPath.substring(0, dot)}.mp4'
            : '$oldPath.mp4';
        try {
          final renamed = await File(oldPath).rename(mp4Path);
          primary.sourcePath = renamed.path;
          transformedPathMap[oldPath.toLowerCase()] = renamed.path;
          _updateEntitySecondaryExtensions(
            entity,
            path.extension(renamed.path),
          );
          logPrint(
            '[Step 6/8] Info: ${path.basename(oldPath)} has no embeddable JPEG; renamed to .mp4 as fallback ($e).',
          );
        } catch (_) {
          logPrint(
            '[Step 6/8] Warning: Failed to transform ${primary.path} to motion .jpg: $e',
          );
        }
      }
    }

    // Propagate path changes to secondary FileEntity instances in other entities
    // that reference the same .MP/.MV file (e.g. album symlinks).
    _propagateTransformToSecondaries(entities, transformedPathMap);

    return transformed;
  }

  // ─────────────────────────────────────────────────────────────────────────
  // still mode — Pixel .MP/.MV
  // ─────────────────────────────────────────────────────────────────────────

  Future<int> _transformPixelPrimariesToStill(
    final ProcessingContext context,
  ) async {
    int transformed = 0;
    final collection = context.mediaCollection;
    final entities = collection.asList();
    const extractor = MotionPhotoExtractorService();
    // Tracks old-path (lower-case) → new-path for post-pass secondary update.
    final transformedPathMap = <String, String>{};

    for (final entity in entities) {
      final primary = entity.primaryFile;
      final lower = primary.path.toLowerCase();

      if (!(lower.endsWith('.mp') || lower.endsWith('.mv'))) continue;

      final oldPath = primary.path;

      try {
        final dot = oldPath.lastIndexOf('.');
        final basePath = dot > 0 ? oldPath.substring(0, dot) : oldPath;

        // Priority 1: plain still — <stem>.jpg next to the .MP file.
        // This is a straight JPEG with no embedded video; use it directly.
        final plainCandidates = <String>[
          '$basePath.jpg',
          '$basePath.JPG',
          '$basePath.jpeg',
          '$basePath.JPEG',
        ];
        String? plainStillPath;
        for (final candidate in plainCandidates) {
          if (await File(candidate).exists()) {
            plainStillPath = candidate;
            break;
          }
        }
        if (plainStillPath != null) {
          if (context.config.verbose) {
            logDebug(
              '[Step 6/8] [left-behind] .MP redirected to plain still: $plainStillPath (source .MP left in input: $oldPath)',
              forcePrint: true,
            );
          }
          primary.sourcePath = plainStillPath;
          transformedPathMap[oldPath.toLowerCase()] = plainStillPath;
          _updateEntitySecondaryExtensions(
            entity,
            path.extension(plainStillPath),
          );
          _removeEntityDuplicates(collection, entity, plainStillPath);
          transformed++;
          continue;
        }

        // Priority 2: motion-photo sidecar — <stem>.MP.jpg.
        // It contains an embedded video, so extract only the JPEG still from it.
        final motionSidecarCandidates = <String>[
          '$oldPath.jpg',
          '$oldPath.JPG',
          '$oldPath.jpeg',
          '$oldPath.JPEG',
        ];
        String? motionSidecarPath;
        for (final candidate in motionSidecarCandidates) {
          if (await File(candidate).exists()) {
            motionSidecarPath = candidate;
            break;
          }
        }
        if (motionSidecarPath != null) {
          bool isMotion = false;
          try {
            isMotion = await MotionPhotos(motionSidecarPath).isMotionPhoto();
          } catch (_) {
            // Detection failed — treat as plain still and use directly.
          }
          if (isMotion) {
            // Extract the pure JPEG still from the motion sidecar.
            // Strip the XMP APP1 segment from the extracted bytes: the motion
            // sidecar's XMP contains stale GCamera:MicroVideoOffset / MicroVideo
            // markers that would cause isMotionPhoto() to return true even for
            // a file with no appended video, because the motion_photos package
            // does not bounds-check the offset before returning a VideoIndex.
            final motionPhoto = await extractor.extractMotionPhoto(
              motionSidecarPath,
            );
            final stillBytes = extractor.stripMotionPhotoXmp(
              motionPhoto.imageData,
            );
            final stillPath = '$basePath.jpg';
            await File(stillPath).writeAsBytes(stillBytes);
            if (context.config.verbose) {
              logDebug(
                '[Step 6/8] [left-behind] Extracted still from motion sidecar: $motionSidecarPath → $stillPath (source .MP and sidecar both left in input: $oldPath)',
                forcePrint: true,
              );
            }
            primary.sourcePath = stillPath;
            transformedPathMap[oldPath.toLowerCase()] = stillPath;
            _updateEntitySecondaryExtensions(entity, path.extension(stillPath));
            // Remove the sidecar entity from the collection so it is not moved to output.
            _removeEntityDuplicates(collection, entity, motionSidecarPath);
            transformed++;
            continue;
          } else {
            // Sidecar is a plain JPEG despite the .MP.jpg name — use directly.
            if (context.config.verbose) {
              logDebug(
                '[Step 6/8] [left-behind] .MP redirected to plain-JPEG sidecar: $motionSidecarPath (source .MP left in input: $oldPath)',
                forcePrint: true,
              );
            }
            primary.sourcePath = motionSidecarPath;
            transformedPathMap[oldPath.toLowerCase()] = motionSidecarPath;
            _updateEntitySecondaryExtensions(
              entity,
              path.extension(motionSidecarPath),
            );
            _removeEntityDuplicates(collection, entity, motionSidecarPath);
            transformed++;
            continue;
          }
        }

        // Priority 3: no sidecar at all — extract embedded JPEG from the .MP container.
        final motionPhoto = await extractor.extractMotionPhoto(oldPath);
        final stillPath = '$basePath.jpg';
        // Strip stale motion-photo XMP so the extracted still is not mis-identified
        // as a motion photo by isMotionPhoto() on output.
        await File(
          stillPath,
        ).writeAsBytes(extractor.stripMotionPhotoXmp(motionPhoto.imageData));

        if (context.config.verbose) {
          logDebug(
            '[Step 6/8] [left-behind] Source .MP left in input after extracting embedded still: $oldPath',
            forcePrint: true,
          );
        }

        primary.sourcePath = stillPath;
        transformedPathMap[oldPath.toLowerCase()] = stillPath;
        _updateEntitySecondaryExtensions(entity, path.extension(stillPath));
        transformed++;
      } catch (e) {
        // No still image could be extracted from the .MP file (some Pixel .MP
        // files are pure video containers with no embedded JPEG). Rename to
        // .mp4 so the video is preserved instead of leaving an orphaned .mp file.
        final dot = oldPath.lastIndexOf('.');
        final mp4Path = dot > 0
            ? '${oldPath.substring(0, dot)}.mp4'
            : '$oldPath.mp4';
        try {
          final renamed = await File(oldPath).rename(mp4Path);
          primary.sourcePath = renamed.path;
          transformedPathMap[oldPath.toLowerCase()] = renamed.path;
          _updateEntitySecondaryExtensions(
            entity,
            path.extension(renamed.path),
          );
          logPrint(
            '[Step 6/8] Info: ${path.basename(oldPath)} has no extractable still image; renamed to .mp4 as fallback ($e).',
          );
        } catch (_) {
          logPrint(
            '[Step 6/8] Warning: Failed to transform ${primary.path} to still image: $e',
          );
        }
      }
    }

    // Propagate path changes to secondary FileEntity instances in other entities
    // that reference the same .MP/.MV file (e.g. album symlinks).
    _propagateTransformToSecondaries(entities, transformedPathMap);

    return transformed;
  }

  // ─────────────────────────────────────────────────────────────────────────
  // Helpers
  // ─────────────────────────────────────────────────────────────────────────

  /// Returns the path of the largest existing file among the candidate list,
  /// preferring motion-photo sidecars (`*.MP.jpg`) over plain stills.
  /// Returns null if none of the candidates exist.
  Future<String?> _findPreferredStillImagePath(final String mpPath) async {
    final dot = mpPath.lastIndexOf('.');
    final basePath = dot > 0 ? mpPath.substring(0, dot) : mpPath;

    final candidates = <String>[
      '$mpPath.jpg',
      '$mpPath.JPG',
      '$mpPath.jpeg',
      '$mpPath.JPEG',
      '$basePath.jpg',
      '$basePath.JPG',
      '$basePath.jpeg',
      '$basePath.JPEG',
    ];

    String? preferredPath;
    int preferredSize = -1;

    for (final candidate in candidates) {
      final file = File(candidate);
      if (await file.exists()) {
        final size = await file.length();
        if (size > preferredSize) {
          preferredSize = size;
          preferredPath = candidate;
        }
      }
    }

    return preferredPath;
  }

  /// Removes every entity in [collection] (other than [owner]) whose primary
  /// sourcePath equals [ownedPath] (case-insensitive, cross-platform), and
  /// also strips [ownedPath] from the secondary-file lists of all other
  /// entities so that no entity can move the same file as a secondary after
  /// [owner] has claimed it as its primary.
  void _removeEntityDuplicates(
    final MediaEntityCollection collection,
    final MediaEntity owner,
    final String ownedPath,
  ) {
    final normalized = ownedPath.replaceAll('\\', '/').toLowerCase();

    // Remove entities (other than owner) whose PRIMARY path matches ownedPath.
    final duplicates = collection.asList().where((final e) {
      if (e == owner) return false;
      return e.primaryFile.sourcePath.replaceAll('\\', '/').toLowerCase() ==
          normalized;
    }).toList();
    collection.removeAll(duplicates);

    // Also strip ownedPath from the SECONDARY lists of all remaining entities
    // so that no entity moves the same file as a secondary after owner claims it.
    for (final entity in collection.asList()) {
      if (entity == owner) continue;
      entity.secondaryFiles.removeWhere(
        (final sec) =>
            sec.sourcePath.replaceAll('\\', '/').toLowerCase() == normalized,
      );
    }
  }

  /// Updates secondary [FileEntity] instances across all [entities] whose
  /// [sourcePath] matches a key in [transformedPathMap] (case-insensitive).
  ///
  /// In jpg/still modes the primary-file transform loop only updates the
  /// [primaryFile.sourcePath] of the entity that owns the .MP file.  However,
  /// the same underlying .MP may appear as a *secondary* FileEntity inside
  /// another entity (e.g. an album entity referencing the same file).  Without
  /// this pass the secondary's sourcePath stays as ".MP", causing album
  /// symlinks to be named with the old extension instead of ".jpg".
  ///
  /// Two cases are handled:
  /// 1. **Cross-entity same-path**: a secondary's sourcePath matches an entry
  ///    in [transformedPathMap] directly (same file referenced from a different
  ///    entity) → replace with the mapped new path.
  /// 2. **Same-entity album copy**: a secondary of this entity still has a
  ///    `.mp`/`.mv` extension, and the entity's own primary WAS transformed
  ///    (its old path is in the map) → apply the same extension change to the
  ///    secondary so album symlinks use the correct extension.
  void _propagateTransformToSecondaries(
    final List<MediaEntity> entities,
    final Map<String, String> transformedPathMap,
  ) {
    if (transformedPathMap.isEmpty) return;
    for (final entity in entities) {
      for (final sec in entity.secondaryFiles) {
        // Case 1: the secondary path is directly in the map.
        final secKey = sec.sourcePath.toLowerCase();
        final directMapping = transformedPathMap[secKey];
        if (directMapping != null) {
          sec.sourcePath = directMapping;
        }
        // Note: Case 2 (same-entity album copy) is handled inline in the
        // transform loop via _updateEntitySecondaryExtensions(), because by
        // the time this method runs the primary.sourcePath is already updated
        // and looking it up by new path wouldn't find the old-path key.
      }
    }
  }

  /// For each secondary [FileEntity] in [entity] that still ends in `.mp` or
  /// `.mv`, replaces that extension with [newExt] (e.g. `".jpg"` or `".mp4"`).
  ///
  /// Called inline immediately after updating [primaryFile.sourcePath] so that
  /// album-copy secondaries (which share the same stem but live in a different
  /// directory) receive the correct extension for album shortcut naming.
  void _updateEntitySecondaryExtensions(
    final MediaEntity entity,
    final String newExt,
  ) {
    for (final sec in entity.secondaryFiles) {
      final lower = sec.sourcePath.toLowerCase();
      if (lower.endsWith('.mp') || lower.endsWith('.mv')) {
        final dot = sec.sourcePath.lastIndexOf('.');
        if (dot > 0) {
          sec.sourcePath = sec.sourcePath.substring(0, dot) + newExt;
        }
      }
    }
  }
}
