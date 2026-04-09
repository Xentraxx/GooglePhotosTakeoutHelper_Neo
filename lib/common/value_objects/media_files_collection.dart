import 'dart:io';

/// Value object representing a collection of media files with their album associations
///
/// This immutable collection maintains the mapping between album names (or null for
/// year-based organization) and their corresponding files.
@Deprecated(
  'MediaFilesCollection uses the legacy Map<String?, File> model and is not '
  'used in the main pipeline. It will be removed in a future version.',
)
class MediaFilesCollection {
  /// Creates a new media files collection
  const MediaFilesCollection(this._files);

  /// Creates a collection with a single file (no album association)
  MediaFilesCollection.single(final File file) : _files = {null: file};

  /// Creates a collection from a regular map
  factory MediaFilesCollection.fromMap(final Map<String?, File> files) =>
      MediaFilesCollection(Map.unmodifiable(files));

  final Map<String?, File> _files;

  /// Gets all files in the collection
  Map<String?, File> get files => _files;

  /// Gets the first file (used for primary operations)
  File get firstFile => _files.values.first;

  /// Gets all album names (excluding null which represents year-based organization)
  Set<String> get albumNames => _files.keys.whereType<String>().toSet();

  /// Checks if this media has files in albums
  bool get hasAlbumFiles => albumNames.isNotEmpty;

  /// Checks if this media has year-based files (null key)
  bool get hasYearBasedFiles => _files.containsKey(null);

  /// Gets the file for a specific album, or null if not found
  File? getFileForAlbum(final String? albumName) => _files[albumName];

  /// Creates a new collection with an additional file/album association
  MediaFilesCollection withFile(final String? albumName, final File file) {
    final newFiles = Map<String?, File>.from(_files);
    newFiles[albumName] = file;
    return MediaFilesCollection(Map.unmodifiable(newFiles));
  }

  /// Creates a new collection with multiple additional associations
  MediaFilesCollection withFiles(final Map<String?, File> additionalFiles) {
    final newFiles = Map<String?, File>.from(_files);
    newFiles.addAll(additionalFiles);
    return MediaFilesCollection(Map.unmodifiable(newFiles));
  }

  /// Creates a new collection without a specific album association
  MediaFilesCollection withoutAlbum(final String? albumName) {
    if (!_files.containsKey(albumName)) {
      return this; // No change needed
    }

    final newFiles = Map<String?, File>.from(_files);
    newFiles.remove(albumName);
    return MediaFilesCollection(Map.unmodifiable(newFiles));
  }

  /// Number of file associations
  int get length => _files.length;

  /// Whether the collection is empty
  bool get isEmpty => _files.isEmpty;

  /// Whether the collection is not empty
  bool get isNotEmpty => _files.isNotEmpty;

  /// Gets the album key for duplicate removal grouping
  ///
  /// Returns the first album name found, or null if the media is only in year folders.
  /// This is used to group media by album for album-aware duplicate removal.
  // ignore: prefer_expression_function_bodies
  String? getAlbumKey() {
    // Return the first album name found, or null for year-based files
    return albumNames.isNotEmpty ? albumNames.first : null;
  }

  @override
  bool operator ==(final Object other) {
    if (identical(this, other)) return true;
    if (other is! MediaFilesCollection) return false;

    if (_files.length != other._files.length) return false;

    for (final entry in _files.entries) {
      final otherFile = other._files[entry.key];
      if (otherFile == null || otherFile.path != entry.value.path) {
        return false;
      }
    }

    return true;
  }

  @override
  int get hashCode => Object.hashAll(
    _files.entries.map((final e) => Object.hash(e.key, e.value.path)),
  );
  @override
  String toString() {
    final albumInfo = albumNames.isNotEmpty ? ', albums: $albumNames' : '';
    return 'MediaFilesCollection(${firstFile.path}$albumInfo)';
  }
}
