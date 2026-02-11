// ignore_for_file: unnecessary_getters_setters

import 'dart:io';
import 'package:gpth/gpth_lib_exports.dart';
import 'package:unorm_dart/unorm_dart.dart' as unorm;

/// Immutable domain entity representing a media file (photo or video).
///
/// This is the core domain model for media files, designed to be immutable
/// and thread-safe. All “modifications” return new instances instead of
/// mutating existing state.
///
/// UPDATED MODEL:
/// - Replaces the previous `MediaFilesCollection files` with:
///   - `primaryFile`: canonical file path (chosen by accuracy/name-length and
///     year-folder preference on ties)
///   - `secondaryFiles`: original paths of redundant duplicates (kept only as
///     metadata after Step 3)
///   - `albumsMap`: album membership metadata
///
/// EXTENDED MODEL (FileEntity-based):
/// - `primaryFile` is now a `FileEntity` (not a File)
/// - `secondaryFiles` is now a `List<FileEntity>`
/// - New: `duplicatesFiles` is a `List<FileEntity>` representing same-directory
///   duplicates (worse ranked) compared to the best-ranked file in that folder.
///
/// Ranking rules (lower ranking = better):
/// 1) Files under a year folder (e.g., /.../2020/...) outrank files under album folders
/// 2) On ties, shorter basename outranks longer basename
/// 3) On ties, shorter full path outranks longer full path
///
/// Primary/secondaries/duplicates selection:
/// - The best-ranked file across the entity becomes `primaryFile`
/// - Files in *different* directories than the primary become `secondaryFiles`
/// - Files in the *same* directory as another better-ranked file become `duplicatesFiles`
///
/// NOTE: Rankings are now **sequential per entity**: after ordering by the rules,
/// each file receives rank `1..N` where `1` is the highest priority.
class MediaEntity {
  /// Creates a new media entity.
  ///
  /// NOTE: This public factory normalizes ranking and splits files into primary,
  /// secondary, and duplicates according to the rules described above.
  factory MediaEntity({
    required final FileEntity primaryFile,
    final List<FileEntity>? secondaryFiles,
    final List<FileEntity>? duplicatesFiles,
    final DateTime? dateTaken,
    final DateAccuracy? dateAccuracy,
    final DateTimeExtractionMethod? dateTimeExtractionMethod,
    final bool partnershared = false,
    final Map<String, AlbumEntity>? albumsMap,
  }) {
    final all = <FileEntity>[
      primaryFile,
      ...?secondaryFiles,
      ...?duplicatesFiles,
    ];

    final normalized = _normalizeAndSplit(all);

    // Ensure albumsMap is enriched with non-canonical files discovered in this entity.
    final updatedAlbums = _augmentAlbumsForNonCanonical(
      albumsMap ?? const {},
      <FileEntity>[
        normalized.primary,
        ...normalized.secondaries,
        ...normalized.duplicates,
      ],
    );

    return MediaEntity._internal(
      primaryFile: normalized.primary,
      secondaryFiles: normalized.secondaries,
      duplicatesFiles: normalized.duplicates,
      dateTaken: dateTaken,
      dateAccuracy: dateAccuracy,
      dateTimeExtractionMethod: dateTimeExtractionMethod,
      partnerShared: partnershared,
      albumsMap: updatedAlbums,
    );
  }

  /// Convenience factory for a single-file entity.
  factory MediaEntity.single({
    required final FileEntity file,
    final DateTime? dateTaken,
    final DateAccuracy? dateAccuracy,
    final DateTimeExtractionMethod? dateTimeExtractionMethod,
    final bool partnerShared = false,
    final Map<String, AlbumEntity>? albumsMap,
  }) => MediaEntity(
    primaryFile: file,
    secondaryFiles: const <FileEntity>[],
    duplicatesFiles: const <FileEntity>[],
    dateTaken: dateTaken,
    dateAccuracy: dateAccuracy,
    dateTimeExtractionMethod: dateTimeExtractionMethod,
    partnershared: partnerShared,
    albumsMap: albumsMap,
  );

  /// Private internal constructor used after normalization.
  const MediaEntity._internal({
    required this.primaryFile,
    required this.secondaryFiles,
    required this.duplicatesFiles,
    this.dateTaken,
    this.dateAccuracy,
    this.dateTimeExtractionMethod,
    this.partnerShared = false,
    required this.albumsMap,
  });

  /// Album metadata: album name → AlbumInfo.
  /// This is used to reconstruct album relationships later in the pipeline.
  final Map<String, AlbumEntity> albumsMap;

