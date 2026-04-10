/// Application constants and default values
///
/// Extracted from utils.dart to provide a single source of truth
/// for all application constants.
library;

/// Application version
const String version = '5.2.0';

/// Multilingual Google Photos "Photos from" prefixes used in Takeout year folders.
/// Keep this as the single source of truth for year-folder language variants.
const String photosFromPrefixPattern =
    r'Photos from|Fotos del|Fotos von|Foto da|Foto_s van';

/// Regex pattern for localized year folders like "Photos from 2024".
const String photosFromYearFolderPattern =
    '^(?:$photosFromPrefixPattern) \\d{4}\$';

/// Special folders
const List<String> specialFolders = <String>[
  'locked folder', // EN only
  'archive', // EN
  'trash', // EN
  'archivo', // ES
  'papelera', // ES (trash)
  'arquivo', // PT
  'lixeira', // PT (trash)
  'archivio', // IT
  'cestino', // IT (trash)
  'archive', // FR
  'corbeille', // FR (trash)
  'archiv', // DE
  'archivieren', // DE (wrong translation of google photos)
  'papierkorb', // DE (trash)
  'archief', // NL
  'archiveren', // NL (wrong translation of google photos)
  'prullenbak', // NL (trash)
  'архив', // RU
  'корзина', // RU (trash)
  'archiwum', // PL
  'kosz', // PL (trash)
  '档案', // ZH (archive)
  '回收站', // ZH (trash)
  'アーカイブ', // JA
  'ゴミ箱', // JA (trash)
  'arxiu', // CA
  'paperera', // CA (trash)
];

/// Untitled albums folders
const List<String> untitledAlbums = <String>[
  'untitled', // EN
  'unknown', // EN
  'desconocido', // ES
  'sin título', // ES
  'desconhecido', // PT
  'sem título', // PT
  'sconosciuto', // IT
  'senza nome', // IT
  'inconnu', // FR
  'sans titre', // FR
  'unbenannt', // DE
  'ohne titel', // DE
  'onbekend', // NL
  'naamloos', // NL
  'неизвестный', // RU
  'без названия', // RU
  'nieznany', // PL
  'bez tytułu', // PL
  '未知', // ZH
  '无标题', // ZH
  '不明', // JA
  '無題', // JA
  'desconegut', // CA
  'sense títol', // CA
];

/// File extensions for additional media formats not covered by MIME types
class MediaExtensions {
  /// Raw camera formats and special video formats
  static const List<String> additional = <String>['.mp', '.mv', '.dng', '.cr2'];
}

/// Default width for progress bars in console output
const int defaultBarWidth = 40;

/// Default maximum file size for processing (64MB)
const int defaultMaxFileSize = 64 * 1024 * 1024;

/// Processing limits and thresholds
class ProcessingLimits {
  /// Chunk size for streaming hash calculations
  static const int hashChunkSize = 64 * 1024; // 64KB

  /// Buffer size for file I/O operations
  static const int ioBufferSize = 8 * 1024; // 8KB
}

/// Safely converts a [double] to [int], returning [fallback] when the value
/// is NaN or Infinity (e.g. from a division by zero).
int safeToInt(final double value, {final int fallback = 0}) {
  if (value.isNaN || value.isInfinite) return fallback;
  return value.toInt();
}

/// Like [safeToInt] but rounds instead of truncating.
int safeRoundToInt(final double value, {final int fallback = 0}) {
  if (value.isNaN || value.isInfinite) return fallback;
  return value.round();
}

/// Application exit codes
class ExitCodes {
  /// Normal exit
  static const int success = 0;

  /// General error
  static const int error = 1;

  /// Invalid arguments
  static const int invalidArgs = 2;

  /// File not found
  static const int fileNotFound = 3;

  /// Permission denied
  static const int permissionDenied = 4;

  /// ExifTool not found
  static const int exifToolNotFound = 5;

  /// Input folder does not exist or is invalid
  static const int inputValidationError = 11;

  /// ZIP extraction failed during late extraction step
  static const int zipExtractionFailed = 12;

  /// Output directory is not empty and auto-clean was refused
  static const int outputNotEmpty = 13;
}

/// Album behaviour options presented to the user in CLI / interactive mode.
///
/// Keys are the CLI option strings; values are the human-readable descriptions
/// shown in `--help` output and in the interactive prompt.
const Map<String, String> kAlbumOptions = <String, String>{
  'shortcut':
      '[Recommended] Album folders with symlinks to original photos\n'
      'Recommended as it will take the least space and provides better compability\n'
      'with cloud services and file type detection\n',
  'reverse-shortcut':
      'Album folders with ORIGINAL photos. "ALL_PHOTOS" folder \n'
      'with shortcuts/symlinks to albums. If a photo is in an album, \n'
      'the original is saved. CAUTION: If a photo is in multiple albums, it will \n'
      'be duplicated in the other albums, and the shortcuts/symlinks in \n'
      '"ALL_PHOTOS" will point only to one album.\n',
  'duplicate-copy':
      'Album folders with photos copied into them. \n'
      'This will work across all systems, but may take wayyy more space!!\n',
  'json':
      'Put ALL photos (including Archive and Trash) in one folder and \n'
      'make a .json file with info about albums. \n'
      "Use if you're a programmer, or just want to get everything, \n"
      'ignoring lack of year-folders etc.\n'
      'WARNING: This moves Archive/Trash into ALL_PHOTOS!!!\n',
  'nothing':
      'Just ignore them and put year-photos into one folder. \n'
      'WARNING: This moves Archive/Trash into ALL_PHOTOS!!!\n',
  'ignore':
      'Ignore albums completely. Canonical files go to ALL_PHOTOS; \n'
      'non-canonical files are deleted (not moved or copied to albums). \n'
      'Use when you do not want any album representation.\n'
      'WARNING: This ignores Archive/Trash !!!\n',
};
