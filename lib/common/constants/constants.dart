/// Application constants and default values
///
/// Extracted from utils.dart to provide a single source of truth
/// for all application constants.
library;

/// Application version
const String version = '5.1.0';

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
  'papierkorb', // DE (trash)
  'archief', // NL
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
  'senza titolo', // IT
  'inconnu', // FR
  'sans titre', // FR
  'Unbenannt', // DE
  'ohne titel', // DE
  'onbekend', // NL
  'zonder titel', // NL
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
}