  /// Capture/creation datetime (best-known).
  final DateTime? dateTaken;

  /// Date extraction accuracy.
  final DateAccuracy? dateAccuracy;

  /// How the date/time information was extracted.
  final DateTimeExtractionMethod? dateTimeExtractionMethod;

  /// Whether this media was shared by a partner (Google Photos partner sharing).
  final bool partnerShared;

  /// Canonical (primary) file for this media entity.
  final FileEntity primaryFile;

  /// Original physical paths of all secondary duplicates across *different* folders.
  final List<FileEntity> secondaryFiles;

  /// Duplicates that live in the *same* folder as a better-ranked file.
  final List<FileEntity> duplicatesFiles;

  /// Backward-compat convenience getter (integer accuracy).
  int? get dateTakenAccuracy => dateAccuracy?.value;

  /// Whether this media is associated with any album.
  bool get hasAlbumAssociations => albumsMap.isNotEmpty;

  /// All album names where this media belongs to.
  Set<String> get albumNames => albumsMap.keys.toSet();

  /// Returns true if any path (primary or secondary/duplicate) lives inside a “year-based” folder.
  ///
  /// Heuristics:
  /// - Pure year directory: `2020`, `2015`, ...
  /// - Localized folder names: `Photos from 2019`, `Fotos de 2019` (case-insensitive)
  bool get hasYearBasedFiles {
    if (_pathIsInYearFolder(primaryFile.sourcePath)) return true;
    for (final f in secondaryFiles) {
      if (_pathIsInYearFolder(f.sourcePath)) return true;
    }
    for (final f in duplicatesFiles) {
      if (_pathIsInYearFolder(f.sourcePath)) return true;
    }
    return false;
  }

  // ────────────────────────────────────────────────────────────────────────────
  // External accessors (requested API)
  // ────────────────────────────────────────────────────────────────────────────

  /// Returns the number of secondary files.
  int get secondaryCount => secondaryFiles.length;

  /// Returns the number of duplicate files (same-folder duplicates).
  int get duplicatesCount => duplicatesFiles.length;

  /// Returns the total number of files in the entity.
  int get totalFilesCount => 1 + secondaryFiles.length + duplicatesFiles.length;

  /// Returns only the primary file (as a singleton unmodifiable list).
  List<FileEntity> getPrimary() => List<FileEntity>.unmodifiable([primaryFile]);

  /// Returns all secondary files.
  List<FileEntity> getSecondary() =>
      List<FileEntity>.unmodifiable(secondaryFiles);

  /// Returns primary and secondary files (unmodifiable). (excludes duplicates).
  List<FileEntity> getPrimaryAndSecondary() =>
      List<FileEntity>.unmodifiable([primaryFile, ...secondaryFiles]);

  /// Returns all duplicate files.
  List<FileEntity> getDuplicates() =>
      List<FileEntity>.unmodifiable(duplicatesFiles);

  /// Returns all files in the entity, including the primary one.
  List<FileEntity> getAllFiles() => List<FileEntity>.unmodifiable([
    primaryFile,
    ...secondaryFiles,
    ...duplicatesFiles,
  ]);

  /// Returns the best-ranked file (i.e., the current primary).
  FileEntity getBestRankedFile() => primaryFile;

  /// Returns a copy swapping the given `secondary` with the current `primary`.
  /// The former primary becomes a secondary; normalization is applied afterward.
  MediaEntity swapPrimaryWithSecondary(final FileEntity secondary) {
    if (!secondaryFiles.any((final f) => _sameIdentity(f, secondary))) {
      return this;
    }
    final all = getAllFiles();
    // Promote the provided secondary by lowering its ranking to beat all others.
    final promoted = _withRankingAdjusted(secondary, -1);
    final replacedAll = all
        .map((final f) => _sameIdentity(f, secondary) ? promoted : f)
        .toList(growable: false);
    final normalized = _normalizeAndSplit(replacedAll);
    return _copyWithFiles(normalized);
  }

  // ────────────────────────────────────────────────────────────────────────────
  // Mutators (immutable-by-copy) — keep existing API adapted to FileEntity
  // ────────────────────────────────────────────────────────────────────────────

