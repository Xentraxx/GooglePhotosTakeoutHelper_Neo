/// Strongly-typed album metadata for a media entity.
/// Kept minimal on purpose but easily extensible (cover, description, id, etc.).
class AlbumEntity {
  const AlbumEntity({required this.name, final Set<String>? sourceDirectories})
    : sourceDirectories = sourceDirectories ?? const {};

  factory AlbumEntity.fromJson(final Map<String, dynamic> json) {
    final name = json['name'] is String ? json['name'] as String : '';
    final dirs = json['sourceDirectories'] is List
        ? Set<String>.from(
            (json['sourceDirectories'] as List).map((final e) => '$e'),
          )
        : const <String>{};
    return AlbumEntity(name: name, sourceDirectories: dirs);
  }

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

  Map<String, dynamic> toJson() => {
    'name': name,
    'sourceDirectories': sourceDirectories.toList(growable: false),
  };
}
