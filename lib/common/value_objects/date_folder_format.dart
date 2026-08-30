import 'package:path/path.dart' as path;

/// Value object representing a custom date-based folder structure template
/// for the `--divide-to-dates` flag (issue #142).
///
/// Allows users to specify arbitrary folder hierarchies such as `yyyy/yyyy-mm`
/// instead of being limited to the predefined 0/1/2/3 presets (none/year/month/day).
///
/// ## Token syntax (case-insensitive)
///
/// | Token | Meaning            | Example (2026-08-30) |
/// |-------|--------------------|----------------------|
/// | `yyyy`| 4-digit year       | `2026`               |
/// | `yy`  | 2-digit year       | `26`                 |
/// | `mm`  | zero-padded month | `08`                 |
/// | `dd`  | zero-padded day    | `30`                 |
///
/// Folder names are date-only, so `mm`/`MM` are unambiguously "month" (no
/// time component to conflict with minutes).
///
/// `/` is treated as a path-component separator; any other characters
/// (`-`, `_`, `.`, spaces, …) are kept as literal text within a folder name.
/// Each path component is sanitized against illegal filename characters.
///
/// Example: `yyyy/yyyy-mm` → `2026/2026-08` (two folder levels).
class DateFolderFormat {
  /// Creates a date folder format from a validated template string.
  ///
  /// Prefer [parse] / [tryParse] for input validation. This constructor
  /// trusts the caller to pass an already-validated template.
  const DateFolderFormat(this.template);

  /// The raw template string (e.g. `yyyy/yyyy-mm`).
  final String template;

  /// Regex matching the recognized tokens (case-insensitive).
  ///
  /// `yyyy` is listed before `yy` so the longer token wins during replacement.
  static final RegExp _tokenRegex = RegExp(
    r'yyyy|yy|mm|dd',
    caseSensitive: false,
  );

  /// Generates the relative folder path for [date] using this template.
  ///
  /// Returns a platform-appropriate relative path (components joined with
  /// `path.separator` via [path.join]). Each component is sanitized to strip
  /// illegal filename characters.
  ///
  /// Example: template `yyyy/yyyy-mm` with date `2026-08-30` returns
  /// `2026${separator}2026-08`.
  String generateFolderPath(final DateTime date) {
    final String substituted = template.replaceAllMapped(_tokenRegex, (
      final Match m,
    ) {
      switch (m.group(0)!.toLowerCase()) {
        case 'yyyy':
          return '${date.year}';
        case 'yy':
          return (date.year % 100).toString().padLeft(2, '0');
        case 'mm':
          return date.month.toString().padLeft(2, '0');
        case 'dd':
          return date.day.toString().padLeft(2, '0');
        default:
          // Unreachable: the regex only matches the four tokens above.
          return m.group(0)!;
      }
    });

    // Split on `/` into path components, sanitize each, drop empties, re-join.
    final List<String> components = substituted
        .split('/')
        .map((final String c) => _sanitizePathComponent(c))
        .where((final String c) => c.isNotEmpty)
        .toList();

    return path.joinAll(components);
  }

  /// Parses a custom date folder format template string.
  ///
  /// Throws [FormatException] if [input] is empty or contains no recognized
  /// token (`yyyy`/`yy`/`mm`/`dd`, case-insensitive).
  ///
  /// Note: this does NOT reject the 0-3 preset integers — callers should
  /// check for presets first via [isPreset] and route them to
  /// [DateDivisionLevel.fromInt].
  static DateFolderFormat parse(final String input) {
    final String trimmed = input.trim();
    if (trimmed.isEmpty) {
      throw const FormatException('Date folder format cannot be empty');
    }
    if (!_tokenRegex.hasMatch(trimmed)) {
      throw FormatException(
        'Date folder format "$input" contains no recognized token. '
        'Use yyyy, yy, mm, dd (e.g. "yyyy/yyyy-mm").',
      );
    }
    return DateFolderFormat(trimmed);
  }

  /// Parses [input] like [parse] but returns `null` on failure instead of
  /// throwing. Convenient for validation loops in interactive mode.
  static DateFolderFormat? tryParse(final String input) {
    try {
      return parse(input);
    } on FormatException {
      return null;
    }
  }

  /// Returns `true` if [input] is one of the legacy 0-3 presets (so callers
  /// can route them to [DateDivisionLevel.fromInt] instead of custom parsing).
  static bool isPreset(final String input) {
    final String trimmed = input.trim();
    return trimmed == '0' || trimmed == '1' || trimmed == '2' || trimmed == '3';
  }

  /// Sanitizes a single path component by replacing illegal filename
  /// characters with `_`. Mirrors the logic in
  /// `PathGeneratorService.sanitizeFileName`.
  static String _sanitizePathComponent(final String component) => component
      .replaceAll(RegExp(r'[<>:"/\\|?*]'), '_')
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim();

  @override
  String toString() => template;

  @override
  bool operator ==(final Object other) =>
      other is DateFolderFormat && other.template == template;

  @override
  int get hashCode => template.hashCode;
}

/// The result of an interactive date-division prompt: either a legacy
/// 0-3 preset ([DateDivisionLevel]) or a custom [DateFolderFormat] (issue #142).
///
/// Exactly one of [preset] / [custom] is non-null.
class DateDivisionSelection {
  const DateDivisionSelection._({this.preset, this.custom});

  /// A legacy preset selection (0-3).
  factory DateDivisionSelection.preset(final int value) =>
      DateDivisionSelection._(preset: value);

  /// A custom format selection.
  factory DateDivisionSelection.custom(final DateFolderFormat format) =>
      DateDivisionSelection._(custom: format);

  final int? preset;
  final DateFolderFormat? custom;

  /// Whether this is a custom (non-preset) selection.
  bool get isCustom => custom != null;

  @override
  bool operator ==(final Object other) =>
      other is DateDivisionSelection &&
      other.preset == preset &&
      other.custom == custom;

  @override
  int get hashCode => Object.hash(preset, custom);

  @override
  String toString() =>
      custom != null ? 'custom(${custom!.template})' : 'preset($preset)';
}