  /// Returns a copy with updated date/accuracy/method.
  MediaEntity withDate({
    final DateTime? dateTaken,
    final DateAccuracy? dateAccuracy,
    final DateTimeExtractionMethod? dateTimeExtractionMethod,
  }) => MediaEntity._internal(
    primaryFile: primaryFile,
    secondaryFiles: secondaryFiles,
    duplicatesFiles: duplicatesFiles,
    dateTaken: dateTaken ?? this.dateTaken,
    dateAccuracy: dateAccuracy ?? this.dateAccuracy,
    dateTimeExtractionMethod:
        dateTimeExtractionMethod ?? this.dateTimeExtractionMethod,
    partnerShared: partnerShared,
    albumsMap: albumsMap,
  );

  /// Returns a copy with album membership updated/added (metadata only).
  MediaEntity withAlbumInfo(final String albumName, {final String? sourceDir}) {
    if (albumName.isEmpty) return this;
    final existing = albumsMap[albumName];
    final updated = (existing == null)
        ? AlbumEntity(
            name: albumName,
            sourceDirectories: sourceDir != null && sourceDir.isNotEmpty
                ? {sourceDir}
                : const {},
          )
        : (sourceDir != null && sourceDir.isNotEmpty
              ? existing.addSourceDir(sourceDir)
              : existing);

    final next = Map<String, AlbumEntity>.from(albumsMap)
      ..[albumName] = updated;

    return MediaEntity._internal(
      primaryFile: primaryFile,
      secondaryFiles: secondaryFiles,
      duplicatesFiles: duplicatesFiles,
      dateTaken: dateTaken,
      dateAccuracy: dateAccuracy,
      dateTimeExtractionMethod: dateTimeExtractionMethod,
      partnerShared: partnerShared,
      albumsMap: next,
    );
  }

  /// Returns a copy adding a secondary-like file. It will be ranked and the
  /// entity will be normalized, so it might become primary or duplicate.
  MediaEntity withSecondaryFile(final FileEntity file) {
    final all = getAllFiles();
    if (all.any((final f) => _sameIdentity(f, file))) return this;

    final rankedNew = _withRankingComputed(file, all);
    final normalized = _normalizeAndSplit([...all, rankedNew]);
    return _copyWithFiles(normalized);
  }

  /// Returns a copy promoting `newPrimary` to primary in an immutable way.
  ///
  /// NOTE: With ranking normalization, this method will force `newPrimary`
  /// to become the best-ranked candidate before splitting again.
  MediaEntity withPrimaryFile(final FileEntity newPrimary) {
    final all = getAllFiles();
    if (!all.any((final f) => _sameIdentity(f, newPrimary))) return this;
    final forcedBest = _withRankingAdjusted(newPrimary, -1);
    final replacedAll = all
        .map((final f) => _sameIdentity(f, newPrimary) ? forcedBest : f)
        .toList();
    final normalized = _normalizeAndSplit(replacedAll);
    return _copyWithFiles(normalized);
  }

  /// Merges this entity with another:
  /// - Merges album metadata (deep merge).
  /// - Selects the best date/accuracy/method.
  /// - Accumulates files (deduplicated by identity) then re-ranks and normalizes.
  ///
  /// The final primary is selected by ranking rules across the merged set.
  MediaEntity mergeWith(final MediaEntity other) {
    // 1) Merge album metadata
    final Map<String, AlbumEntity> mergedAlbums = <String, AlbumEntity>{};
    for (final e in albumsMap.entries) {
      mergedAlbums[e.key] = e.value;
    }
    for (final e in other.albumsMap.entries) {
      final existing = mergedAlbums[e.key];
      mergedAlbums[e.key] = existing == null
          ? e.value
          : existing.merge(e.value);
    }

    // 2) Pick the best date/accuracy/method
    final DateTime? bestDate;
    final DateAccuracy? bestAccuracy;
    final DateTimeExtractionMethod? bestMethod;

    if (dateAccuracy == null && other.dateAccuracy == null) {
      bestDate = dateTaken ?? other.dateTaken;
      bestAccuracy = null;
      bestMethod = dateTimeExtractionMethod ?? other.dateTimeExtractionMethod;
    } else if (dateAccuracy == null) {
      bestDate = other.dateTaken;
      bestAccuracy = other.dateAccuracy;
      bestMethod = other.dateTimeExtractionMethod;
    } else if (other.dateAccuracy == null) {
      bestDate = dateTaken;
      bestAccuracy = dateAccuracy;
      bestMethod = dateTimeExtractionMethod;
    } else {
      if (dateAccuracy!.isBetterThan(other.dateAccuracy!)) {
        bestDate = dateTaken;
        bestAccuracy = dateAccuracy;
        bestMethod = dateTimeExtractionMethod;
      } else {
        bestDate = other.dateTaken;
        bestAccuracy = other.dateAccuracy;
        bestMethod = other.dateTimeExtractionMethod;
      }
    }

    // 3) Merge files by identity (sourcePath + targetPath + isShortcut)
    final mergedAll = <FileEntity>[];
    void addUnique(final FileEntity f) {
      if (!mergedAll.any((final x) => _sameIdentity(x, f))) mergedAll.add(f);
    }

    getAllFiles().forEach(addUnique);
    other.getAllFiles().forEach(addUnique);

    final normalized = _normalizeAndSplit(mergedAll);

    // Enrich merged album metadata using any non-canonical files present in the merged entity.
    final mergedAlbumsUpdated = _augmentAlbumsForNonCanonical(
      mergedAlbums,
      <FileEntity>[
        normalized.primary,
        ...normalized.secondaries,
        ...normalized.duplicates,
      ],
    );

    return MediaEntity._internal(
      primaryFile: normalized.primary,
      secondaryFiles: normalized.secondaries,
      duplicatesFiles: normalized.duplicates,
      dateTaken: bestDate,
      dateAccuracy: bestAccuracy,
      dateTimeExtractionMethod: bestMethod,
      partnerShared: partnerShared || other.partnerShared,
      albumsMap: mergedAlbumsUpdated,
    );
  }

