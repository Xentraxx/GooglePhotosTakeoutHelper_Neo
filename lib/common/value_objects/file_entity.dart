// ignore_for_file: unnecessary_getters_setters
import 'dart:io';
import 'package:gpth_neo/gpth_lib_exports.dart';
import 'package:unorm_dart/unorm_dart.dart' as unorm;

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

  factory FileEntity.fromJson(final Map<String, dynamic> json) {
    String src = json['sourcePath'] is String
        ? json['sourcePath'] as String
        : '';
    String? tgt = json['targetPath'] is String
        ? json['targetPath'] as String
        : null;
    src = Platform.isWindows ? src.replaceAll('/', '\\') : src;
    if (tgt != null && tgt.isNotEmpty) {
      tgt = Platform.isWindows ? tgt.replaceAll('/', '\\') : tgt;
    }
    final int ranking = json['ranking'] is int
        ? json['ranking'] as int
        : (json['ranking'] is num ? (json['ranking'] as num).toInt() : 0);
    DateAccuracy? dateAccuracy;
    if (json['dateAccuracy'] is int) {
      dateAccuracy = DateAccuracy.fromInt(json['dateAccuracy'] as int);
    }
    return FileEntity(
      sourcePath: src,
      targetPath: tgt,
      isShortcut: json['isShortcut'] as bool? ?? false,
      isMoved: json['isMoved'] as bool? ?? false,
      isDeleted: json['isDeleted'] as bool? ?? false,
      isDuplicateCopy: json['isDuplicateCopy'] as bool? ?? false,
      dateAccuracy: dateAccuracy,
      ranking: ranking,
    );
  }

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
      photosFromYearFolderPattern,
      caseSensitive: false,
    ); // localized "Photos from YYYY"

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

  Map<String, dynamic> toJson() {
    final srcFs = _sourcePath.replaceAll('\\', '/');
    final tgtFs = _targetPath?.replaceAll('\\', '/');
    return {
      'sourcePath': srcFs,
      'targetPath': tgtFs,
      'isCanonical': _isCanonical,
      'isShortcut': _isShortcut,
      'isMoved': _isMoved,
      'isDeleted': _isDeleted,
      'isDuplicateCopy': _isDuplicateCopy,
      'dateAccuracy': _dateAccuracy?.value,
      'dateAccuracyLabel': _dateAccuracy?.description,
      'ranking': _ranking,
    };
  }
}