  @override
  bool operator ==(final Object other) {
    if (identical(this, other)) return true;
    if (other is! MediaEntity) return false;

    // Primary identity comparison
    if (!_sameIdentity(other.primaryFile, primaryFile)) return false;

    final samePartner = other.partnerShared == partnerShared;
    final sameDate =
        other.dateTaken == dateTaken &&
        other.dateAccuracy == dateAccuracy &&
        other.dateTimeExtractionMethod == dateTimeExtractionMethod;

    // Compare album keys only (cheap structural equality)
    final aKeys = albumsMap.keys.toSet();
    final bKeys = other.albumsMap.keys.toSet();
    final sameAlbumKeys =
        aKeys.length == bKeys.length && aKeys.containsAll(bKeys);

    // Compare secondaries and duplicates by identity sets
    bool listEq(final List<FileEntity> a, final List<FileEntity> b) {
      final sa = a.map(_fileIdentityKey).toSet();
      final sb = b.map(_fileIdentityKey).toSet();
      return sa.length == sb.length && sa.containsAll(sb);
    }

    final sameSecondaries = listEq(secondaryFiles, other.secondaryFiles);
    final sameDuplicates = listEq(duplicatesFiles, other.duplicatesFiles);

    return samePartner &&
        sameDate &&
        sameAlbumKeys &&
        sameSecondaries &&
        sameDuplicates;
  }

  @override
  int get hashCode => Object.hash(
    _fileIdentityKey(primaryFile),
    dateTaken,
    dateAccuracy,
    dateTimeExtractionMethod,
    partnerShared,
    Object.hashAllUnordered(albumsMap.keys),
    Object.hashAllUnordered(secondaryFiles.map(_fileIdentityKey)),
    Object.hashAllUnordered(duplicatesFiles.map(_fileIdentityKey)),
  );

  @override
  String toString() {
    final dateInfo = dateTaken != null ? ', dateTaken: $dateTaken' : '';
    final accuracyInfo = dateAccuracy != null
        ? ' (${dateAccuracy!.description})'
        : '';
    final albumsCount = albumNames.length;
    final secondaries = secondaryFiles.length;
    final duplicates = duplicatesFiles.length;
    // Always print partnerShared in camelCase and include the flag even when false.
    return 'MediaEntity(${primaryFile.sourcePath}$dateInfo$accuracyInfo, '
        'dateTaken: $dateTaken, dateAccuracy: $dateAccuracy, albums: $albumsCount, secondaries: $secondaries, duplicates: $duplicates, partnerShared: $partnerShared)';
  }

  // ===== Private helpers =====

  /// Normalizes ranking for all candidates and splits into primary/secondary/duplicates.
  static _SplitResult _normalizeAndSplit(final List<FileEntity> allRaw) {
    // 1) Deduplicate by identity
    final all = <FileEntity>[];
    for (final f in allRaw) {
      if (!all.any((final x) => _sameIdentity(x, f))) all.add(f);
    }

    // 2) Compute preliminary ranking for shape-compat (not decisive anymore).
    final prelim = all
        .map((final f) => _withRankingComputed(f, all))
        .toList(growable: false);

    // 3) Determine final order:
    //    - Any negative `ranking` means "force to the front" (used by withPrimaryFile)
    //    - Then apply the canonical/basename/path-length rules
    final ordered = _orderForRanking(prelim);

    // 4) Assign sequential rankings 1..N (1 = highest priority)
    final ranked = <FileEntity>[];
    for (var i = 0; i < ordered.length; i++) {
      final f = ordered[i];
      ranked.add(
        FileEntity(
          sourcePath: f.sourcePath,
          targetPath: f.targetPath,
          isShortcut: f.isShortcut,
          dateAccuracy: f.dateAccuracy,
          ranking: i + 1,
        ),
      );
    }

    // 5) Select primary (rank 1 wins)
    final primary = ranked.first;

    // 6) Partition by folder:
    //    - same-folder worse-ranked files → duplicates
    //    - different-folder files → secondaries
    final primaryDir = _dirOf(primary.sourcePath);
    final secondaries = <FileEntity>[];
    final duplicates = <FileEntity>[];

    // Build per-folder best to determine duplicates within each folder
    final byFolder = <String, List<FileEntity>>{};
    for (final f in ranked) {
      final dir = _dirOf(f.sourcePath);
      (byFolder[dir] ??= <FileEntity>[]).add(f);
    }
    final bestPerFolder = <String, FileEntity>{};
    for (final e in byFolder.entries) {
      e.value.sort(_byRankingThenPath);
      bestPerFolder[e.key] = e.value.first;
    }

    for (final f in ranked.skip(1)) {
      final dir = _dirOf(f.sourcePath);
      final bestInDir = bestPerFolder[dir]!;
      if (_sameIdentity(f, bestInDir)) {
        // if it's the best in its folder but not the global best, it is a secondary (different folder than primary)
        if (dir == primaryDir) {
          // same folder as primary but not better than primary → duplicate
          duplicates.add(f);
        } else {
          secondaries.add(f);
        }
      } else {
        // not best in its own folder → duplicate
        duplicates.add(f);
      }
    }

    return _SplitResult(
      primary: primary,
      secondaries: secondaries,
      duplicates: duplicates,
    );
  }

  /// Compute or refresh ranking for `file` against the full set `all`.
  static FileEntity _withRankingComputed(
    final FileEntity file,
    final List<FileEntity> all,
  ) {
    final rank = _computeRanking(file);
    // produce a new FileEntity with updated ranking (keeping all other fields)
    return FileEntity(
      sourcePath: file.sourcePath,
      targetPath: file.targetPath,
      isShortcut: file.isShortcut,
      dateAccuracy: file.dateAccuracy,
      ranking: rank,
    );
    // `isCanonical` is automatically recalculated by FileEntity on construction
  }

  /// Adjust ranking to a specific value (used to force a promotion).
  static FileEntity _withRankingAdjusted(
    final FileEntity file,
    final int ranking,
  ) => FileEntity(
    sourcePath: file.sourcePath,
    targetPath: file.targetPath,
    isShortcut: file.isShortcut,
    dateAccuracy: file.dateAccuracy,
    ranking: ranking,
  );

  /// Ranking calculation:
  /// - Prefer year-folder (canonical) over album-folder
  /// - On tie, shorter basename wins
  /// - On tie, shorter full path wins
  ///
  /// IMPORTANT: This function now returns a **provisional** value only.
  /// Final ranks are assigned **sequentially (1..N)** inside `_normalizeAndSplit`.
  static int _computeRanking(final FileEntity f) =>
      0; // Keep returning 0 to avoid leaking an absolute score. Ordering is decided later.

  /// Comparator: by ranking, then by path (stable)
  static int _byRankingThenPath(final FileEntity a, final FileEntity b) {
    final r = a.ranking.compareTo(b.ranking);
    if (r != 0) return r;
    return a.sourcePath.compareTo(b.sourcePath);
  }

  /// Orders files for ranking assignment:
  /// 1) Files with negative `ranking` first (explicit promotion)
  /// 2) Canonical (year-folder) before album-folder
  /// 3) Shorter basename first
  /// 4) Shorter full path first
  /// 5) Stable tie-breaker by lowercase path
  static List<FileEntity> _orderForRanking(final List<FileEntity> files) {
    final forced = <FileEntity>[];
    final regular = <FileEntity>[];
    for (final f in files) {
      if (f.ranking < 0) {
        forced.add(f);
      } else {
        regular.add(f);
      }
    }
    int cmp(final FileEntity a, final FileEntity b) {
      final ac = _pathIsInYearFolder(a.sourcePath) ? 0 : 1;
      final bc = _pathIsInYearFolder(b.sourcePath) ? 0 : 1;
      if (ac != bc) return ac - bc;

      final ab = _basenameOf(a.sourcePath).length;
      final bb = _basenameOf(b.sourcePath).length;
      if (ab != bb) return ab - bb;

      final ap = a.sourcePath.length;
      final bp = b.sourcePath.length;
      if (ap != bp) return ap - bp;

      return a.sourcePath.toLowerCase().compareTo(b.sourcePath.toLowerCase());
    }

    forced.sort(cmp);
    regular.sort(cmp);
    return <FileEntity>[...forced, ...regular];
  }

  static bool _sameIdentity(final FileEntity a, final FileEntity b) =>
      a.sourcePath == b.sourcePath &&
      a.targetPath == b.targetPath &&
      a.isShortcut == b.isShortcut;

  static String _fileIdentityKey(final FileEntity f) =>
      '${f.isShortcut ? 'S' : 'F'}|${f.targetPath ?? ''}|${f.sourcePath}';

  static String _dirOf(final String p) {
    final normalized = p.replaceAll('\\', '/');
    final idx = normalized.lastIndexOf('/');
    return idx < 0 ? '' : normalized.substring(0, idx);
  }

  static String _basenameOf(final String p) {
    final normalized = p.replaceAll('\\', '/');
    final idx = normalized.lastIndexOf('/');
    return idx < 0 ? normalized : normalized.substring(idx + 1);
  }

  static bool _pathIsInYearFolder(final String p) {
    final normalized = p.replaceAll('\\', '/');
    final segments = normalized.split('/');

    final pureYear = RegExp(r'^\d{4}$');
    final localizedYear = RegExp(
      '^(${TakeoutFolderClassifierService.localizedYearPattern})\\s+\\d{4}\$',
      caseSensitive: false,
    );

    for (final seg in segments) {
      final s = seg.trim();
      if (pureYear.hasMatch(s)) return true;
      if (localizedYear.hasMatch(s.toLowerCase())) return true;
    }
    return false;
  }

  /// Enriches the albums map using every non-canonical file in [files].
  /// Album name is inferred from the parent directory name of each file.
  static Map<String, AlbumEntity> _augmentAlbumsForNonCanonical(
    final Map<String, AlbumEntity> base,
    final List<FileEntity> files,
  ) {
    if (files.isEmpty) return base;
    final next = Map<String, AlbumEntity>.from(base);
    for (final f in files) {
      if (f.isCanonical) continue; // Only enrich from non-canonical files
      final dir = _dirOf(f.sourcePath);
      if (dir.isEmpty) continue;
      final albumName = _basenameOf(dir);
      if (albumName.isEmpty) continue;

      final existing = next[albumName];
      next[albumName] = existing == null
          ? AlbumEntity(name: albumName, sourceDirectories: {dir})
          : existing.addSourceDir(dir);
    }
    return next;
  }

  MediaEntity _copyWithFiles(final _SplitResult norm) {
    // Auto-augment albums metadata with any non-canonical files present in this new shape.
    final updatedAlbums = _augmentAlbumsForNonCanonical(albumsMap, <FileEntity>[
      norm.primary,
      ...norm.secondaries,
      ...norm.duplicates,
    ]);
    return MediaEntity._internal(
      primaryFile: norm.primary,
      secondaryFiles: norm.secondaries,
      duplicatesFiles: norm.duplicates,
      dateTaken: dateTaken,
      dateAccuracy: dateAccuracy,
      dateTimeExtractionMethod: dateTimeExtractionMethod,
      partnerShared: partnerShared,
      albumsMap: updatedAlbums,
    );
  }
}

/// Represents a single file entity within GPTH.
/// Encapsulates source and target paths, canonicality, shortcut status,
/// date accuracy, and ranking information.
///
/// A FileEntity can represent:
/// - The primary file of a MediaEntity (lowest ranking value)
/// - A secondary file (higher ranking values)
/// - A shortcut created during Step 7 (isShortcut = true)
class FileEntity {
  FileEntity({
    required final String sourcePath,
    final String? targetPath,
    final bool isShortcut = false,
    final bool isMoved = false,
    final bool isDeleted = false,
    final bool isDuplicateCopy = false,
    final DateAccuracy? dateAccuracy,
    final int ranking = 0,
  }) : _sourcePath = _nfc(sourcePath),
       _targetPath = targetPath != null ? _nfc(targetPath) : null,
       _isShortcut = isShortcut,
       _isMoved = isMoved,
       _isDeleted = isDeleted,
       _isDuplicateCopy = isDuplicateCopy,
       _dateAccuracy = dateAccuracy,
       _ranking = ranking,
       _isCanonical = _calculateCanonical(
         _nfc(sourcePath),
         targetPath != null ? _nfc(targetPath) : null,
       );

  String _sourcePath;
  String? _targetPath;
  bool _isCanonical;
  bool _isShortcut;
  bool _isMoved;
  bool _isDeleted;
  bool _isDuplicateCopy;
  DateAccuracy? _dateAccuracy;
  int _ranking;

  /// Normalize a path string to NFC form.
  ///
  /// On macOS, HFS+/APFS stores filenames in NFD (decomposed) Unicode form
  /// (e.g. `ö` as `o` + combining diaeresis U+0308). Dart's Directory.list()
  /// returns these NFD paths, but File() operations may fail when the internal
  /// path representation doesn't match the on-disk form.
  ///
  /// By normalizing all paths to NFC (composed) form at the point of storage,
  /// we ensure consistent path handling across platforms — fixing issues with
  /// German umlauts (ä, ö, ü, ß) and other accented characters.
  static String _nfc(final String path) => unorm.nfc(path);

  // ────────────────────────────────────────────────────────────────
  // Getters
  // ────────────────────────────────────────────────────────────────

  /// Original source path (where the file was discovered).
  String get sourcePath => _sourcePath;

  /// Final target path (where the file is moved/copied to), or null if not moved.
  String? get targetPath => _targetPath;

  /// Effective path: returns targetPath if not null (file moved), otherwise sourcePath.
  String get path => _targetPath ?? _sourcePath;

  /// Whether this file is considered canonical (see _calculateCanonical).
  bool get isCanonical => _isCanonical;

  /// True when Step 7 strategy placed this file as a shortcut to the entity primary.
  bool get isShortcut => _isShortcut;

  /// True when the file has been moved to a new target path.
  bool get isMoved => _isMoved;

  /// True when the file has been marked as deleted.
  bool get isDeleted => _isDeleted;

  /// True when the file is a duplicate copy of another entity.
  bool get isDuplicateCopy => _isDuplicateCopy;

  /// Date accuracy associated to this file (if any).
  DateAccuracy? get dateAccuracy => _dateAccuracy;

  /// Ranking score (lower is better). The best-ranked file becomes the primary.
  int get ranking => _ranking;

  /// Convenience: obtain a dart:io File for the effective path (target if present).
  File asFile() => File(path);

  // ────────────────────────────────────────────────────────────────
  // Setters
  // ────────────────────────────────────────────────────────────────

  set sourcePath(final String value) {
    _sourcePath = _nfc(value);
    _isCanonical = _calculateCanonical(_sourcePath, _targetPath);
  }

  set targetPath(final String? value) {
    _targetPath = value != null ? _nfc(value) : null;
    _isCanonical = _calculateCanonical(_sourcePath, _targetPath);
  }

  set isShortcut(final bool value) {
    _isShortcut = value;
  }

  set isMoved(final bool value) {
    _isMoved = value;
  }

  set isDeleted(final bool value) {
    _isDeleted = value;
  }

  set isDuplicateCopy(final bool value) {
    _isDuplicateCopy = value;
  }

  set dateAccuracy(final DateAccuracy? accuracy) {
    _dateAccuracy = accuracy;
  }

  set ranking(final int value) {
    _ranking = value;
  }

  // ────────────────────────────────────────────────────────────────
  // Internal logic
  // ────────────────────────────────────────────────────────────────

  /// Canonicality rules:
  /// - Canonical if sourcePath resides under a folder segment that starts with "Photos from YYYY)" where YYYY is 19xx or 20xx (suffix allowed until next separator), OR
  /// - Canonical if targetPath points to ALL_PHOTOS (versus Albums folders).
  ///
  /// Additional rules (extended as requested):
  /// - For the source: if the *parent folder name* contains "Photos from YYYY" (case-insensitive, where YYYY is a valid year 19xx/20xx), OR if the parent folder name is exactly "YYYY".
  /// - For the target: look at the *directory path* (excluding the filename) and return true if it contains:
  ///     * "ALL_PHOTOS" anywhere, OR
  ///     * a segment "YYYY", OR
  ///     * a structure "YYYY/MM", OR
  ///     * a segment "YYYY-MM"  (YYYY is 19xx/20xx and MM is 01..12).
  static bool _calculateCanonical(final String source, final String? target) {
    // Normalize separators to work uniformly with /.
    String norm(final String p) => p.replaceAll('\\', '/');

    // Extract parent folder name of the file from a full path.
    String parentName(final String p) {
      final n = norm(p);
      final lastSlash = n.lastIndexOf('/');
      if (lastSlash < 0) return '';
      final dir = n.substring(0, lastSlash);
      final prevSlash = dir.lastIndexOf('/');
      return prevSlash < 0 ? dir : dir.substring(prevSlash + 1);
    }

    // Extract directory path (exclude filename) from a full path.
    String dirPath(final String p) {
      final n = norm(p);
      final lastSlash = n.lastIndexOf('/');
      return lastSlash < 0 ? '' : n.substring(0, lastSlash);
    }

    // ── Source parent folder checks ────────────────────────────────
    final parent = parentName(source);
    final yearOnlyRe = RegExp(r'^(?:19|20)\d{2}$'); // exact folder "YYYY"
    final photosFromRe = RegExp(
      r'photos\s+from\s+(?:19|20)\d{2}',
      caseSensitive: false,
    ); // contains "Photos from YYYY"

    final fromYearFolder =
        yearOnlyRe.hasMatch(parent) || photosFromRe.hasMatch(parent);

    // ── Target directory checks (exclude filename) ─────────────────
    bool toAllPhotos = false;
    bool toYearStructures = false;

    if (target != null && target.isNotEmpty) {
      final dir = dirPath(target);

      // ALL_PHOTOS anywhere in the path (directory context only)
      final allPhotosPattern = RegExp(r'(?:^|/)ALL_PHOTOS(?:/|$)');
      toAllPhotos = allPhotosPattern.hasMatch(dir);

      // Year-only segment: .../YYYY/...
      final yearOnlySegment = RegExp(r'(?:^|/)(?:19|20)\d{2}(?:/|$)');

      // Year/Month structure: .../YYYY/MM/...
      final yearMonthSlash = RegExp(
        r'(?:^|/)(?:19|20)\d{2}/(?:0[1-9]|1[0-2])(?:/|$)',
      );

      // Year-Month segment: .../YYYY-MM/...
      final yearMonthDash = RegExp(
        r'(?:^|/)(?:19|20)\d{2}-(?:0[1-9]|1[0-2])(?:/|$)',
      );

      toYearStructures =
          yearOnlySegment.hasMatch(dir) ||
          yearMonthSlash.hasMatch(dir) ||
          yearMonthDash.hasMatch(dir);
    }

    return fromYearFolder || toAllPhotos || toYearStructures;
  }

  @override
  String toString() =>
      'FileEntity(sourcePath=$_sourcePath, targetPath=$_targetPath, '
      'path=$path, isCanonical=$_isCanonical, isShortcut=$_isShortcut, '
      'isMoved=$_isMoved, isDeleted=$_isDeleted, isDuplicateCopy=$_isDuplicateCopy, '
      'dateAccuracy=$_dateAccuracy, ranking=$_ranking)';
}

/// Strongly-typed album metadata for a media entity.
/// Kept minimal on purpose but easily extensible (cover, description, id, etc.).
class AlbumEntity {
  const AlbumEntity({required this.name, final Set<String>? sourceDirectories})
    : sourceDirectories = sourceDirectories ?? const {};

  /// Album display/name key (already sanitized by the discovery layer).
  final String name;

  /// Directories in the Takeout where a physical file for this album existed.
  /// Useful for diagnostics and reliable album reconstruction.
  final Set<String> sourceDirectories;

  /// Returns a new `AlbumInfo` with `dir` added to `sourceDirectories`.
  AlbumEntity addSourceDir(final String dir) {
    if (dir.isEmpty) return this;
    final next = Set<String>.from(sourceDirectories)..add(dir);
    return AlbumEntity(name: name, sourceDirectories: next);
  }

  /// Merges two AlbumInfo objects with the same album name.
  AlbumEntity merge(final AlbumEntity other) {
    if (other.name != name) return this;
    if (other.sourceDirectories.isEmpty) return this;
    final next = Set<String>.from(sourceDirectories)
      ..addAll(other.sourceDirectories);
    return AlbumEntity(name: name, sourceDirectories: next);
  }

  @override
  String toString() =>
      'AlbumInfo(name: $name, dirs: ${sourceDirectories.length})';
}

/// Helper container for normalized split.
class _SplitResult {
  const _SplitResult({
    required this.primary,
    required this.secondaries,
    required this.duplicates,
  });

  final FileEntity primary;
  final List<FileEntity> secondaries;
  final List<FileEntity> duplicates;
}
